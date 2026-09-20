import { describe, expect, it } from "vitest";
import type { NetworkInterfaceInfo } from "node:os";

import { buildPairingUri, parsePairingUri } from "../../../src/main/remoteHost/pairingPayload";
import {
  pickGlobalIPv6,
  WanEndpointPublisher,
  type NatPmpLike,
  type UpnpLike
} from "../../../src/main/remoteHost/WanEndpointPublisher";
import type { IgdControlPoint } from "../../../src/main/remoteHost/UpnpIgd";

function iface(family: string, address: string, internal = false): NetworkInterfaceInfo[] {
  return [{ address, family, internal, netmask: "", mac: "", cidr: null, scopeid: 0 }];
}

describe("pickGlobalIPv6", () => {
  it("excludes link-local/ULA/loopback/internal and ranks EUI-64 first", () => {
    const picked = pickGlobalIPv6({
      eth0: [
        ...iface("IPv6", "2409:8a55::1234"),           // 全球单播
        ...iface("IPv6", "fe80::abcd"),                 // link-local
        ...iface("IPv6", "fd00::9"),                    // ULA
        ...iface("IPv6", "2409:8a55:0:0:aaaa:bbff:fecc:dddd"), // EUI-64 全球
        ...iface("IPv4", "192.168.1.2")
      ],
      lo: iface("IPv6", "::1", true)
    });
    expect(picked).toHaveLength(2);
    expect(picked[0]).toBe("2409:8a55:0:0:aaaa:bbff:fecc:dddd"); // EUI-64 排前
    expect(picked[1]).toBe("2409:8a55::1234");
  });
});

