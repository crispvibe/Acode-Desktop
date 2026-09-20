import { createPrivateKey, X509Certificate } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { loadOrCreateHostIdentity, spkiSha256Hex } from "../../../src/main/remoteHost/HostIdentity";

const tempDirs: string[] = [];

afterEach(async () => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) await rm(dir, { recursive: true, force: true });
  }
});

async function freshDir(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "acode-identity-test-"));
  tempDirs.push(dir);
  return dir;
}

describe("HostIdentity（契约 §4.3：ECDSA P-256 / CN=acode-host / 10 年）", () => {
  it("generates a P-256 self-signed cert and persists it under userData", async () => {
    const dir = await freshDir();
    const identity = await loadOrCreateHostIdentity(dir);

    const key = createPrivateKey(identity.keyPem);
    expect(key.asymmetricKeyType).toBe("ec");
    expect(key.asymmetricKeyDetails?.namedCurve).toBe("prime256v1");

    const cert = new X509Certificate(identity.certPem);
    expect(cert.subject).toContain("CN=acode-host");
    expect(cert.issuer).toBe(cert.subject); // 自签
    const years = (new Date(cert.validTo).getTime() - new Date(cert.validFrom).getTime()) / (365.25 * 24 * 3600 * 1000);
    expect(years).toBeGreaterThan(9.5);

    // SPKI-SHA256 hex = 64 hex chars。
    expect(identity.fingerprintHex).toMatch(/^[0-9a-f]{64}$/);
    expect(identity.fingerprintHex).toBe(spkiSha256Hex(identity.certPem));
  });

  it("reloads the same identity on the second call（指纹稳定）", async () => {
    const dir = await freshDir();
    const first = await loadOrCreateHostIdentity(dir);
    const second = await loadOrCreateHostIdentity(dir);
    expect(second.fingerprintHex).toBe(first.fingerprintHex);
    expect(second.keyPem).toBe(first.keyPem);
  });
});
