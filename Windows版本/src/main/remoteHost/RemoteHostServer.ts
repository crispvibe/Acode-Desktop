// RemoteHostServer（Windows host）—— 移植自 Mac 的 `RemoteChatServer.swift`
// 的传输 + 广播职责（去掉 legacy/WebRTC 路径，只保留一期需要的 VNC 协议）。
//
// 职责（纯传输层，不含面板逻辑）：
//   1. 起 https+wss 服务器（自签 ECDSA P-256 证书，客户端走 SPKI pin 校验）；
//      LAN/WAN 同一套 wss+Bearer 鉴权（契约 §4.1/§4.2）。
//   2. 维护每条连接的 focus（focusedSessionId / isResolvingDraftSession）。
//   3. 把 broadcaster 产出的 PanelStateEnvelope 按 focus fanout 给匹配的连接。
//   4. 解析手机来的 `command` / `resume` 帧，交给 delegate（RemoteHostController）
//      处理面板逻辑，回 `command_ack` / `panel_state`。
//
// HTTP 端点契约（§4.2）：/health、/pair 不鉴权（/pair 仅私网来源），
// /connect_info 与其余 HTTP + WS upgrade 一律 Bearer。
// 面板逻辑（snapshot 组装、命令应用）由 delegate 提供。

import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import type { Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket, type RawData } from "ws";

import { isLoopbackAddress, isPrivateSourceAddress } from "./ipRanges.js";
import {
  AUTH_FAILURES_PER_CONNECTION_LIMIT,
  type PairingService
} from "./PairingService.js";

import {
  attachmentUploadRequestSchema,
  commandSchema,
  recoveryErrorResponse,
  recoveryOkResponse,
  recoveryRequestSchema,
  remoteRecoveryLimits,
  remoteVNCFrameType,
  resumeRequestSchema,
  type CommandAck,
  type PanelStatePatch,
  type PanelStateSnapshot,
  type RecoveryRequest,
  type RemoteCommand
} from "../../shared/remoteProtocol.js";
import { storeUploadedAttachment } from "./AttachmentStore.js";
import type { PanelStateEnvelope, ReplayPayload } from "./PanelStateBroadcaster.js";

/** 单条 WS 消息上限，对齐 Mac 的 25MB（含附件的命令帧）。 */
const MAX_FRAME_BYTES = 25 * 1024 * 1024;

/** HTTP `POST /attachments` 请求体上限：base64(10MB) + 64KB JSON 余量，对齐 Mac 的附件帧上限。 */
const MAX_HTTP_BODY_BYTES = remoteRecoveryLimits.maximumTextFrameUTF8Bytes;

/** `POST /pair` 请求体上限：{code, deviceName} 只有几十字节，4KB 足够。 */
const MAX_PAIR_BODY_BYTES = 4 * 1024;

/** 命令应用结果（delegate → server）。对应 Mac `RemoteChatCommandRouter.Dispatch`。 */
export interface RemoteHostCommandDispatch {
  /** 要回给手机的 ack。 */
  ack: CommandAck;
  /** 是否更新本连接的 focus。 */
  shouldUpdateFocusedSessionId: boolean;
  /** 新的 focus（仅在 shouldUpdateFocusedSessionId 为真时使用）。 */
  newFocusedSessionId: string | null;
  /** 命令导致 focus 切换时，是否需要立刻补推一份当前 focus 的全量 snapshot。 */
  shouldPushSnapshotForFocus: boolean;
}

/** 面板逻辑代理：由 RemoteHostController 实现，桥接渲染进程与 broadcaster。 */
export interface RemoteHostServerDelegate {
  /** 把手机来的命令转给渲染进程执行，返回 ack 与 focus 变更。 */
  applyCommand(command: RemoteCommand, focusedSessionId: string | null): Promise<RemoteHostCommandDispatch>;
  /** resume 路径：给定 (sessionId, lastRevision) 返回 patch 链或全量 snapshot。 */
  replayPayload(sessionId: string | null, lastRevision: number | null): ReplayPayload;
  /** 取某会话最新 snapshot（focus 补推 / resume 兜底）。 */
  snapshotFor(sessionId: string | null): PanelStateSnapshot | null;
}

/** 对外发布的候选 endpoint（契约 §4.4 eps 元素）。 */
export interface RemoteHostEndpoint {
  a: string;
  p: number;
}