describe("WanEndpointPublisher", () => {
  const interfacesWithV6 = {
    eth0: [...iface("IPv6", "2409:8a55::1234"), ...iface("IPv4", "192.168.1.2")]
  };

  function pmp(overrides: Partial<NatPmpLike> = {}): NatPmpLike {
    return {
      getExternalAddress: async () => ({ externalIp: "203.0.113.5" }),
      mapTcp: async (_internal, _suggested, lifetime) => ({ externalPort: 50443, lifetimeSeconds: lifetime }),
      ...overrides
    };
  }

  function upnp(overrides: Partial<UpnpLike> = {}): UpnpLike {
    const point: IgdControlPoint = { controlUrl: "http://gw/ctl", serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1" };
    return {
      discoverControlPoint: async () => point,
      getExternalIpAddress: async () => "203.0.113.9",
      addTcpPortMapping: async (_p, o) => ({ externalPort: o.externalPort, leaseSeconds: o.leaseSeconds }),
      ...overrides
    };
  }

  it("publishes global IPv6 first, then NAT-PMP mapped IPv4, LAN last", async () => {
    const publisher = new WanEndpointPublisher({
      port: 18765,
      networkInterfaces: () => interfacesWithV6,
      gatewayResolver: async () => "192.168.1.1",
      natPmpFactory: () => pmp(),
      upnpFactory: () => upnp(),
      lanIPv4: () => "192.168.1.2"
    });
    await publisher.refresh();
    const diagnostics = publisher.getDiagnostics();
    expect(diagnostics.mappingMethod).toBe("nat-pmp");
    expect(diagnostics.endpoints.map((e) => `${e.a}:${e.p}`)).toEqual([
      "2409:8a55::1234:18765",
      "203.0.113.5:50443",
      "192.168.1.2:18765"
    ]);
    expect(diagnostics.endpoints[0].status).toBe("unverified");
    expect(diagnostics.endpoints[1].status).toBe("ok");
    // 对外 eps（QR/连接串/pair/connect_info）只发 WAN 候选，与 Mac 一致不含 LAN；
    // LAN 地址由客户端自己并入（扫码/握手所用地址），诊断里仍展示。
    expect(publisher.getEndpoints()).toEqual([
      { a: "2409:8a55::1234", p: 18765 },
      { a: "203.0.113.5", p: 50443 }
    ]);
    expect(diagnostics.notes).toContain("直连可用");
  });

  it("flags CGNAT when the router's external IPv4 is non-public and skips mapping", async () => {
    let mapped = false;
    const publisher = new WanEndpointPublisher({
      port: 18765,
      networkInterfaces: () => interfacesWithV6,
      gatewayResolver: async () => "192.168.1.1",
      natPmpFactory: () => pmp({
        getExternalAddress: async () => ({ externalIp: "100.64.1.1" }),
        mapTcp: async () => {
          mapped = true;
          return { externalPort: 50443, lifetimeSeconds: 3600 };
        }
      }),
      upnpFactory: () => upnp(),
      lanIPv4: () => "192.168.1.2"
    });
    await publisher.refresh();
    const diagnostics = publisher.getDiagnostics();
    expect(diagnostics.cgnatIPv4).toBe(true);
    expect(diagnostics.mappingMethod).toBe("none");
    expect(mapped).toBe(false); // CGNAT 下不再做无用映射
    expect(diagnostics.notes.some((note) => note.includes("CGNAT"))).toBe(true);
    expect(diagnostics.endpoints.some((e) => e.kind === "ipv4-mapped")).toBe(false);
  });

  it("falls back to UPnP when NAT-PMP fails", async () => {
    const publisher = new WanEndpointPublisher({
      port: 18765,
      networkInterfaces: () => ({ eth0: iface("IPv4", "192.168.1.2") }),
      gatewayResolver: async () => "192.168.1.1",
      natPmpFactory: () => pmp({ getExternalAddress: async () => { throw new Error("timeout"); } }),
      upnpFactory: () => upnp(),
      lanIPv4: () => "192.168.1.2"
    });
    await publisher.refresh();
    const diagnostics = publisher.getDiagnostics();
    expect(diagnostics.mappingMethod).toBe("upnp");
    expect(diagnostics.endpoints.map((e) => `${e.a}:${e.p}`)).toEqual([
      "203.0.113.9:18765",
      "192.168.1.2:18765"
    ]);
    expect(diagnostics.notes).toContain("无全球IPv6");
  });

  it("reports manual-forwarding guidance when neither protocol works", async () => {
    const publisher = new WanEndpointPublisher({
      port: 18765,
      networkInterfaces: () => ({ eth0: iface("IPv4", "192.168.1.2") }),
      gatewayResolver: async () => "192.168.1.1",
      natPmpFactory: () => pmp({ getExternalAddress: async () => { throw new Error("timeout"); } }),
      upnpFactory: () => upnp({ discoverControlPoint: async () => null }),
      lanIPv4: () => "192.168.1.2"
    });
    await publisher.refresh();
    const diagnostics = publisher.getDiagnostics();
    expect(diagnostics.mappingMethod).toBe("none");
    expect(diagnostics.notes).toContain("路由器不支持自动映射，需手动端口转发");
    // LAN 地址仍发布，同网段可用。
    expect(diagnostics.endpoints.map((e) => e.a)).toEqual(["192.168.1.2"]);
  });

  it("reports unreachable when there is neither IPv6 nor a public IPv4", async () => {
    const publisher = new WanEndpointPublisher({
      port: 18765,
      networkInterfaces: () => ({}),
      gatewayResolver: async () => null,
      lanIPv4: () => null
    });
    await publisher.refresh();
    const diagnostics = publisher.getDiagnostics();
    expect(diagnostics.endpoints).toHaveLength(0);
    expect(diagnostics.notes.some((note) => note.includes("无法直连"))).toBe(true);
  });
});

describe("pairingPayload（契约 §4.4）", () => {
  it("round-trips acode://pair?d=<base64url(JSON)>", () => {
    const uri = buildPairingUri({
      v: 1,
      n: "Oreo 的 Windows",
      eps: [{ a: "2409:8a55::1234", p: 18765 }, { a: "203.0.113.5", p: 50443 }],
      t: "dGVzdC10b2tlbg",
      fp: "1812cd8d545aea31a84ab041dcd90600158728e95aa93b16bfb03583c80a69e9"
    });
    expect(uri.startsWith("acode://pair?d=")).toBe(true);
    expect(parsePairingUri(uri)).toEqual({
      v: 1,
      n: "Oreo 的 Windows",
      eps: [{ a: "2409:8a55::1234", p: 18765 }, { a: "203.0.113.5", p: 50443 }],
      t: "dGVzdC10b2tlbg",
      fp: "1812cd8d545aea31a84ab041dcd90600158728e95aa93b16bfb03583c80a69e9"
    });
    expect(parsePairingUri("acode://pair?d=!!!")).toBeNull();
    expect(parsePairingUri("https://evil")).toBeNull();
  });
});
