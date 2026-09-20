import { describe, expect, it } from "vitest";

import {
  isGlobalIPv6Address,
  isLinkLocalAddress,
  isLoopbackAddress,
  isNonPublicIPv4,
  isPrivateIPv4,
  isPrivateSourceAddress,
  isUlaIPv6,
  ipv6HasEui64InterfaceId,
  normalizeIPv4Mapped
} from "../../../src/main/remoteHost/ipRanges";

describe("ipRanges.normalizeIPv4Mapped", () => {
  it("strips the ::ffff: prefix", () => {
    expect(normalizeIPv4Mapped("::ffff:192.168.1.2")).toBe("192.168.1.2");
    expect(normalizeIPv4Mapped("::FFFF:10.0.0.1")).toBe("10.0.0.1");
  });
  it("leaves normal addresses untouched", () => {
    expect(normalizeIPv4Mapped("127.0.0.1")).toBe("127.0.0.1");
    expect(normalizeIPv4Mapped("2409:8a55::1234")).toBe("2409:8a55::1234");
  });
});

describe("ipRanges.isLoopbackAddress", () => {
  it("detects v4 and v6 loopback", () => {
    expect(isLoopbackAddress("127.0.0.1")).toBe(true);
    expect(isLoopbackAddress("127.5.6.7")).toBe(true);
    expect(isLoopbackAddress("::1")).toBe(true);
    expect(isLoopbackAddress("::ffff:127.0.0.1")).toBe(true);
    expect(isLoopbackAddress("192.168.1.1")).toBe(false);
  });
});

describe("ipRanges.isPrivateIPv4 / isLinkLocalAddress / isUlaIPv6", () => {
  it("covers RFC1918", () => {
    expect(isPrivateIPv4("10.0.0.1")).toBe(true);
    expect(isPrivateIPv4("172.16.0.1")).toBe(true);
    expect(isPrivateIPv4("172.31.255.254")).toBe(true);
    expect(isPrivateIPv4("172.15.0.1")).toBe(false);
    expect(isPrivateIPv4("172.32.0.1")).toBe(false);
    expect(isPrivateIPv4("192.168.0.1")).toBe(true);
    expect(isPrivateIPv4("8.8.8.8")).toBe(false);
  });
  it("covers link-local", () => {
    expect(isLinkLocalAddress("169.254.10.20")).toBe(true);
    expect(isLinkLocalAddress("fe80::1")).toBe(true);
    expect(isLinkLocalAddress("fe80::abcd:1234")).toBe(true);
    expect(isLinkLocalAddress("fe90::1")).toBe(true);  // fe80::/10 覆盖 fe80–febf
    expect(isLinkLocalAddress("fec0::1")).toBe(false); // site-local，不在 link-local 段
    expect(isLinkLocalAddress("2001:db8::1")).toBe(false);
  });
  it("covers ULA fc00::/7", () => {
    expect(isUlaIPv6("fd00::1")).toBe(true);
    expect(isUlaIPv6("fcff::abcd")).toBe(true);
    expect(isUlaIPv6("fe80::1")).toBe(false);
    expect(isUlaIPv6("2409:8a55::1234")).toBe(false);
  });
});

describe("ipRanges.isPrivateSourceAddress（/pair 来源门槛）", () => {
  it("accepts RFC1918 / link-local / loopback / ULA / v4-mapped private", () => {
    for (const ip of ["192.168.1.5", "10.1.2.3", "172.20.0.8", "169.254.1.1", "127.0.0.1", "::1", "fe80::1234", "fd12:3456::1", "::ffff:192.168.1.5"]) {
      expect(isPrivateSourceAddress(ip), ip).toBe(true);
    }
  });
  it("rejects global addresses (WAN 来源 403)", () => {
    for (const ip of ["8.8.8.8", "203.0.113.5", "100.64.0.1", "2409:8a55::1234", "2606:4700::1111", "", null, undefined] as const) {
      expect(isPrivateSourceAddress(ip as string), String(ip)).toBe(false);
    }
  });
});

describe("ipRanges.isGlobalIPv6Address", () => {
  it("accepts global unicast", () => {
    expect(isGlobalIPv6Address("2409:8a55::1234")).toBe(true);
    expect(isGlobalIPv6Address("2606:4700:4700::1111")).toBe(true);
  });
  it("rejects link-local / ULA / loopback / v4-mapped / unspecified", () => {
    for (const ip of ["fe80::1", "fd00::1", "::1", "::ffff:8.8.8.8", "::", "ff02::1", "not-an-ip", "192.168.1.1"]) {
      expect(isGlobalIPv6Address(ip), ip).toBe(false);
    }
  });
});

describe("ipRanges.isNonPublicIPv4（CGNAT 自检）", () => {
  it("covers 100.64/10 + RFC1918 + link-local + loopback + 0.0.0.0", () => {
    for (const ip of ["100.64.0.1", "100.127.255.254", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.1.1", "127.0.0.1", "0.0.0.0", "bad"]) {
      expect(isNonPublicIPv4(ip), ip).toBe(true);
    }
  });
  it("accepts genuine public IPv4", () => {
    for (const ip of ["8.8.8.8", "203.0.113.5", "100.63.255.255", "100.128.0.1"]) {
      expect(isNonPublicIPv4(ip), ip).toBe(false);
    }
  });
});

describe("ipRanges.ipv6HasEui64InterfaceId", () => {
  it("detects ff:fe in the interface identifier", () => {
    expect(ipv6HasEui64InterfaceId("2409:8a55:1234:5678:98ab:cdff:fe12:3456")).toBe(true);
    expect(ipv6HasEui64InterfaceId("2409:8a55::1234")).toBe(false);
  });
});
