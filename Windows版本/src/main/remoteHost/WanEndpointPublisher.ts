// WanEndpointPublisher —— host 端「对外发布」模块（契约 §5）。
// 周期性产出 eps 候选列表 + 诊断状态：
//   1. 枚举全球 IPv6（排除 link-local/ULA，EUI-64 形态排前）；
//   2. IPv4 走 NAT-PMP（首选，UDP:5351）→ UPnP IGD（兜底）映射 TCP 端口；
//   3. CGNAT 自检：路由器上报的外部 IPv4 是非公网 → IPv4 候选不可用；
//   4. 映射按 lifetime/2 续期；诊断状态给设置页展示 + 手动转发指引。
// PCP（RFC 6887）后置：接口预留 pcp 字段，v2 可插在 NAT-PMP 与 UPnP 之间。

import os from "node:os";

import { gateway4async } from "default-gateway";

import { isGlobalIPv6Address, isNonPublicIPv4, ipv6HasEui64InterfaceId } from "./ipRanges.js";
import { NatPmpClient } from "./NatPmp.js";
import { UpnpIgdClient, type IgdControlPoint } from "./UpnpIgd.js";

const NAT_PMP_LIFETIME_SECONDS = 3600;
const UPNP_LEASE_SECONDS = 3600;
const PERIODIC_REFRESH_MS = 30 * 60_000;
/** 拿不到网关/映射失败时的快速重试间隔（网络可能在恢复中）。 */
const RETRY_REFRESH_MS = 60_000;

export type WanEndpointKind = "ipv6" | "ipv4-mapped" | "lan";
/** "ok"=路由器已确认映射可用；"unverified"=地址存在但入站可达性未经外部验证。 */
export type WanEndpointStatus = "ok" | "unverified";

export interface WanEndpoint {
  a: string;
  p: number;
  kind: WanEndpointKind;
  status: WanEndpointStatus;
}

export interface WanDiagnostics {
  /** 按契约排序：全球 IPv6 在前，映射 IPv4 在后，LAN IPv4 垫底。 */
  endpoints: WanEndpoint[];
  gatewayIPv4: string | null;
  externalIPv4: string | null;
  /** 外部 IPv4 落在 CGNAT/私网段 → 上游还有 NAT，IPv4 候选不可用。 */
  cgnatIPv4: boolean;
  mappingMethod: "nat-pmp" | "upnp" | "none";
  /** 设置页展示用中文诊断文案。 */
  notes: string[];
  lastRefreshAt: string | null;
}

export interface NatPmpLike {
  getExternalAddress(): Promise<{ externalIp: string }>;
  mapTcp(internalPort: number, suggestedExternalPort: number, lifetimeSeconds: number): Promise<{ externalPort: number; lifetimeSeconds: number }>;
}

export interface UpnpLike {
  discoverControlPoint(): Promise<IgdControlPoint | null>;
  getExternalIpAddress(point: IgdControlPoint): Promise<string | null>;
  addTcpPortMapping(
    point: IgdControlPoint,
    options: { internalClient: string; internalPort: number; externalPort: number; leaseSeconds: number; description: string }
  ): Promise<{ externalPort: number; leaseSeconds: number }>;
}

export interface WanEndpointPublisherDeps {
  port: number;
  networkInterfaces?: () => ReturnType<typeof os.networkInterfaces>;
  gatewayResolver?: () => Promise<string | null>;
  natPmpFactory?: (gateway: string) => NatPmpLike;
  upnpFactory?: () => UpnpLike;
  lanIPv4?: () => string | null;
  onUpdate?: (diagnostics: WanDiagnostics) => void;
}

/** 全球 IPv6 枚举（纯函数，可测）：排除 link-local/ULA/loopback，EUI-64 排前。 */
export function pickGlobalIPv6(interfaces: ReturnType<typeof os.networkInterfaces>): string[] {
  const seen = new Set<string>();
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv6" || entry.internal) continue;
      if (isGlobalIPv6Address(entry.address)) seen.add(entry.address);
    }
  }
  return [...seen].sort((a, b) => Number(ipv6HasEui64InterfaceId(b)) - Number(ipv6HasEui64InterfaceId(a)));
}

