// RemoteHostServer（Windows host）—— 移植自 Mac 的 `RemoteChatServer.swift`
// 的传输 + 广播职责（去掉 legacy/WebRTC 路径，只保留一期需要的 VNC 协议）。
//
// 职责（纯传输层，不含面板逻辑）：
//   1. 起 http(`/health`) + ws(`/chat`) 服务器（局域网直连，不鉴权）。
//   2. 维护每条连接的 focus（focusedSessionId / isResolvingDraftSession）。
//   3. 把 broadcaster 产出的 PanelStateEnvelope 按 focus fanout 给匹配的连接。
//   4. 解析手机来的 `command` / `resume` 帧，交给 delegate（RemoteHostController）
//      处理面板逻辑，回 `command_ack` / `panel_state`。
//
// 面板逻辑（snapshot 组装、命令应用）由 delegate 提供，delegate 持有
// PanelStateBroadcaster 并通过 IPC 与渲染进程通信。

import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { randomUUID } from "node:crypto";
import { WebSocketServer, WebSocket, type RawData } from "ws";

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

export interface RemoteHostServerConfig {
  port: number;
  /** true：绑 0.0.0.0 接受局域网连接；false：只绑 127.0.0.1。 */
  bindLAN: boolean;
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

/** 读取 HTTP 请求体并按上限限流：超过 maxBytes 立即销毁连接并抛 PayloadTooLargeError。 */
function readRequestBody(req: IncomingMessage, maxBytes: number): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    const onData = (chunk: Buffer) => {
      total += chunk.length;
      if (total > maxBytes) {
        cleanup();
        req.destroy();
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
  private httpServer: HttpServer | null = null;
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

    const httpServer = createServer((req, res) => this.handleHttp(req, res));
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
    const pathname = requestPathname(req);
    if (pathname === "/health") {
      // 与 macOS host 同形，兼容按字段解码的客户端。
      this.writeJson(res, 200, {
        status: "ok",
        ok: true,
        name: "acode (Windows)",
        version: 1,
        bindLAN: this.config.bindLAN,
        port: this.config.port,
        authRequired: false
      });
      return;
    }
    if (pathname === "/attachments") {
      void this.handleAttachmentUpload(req, res);
      return;
    }
    this.writeJson(res, 404, { error: "not_found", message: "没有找到对应内容，请刷新后重试。" });
  }

  private writeJson(res: ServerResponse, statusCode: number, body: unknown): void {
    res.writeHead(statusCode, {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*"
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
      if (error instanceof PayloadTooLargeError) {
        this.writeJson(res, 413, { error: "attachment_too_large", message: "附件超过大小限制，请压缩后再上传。" });
      } else {
        this.writeJson(res, 400, { error: "upload_failed", message: "附件读取失败，请重试。" });
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
    const pathname = requestPathname(req);
    if (pathname !== "/chat") {
      this.rejectUpgrade(socket, 404, "Not Found");
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
