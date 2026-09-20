// RemoteHostController（Windows host 主进程编排）—— 对应 Mac 的
// `RemoteChatServerController` 的主进程侧职责。
//
// 职责：
//   1. 持久化 host 配置（enabled / port 存 JSON）。
//   2. 持有 PanelStateBroadcaster：渲染进程推来的 snapshot 经 ingest 得到 envelope
//      后调 server.broadcast()。
//   3. 管理 RemoteHostServer 生命周期（enable/disable）。
//   4. 实现 RemoteHostServerDelegate：把手机命令通过 IPC 转发到渲染进程并等结果。
//   5. WAN 直连（契约 §4/§5）：TLS 身份 + PairingService（token/配对码/限流）
//      + WanEndpointPublisher（IPv6/NAT-PMP/UPnP/CGNAT 诊断）+ 配对载荷下发。
//
// LAN/WAN 统一 wss + Bearer 鉴权；/pair 仅私网来源；token 只存 SHA-256 哈希。

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import { randomUUID } from "node:crypto";
import path from "node:path";

import { cleanupAttachmentStore } from "./AttachmentStore.js";
import { loadOrCreateHostIdentity, type HostIdentity } from "./HostIdentity.js";
import { localLanIPv4 } from "../remoteConnect/LanSubnetProbe.js";
import { buildPairingUri } from "./pairingPayload.js";
import { PairingService, type PairedDevice } from "./PairingService.js";
import { PanelStateBroadcaster, type ReplayPayload } from "./PanelStateBroadcaster.js";
import {
  RemoteHostServer,
  type RemoteHostCommandDispatch,
  type RemoteHostServerDelegate
} from "./RemoteHostServer.js";
import { WanEndpointPublisher } from "./WanEndpointPublisher.js";
import type {
  RemoteHostApplyCommandRequest,
  RemoteHostCommandResult,
  RemoteHostPairingInfo,
  RemoteHostStatus
} from "../../shared/ipc.js";
import type { PanelStateSnapshot, RemoteCommand } from "../../shared/remoteProtocol.js";

export const DEFAULT_REMOTE_HOST_PORT = 18765;
const COMMAND_TIMEOUT_MS = 15_000;
const PAIRING_STORE_FILE = "remote-host-pairing.json";

interface PersistedHostConfig {
  enabled: boolean;
  port: number;
}

export interface RemoteHostControllerDeps {
  userDataDir: string;
  /** 把命令转发到渲染进程执行。返回 false 表示当前没有可用渲染进程。 */
  requestApplyCommand: (payload: RemoteHostApplyCommandRequest) => boolean;
  /** 把最新状态推给渲染进程 / 设置页。 */
  publishStatus: (status: RemoteHostStatus) => void;
}

