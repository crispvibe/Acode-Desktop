// UpnpIgd —— UPnP IGD 兜底：SSDP M-SEARCH 找 InternetGatewayDevice，
// 取设备描述里 WANIPConnection/WANPPPConnection 的 controlURL，
// 用 SOAP GetExternalIPAddress / AddPortMapping 建 TCP 端口映射。
// NAT-PMP 不通时由 WanEndpointPublisher 回退到这里。
//
// 网络面收敛在 `UpnpTransport`（可注入 fake 做全链路单测）；XML/SSDP 解析是纯函数。

import dgram from "node:dgram";
import http from "node:http";
import { isIPv4 } from "node:net";

const SSDP_ADDRESS = "239.255.255.250";
const SSDP_PORT = 1900;
const IGD_DEVICE_ST = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";
const WAN_SERVICE_PATTERN = /WANIPConnection|WANPPPConnection/;
const DEFAULT_TIMEOUT_MS = 3_000;

export interface IgdControlPoint {
  /** 绝对 SOAP control URL。 */
  controlUrl: string;
  /** WANIPConnection:1 或 WANPPPConnection:1 等完整 serviceType。 */
  serviceType: string;
}

/** 网络传输注入面：SSDP 查询返回 LOCATION 列表；fetchText/postXml 走普通 HTTP。 */
export interface UpnpTransport {
  ssdpLocations(timeoutMs: number): Promise<string[]>;
  fetchText(url: string, timeoutMs: number): Promise<string>;
  postXml(url: string, headers: Record<string, string>, body: string, timeoutMs: number): Promise<{ status: number; body: string }>;
}

export class UpnpError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UpnpError";
  }
}

// MARK: - 纯解析（可单测）

/** 从 SSDP 响应头里取 LOCATION。 */
export function parseSsdpLocation(responseText: string): string | null {
  for (const line of responseText.split(/\r?\n/)) {
    const match = /^location\s*:\s*(\S+)\s*$/i.exec(line);
    if (match) return match[1];
  }
  return null;
}

function xmlTag(xml: string, tag: string): string | null {
  const match = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, "i").exec(xml);
  return match ? match[1].trim() : null;
}

/** 从 IGD 设备描述 XML 提取 WAN 连接服务的 controlURL（相对地址按 base 解析）。 */
export function parseIgdControlPoint(deviceXml: string, baseUrl: string): IgdControlPoint | null {
  const serviceBlocks = deviceXml.match(/<service>[\s\S]*?<\/service>/gi) ?? [];
  let fallback: IgdControlPoint | null = null;
  for (const block of serviceBlocks) {
    const serviceType = xmlTag(block, "serviceType");
    const controlPath = xmlTag(block, "controlURL");
    if (!serviceType || !controlPath || !WAN_SERVICE_PATTERN.test(serviceType)) continue;
    let controlUrl: string;
    try {
      controlUrl = new URL(controlPath, baseUrl).toString();
    } catch {
      continue;
    }
    const point = { controlUrl, serviceType };
    // WANIPConnection 优先于 WANPPPConnection。
    if (/WANIPConnection/.test(serviceType)) return point;
    fallback ??= point;
  }
  return fallback;
}

/** SOAP 应答里取指定 tag 的文本（含 Fault 时由调用方先判 fault）。 */
export function parseSoapTag(xml: string, tag: string): string | null {
  return xmlTag(xml, tag);
}

export function isSoapFault(xml: string): boolean {
  return /<(\w+:)?Fault[\s>]/i.test(xml);
}

// MARK: - 默认传输实现

function ssdpLocations(timeoutMs: number): Promise<string[]> {
  const query = [
    "M-SEARCH * HTTP/1.1",
    `HOST: ${SSDP_ADDRESS}:${SSDP_PORT}`,
    'MAN: "ssdp:discover"',
    "MX: 1",
    `ST: ${IGD_DEVICE_ST}`,
    "",
    ""
  ].join("\r\n");
  return new Promise((resolve) => {
    const socket = dgram.createSocket({ type: "udp4", reuseAddr: true });
    const locations = new Set<string>();
    const finish = () => {
      try {
        socket.close();
      } catch {
        // ignore
      }
      resolve([...locations]);
    };
    const timer = setTimeout(finish, timeoutMs);
    socket.once("error", () => {
      clearTimeout(timer);
      finish();
    });
    socket.on("message", (message) => {
      const location = parseSsdpLocation(message.toString("utf8"));
      if (location) locations.add(location);
    });
    socket.send(query, SSDP_PORT, SSDP_ADDRESS, (error) => {
      if (error) {
        clearTimeout(timer);
        finish();
      }
    });
  });
}