/** TLS 材料：selfsigned 生成的 ECDSA P-256 自签证书 + SPKI-SHA256 指纹。 */
export interface RemoteHostTlsMaterial {
  certPem: string;
  keyPem: string;
  fingerprintHex: string;
}

export interface RemoteHostServerConfig {
  port: number;
  /** true：绑 0.0.0.0 接受局域网/WAN 连接；false：只绑 127.0.0.1。 */
  bindLAN: boolean;
  /** host 自签证书身份（https+wss）。 */
  tls: RemoteHostTlsMaterial;
  /** Bearer 鉴权 + 配对码兑换。 */
  pairing: PairingService;
  /** 当前对外发布的 eps（/pair、/connect_info 响应）。 */
  endpoints: () => RemoteHostEndpoint[];
  /** /health、/pair 响应里的主机名。 */
  hostName: string;
}

export interface RemoteHostServerCallbacks {
  /** 连接数变化（连/断）。 */
  onConnectionsChanged?: (activeConnectionCount: number) => void;
  /** 运行期错误（端口占用、监听失败等）。 */
  onError?: (error: Error) => void;
}

/**
 * 连接传输出口抽象：WS 连接与隧道虚拟连接都实现它，使命令/广播管道与具体传输解耦。
 * - WS：`send` 走 `ws.send`，`isOpen` 看 readyState，`close` 走 `ws.close`。
 * - 隧道：`send` 走 `signaling.sendTunnelFrame`，`isOpen` 看会话是否仍在，`close` 由 responder 管理。
 */
export interface HostConnectionSink {
  send(text: string): void;
  isOpen(): boolean;
  close?(): void;
}

/** 单连接运行态（传输无关）。 */
export class HostConnection {
  focusedSessionId: string | null = null;
  /**
   * newDraftSession 会让连接先 focus 到一个乐观 draft UUID，随后控制器才会
   * 发出真正的会话 UUID。允许一次 focus 重映射，避免严格 fanout 把新流丢掉。
   */
  isResolvingDraftSession = false;
  /** 串行化本连接的入站命令处理，保证顺序（对应 Mac inboundTaskByConnection）。 */
  inboundChain: Promise<void> = Promise.resolve();

  constructor(private readonly sink: HostConnectionSink) {}

  get isOpen(): boolean {
    return this.sink.isOpen();
  }

  send(value: unknown): void {
    if (!this.sink.isOpen()) return;
    try {
      this.sink.send(JSON.stringify(value));
    } catch {
      // ignore send failure；断开会由 close/error 处理
    }
  }

  closeSink(): void {
    try {
      this.sink.close?.();
    } catch {
      // ignore
    }
  }
}

function snapshotEnvelope(snapshot: PanelStateSnapshot): PanelStateEnvelope {
  return {
    type: "panel_state",
    kind: "snapshot",
    sessionId: snapshot.sessionId,
    revision: snapshot.revision,
    snapshot
  };
}

function patchEnvelope(patch: PanelStatePatch): PanelStateEnvelope {
  return {
    type: "panel_state",
    kind: "patch",
    sessionId: patch.sessionId,
    revision: patch.revision,
    patch
  };
}

function errorAck(commandId: string, message: string, sessionId: string | null): CommandAck {
  return {
    type: remoteVNCFrameType.commandAck,
    commandId,
    status: "error",
    message,
    sessionId
  };
}

/** 从原始帧里尽量抠出 commandId，让解析失败时也能给出可结算的 ack。 */
function probeCommandId(raw: unknown): string | null {
  if (raw && typeof raw === "object" && "commandId" in raw) {
    const value = (raw as { commandId?: unknown }).commandId;
    if (typeof value === "string" && value.length > 0) return value;
  }
  return null;
}

/** 从原始 recovery 帧里尽量抠出 requestId，让解析/限流失败时也能回一条可结算的错误响应。 */
function probeRequestId(raw: unknown): string | null {
  if (raw && typeof raw === "object" && "requestId" in raw) {
    const value = (raw as { requestId?: unknown }).requestId;
    if (typeof value === "string" && value.length > 0) return value;
  }
  return null;
}

/** 请求体超过上限时抛出，供 HTTP 端点回 413。 */
class PayloadTooLargeError extends Error {}

