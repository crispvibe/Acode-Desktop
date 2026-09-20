// 配对载荷（契约 §4.4）：`acode://pair?d=<base64url(JSON)>`。
// JSON: {v:1, n:主机名, eps:[{a,p}], t:token base64url, fp:SPKI-SHA256 hex}
// 二维码与「复制连接串」共用同一载荷。

export interface PairingEndpoint {
  a: string;
  p: number;
}

export interface PairingPayload {
  v: 1;
  n: string;
  eps: PairingEndpoint[];
  t: string;
  fp: string;
}

export function buildPairingUri(payload: PairingPayload): string {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  return `acode://pair?d=${encoded}`;
}

/** 反向解析，供测试与调试核对载荷内容。 */
export function parsePairingUri(uri: string): PairingPayload | null {
  const match = /^acode:\/\/pair\?d=([A-Za-z0-9_-]+)$/.exec(uri);
  if (!match) return null;
  try {
    const parsed = JSON.parse(Buffer.from(match[1], "base64url").toString("utf8")) as PairingPayload;
    return parsed.v === 1 ? parsed : null;
  } catch {
    return null;
  }
}
