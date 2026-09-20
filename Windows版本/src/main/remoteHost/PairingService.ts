// PairingService —— 配对 token / 6 位配对码 / 鉴权限流（契约 §4.2、§4.4）。
//
// - token：32 字节随机 → base64url；服务端只存 SHA-256(token) + 设备元信息。
// - 6 位配对码：5 分钟有效、一次性、每 IP 每分钟 ≤5 次尝试（超限拒绝）。
// - Bearer 鉴权失败限流：每连接 5 次失败关连接；每 IP 每分钟失败 >10 次封禁 60s。
// - QR 载荷内嵌的是「已签发的 token」（via:"qr"），扫码即配对完成，无需再调 /pair。

import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export type PairingVia = "qr" | "code";

export interface PairedDevice {
  deviceId: string;
  deviceName: string;
  createdAt: string;
  lastSeen: string | null;
  via: PairingVia;
}

export interface PairingCode {
  code: string;
  expiresAtMs: number;
}

export type BearerAuthResult =
  | { ok: true; device: PairedDevice }
  | { ok: false; reason: "missing" | "invalid" | "banned" };

export type PairingRedeemResult =
  | { ok: true; token: string; device: PairedDevice }
  | { ok: false; error: "rate_limited" | "invalid_code" };

interface StoredDevice extends PairedDevice {
  tokenHash: string;
}

interface PersistedPairingState {
  version: 1;
  devices: StoredDevice[];
}

const PAIRING_CODE_TTL_MS = 5 * 60_000;
const PAIRING_ATTEMPT_LIMIT = 5;
const PAIRING_ATTEMPT_WINDOW_MS = 60_000;
const AUTH_FAILURE_LIMIT = 10;
const AUTH_FAILURE_WINDOW_MS = 60_000;
const AUTH_BAN_MS = 60_000;
/** 每连接鉴权失败上限：达到即由调用方断开 socket。 */
export const AUTH_FAILURES_PER_CONNECTION_LIMIT = 5;
const MAX_DEVICE_NAME_LENGTH = 64;

