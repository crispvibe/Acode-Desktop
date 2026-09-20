import os from "node:os";

function isPrivateIPv4(host: string): boolean {
  const octets = host.trim().split(".").map((part) => Number.parseInt(part, 10));
  if (octets.length !== 4 || octets.some((value) => Number.isNaN(value) || value < 0 || value > 255)) {
    return false;
  }
  if (octets[0] === 10) return true;
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  if (octets[0] === 192 && octets[1] === 168) return true;
  return false;
}

export function localLanIPv4(): string | null {
  const interfaces = os.networkInterfaces();
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      if (isPrivateIPv4(entry.address)) return entry.address;
    }
  }
  return null;
}

export function lanSubnetPrefix(): string | null {
  const ip = localLanIPv4();
  if (!ip) return null;
  const octets = ip.split(".");
  if (octets.length !== 4) return null;
  return octets.slice(0, 3).join(".");
}

async function healthOk(host: string, port: number): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1_000);
  try {
    const response = await fetch(`http://${host}:${port}/health`, { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

export async function discoverHealthHost(port: number, preferredHost?: string | null): Promise<string | null> {
  if (preferredHost && await healthOk(preferredHost, port)) {
    return preferredHost;
  }
  const prefix = lanSubnetPrefix();
  if (!prefix) return null;
  for (let host = 1; host <= 254; host += 1) {
    const ip = `${prefix}.${host}`;
    if (ip === preferredHost) continue;
    if (await healthOk(ip, port)) return ip;
  }
  return null;
}