function fetchText(url: string, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { timeout: timeoutMs }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      response.on("error", reject);
    });
    request.on("timeout", () => {
      request.destroy(new UpnpError("UPnP 请求超时"));
    });
    request.on("error", reject);
  });
}

function postXml(
  url: string,
  headers: Record<string, string>,
  body: string,
  timeoutMs: number
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const request = http.request(
      {
        hostname: target.hostname,
        port: target.port || 80,
        path: `${target.pathname}${target.search}`,
        method: "POST",
        timeout: timeoutMs,
        headers: {
          "Content-Type": 'text/xml; charset="utf-8"',
          "Content-Length": Buffer.byteLength(body),
          ...headers
        }
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
        response.on("error", reject);
      }
    );
    request.on("timeout", () => {
      request.destroy(new UpnpError("UPnP 请求超时"));
    });
    request.on("error", reject);
    request.end(body);
  });
}

const defaultTransport: UpnpTransport = { ssdpLocations, fetchText, postXml };

// MARK: - client

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function soapEnvelope(serviceType: string, action: string, args: Record<string, string>): string {
  const entries = Object.entries(args)
    .map(([key, value]) => `<${key}>${escapeXml(value)}</${key}>`)
    .join("");
  return (
    '<?xml version="1.0"?>' +
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
    `<s:Body><u:${action} xmlns:u="${escapeXml(serviceType)}">${entries}</u:${action}></s:Body></s:Envelope>`
  );
}

export class UpnpIgdClient {
  private readonly transport: UpnpTransport;
  private readonly timeoutMs: number;

  constructor(options: { transport?: UpnpTransport; timeoutMs?: number } = {}) {
    this.transport = options.transport ?? defaultTransport;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /** SSDP 发现 + 设备描述解析，拿到 WAN 连接的 control point；找不到返回 null。 */
  async discoverControlPoint(): Promise<IgdControlPoint | null> {
    const locations = await this.transport.ssdpLocations(this.timeoutMs);
    for (const location of locations) {
      let xml: string;
      try {
        xml = await this.transport.fetchText(location, this.timeoutMs);
      } catch {
        continue;
      }
      const point = parseIgdControlPoint(xml, location);
      if (point) return point;
    }
    return null;
  }

  /** 路由器上报的外部 IPv4（用于 CGNAT 自检）。 */
  async getExternalIpAddress(point: IgdControlPoint): Promise<string | null> {
    const body = await this.soapCall(point, "GetExternalIPAddress", {});
    const value = parseSoapTag(body, "NewExternalIPAddress");
    return value && isIPv4(value) ? value : null;
  }

  /**
   * 建 TCP 映射。先按带租约请求；部分 IGD 只接受永久租约（lease=0），
   * SOAP Fault 时降级重试一次 lease=0。
   */
  async addTcpPortMapping(
    point: IgdControlPoint,
    options: { internalClient: string; internalPort: number; externalPort: number; leaseSeconds: number; description: string }
  ): Promise<{ externalPort: number; leaseSeconds: number }> {
    const args = {
      NewRemoteHost: "",
      NewExternalPort: String(options.externalPort),
      NewProtocol: "TCP",
      NewInternalPort: String(options.internalPort),
      NewInternalClient: options.internalClient,
      NewEnabled: "1",
      NewPortMappingDescription: options.description,
      NewLeaseDuration: String(options.leaseSeconds)
    };
    try {
      await this.soapCall(point, "AddPortMapping", args);
      return { externalPort: options.externalPort, leaseSeconds: options.leaseSeconds };
    } catch (error) {
      if (options.leaseSeconds === 0) throw error;
      await this.soapCall(point, "AddPortMapping", { ...args, NewLeaseDuration: "0" });
      return { externalPort: options.externalPort, leaseSeconds: 0 };
    }
  }

  private async soapCall(point: IgdControlPoint, action: string, args: Record<string, string>): Promise<string> {
    const response = await this.transport.postXml(
      point.controlUrl,
      { SOAPAction: `"${point.serviceType}#${action}"` },
      soapEnvelope(point.serviceType, action, args),
      this.timeoutMs
    );
    if (response.status < 200 || response.status >= 300 || isSoapFault(response.body)) {
      const detail = parseSoapTag(response.body, "errorDescription") ?? `HTTP ${response.status}`;
      throw new UpnpError(`UPnP ${action} 失败：${detail}`);
    }
    return response.body;
  }
}