interface PendingCommand {
  resolve: (result: RemoteHostCommandResult) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class RemoteHostController implements RemoteHostServerDelegate {
  private readonly broadcaster = new PanelStateBroadcaster();
  private readonly pending = new Map<string, PendingCommand>();
  private server: RemoteHostServer | null = null;
  private identity: HostIdentity | null = null;
  private pairing: PairingService | null = null;
  private publisher: WanEndpointPublisher | null = null;
  /** 本次会话内复用的 QR 配对 token（明文只在内存，持久化只有哈希）。 */
  private qrSessionToken: { token: string; deviceId: string } | null = null;
  private enabled = false;
  private port = DEFAULT_REMOTE_HOST_PORT;
  private lastError: string | null = null;
  private initialized = false;

  constructor(private readonly deps: RemoteHostControllerDeps) {}

  private get configPath(): string {
    return path.join(this.deps.userDataDir, "remote-host.json");
  }

  /** 加载持久化配置与 TLS 身份/配对存储；若 enabled 则启动服务。 */
  async init(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;
    const config = await this.loadConfig();
    this.enabled = config.enabled;
    this.port = config.port;
    const pairing = new PairingService({ storePath: path.join(this.deps.userDataDir, PAIRING_STORE_FILE) });
    this.pairing = pairing;
    const [identity] = await Promise.all([
      loadOrCreateHostIdentity(this.deps.userDataDir),
      pairing.init()
    ]);
    this.identity = identity;
    if (this.enabled) {
      await this.startServer().catch((error: unknown) => {
        this.lastError = error instanceof Error ? error.message : String(error);
      });
    }
    this.emitStatus();
  }

  getStatus(): RemoteHostStatus {
    const lanIp = this.server?.isLanListening ? localLanIPv4() : null;
    return {
      enabled: this.enabled,
      running: this.server?.isRunning ?? false,
      port: this.port,
      lanAddress: lanIp ? `${lanIp}:${this.port}` : null,
      activeConnectionCount: this.server?.activeConnectionCount ?? 0,
      lastError: this.lastError,
      fingerprint: this.identity?.fingerprintHex ?? null,
      wan: this.publisher?.getDiagnostics() ?? null,
      pairedDevices: this.pairing?.listDevices() ?? []
    };
  }

  async setEnabled(enabled: boolean): Promise<RemoteHostStatus> {
    if (this.enabled === enabled && (this.server?.isRunning ?? false) === enabled) {
      return this.getStatus();
    }
    // 先启停成功，再落库 enabled：避免启动失败（如端口占用）却把 enabled=true 持久化。
    if (enabled) {
      await this.startServer();
      this.enabled = true;
    } else {
      await this.stopServer();
      this.enabled = false;
    }
    await this.persistConfig();
    this.emitStatus();
    return this.getStatus();
  }

  /** 渲染进程推来的 snapshot：标记 revision / diff，并按 focus 广播。 */
  ingestSnapshot(snapshot: PanelStateSnapshot): void {
    const envelope = this.broadcaster.ingest(snapshot);
    this.server?.broadcast(envelope);
  }

  /** 渲染进程执行完命令后回传结果，结算对应的 pending。 */
  resolveCommandResult(result: RemoteHostCommandResult): void {
    const entry = this.pending.get(result.requestId);
    if (!entry) return;
    clearTimeout(entry.timer);
    this.pending.delete(result.requestId);
    entry.resolve(result);
  }

  async shutdown(): Promise<void> {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("controller shutting down"));
    }
    this.pending.clear();
    await this.stopServer();
    await this.pairing?.dispose();
  }

  // MARK: - WAN 直连配对 / 诊断（契约 §4.4、§5.3）

  /**
   * 配对信息：QR/连接串共用的 acode://pair 载荷 + 屏显 6 位码。
   * QR token 在本次会话内复用（明文只在内存）；会话外只能重发新 token，
   * 签发新 QR token 会吊销此前从未连上的 QR token（见 PairingService.issueQrToken）。
   */
  async getPairingInfo(): Promise<RemoteHostPairingInfo | null> {
    const identity = this.identity;
    const pairing = this.pairing;
    if (!identity || !pairing || !this.server?.isLanListening) return null;

    const qrToken = this.ensureQrToken(pairing);
    if (!qrToken) return null;
    // eps 为空（首轮刷新未完成）时先补一轮，避免发出无地址的配对串。
    if (this.publisher && this.publisher.getEndpoints().length === 0) {
      await this.publisher.refresh();
    }
    const pairingCode = pairing.ensurePairingCode();
    const pairingUri = buildPairingUri({
      v: 1,
      n: os.hostname(),
      eps: this.publisher?.getEndpoints() ?? [],
      t: qrToken,
      fp: identity.fingerprintHex
    });
    return {
      pairingUri,
      code: pairingCode.code,
      codeExpiresAt: new Date(pairingCode.expiresAtMs).toISOString(),
      fingerprintHex: identity.fingerprintHex
    };
  }

  /** 吊销已配对设备；返回最新状态供设置页刷新。 */
  async revokeDevice(deviceId: string): Promise<RemoteHostStatus> {
    const pairing = this.pairing;
    if (pairing) {
      pairing.revokeDevice(deviceId);
      if (this.qrSessionToken?.deviceId === deviceId) this.qrSessionToken = null;
    }
    this.emitStatus();
    return this.getStatus();
  }

  /** 强制刷新 WAN endpoint 诊断（设置页「刷新诊断」按钮）。 */
  async refreshEndpoints(): Promise<RemoteHostStatus> {
    await this.publisher?.refresh();
    this.emitStatus();
    return this.getStatus();
  }

  private ensureQrToken(pairing: PairingService): string | null {
    const session = this.qrSessionToken;
    if (session && pairing.listDevices().some((device) => device.deviceId === session.deviceId)) {
      return session.token;
    }
    const issued = pairing.issueQrToken();
    this.qrSessionToken = { token: issued.token, deviceId: issued.device.deviceId };
    this.emitStatus();
    return issued.token;
  }

  // MARK: - RemoteHostServerDelegate

  async applyCommand(command: RemoteCommand, focusedSessionId: string | null): Promise<RemoteHostCommandDispatch> {
    const requestId = randomUUID();
    const resultPromise = new Promise<RemoteHostCommandResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error("命令处理超时。"));
      }, COMMAND_TIMEOUT_MS);
      this.pending.set(requestId, { resolve, reject, timer });
    });

    const delivered = this.deps.requestApplyCommand({ requestId, focusedSessionId, command });
    if (!delivered) {
      const entry = this.pending.get(requestId);
      if (entry) {
        clearTimeout(entry.timer);
        this.pending.delete(requestId);
      }
      throw new Error("渲染进程暂不可用。");
    }

    const result = await resultPromise;
    return {
      ack: result.ack,
      shouldUpdateFocusedSessionId: result.shouldUpdateFocusedSessionId,
      newFocusedSessionId: result.newFocusedSessionId ?? null,
      shouldPushSnapshotForFocus: result.shouldPushSnapshotForFocus
    } satisfies RemoteHostCommandDispatch;
  }

  replayPayload(sessionId: string | null, lastRevision: number | null): ReplayPayload {
    return this.broadcaster.replayPayload(sessionId, lastRevision);
  }

  snapshotFor(sessionId: string | null): PanelStateSnapshot | null {
    return this.broadcaster.snapshotFor(sessionId);
  }

  // MARK: - server lifecycle

  private async startServer(): Promise<void> {
    if (this.server) return;
    const identity = this.identity;
    const pairing = this.pairing;
    if (!identity || !pairing) {
      throw new Error("远程 host 尚未初始化。");
    }
    // 启动即清理上一次会话遗留的附件临时文件，避免跨运行无主累积。
    await cleanupAttachmentStore();

    const publisher = new WanEndpointPublisher({
      port: this.port,
      lanIPv4: localLanIPv4,
      onUpdate: () => this.emitStatus()
    });
    this.publisher = publisher;

    const server = new RemoteHostServer(
      {
        port: this.port,
        bindLAN: true,
        tls: { certPem: identity.certPem, keyPem: identity.keyPem, fingerprintHex: identity.fingerprintHex },
        pairing,
        endpoints: () => publisher.getEndpoints(),
        hostName: os.hostname()
      },
      this,
      {
        onConnectionsChanged: () => this.emitStatus(),
        onError: (error) => {
          this.lastError = error.message;
          this.emitStatus();
        }
      }
    );
    this.server = server;
    try {
      await server.start();
    } catch (error) {
      this.server = null;
      this.publisher = null;
      this.lastError = error instanceof Error ? error.message : String(error);
      throw error;
    }
    this.lastError = server.lastErrorMessage;
    publisher.start();
  }

  private async stopServer(): Promise<void> {
    const server = this.server;
    const publisher = this.publisher;
    this.server = null;
    this.publisher = null;
    if (server) await server.stop();
    if (publisher) await publisher.stop();
    // 停用时清理本次会话写入的附件临时文件。
    await cleanupAttachmentStore();
  }

  // MARK: - persistence

  private emitStatus(): void {
    this.deps.publishStatus(this.getStatus());
  }

  private async loadConfig(): Promise<PersistedHostConfig> {
    try {
      const raw = await readFile(this.configPath, "utf8");
      const parsed = JSON.parse(raw) as Partial<PersistedHostConfig>;
      const port = typeof parsed.port === "number" && parsed.port >= 1 && parsed.port <= 65535
        ? parsed.port
        : DEFAULT_REMOTE_HOST_PORT;
      return { enabled: parsed.enabled === true, port };
    } catch {
      return { enabled: false, port: DEFAULT_REMOTE_HOST_PORT };
    }
  }

  private async persistConfig(): Promise<void> {
    const config: PersistedHostConfig = { enabled: this.enabled, port: this.port };
    try {
      await mkdir(path.dirname(this.configPath), { recursive: true });
      const tmp = `${this.configPath}.tmp`;
      await writeFile(tmp, `${JSON.stringify(config, null, 2)}\n`, "utf8");
      await rename(tmp, this.configPath);
    } catch {
      // 配置持久化失败不致命（下次仍可用默认值）。
    }
  }
}