/**
 * 读取 HTTP 请求体并按上限限流：超过 maxBytes 抛 PayloadTooLargeError。
 * 不 destroy socket——由调用方回 413 + `Connection: close`（先写响应再关连接，
 * 否则 destroyed socket 上写响应会触发未处理的 error 事件）。
 */
function readRequestBody(req: IncomingMessage, maxBytes: number): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    const onData = (chunk: Buffer) => {
      total += chunk.length;
      if (total > maxBytes) {
        cleanup();
        reject(new PayloadTooLargeError("request body too large"));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => {
      cleanup();
      resolve(Buffer.concat(chunks));
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      req.removeListener("data", onData);
      req.removeListener("end", onEnd);
      req.removeListener("error", onError);
    };
    req.on("data", onData);
    req.on("end", onEnd);
    req.on("error", onError);
  });
}

function toFrameText(data: RawData): string {
  return typeof data === "string" ? data : data.toString("utf8");
}

function requestPathname(req: IncomingMessage): string {
  try {
    return new URL(req.url ?? "/", "http://localhost").pathname;
  } catch {
    return "/";
  }
}

export class RemoteHostServer {
  private httpServer: HttpsServer | null = null;
  private wss: WebSocketServer | null = null;
  private readonly connections = new Set<HostConnection>();
  private readonly wsConnections = new Map<WebSocket, HostConnection>();
  private running = false;
  private lanListening = false;
  private lastError: string | null = null;

  constructor(
    private readonly config: RemoteHostServerConfig,
    private readonly delegate: RemoteHostServerDelegate,
    private readonly callbacks: RemoteHostServerCallbacks = {}
  ) {}

  /** 管道是否就绪（命令/广播/虚拟连接可用）；与 LAN 是否监听端口解耦。 */
  get isRunning(): boolean {
    return this.running;
  }

  /** LAN（http/ws）是否成功绑定端口；隧道/WebRTC 不依赖它。 */
  get isLanListening(): boolean {
    return this.lanListening;
  }

  get activeConnectionCount(): number {
    return this.connections.size;
  }

  get lastErrorMessage(): string | null {
    return this.lastError;
  }

  async start(): Promise<void> {
    if (this.running) return;
    // 管道先就绪：即使 LAN 端口绑定失败，虚拟连接仍可工作。
    this.running = true;
    this.lastError = null;
    await this.startLanListener();
  }