async function defaultGatewayResolver(): Promise<string | null> {
  try {
    const result = await gateway4async();
    return result.gateway;
  } catch {
    return null;
  }
}

export class WanEndpointPublisher {
  private readonly deps: WanEndpointPublisherDeps;
  private diagnostics: WanDiagnostics = {
    endpoints: [],
    gatewayIPv4: null,
    externalIPv4: null,
    cgnatIPv4: false,
    mappingMethod: "none",
    notes: [],
    lastRefreshAt: null
  };
  private refreshTimer: NodeJS.Timeout | null = null;
  private refreshing: Promise<void> | null = null;
  private running = false;
  /** 最近一次成功映射实际授予的 lifetime（NAT-PMP/UPnP），用于 lifetime/2 续期。 */
  private mappingLifetimeSeconds: number | null = null;

  constructor(deps: WanEndpointPublisherDeps) {
    this.deps = deps;
  }

  getDiagnostics(): WanDiagnostics {
    return this.diagnostics;
  }

  /**
   * 契约 §4.4 eps：对外发布仅 WAN 候选（全球 v6 → 映射 v4），与 Mac 一致不含 LAN 地址——
   * 客户端侧会把「完成握手/配对时所用地址」自行并入 eps（Android EndpointStore 同款逻辑），
   * QR/连接串里塞 LAN 地址反而会让离线扫码的手机多一次必然失败的竞速。
   * LAN 行仍保留在 diagnostics.endpoints 供设置页展示。
   */
  getEndpoints(): Array<{ a: string; p: number }> {
    return this.diagnostics.endpoints
      .filter((endpoint) => endpoint.kind !== "lan")
      .map((endpoint) => ({ a: endpoint.a, p: endpoint.p }));
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    void this.refresh();
  }

  async stop(): Promise<void> {
    this.running = false;
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
    if (this.refreshing) {
      await this.refreshing.catch(() => undefined);
    }
  }

  /** 强制刷一轮（设置页「刷新诊断」/启动/续期定时器共用）。 */
  refresh(): Promise<void> {
    if (!this.refreshing) {
      this.refreshing = this.doRefresh()
        .catch(() => undefined)
        .finally(() => {
          this.refreshing = null;
          this.scheduleNext();
        });
    }
    return this.refreshing;
  }

