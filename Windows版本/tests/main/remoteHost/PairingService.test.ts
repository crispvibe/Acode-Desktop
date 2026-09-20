import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  AUTH_FAILURES_PER_CONNECTION_LIMIT,
  extractBearerToken,
  PairingService
} from "../../../src/main/remoteHost/PairingService";

const tempDirs: string[] = [];

afterEach(async () => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) await rm(dir, { recursive: true, force: true });
  }
});

async function makeService(now?: () => number): Promise<PairingService> {
  const dir = await mkdtemp(path.join(tmpdir(), "acode-pairing-test-"));
  tempDirs.push(dir);
  const service = new PairingService({ storePath: path.join(dir, "pairing.json"), now });
  await service.init();
  return service;
}

describe("extractBearerToken", () => {
  it("parses Bearer headers case-insensitively and rejects junk", () => {
    expect(extractBearerToken("Bearer abc.def")).toBe("abc.def");
    expect(extractBearerToken("bearer xyz")).toBe("xyz");
    expect(extractBearerToken("  Bearer  tok  ")).toBe("tok");
    expect(extractBearerToken(undefined)).toBeNull();
    expect(extractBearerToken("Basic abc")).toBeNull();
    expect(extractBearerToken("Bearer")).toBeNull();
  });
});

describe("PairingService token lifecycle", () => {
  it("issues 32-byte base64url tokens and authenticates them by hash", async () => {
    const service = await makeService();
    const { token, device } = service.issueToken("手机 A", "code");
    // 32 字节 → base64url 43 字符，无 padding。
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(device.deviceName).toBe("手机 A");

    const authed = service.authenticate(token);
    expect(authed?.deviceId).toBe(device.deviceId);
    expect(authed?.lastSeen).not.toBeNull();
    expect(service.authenticate("wrong-token")).toBeNull();
  });

  it("persists only the SHA-256 hash — the raw token never hits disk", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "acode-pairing-test-"));
    tempDirs.push(dir);
    const storePath = path.join(dir, "pairing.json");
    const service = new PairingService({ storePath });
    await service.init();
    const { token } = service.issueToken("手机 B", "qr");
    await service.dispose();

    const raw = await import("node:fs/promises").then((fs) => fs.readFile(storePath, "utf8"));
    expect(raw).not.toContain(token);
    expect(raw).toContain("tokenHash");

    // 重启后凭哈希仍可认证。
    const reloaded = new PairingService({ storePath });
    await reloaded.init();
    expect(reloaded.authenticate(token)?.deviceName).toBe("手机 B");
    await reloaded.dispose();
  });

  it("lists devices and revokes them", async () => {
    const service = await makeService();
    const a = service.issueToken("A", "code").device;
    service.issueToken("B", "qr");
    expect(service.listDevices().map((d) => d.deviceName).sort()).toEqual(["A", "B"]);
    expect(service.revokeDevice(a.deviceId)).toBe(true);
    expect(service.revokeDevice(a.deviceId)).toBe(false);
    expect(service.listDevices().map((d) => d.deviceName)).toEqual(["B"]);
  });

  it("a new QR token revokes previous QR tokens that never connected", async () => {
    const service = await makeService();
    const first = service.issueQrToken();
    const second = service.issueQrToken();
    const devices = service.listDevices();
    expect(devices).toHaveLength(1);
    expect(devices[0].deviceId).toBe(second.device.deviceId);
    expect(service.authenticate(first.token)).toBeNull();
    expect(service.authenticate(second.token)).not.toBeNull();
  });

  it("keeps QR tokens that already connected", async () => {
    const service = await makeService();
    const first = service.issueQrToken();
    service.authenticate(first.token); // lastSeen 非空
    service.issueQrToken();
    expect(service.listDevices()).toHaveLength(2);
  });
});

describe("PairingService 6 位配对码", () => {
  it("issues a 6-digit code valid for 5 minutes and redeems it once", async () => {
    const service = await makeService();
    const { code, expiresAtMs } = service.ensurePairingCode();
    expect(code).toMatch(/^\d{6}$/);
    expect(expiresAtMs).toBeGreaterThan(Date.now());
    // 未过期前复用同一个码。
    expect(service.ensurePairingCode().code).toBe(code);

    const ok = service.redeemPairingCode("192.168.1.10", code, "手机 C");
    expect(ok.ok).toBe(true);
    if (ok.ok) expect(ok.device.via).toBe("code");

    const replay = service.redeemPairingCode("192.168.1.10", code, "手机 C");
    expect(replay.ok).toBe(false);
  });

  it("rejects expired codes", async () => {
    let now = 1_000_000;
    const service = await makeService(() => now);
    const { code } = service.ensurePairingCode();
    now += 5 * 60_000 + 1;
    const result = service.redeemPairingCode("192.168.1.10", code, "手机");
    expect(result).toEqual({ ok: false, error: "invalid_code" });
  });

  it("rate-limits /pair attempts to 5 per IP per minute", async () => {
    let now = 1_000_000;
    const service = await makeService(() => now);
    service.ensurePairingCode();
    for (let i = 0; i < 5; i += 1) {
      expect(service.redeemPairingCode("10.0.0.9", "bad", "x").ok).toBe(false);
    }
    const limited = service.redeemPairingCode("10.0.0.9", "bad", "x");
    expect(limited).toEqual({ ok: false, error: "rate_limited" });
    // 不同 IP 不受影响。
    const other = service.redeemPairingCode("10.0.0.10", "bad", "x");
    expect(other).toEqual({ ok: false, error: "invalid_code" });
    // 窗口滑过后恢复。
    now += 61_000;
    expect(service.redeemPairingCode("10.0.0.9", "bad", "x")).toEqual({ ok: false, error: "invalid_code" });
  });
});

describe("PairingService Bearer 鉴权限流", () => {
  it("returns missing for absent headers, invalid for bad tokens, ok for real ones", async () => {
    const service = await makeService();
    const { token } = service.issueToken("手机", "code");
    expect(service.checkBearerAuth(undefined, "10.0.0.1")).toEqual({ ok: false, reason: "missing" });
    expect(service.checkBearerAuth("Bearer nope", "10.0.0.1")).toEqual({ ok: false, reason: "invalid" });
    const ok = service.checkBearerAuth(`Bearer ${token}`, "10.0.0.1");
    expect(ok.ok).toBe(true);
  });

  it("counts per-socket failures toward the 5-per-connection limit", async () => {
    const service = await makeService();
    const socket = {};
    for (let i = 0; i < AUTH_FAILURES_PER_CONNECTION_LIMIT; i += 1) {
      service.checkBearerAuth("Bearer bad", "10.1.1.1", socket);
    }
    expect(service.socketFailureCount(socket)).toBe(AUTH_FAILURES_PER_CONNECTION_LIMIT);
    expect(service.socketFailureCount({})).toBe(0);
  });

  it("bans an IP for 60s after >10 failures per minute", async () => {
    let now = 1_000_000;
    const service = await makeService(() => now);
    const { token } = service.issueToken("手机", "code");
    for (let i = 0; i < 11; i += 1) {
      service.checkBearerAuth("Bearer bad", "172.16.0.2", null as unknown as object);
    }
    expect(service.checkBearerAuth(`Bearer ${token}`, "172.16.0.2")).toEqual({ ok: false, reason: "banned" });
    now += 61_000;
    const ok = service.checkBearerAuth(`Bearer ${token}`, "172.16.0.2");
    expect(ok.ok).toBe(true);
  });
});
