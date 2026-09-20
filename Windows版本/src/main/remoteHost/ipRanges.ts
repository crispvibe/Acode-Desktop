// ipRanges —— WAN 直连的 IP 地址分类纯函数。
// 契约（remote-chat-wan-direct.md §4.2/§5）：
//   - /pair 仅接受私网来源：RFC1918 + link-local + loopback（IPv6 侧对应 ULA + link-local + ::1）。
//   - 全球 IPv6 候选：排除 link-local(fe80::/10) / ULA(fc00::/7) / loopback / v4-mapped。
//   - CGNAT 自检：路由器上报的外部 IPv4 落在 100.64/10、10/8、172.16/12、192.168/16 → 上游还有 NAT。

import { isIPv4, isIPv6 } from "node:net";

/** 把 `::ffff:a.b.c.d` 归一成 `a.b.c.d`，其余原样返回。 */
export function normalizeIPv4Mapped(address: string): string {
  const match = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(address.trim());
  return match ? match[1] : address.trim();
}

/** IPv6 → 8 个 hextet；含嵌入 IPv4 写法（::ffff:1.2.3.4 / ::1.2.3.4）。解析失败返回 null。 */
function ipv6Hextets(address: string): number[] | null {
  if (!isIPv6(address)) return null;
  let text = address.trim().toLowerCase();
  const zoneIndex = text.indexOf("%");
  if (zoneIndex >= 0) text = text.slice(0, zoneIndex);
  const embedded = /^(.+:)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(text);
  if (embedded) {
    const octets = embedded[2].split(".").map((part) => Number.parseInt(part, 10));
    if (octets.some((value) => Number.isNaN(value) || value > 255)) return null;
    const hi = ((octets[0] << 8) | octets[1]).toString(16);
    const lo = ((octets[2] << 8) | octets[3]).toString(16);
    text = `${embedded[1]}${hi}:${lo}`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] === "" ? [] : halves[0].split(":");
  const tail = halves.length === 2 ? (halves[1] === "" ? [] : halves[1].split(":")) : [];
  const hextets: number[] = [];
  for (const part of [...head, ...tail]) {
    if (!/^[0-9a-f]{1,4}$/.test(part)) return null;
    hextets.push(Number.parseInt(part, 16));
  }
  if (halves.length === 1) {
    if (hextets.length !== 8) return null;
    return hextets;
  }
  const missing = 8 - hextets.length;
  if (missing <= 0) return null;
  return [...head.map((part) => Number.parseInt(part, 16)), ...Array<number>(missing).fill(0), ...tail.map((part) => Number.parseInt(part, 16))];
}

function ipv4Octets(address: string): number[] | null {
  if (!isIPv4(address)) return null;
  return address.split(".").map((part) => Number.parseInt(part, 10));
}

/** 127.0.0.0/8 或 ::1。 */
export function isLoopbackAddress(address: string): boolean {
  const ip = normalizeIPv4Mapped(address);
  const octets = ipv4Octets(ip);
  if (octets) return octets[0] === 127;
  const hextets = ipv6Hextets(ip);
  return hextets !== null && hextets.slice(0, 7).every((value) => value === 0) && hextets[7] === 1;
}

/** RFC1918：10/8、172.16/12、192.168/16。 */
export function isPrivateIPv4(address: string): boolean {
  const octets = ipv4Octets(normalizeIPv4Mapped(address));
  if (!octets) return false;
  if (octets[0] === 10) return true;
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] === 192 && octets[1] === 168) return true;
  return false;
}

/** IPv4 169.254.0.0/16；IPv6 fe80::/10。 */
export function isLinkLocalAddress(address: string): boolean {
  const ip = normalizeIPv4Mapped(address);
  const octets = ipv4Octets(ip);
  if (octets) return octets[0] === 169 && octets[1] === 254;
  const hextets = ipv6Hextets(ip);
  return hextets !== null && (hextets[0] & 0xffc0) === 0xfe80;
}

/** IPv6 ULA：fc00::/7。 */
export function isUlaIPv6(address: string): boolean {
  const hextets = ipv6Hextets(normalizeIPv4Mapped(address));
  return hextets !== null && (hextets[0] & 0xfe00) === 0xfc00;
}

/** ::/128 或 0.0.0.0。 */
export function isUnspecifiedAddress(address: string): boolean {
  const ip = normalizeIPv4Mapped(address);
  if (ipv4Octets(ip)) return ip === "0.0.0.0";
  const hextets = ipv6Hextets(ip);
  return hextets !== null && hextets.every((value) => value === 0);
}

/**
 * /pair 来源门槛：仅私网/回环。IPv4 = RFC1918 + 169.254/16 + 127/8；
 * IPv6 = ULA(fc00::/7) + link-local(fe80::/10) + ::1。全球单播来源一律视为 WAN 拒绝。
 */
export function isPrivateSourceAddress(address: string | null | undefined): boolean {
  if (!address) return false;
  const ip = normalizeIPv4Mapped(address);
  return isPrivateIPv4(ip) || isLinkLocalAddress(ip) || isLoopbackAddress(ip) || isUlaIPv6(ip);
}

/** 全球单播 IPv6 候选：排除 link-local / ULA / loopback / v4-mapped / 未指定 / 组播。 */
export function isGlobalIPv6Address(address: string): boolean {
  const ip = normalizeIPv4Mapped(address);
  if (!isIPv6(ip)) return false; // 纯 IPv4 与 v4-mapped（已归一成 IPv4 文本）在此被排除
  if (isLinkLocalAddress(ip) || isUlaIPv6(ip) || isLoopbackAddress(ip) || isUnspecifiedAddress(ip)) return false;
  const hextets = ipv6Hextets(ip);
  if (!hextets) return false;
  if ((hextets[0] & 0xff00) === 0xff00) return false; // 组播不会出现在接口上，防御性排除
  return true;
}

/** EUI-64 形态（接口 ID 中间插入 ff:fe）排前，与 Mac 端优先级一致。 */
export function ipv6HasEui64InterfaceId(address: string): boolean {
  const hextets = ipv6Hextets(address);
  if (!hextets) return false;
  return (hextets[5] & 0x00ff) === 0x00ff && (hextets[6] & 0xff00) === 0xfe00;
}

/**
 * CGNAT/非公网 IPv4：100.64.0.0/10（CGNAT）、10/8、172.16/12、192.168/16、
 * 169.254/16（link-local）、127/8（loopback）、0.0.0.0。命中 → 上游还有 NAT，映射无意义。
 */
export function isNonPublicIPv4(address: string): boolean {
  const octets = ipv4Octets(normalizeIPv4Mapped(address));
  if (!octets) return true;
  if (isPrivateIPv4(address)) return true;
  if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return true;
  if (octets[0] === 169 && octets[1] === 254) return true;
  if (octets[0] === 127) return true;
  if (octets[0] === 0) return true;
  return false;
}
