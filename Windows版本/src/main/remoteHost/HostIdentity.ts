// HostIdentity —— host 端 TLS 身份（契约 §4.3）。
// 用 selfsigned 生成 ECDSA P-256 自签证书（CN=acode-host，10 年有效），
// 私钥+证书以 PEM 持久化在 userData/remote-host-tls/（文件权限 0600，仅本机账户可读）。
// 客户端校验只认 SPKI-SHA256 pin（fp 进配对载荷），证书轮换 → 指纹变 → 必须重新配对。

import { createHash, X509Certificate } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { generate } from "selfsigned";

export interface HostIdentity {
  certPem: string;
  keyPem: string;
  /** SPKI-SHA256 hex，对应配对载荷的 `fp` 字段。 */
  fingerprintHex: string;
}

const CERT_COMMON_NAME = "acode-host";
const CERT_LIFETIME_YEARS = 10;
const IDENTITY_DIR = "remote-host-tls";
const KEY_FILE = "key.pem";
const CERT_FILE = "cert.pem";

/** 证书 SPKI（DER）的 SHA-256 hex —— 四端统一的 pinning 指纹。 */
export function spkiSha256Hex(certPem: string): string {
  const cert = new X509Certificate(certPem);
  const spkiDer = cert.publicKey.export({ format: "der", type: "spki" });
  return createHash("sha256").update(spkiDer).digest("hex");
}

async function generateIdentity(): Promise<HostIdentity> {
  const notAfter = new Date();
  notAfter.setFullYear(notAfter.getFullYear() + CERT_LIFETIME_YEARS);
  const pems = await generate([{ name: "commonName", value: CERT_COMMON_NAME }], {
    keyType: "ec",
    curve: "P-256",
    algorithm: "sha256",
    notAfterDate: notAfter
  });
  return { certPem: pems.cert, keyPem: pems.private, fingerprintHex: spkiSha256Hex(pems.cert) };
}

async function bestEffortUserOnly(filePath: string): Promise<void> {
  try {
    await chmod(filePath, 0o600);
  } catch {
    // Windows NTFS 上 POSIX chmod 是 no-op；ACL 默认已是仅当前用户，忽略失败。
  }
}

/** 读已持久化的身份；文件缺失/损坏时返回 null，由调用方重新生成。 */
async function readIdentity(dir: string): Promise<HostIdentity | null> {
  try {
    const [keyPem, certPem] = await Promise.all([
      readFile(path.join(dir, KEY_FILE), "utf8"),
      readFile(path.join(dir, CERT_FILE), "utf8")
    ]);
    // 解析失败（文件截断/损坏）视同不存在，走重新生成。
    return { certPem, keyPem, fingerprintHex: spkiSha256Hex(certPem) };
  } catch {
    return null;
  }
}

/** 加载或生成 host TLS 身份。生成只发生在首次启用/文件损坏时。 */
export async function loadOrCreateHostIdentity(userDataDir: string): Promise<HostIdentity> {
  const dir = path.join(userDataDir, IDENTITY_DIR);
  const existing = await readIdentity(dir);
  if (existing) return existing;

  const identity = await generateIdentity();
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, KEY_FILE), identity.keyPem, "utf8");
  await writeFile(path.join(dir, CERT_FILE), identity.certPem, "utf8");
  await bestEffortUserOnly(path.join(dir, KEY_FILE));
  await bestEffortUserOnly(path.join(dir, CERT_FILE));
  return identity;
}
