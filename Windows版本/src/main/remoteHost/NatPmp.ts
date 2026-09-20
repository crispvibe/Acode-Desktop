// NatPmp —— NAT-PMP（RFC 6886）客户端：拿默认网关 UDP:5351，
// 先 external-address 拿路由器 WAN IP，再 TCP mapping 把内部端口映射到外部端口。
// lifetime/2 续期由 WanEndpointPublisher 调度。
//
// codec（encode/decode）是纯函数可单测；网络层通过 `sendUdp` 注入便于测试。

import dgram from "node:dgram";

export const NAT_PMP_PORT = 5351;
const NAT_PMP_VERSION = 0;
const OP_EXTERNAL_ADDRESS = 0;
const OP_MAP_TCP = 2;
const RESPONSE_FLAG = 0x80;
/** RFC 6886 §3.1：首次重传 250ms，每次翻倍。默认 4 次尝试 ≈ 1.9s。 */
const DEFAULT_FIRST_TIMEOUT_MS = 250;
const DEFAULT_ATTEMPTS = 4;

export class NatPmpError extends Error {
  constructor(
    message: string,
    readonly resultCode: number | null = null
  ) {
    super(message);
    this.name = "NatPmpError";
  }
}

export interface NatPmpMapping {
  internalPort: number;
  externalPort: number;
  lifetimeSeconds: number;
  epochSeconds: number;
}

export function encodeExternalAddressRequest(): Buffer {
  return Buffer.from([NAT_PMP_VERSION, OP_EXTERNAL_ADDRESS]);
}

/** 应答：ver(1) op(1) result(2) epoch(4) externalIp(4)。 */
export function decodeExternalAddressResponse(message: Buffer): { externalIp: string; epochSeconds: number } {
  if (message.length < 12) throw new NatPmpError("NAT-PMP 应答过短");
  if (message[0] !== NAT_PMP_VERSION || message[1] !== (OP_EXTERNAL_ADDRESS | RESPONSE_FLAG)) {
    throw new NatPmpError("NAT-PMP 应答 op 不匹配");
  }
  const resultCode = message.readUInt16BE(2);
  if (resultCode !== 0) throw new NatPmpError(`NAT-PMP external-address 失败（code=${resultCode}）`, resultCode);
  return {
    externalIp: `${message[8]}.${message[9]}.${message[10]}.${message[11]}`,
    epochSeconds: message.readUInt32BE(4)
  };
}

export function encodeTcpMappingRequest(internalPort: number, suggestedExternalPort: number, lifetimeSeconds: number): Buffer {
  const message = Buffer.alloc(12);
  message[0] = NAT_PMP_VERSION;
  message[1] = OP_MAP_TCP;
  message.writeUInt16BE(0, 2);
  message.writeUInt16BE(internalPort & 0xffff, 4);
  message.writeUInt16BE(suggestedExternalPort & 0xffff, 6);
  message.writeUInt32BE(lifetimeSeconds >>> 0, 8);
  return message;
}

/** 应答：ver(1) op(1) result(2) epoch(4) internalPort(2) externalPort(2) lifetime(4)。 */
export function decodeMappingResponse(message: Buffer): NatPmpMapping {
  if (message.length < 16) throw new NatPmpError("NAT-PMP 应答过短");
  if (message[0] !== NAT_PMP_VERSION || message[1] !== (OP_MAP_TCP | RESPONSE_FLAG)) {
    throw new NatPmpError("NAT-PMP 应答 op 不匹配");
  }
  const resultCode = message.readUInt16BE(2);
  if (resultCode !== 0) throw new NatPmpError(`NAT-PMP mapping 失败（code=${resultCode}）`, resultCode);
  return {
    internalPort: message.readUInt16BE(8),
    externalPort: message.readUInt16BE(10),
    lifetimeSeconds: message.readUInt32BE(12),
    epochSeconds: message.readUInt32BE(4)
  };
}

/** 发一个 UDP 请求并等一条应答；超时 reject。 */
export type UdpExchange = (payload: Buffer, port: number, host: string, timeoutMs: number) => Promise<Buffer>;

function dgramExchange(payload: Buffer, port: number, host: string, timeoutMs: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket("udp4");
    const timer = setTimeout(() => {
      socket.close();
      reject(new NatPmpError("NAT-PMP 应答超时"));
    }, timeoutMs);
    socket.once("error", (error) => {
      clearTimeout(timer);
      socket.close();
      reject(error);
    });
    socket.once("message", (message) => {
      clearTimeout(timer);
      socket.close();
      resolve(message);
    });
    socket.send(payload, port, host, (error) => {
      if (error) {
        clearTimeout(timer);
        socket.close();
        reject(error);
      }
    });
  });
}

export class NatPmpClient {
  private readonly exchange: UdpExchange;
  private readonly firstTimeoutMs: number;
  private readonly attempts: number;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly gateway: string,
    options: { exchange?: UdpExchange; firstTimeoutMs?: number; attempts?: number } = {}
  ) {
    this.exchange = options.exchange ?? dgramExchange;
    this.firstTimeoutMs = options.firstTimeoutMs ?? DEFAULT_FIRST_TIMEOUT_MS;
    this.attempts = options.attempts ?? DEFAULT_ATTEMPTS;
  }

  /** 路由器 WAN 侧 IPv4（用于 CGNAT 自检与对外发布）。 */
  getExternalAddress(): Promise<{ externalIp: string; epochSeconds: number }> {
    return this.enqueue(() => this.request(encodeExternalAddressRequest(), decodeExternalAddressResponse));
  }

  /** 建 TCP 映射；suggestedExternalPort=0 表示由路由器挑一个高位端口。 */
  mapTcp(internalPort: number, suggestedExternalPort: number, lifetimeSeconds: number): Promise<NatPmpMapping> {
    return this.enqueue(() =>
      this.request(encodeTcpMappingRequest(internalPort, suggestedExternalPort, lifetimeSeconds), decodeMappingResponse)
    );
  }

  /** 同一 socket 复用语义下串行化请求（发布循环本身串行，这里兜底并发调用）。 */
  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const next = this.chain.then(work, work);
    this.chain = next.catch(() => undefined);
    return next;
  }

  private async request<T>(payload: Buffer, decode: (message: Buffer) => T): Promise<T> {
    let timeoutMs = this.firstTimeoutMs;
    let lastError: unknown = new NatPmpError("NAT-PMP 请求失败");
    for (let attempt = 0; attempt < this.attempts; attempt += 1) {
      try {
        const message = await this.exchange(payload, NAT_PMP_PORT, this.gateway, timeoutMs);
        return decode(message);
      } catch (error) {
        lastError = error;
        // 协议层错误（非 0 resultCode / op 不匹配）重试无意义，立即抛出。
        if (error instanceof NatPmpError && error.resultCode !== null) throw error;
        timeoutMs *= 2;
      }
    }
    throw lastError;
  }
}