  /** 绑定 http/ws LAN 监听。失败不致命：记录错误并降级，仅 LAN 直连不可用。 */
  private async startLanListener(): Promise<void> {
    if (this.httpServer) return;
    const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });
    wss.on("connection", (ws) => this.handleConnection(ws));

    const httpServer = createHttpsServer(
      {
        cert: this.config.tls.certPem,
        key: this.config.tls.keyPem,
        minVersion: "TLSv1.2"
      },
      (req, res) => this.handleHttp(req, res)
    );
    httpServer.on("upgrade", (req, socket, head) => this.handleUpgrade(req, socket, head));
    httpServer.on("error", (error) => {
      this.lastError = error.message;
      this.callbacks.onError?.(error);
    });

    const host = this.config.bindLAN ? "0.0.0.0" : "127.0.0.1";

    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: Error) => {
          httpServer.removeListener("listening", onListening);
          reject(error);
        };
        const onListening = () => {
          httpServer.removeListener("error", onError);
          resolve();
        };
        httpServer.once("error", onError);
        httpServer.once("listening", onListening);
        httpServer.listen(this.config.port, host);
      });
    } catch (error) {
      this.lanListening = false;
      this.lastError = error instanceof Error ? error.message : String(error);
      try {
        httpServer.close();
      } catch {
        // ignore
      }
      try {
        wss.close();
      } catch {
        // ignore
      }
      this.callbacks.onError?.(error instanceof Error ? error : new Error(this.lastError));
      return;
    }

    this.httpServer = httpServer;
    this.wss = wss;
    this.lanListening = true;
    this.lastError = null;
  }

  async stop(): Promise<void> {
    this.running = false;
    this.lanListening = false;
    for (const connection of this.connections) {
      connection.closeSink();
    }
    this.connections.clear();
    this.wsConnections.clear();

    const wss = this.wss;
    this.wss = null;
    if (wss) {
      await new Promise<void>((resolve) => wss.close(() => resolve()));
    }

    const httpServer = this.httpServer;
    this.httpServer = null;
    if (httpServer) {
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
    }

    this.notifyConnectionsChanged();
  }

  /** 把 broadcaster 产出的 envelope 按 focus fanout。供 RemoteHostController 调用。 */
  broadcast(envelope: PanelStateEnvelope): void {
    if (this.connections.size === 0) return;
    for (const connection of this.connections) {
      if (!connection.isOpen) continue;
      if (!this.shouldSend(envelope, connection)) continue;
      connection.send(envelope);
    }
  }

  // MARK: - 虚拟连接（隧道/WebRTC 复用同一命令+广播管道）

  /** 接入一条非 WS 的虚拟连接（如隧道）。返回的连接会参与广播 fanout 与命令处理。 */
  attachVirtualConnection(sink: HostConnectionSink): HostConnection {
    const connection = new HostConnection(sink);
    this.connections.add(connection);
    this.notifyConnectionsChanged();
    // 与 WS 一致：接入即回 hello，让客户端把连接状态翻起来。
    connection.send({ type: "hello", status: "connected" });
    return connection;
  }

  /** 摘除一条虚拟连接（隧道关闭时由 responder 调用）。 */
  detachVirtualConnection(connection: HostConnection): void {
    if (!this.connections.delete(connection)) return;
    this.notifyConnectionsChanged();
  }

  /** 把隧道收到的一帧文本喂进与 WS 相同的命令/resume 管道。 */
  deliverFrame(connection: HostConnection, text: string): void {
    this.handleFrameText(connection, text);
  }

  // MARK: - HTTP

  private handleHttp(req: IncomingMessage, res: ServerResponse): void {
    const remoteAddress = req.socket.remoteAddress ?? "";
    // bindLAN=false 防线：即便监听面意外放大，也只接受回环来源。
    if (!this.config.bindLAN && !isLoopbackAddress(remoteAddress)) {
      this.writeJson(res, 403, { error: "forbidden" });
      return;
    }
    // 被封禁的 IP 在路由之前一律 429（契约 §4.2 限流，与 Mac 端一致）。
    if (this.config.pairing.isIpBanned(remoteAddress)) {
      this.writeJson(res, 429, { error: "rate_limited", message: "尝试次数过多，请稍后再试。" });
      return;
    }

    const pathname = requestPathname(req);
    if (pathname === "/health") {
      // 契约 §4.2：发现用，不鉴权。proto:2 表示「鉴权服务器」，pair:true 表示支持 /pair。
      this.writeJson(res, 200, {
        status: "ok",
        ok: true,
        name: this.config.hostName,
        version: 1,
        proto: 2,
        pair: true,
        bindLAN: this.config.bindLAN,
        port: this.config.port,
        authRequired: true
      });
      return;
    }
    if (pathname === "/pair") {
      void this.handlePairRequest(req, res, remoteAddress).catch(() => undefined);
      return;
    }

    // 其余所有 HTTP 端点一律 Bearer 鉴权。
    if (!this.authorizeHttp(req, res)) return;
    if (pathname === "/connect_info") {
      if (req.method !== "GET") {
        this.writeJson(res, 405, { error: "method_not_allowed" });
        return;
      }
      this.writeJson(res, 200, { name: this.config.hostName, eps: this.config.endpoints() });
      return;
    }
    if (pathname === "/attachments") {
      void this.handleAttachmentUpload(req, res).catch(() => undefined);
      return;
    }
    this.writeJson(res, 404, { error: "not_found", message: "没有找到对应内容，请刷新后重试。" });
  }

  /**
   * Bearer 校验：缺失/错误/被封禁 → 401。
   * 单连接累计失败达上限时带 `Connection: close` 让底层 socket 随响应关闭（契约 §4.2 限流）。
   */
  private authorizeHttp(req: IncomingMessage, res: ServerResponse): boolean {
    const result = this.config.pairing.checkBearerAuth(
      req.headers.authorization,
      req.socket.remoteAddress ?? "",
      req.socket
    );
    if (result.ok) return true;
    const exhausted = this.config.pairing.socketFailureCount(req.socket) >= AUTH_FAILURES_PER_CONNECTION_LIMIT;
    this.writeJson(res, 401, { error: "unauthorized" }, exhausted ? { Connection: "close" } : undefined);
    return false;
  }

  /**
   * POST /pair：6 位配对码换 token（契约 §4.2）。
   * 仅私网/回环来源；WAN 来源直接 403。每 IP 每分钟 ≤5 次尝试。
   * body {code, deviceName} → 200 {token, fp, name, eps}。
   */
  private async handlePairRequest(req: IncomingMessage, res: ServerResponse, remoteAddress: string): Promise<void> {
    if (req.method !== "POST") {
      this.writeJson(res, 405, { error: "method_not_allowed", message: "当前请求方式不支持。" });
      return;
    }
    if (!isPrivateSourceAddress(remoteAddress)) {
      this.writeJson(res, 403, { error: "pair_forbidden", message: "配对仅允许局域网来源。" });
      return;
    }

    let rawBody: Buffer;
    try {
      rawBody = await readRequestBody(req, MAX_PAIR_BODY_BYTES);
    } catch (error) {
      // 超限/读失败时带 Connection: close：剩余未读请求体会随连接关闭被丢弃，
      // 避免污染 keep-alive 复用的下一条请求。
      const closeHeader = { Connection: "close" };
      if (error instanceof PayloadTooLargeError) {
        this.writeJson(res, 413, { error: "payload_too_large", message: "请求体过大。" }, closeHeader);
      } else {
        this.writeJson(res, 400, { error: "bad_request", message: "请求内容格式不正确，请重试。" }, closeHeader);
      }
      return;
    }
    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(rawBody.toString("utf8"));
    } catch {
      this.writeJson(res, 400, { error: "bad_request", message: "请求内容格式不正确，请重试。" });
      return;
    }
    const body = parsedBody && typeof parsedBody === "object"
      ? (parsedBody as { code?: unknown; deviceName?: unknown })
      : {};
    const result = this.config.pairing.redeemPairingCode(remoteAddress, body.code, body.deviceName);
    if (!result.ok) {
      if (result.error === "rate_limited") {
        this.writeJson(res, 429, { error: "rate_limited", message: "尝试次数过多，请稍后再试。" });
      } else {
        this.writeJson(res, 403, { error: "invalid_pairing_code", message: "配对码错误或已过期。" });
      }
      return;
    }
    this.writeJson(res, 200, {
      token: result.token,
      fp: this.config.tls.fingerprintHex,
      name: this.config.hostName,
      eps: this.config.endpoints()
    });
  }

  private writeJson(res: ServerResponse, statusCode: number, body: unknown, extraHeaders?: Record<string, string>): void {
    res.writeHead(statusCode, {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
      ...extraHeaders
    });
    res.end(JSON.stringify(body));
  }

  /** HTTP 附件直传（LAN 直连）：读体（限流）→ 落盘 → 回 201 {filename, path}。对齐 Mac `POST /attachments`。 */
  private async handleAttachmentUpload(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.method !== "POST") {
      this.writeJson(res, 405, { error: "method_not_allowed", message: "当前请求方式不支持。" });
      return;
    }

    let rawBody: Buffer;
    try {
      rawBody = await readRequestBody(req, MAX_HTTP_BODY_BYTES);
    } catch (error) {
      const closeHeader = { Connection: "close" };
      if (error instanceof PayloadTooLargeError) {
        this.writeJson(res, 413, { error: "attachment_too_large", message: "附件超过大小限制，请压缩后再上传。" }, closeHeader);
      } else {
        this.writeJson(res, 400, { error: "upload_failed", message: "附件读取失败，请重试。" }, closeHeader);
      }
      return;
    }

    let parsedBody: unknown;
    try {
      parsedBody = JSON.parse(rawBody.toString("utf8"));
    } catch {
      this.writeJson(res, 400, { error: "upload_failed", message: "文件内容格式不正确，请重新上传。" });
      return;
    }
    const upload = attachmentUploadRequestSchema.safeParse(parsedBody);
    if (!upload.success) {
      this.writeJson(res, 400, { error: "upload_failed", message: "附件信息不完整，请重新上传。" });
      return;
    }

    const result = await storeUploadedAttachment(upload.data.filename, upload.data.contentBase64);
    if (result.ok) {
      this.writeJson(res, 201, { filename: result.value.filename, path: result.value.path });
    } else {
      this.writeJson(res, result.error.statusCode, { error: result.error.code, message: result.error.message });
    }
  }

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    const remoteAddress = (socket as Socket).remoteAddress ?? "";
    if (!this.config.bindLAN && !isLoopbackAddress(remoteAddress)) {
      this.rejectUpgrade(socket, 403, "Forbidden");
      return;
    }
    if (this.config.pairing.isIpBanned(remoteAddress)) {
      this.rejectUpgrade(socket, 429, "Too Many Requests");
      return;
    }
    const pathname = requestPathname(req);
    if (pathname !== "/chat") {
      this.rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    // 契约 §4.2：WS upgrade 带 Authorization: Bearer，鉴权失败在 101 之前回 401。
    const auth = this.config.pairing.checkBearerAuth(req.headers.authorization, remoteAddress, socket);
    if (!auth.ok) {
      this.rejectUpgrade(socket, 401, "Unauthorized");
      return;
    }
    const wss = this.wss;
    if (!wss) {
      this.rejectUpgrade(socket, 503, "Service Unavailable");
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  }

  private rejectUpgrade(socket: Duplex, statusCode: number, reason: string): void {
    socket.write(`HTTP/1.1 ${statusCode} ${reason}\r\nConnection: close\r\n\r\n`);
    socket.destroy();
  }

  // MARK: - WebSocket

  private handleConnection(ws: WebSocket): void {
    const connection = new HostConnection({
      send: (text) => ws.send(text),
      isOpen: () => ws.readyState === WebSocket.OPEN,
      close: () => {
        try {
          ws.close(1001, "server stopping");
        } catch {
          // ignore
        }
      }
    });
    this.connections.add(connection);
    this.wsConnections.set(ws, connection);
    this.notifyConnectionsChanged();

    ws.on("message", (data) => this.handleFrameText(connection, toFrameText(data)));
    ws.on("close", () => this.removeWsConnection(ws));
    ws.on("error", () => this.removeWsConnection(ws));

    // 与 Mac 一致：连上先回 hello，让客户端把连接状态翻起来。
    connection.send({ type: "hello", status: "connected" });
  }

  private removeWsConnection(ws: WebSocket): void {
    const connection = this.wsConnections.get(ws);
    this.wsConnections.delete(ws);
    if (connection) this.connections.delete(connection);
    try {
      ws.terminate();
    } catch {
      // ignore
    }
    this.notifyConnectionsChanged();
  }

  private handleFrameText(connection: HostConnection, text: string): void {
    if (!text) return;
    // 隧道 / WebRTC 通道没有 ws maxPayload 兜底，这里统一按上限拒收超大帧，防止内存被打爆。
    if (Buffer.byteLength(text, "utf8") > MAX_FRAME_BYTES) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return;
    }
    if (!parsed || typeof parsed !== "object") return;
    const type = (parsed as { type?: unknown }).type;

    if (type === remoteVNCFrameType.command) {
      this.handleCommandFrame(connection, parsed);
      return;
    }
    if (type === remoteVNCFrameType.resume) {
      this.handleResumeFrame(connection, parsed);
      return;
    }
    if (type === remoteVNCFrameType.recoveryRequest) {
      // 文本帧体积已在上方按 MAX_FRAME_BYTES 拦截；recovery 单独再按协议上限拒收超大附件帧。
      if (Buffer.byteLength(text, "utf8") > remoteRecoveryLimits.maximumTextFrameUTF8Bytes) {
        const requestId = probeRequestId(parsed);
        if (requestId) {
          connection.send(recoveryErrorResponse(requestId, "恢复请求过大，请压缩附件后重试。"));
        }
        return;
      }
      this.handleRecoveryFrame(connection, parsed);
      return;
    }
    // 其他帧（含 legacy）一期不处理，静默丢弃。
  }

  /**
   * recovery_request 帧处理。一期 Windows host 仅支持 uploadAttachment（附件上传），
   * 其余 op（catalog/sessions/messages/projectFiles）在 Windows 走 panel_state 推送，
   * 这里回明确错误，避免手机端静默等待超时。
   */
  private handleRecoveryFrame(connection: HostConnection, raw: unknown): void {
    const result = recoveryRequestSchema.safeParse(raw);
    if (!result.success) {
      const requestId = probeRequestId(raw);
      if (requestId) {
        connection.send(recoveryErrorResponse(requestId, "恢复请求格式不正确，请重试。"));
      }
      return;
    }
    const request = result.data;
    if (request.op !== "uploadAttachment") {
      connection.send(recoveryErrorResponse(request.requestId, "当前不支持此操作，请刷新后重试。"));
      return;
    }
    // 附件落盘是异步的，串行化到本连接的入站链，保证与命令处理同序、不交叉。
    connection.inboundChain = connection.inboundChain
      .then(() => this.processRecoveryUpload(connection, request))
      .catch(() => undefined);
  }

  private async processRecoveryUpload(connection: HostConnection, request: RecoveryRequest): Promise<void> {
    if (request.filename == null || request.contentBase64 == null) {
      connection.send(recoveryErrorResponse(request.requestId, "附件信息不完整，请重新上传。"));
      return;
    }
    const result = await storeUploadedAttachment(request.filename, request.contentBase64);
    if (!this.connections.has(connection)) return; // 连接已断开
    if (result.ok) {
      connection.send(recoveryOkResponse(request.requestId, {
        attachmentUpload: { filename: result.value.filename, path: result.value.path }
      }));
    } else {
      connection.send(recoveryErrorResponse(request.requestId, result.error.message));
    }
  }

  private handleCommandFrame(connection: HostConnection, raw: unknown): void {
    const result = commandSchema.safeParse(raw);
    if (!result.success) {
      const commandId = probeCommandId(raw);
      connection.send(errorAck(commandId ?? randomUUID(), "操作内容格式不正确，请重试。", null));
      return;
    }
    const command = result.data;
    // 串行化本连接命令，保证顺序（对应 Mac 的 await previousTask）。
    connection.inboundChain = connection.inboundChain
      .then(() => this.processCommand(connection, command))
      .catch(() => undefined);
  }

  private async processCommand(connection: HostConnection, command: RemoteCommand): Promise<void> {
    let dispatch: RemoteHostCommandDispatch;
    try {
      dispatch = await this.delegate.applyCommand(command, connection.focusedSessionId);
    } catch {
      connection.send(errorAck(command.commandId, "远程面板暂时不可用，请稍后重试。", command.sessionId ?? null));
      return;
    }
    if (!this.connections.has(connection)) return; // 连接已断开

    connection.send(dispatch.ack);
    if (dispatch.shouldUpdateFocusedSessionId) {
      connection.focusedSessionId = dispatch.newFocusedSessionId;
      connection.isResolvingDraftSession = command.op === "newDraftSession";
    }
    if (dispatch.shouldPushSnapshotForFocus) {
      const snapshot = this.delegate.snapshotFor(connection.focusedSessionId);
      if (snapshot) connection.send(snapshotEnvelope(snapshot));
    }
  }

  private handleResumeFrame(connection: HostConnection, raw: unknown): void {
    const result = resumeRequestSchema.safeParse(raw);
    if (!result.success) return;
    const sessionId = result.data.sessionId ?? null;
    const lastRevision = result.data.lastRevision ?? null;
    if (sessionId) connection.focusedSessionId = sessionId;

    const payload = this.delegate.replayPayload(sessionId, lastRevision);
    switch (payload.kind) {
      case "snapshot":
        connection.send(snapshotEnvelope(payload.snapshot));
        break;
      case "patches":
        for (const patch of payload.patches) {
          connection.send(patchEnvelope(patch));
        }
        break;
      case "empty": {
        // client 已追上（lastRevision == currentRevision）时也要回一份 snapshot，
        // 否则客户端会卡在“连接中”（它把收到任意 envelope 当连接 OK 的信号）。
        const snapshot = this.delegate.snapshotFor(sessionId) ?? this.delegate.snapshotFor(null);
        if (snapshot) connection.send(snapshotEnvelope(snapshot));
        break;
      }
    }
  }

  /** envelope.sessionId 与连接 focus 的匹配规则，移植自 Mac shouldSendVNCEnvelope。 */
  private shouldSend(envelope: PanelStateEnvelope, connection: HostConnection): boolean {
    if (connection.focusedSessionId === null) {
      return envelope.sessionId === null;
    }
    if (envelope.sessionId === null) {
      return true;
    }
    if (envelope.sessionId === connection.focusedSessionId) {
      connection.isResolvingDraftSession = false;
      return true;
    }
    if (connection.isResolvingDraftSession) {
      connection.focusedSessionId = envelope.sessionId;
      connection.isResolvingDraftSession = false;
      return true;
    }
    return false;
  }

  private notifyConnectionsChanged(): void {
    this.callbacks.onConnectionsChanged?.(this.connections.size);
  }
}