  private scheduleNext(): void {
    if (!this.running) return;
    const base = this.diagnostics.gatewayIPv4 ? PERIODIC_REFRESH_MS : RETRY_REFRESH_MS;
    // 按授予 lifetime/2 续期（契约 §5.2）；无映射/永久租约走周期刷新。
    const renewMs = this.mappingLifetimeSeconds !== null && this.mappingLifetimeSeconds > 0
      ? (this.mappingLifetimeSeconds / 2) * 1000
      : Number.POSITIVE_INFINITY;
    const delay = Math.min(base, renewMs);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      void this.refresh();
    }, delay);
    this.refreshTimer.unref?.();
  }

  private async doRefresh(): Promise<void> {
    const port = this.deps.port;
    this.mappingLifetimeSeconds = null; // 由本轮映射结果重填
    const interfaces = (this.deps.networkInterfaces ?? os.networkInterfaces)();
    const ipv6Addresses = pickGlobalIPv6(interfaces);
    const lanIp = (this.deps.lanIPv4 ?? (() => null))();

    const endpoints: WanEndpoint[] = ipv6Addresses.map((address) => ({
      a: address,
      p: port,
      kind: "ipv6",
      // 无法自证入站可达（需外部探测）：标 unverified，由文案提示防火墙放行。
      status: "unverified"
    }));

    let gateway: string | null = null;
    let externalIp: string | null = null;
    let cgnat = false;
    let mappingMethod: WanDiagnostics["mappingMethod"] = "none";
    let mappingError: string | null = null;

    try {
      gateway = await (this.deps.gatewayResolver ?? defaultGatewayResolver)();
    } catch {
      gateway = null;
    }

    if (gateway) {
      // NAT-PMP 首选。
      const pmp = (this.deps.natPmpFactory ?? ((gw) => new NatPmpClient(gw)))(gateway);
      try {
        const external = await pmp.getExternalAddress();
        externalIp = external.externalIp;
        if (isNonPublicIPv4(externalIp)) {
          cgnat = true;
        } else {
          const mapping = await pmp.mapTcp(port, 0, NAT_PMP_LIFETIME_SECONDS);
          mappingMethod = "nat-pmp";
          this.mappingLifetimeSeconds = mapping.lifetimeSeconds;
          endpoints.push({ a: externalIp, p: mapping.externalPort, kind: "ipv4-mapped", status: "ok" });
        }
      } catch (error) {
        mappingError = error instanceof Error ? error.message : String(error);
      }

      // UPnP IGD 兜底：仅在 NAT-PMP 失败（非 CGNAT）时尝试。
      if (!cgnat && mappingMethod === "none") {
        const upnp = (this.deps.upnpFactory ?? (() => new UpnpIgdClient()))();
        try {
          const point = await upnp.discoverControlPoint();
          if (point) {
            const upnpExternal = await upnp.getExternalIpAddress(point);
            if (upnpExternal) externalIp = upnpExternal;
            if (upnpExternal && isNonPublicIPv4(upnpExternal)) {
              cgnat = true;
            } else if (upnpExternal && lanIp) {
              const mapping = await upnp.addTcpPortMapping(point, {
                internalClient: lanIp,
                internalPort: port,
                externalPort: port,
                leaseSeconds: UPNP_LEASE_SECONDS,
                description: "acode remote"
              });
              mappingMethod = "upnp";
              // UPnP 兜底已成功：清掉 NAT-PMP 留下的失败信息，避免诊断误报「映射失败」。
              mappingError = null;
              // leaseSeconds=0 表示永久租约，无需续期（归一为 null 走周期刷新）。
              this.mappingLifetimeSeconds = mapping.leaseSeconds > 0 ? mapping.leaseSeconds : null;
              endpoints.push({ a: upnpExternal, p: mapping.externalPort, kind: "ipv4-mapped", status: "ok" });
            }
          } else {
            mappingError ??= "未发现 UPnP IGD";
          }
        } catch (error) {
          mappingError = error instanceof Error ? error.message : String(error);
        }
      }
    }

    if (lanIp) {
      endpoints.push({ a: lanIp, p: port, kind: "lan", status: "ok" });
    }

    const notes: string[] = [];
    if (endpoints.length > 0) notes.push("直连可用");
    if (ipv6Addresses.length === 0) notes.push("无全球IPv6");
    if (cgnat) notes.push("CGNAT：运营商级 NAT，IPv4 映射不可用");
    if (gateway === null) notes.push("未找到默认网关，跳过端口映射");
    if (mappingMethod === "none" && !cgnat && gateway !== null) {
      notes.push("路由器不支持自动映射，需手动端口转发");
    }
    if (mappingError) notes.push(`端口映射失败：${mappingError}`);
    if (endpoints.length === 0) {
      notes.push("当前网络无法直连：既无全球 IPv6 也未映射到公网 IPv4");
    }
    // 防火墙检测能力平台差异大（契约 §5.4 标注 🔴）：给固定指引文案。
    notes.push(`如无法连接，请在 Windows 防火墙放行 TCP ${port} 入站`);

    this.diagnostics = {
      endpoints,
      gatewayIPv4: gateway,
      externalIPv4: externalIp,
      cgnatIPv4: cgnat,
      mappingMethod,
      notes,
      lastRefreshAt: new Date().toISOString()
    };
    this.deps.onUpdate?.(this.diagnostics);
  }
}
