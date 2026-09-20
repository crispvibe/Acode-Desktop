import { describe, expect, it } from "vitest";

import {
  decodeExternalAddressResponse,
  decodeMappingResponse,
  encodeExternalAddressRequest,
  encodeTcpMappingRequest,
  NatPmpClient,
  NatPmpError,
  type UdpExchange
} from "../../../src/main/remoteHost/NatPmp";

describe("NatPmp codec（RFC 6886）", () => {
  it("encodes the external-address request as [0, 0]", () => {
    expect(encodeExternalAddressRequest()).toEqual(Buffer.from([0, 0]));
  });

  it("decodes an external-address response", () => {
    const response = Buffer.from([0, 0x80, 0, 0, 0, 0, 0, 0, 203, 0, 113, 5]);
    expect(decodeExternalAddressResponse(response)).toEqual({ externalIp: "203.0.113.5", epochSeconds: 0 });
  });

  it("round-trips a TCP mapping request/response", () => {
    const request = encodeTcpMappingRequest(18765, 0, 3600);
    expect(request.length).toBe(12);
    expect(request[1]).toBe(2); // op=TCP mapping
    expect(request.readUInt16BE(4)).toBe(18765);
    expect(request.readUInt16BE(6)).toBe(0);
    expect(request.readUInt32BE(8)).toBe(3600);

    const response = Buffer.alloc(16);
    response[1] = 0x82;
    response.writeUInt32BE(120, 4); // epoch
    response.writeUInt16BE(18765, 8);
    response.writeUInt16BE(50443, 10);
    response.writeUInt32BE(3600, 12);
    expect(decodeMappingResponse(response)).toEqual({
      internalPort: 18765,
      externalPort: 50443,
      lifetimeSeconds: 3600,
      epochSeconds: 120
    });
  });

  it("throws NatPmpError with the result code on error responses", () => {
    const response = Buffer.from([0, 0x80, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0]);
    try {
      decodeExternalAddressResponse(response);
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(NatPmpError);
      expect((error as NatPmpError).resultCode).toBe(3);
    }
  });
});

describe("NatPmpClient", () => {
  it("queries external address then maps a port over the injected exchange", async () => {
    const sent: Buffer[] = [];
    const exchange: UdpExchange = async (payload) => {
      sent.push(Buffer.from(payload));
      if (payload[1] === 0) {
        const response = Buffer.from([0, 0x80, 0, 0, 0, 0, 0, 0, 203, 0, 113, 5]);
        return response;
      }
      const response = Buffer.alloc(16);
      response[1] = 0x82;
      response.writeUInt16BE(payload.readUInt16BE(4), 8);
      response.writeUInt16BE(49152, 10);
      response.writeUInt32BE(3600, 12);
      return response;
    };
    const client = new NatPmpClient("192.168.1.1", { exchange, firstTimeoutMs: 10 });
    expect((await client.getExternalAddress()).externalIp).toBe("203.0.113.5");
    const mapping = await client.mapTcp(18765, 0, 3600);
    expect(mapping.externalPort).toBe(49152);
    expect(sent.length).toBe(2);
  });

  it("retries on timeout and fails after the attempt budget", async () => {
    let calls = 0;
    const exchange: UdpExchange = async () => {
      calls += 1;
      throw new NatPmpError("NAT-PMP 应答超时");
    };
    const client = new NatPmpClient("192.168.1.1", { exchange, firstTimeoutMs: 1, attempts: 3 });
    await expect(client.getExternalAddress()).rejects.toBeInstanceOf(NatPmpError);
    expect(calls).toBe(3);
  });

  it("does not retry protocol-level result codes", async () => {
    let calls = 0;
    const exchange: UdpExchange = async () => {
      calls += 1;
      return Buffer.from([0, 0x80, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0]); // not authorized
    };
    const client = new NatPmpClient("192.168.1.1", { exchange, firstTimeoutMs: 1, attempts: 3 });
    await expect(client.getExternalAddress()).rejects.toMatchObject({ resultCode: 2 });
    expect(calls).toBe(1);
  });
});