function sha256Hex(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function sanitizeDeviceName(value: unknown): string {
  const name = typeof value === "string" ? value.trim() : "";
  if (!name) return "未命名设备";
  return name.slice(0, MAX_DEVICE_NAME_LENGTH);
}

/** 从 Authorization 头取 Bearer token；缺失/非 Bearer → null。 */
export function extractBearerToken(authorizationHeader: string | undefined): string | null {
  if (!authorizationHeader) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(authorizationHeader.trim());
  return match ? match[1] : null;
}

export class PairingService {
  private readonly now: () => number;
  private readonly storePath: string;
  private readonly devices = new Map<string, StoredDevice>();
  private readonly authFailuresByIp = new Map<string, number[]>();
  private readonly bannedUntilByIp = new Map<string, number>();
  private readonly pairAttemptsByIp = new Map<string, number[]>();
  private readonly socketFailures = new WeakMap<object, number>();
  private pairingCode: PairingCode | null = null;
  private persistTimer: NodeJS.Timeout | null = null;
  private initialized = false;

  constructor(options: { storePath: string; now?: () => number }) {
    this.storePath = options.storePath;
    this.now = options.now ?? (() => Date.now());
  }

  async init(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;
    try {
      const raw = await readFile(this.storePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<PersistedPairingState>;
      if (!Array.isArray(parsed.devices)) return;
      for (const device of parsed.devices) {
        if (!device || typeof device.deviceId !== "string" || typeof device.tokenHash !== "string") continue;
        this.devices.set(device.deviceId, {
          deviceId: device.deviceId,
          deviceName: sanitizeDeviceName(device.deviceName),
          tokenHash: device.tokenHash,
          createdAt: typeof device.createdAt === "string" ? device.createdAt : new Date().toISOString(),
          lastSeen: typeof device.lastSeen === "string" ? device.lastSeen : null,
          via: device.via === "code" ? "code" : "qr"
        });
      }
    } catch {
      // 无持久化文件或损坏 → 空设备列表起步。
    }
  }

  /** 签发新 token（明文只在此处返回，不落盘）。 */
  issueToken(deviceName: string, via: PairingVia): { token: string; device: PairedDevice } {
    const token = randomBytes(32).toString("base64url");
    const device: StoredDevice = {
      deviceId: randomUUID(),
      deviceName: sanitizeDeviceName(deviceName),
      tokenHash: sha256Hex(token),
      createdAt: new Date(this.now()).toISOString(),
      lastSeen: null,
      via
    };
    this.devices.set(device.deviceId, device);
    this.schedulePersist();
    return { token, device: this.publicDevice(device) };
  }

  /**
   * 签发 QR 载荷内嵌的 token。每次签发会吊销此前从未连上过的 QR token
   * （屏上二维码轮换语义与常见扫码配对一致），已连过的设备不受影响。
   */
  issueQrToken(): { token: string; device: PairedDevice } {
    for (const device of this.devices.values()) {
      if (device.via === "qr" && device.lastSeen === null) {
        this.devices.delete(device.deviceId);
      }
    }
    return this.issueToken("扫码配对设备", "qr");
  }

  /**
   * Bearer 鉴权总入口：封禁检查 → token 校验 → 失败计数（IP 滑窗 + 单连接）。
   * socket 传 null 表示无连接语境（如纯 HTTP 语义测试），只做 IP 维度计数。
   */
  checkBearerAuth(authorizationHeader: string | undefined, remoteAddress: string, socket?: object): BearerAuthResult {
    const ip = remoteAddress || "unknown";
    if (this.isIpBanned(ip)) {
      return { ok: false, reason: "banned" };
    }
    const token = extractBearerToken(authorizationHeader);
    if (!token) {
      this.noteAuthFailure(ip, socket ?? null);
      return { ok: false, reason: "missing" };
    }
    const device = this.authenticate(token);
    if (!device) {
      this.noteAuthFailure(ip, socket ?? null);
      return { ok: false, reason: "invalid" };
    }
    return { ok: true, device };
  }

  /** 校验 token（哈希比对），命中则刷新 lastSeen。不记失败——失败计数由 checkBearerAuth 负责。 */
  authenticate(token: string): PairedDevice | null {
    const hash = sha256Hex(token);
    const hashBuffer = Buffer.from(hash, "utf8");
    for (const device of this.devices.values()) {
      const candidate = Buffer.from(device.tokenHash, "utf8");
      if (candidate.length !== hashBuffer.length) continue;
      if (!timingSafeEqual(candidate, hashBuffer)) continue;
      device.lastSeen = new Date(this.now()).toISOString();
      this.schedulePersist();
      return this.publicDevice(device);
    }
    return null;
  }

  /** 当前 socket 的累计鉴权失败次数（达到上限后调用方应断开连接）。 */
  socketFailureCount(socket: object): number {
    return this.socketFailures.get(socket) ?? 0;
  }

  isIpBanned(ip: string): boolean {
    const until = this.bannedUntilByIp.get(ip);
    if (until === undefined) return false;
    if (this.now() < until) return true;
    this.bannedUntilByIp.delete(ip);
    return false;
  }

  /** 当前生效的配对码：无或过期则重新生成（6 位数字，5 分钟）。 */
  ensurePairingCode(): PairingCode {
    const existing = this.pairingCode;
    if (existing && existing.expiresAtMs > this.now()) return existing;
    const code: PairingCode = {
      code: randomInt(0, 1_000_000).toString().padStart(6, "0"),
      expiresAtMs: this.now() + PAIRING_CODE_TTL_MS
    };
    this.pairingCode = code;
    return code;
  }

  /** 用 6 位码换 token。码一次性：无论设备名如何，兑中即作废。 */
  redeemPairingCode(remoteAddress: string, code: unknown, deviceName: unknown): PairingRedeemResult {
    const ip = remoteAddress || "unknown";
    const attempts = this.pairAttemptsByIp.get(ip) ?? [];
    const windowStart = this.now() - PAIRING_ATTEMPT_WINDOW_MS;
    const recent = attempts.filter((at) => at > windowStart);
    if (recent.length >= PAIRING_ATTEMPT_LIMIT) {
      this.pairAttemptsByIp.set(ip, recent);
      return { ok: false, error: "rate_limited" };
    }
    recent.push(this.now());
    this.pairAttemptsByIp.set(ip, recent);

    const active = this.pairingCode;
    const submitted = typeof code === "string" ? code.trim() : "";
    if (!active || active.expiresAtMs <= this.now() || submitted !== active.code) {
      return { ok: false, error: "invalid_code" };
    }
    this.pairingCode = null; // 一次性
    const issued = this.issueToken(sanitizeDeviceName(deviceName), "code");
    return { ok: true, token: issued.token, device: issued.device };
  }

  listDevices(): PairedDevice[] {
    return [...this.devices.values()]
      .map((device) => this.publicDevice(device))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  revokeDevice(deviceId: string): boolean {
    const removed = this.devices.delete(deviceId);
    if (removed) this.schedulePersist();
    return removed;
  }

  /** 单个 IP 记一次鉴权失败；IP 滑窗超限则封禁 60s。 */
  private noteAuthFailure(ip: string, socket: object | null): void {
    if (socket) {
      this.socketFailures.set(socket, this.socketFailureCount(socket) + 1);
    }
    const windowStart = this.now() - AUTH_FAILURE_WINDOW_MS;
    const recent = (this.authFailuresByIp.get(ip) ?? []).filter((at) => at > windowStart);
    recent.push(this.now());
    this.authFailuresByIp.set(ip, recent);
    if (recent.length > AUTH_FAILURE_LIMIT) {
      this.bannedUntilByIp.set(ip, this.now() + AUTH_BAN_MS);
    }
    this.sweepMaps();
  }

  /** 防内存膨胀：map 过大时清掉滑窗外/已解封的陈旧条目。 */
  private sweepMaps(): void {
    const cutoff = this.now() - AUTH_FAILURE_WINDOW_MS;
    if (this.authFailuresByIp.size > 512) {
      for (const [ip, stamps] of this.authFailuresByIp) {
        if (stamps.every((at) => at <= cutoff)) this.authFailuresByIp.delete(ip);
      }
    }
    if (this.pairAttemptsByIp.size > 512) {
      for (const [ip, stamps] of this.pairAttemptsByIp) {
        if (stamps.every((at) => at <= cutoff)) this.pairAttemptsByIp.delete(ip);
      }
    }
    if (this.bannedUntilByIp.size > 512) {
      for (const [ip, until] of this.bannedUntilByIp) {
        if (until <= this.now()) this.bannedUntilByIp.delete(ip);
      }
    }
  }

  private publicDevice(device: StoredDevice): PairedDevice {
    return {
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      createdAt: device.createdAt,
      lastSeen: device.lastSeen,
      via: device.via
    };
  }

  private schedulePersist(): void {
    if (this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = null;
      void this.persistNow();
    }, 250);
    this.persistTimer.unref?.();
  }

  private async persistNow(): Promise<void> {
    const state: PersistedPairingState = { version: 1, devices: [...this.devices.values()] };
    try {
      await mkdir(path.dirname(this.storePath), { recursive: true });
      const tmp = `${this.storePath}.tmp`;
      await writeFile(tmp, `${JSON.stringify(state, null, 2)}\n`, "utf8");
      await rename(tmp, this.storePath);
    } catch {
      // 持久化失败不致命：内存态仍可用，下次变更再写。
    }
  }

  /** 关定时器并把未落盘的变更写完（shutdown 调用）。 */
  async dispose(): Promise<void> {
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = null;
      await this.persistNow();
    }
  }
}
