import { createServer, type Server } from "node:http";
import https from "node:https";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import WebSocket from "ws";

import { loadOrCreateHostIdentity, type HostIdentity } from "../../../src/main/remoteHost/HostIdentity";
import { PairingService } from "../../../src/main/remoteHost/PairingService";
import {
  RemoteHostServer,
  type RemoteHostServerConfig,
  type RemoteHostServerDelegate
} from "../../../src/main/remoteHost/RemoteHostServer";
import { ATTACHMENT_DIRECTORY_NAME } from "../../../src/main/remoteHost/AttachmentStore";
import type { PanelStateEnvelope, ReplayPayload } from "../../../src/main/remoteHost/PanelStateBroadcaster";
import type { PanelStateSnapshot } from "../../../src/shared/remoteProtocol";

const base64 = (text: string): string => Buffer.from(text, "utf8").toString("base64");

let sharedIdentity: HostIdentity | null = null;
const tempDirs: string[] = [];

beforeAll(async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "acode-identity-test-"));
  tempDirs.push(dir);
  sharedIdentity = await loadOrCreateHostIdentity(dir);
});

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function waitForFrame(sent: string[], type: string, timeoutMs = 1000): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const match = sent.map((entry) => JSON.parse(entry) as Record<string, unknown>).find((frame) => frame.type === type);
    if (match) return match;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for frame type=${type}; got ${sent.join(", ")}`);
}

function buildSnapshot(): PanelStateSnapshot {
  return { revision: 1, sessionId: null } as unknown as PanelStateSnapshot;
}

function buildDelegate(snapshot: PanelStateSnapshot): RemoteHostServerDelegate {
  return {
    applyCommand: vi.fn(async (command) => ({
      ack: { type: "command_ack", commandId: command.commandId, status: "ok", message: null, sessionId: null } as const,
      shouldUpdateFocusedSessionId: false,
      newFocusedSessionId: null,
      shouldPushSnapshotForFocus: false
    })),
    replayPayload: vi.fn((): ReplayPayload => ({ kind: "snapshot", snapshot })),
    snapshotFor: vi.fn(() => snapshot)
  };
}

function listenOnEphemeralPort(): Promise<{ server: Server; port: number }> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address && typeof address === "object") {
        resolve({ server, port: address.port });
      } else {
        reject(new Error("no port"));
      }
    });
  });
}

/** 契约要求的完整 config：TLS 身份 + PairingService + endpoints provider。 */
async function makeConfig(port: number, bindLAN = false): Promise<{ config: RemoteHostServerConfig; pairing: PairingService }> {
  if (!sharedIdentity) throw new Error("identity not initialized");
  const dir = await mkdtemp(path.join(tmpdir(), "acode-pairing-test-"));
  tempDirs.push(dir);
  const pairing = new PairingService({ storePath: path.join(dir, "pairing.json") });
  await pairing.init();
  return {
    pairing,
    config: {
      port,
      bindLAN,
      tls: {
        certPem: sharedIdentity.certPem,
        keyPem: sharedIdentity.keyPem,
        fingerprintHex: sharedIdentity.fingerprintHex
      },
      pairing,
      endpoints: () => [
        { a: "2409:8a55::1234", p: port },
        { a: "203.0.113.5", p: 50443 }
      ],
      hostName: "test-host"
    }
  };
}

/** https JSON 请求（自签证书：rejectUnauthorized=false）。 */
function httpsJson(
  port: number,
  method: string,
  pathname: string,
  options: { token?: string; body?: unknown } = {}
): Promise<{ status: number; body: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const payload = options.body === undefined ? null : JSON.stringify(options.body);
    const request = https.request(
      {
        hostname: "127.0.0.1",
        port,
        path: pathname,
        method,
        rejectUnauthorized: false,
        headers: {
          ...(payload ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) } : {}),
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {})
        }
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () => {
          let body: Record<string, unknown> = {};
          try {
            body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
          } catch {
            // body 非 JSON 时返回空对象，状态码照常断言。
          }
          resolve({ status: response.statusCode ?? 0, body });
        });
      }
    );
    request.on("error", reject);
    if (payload) request.write(payload);
    request.end();
  });
}

describe("RemoteHostServer LAN/pipeline decoupling", () => {
  let occupied: Server | null = null;
  let host: RemoteHostServer | null = null;

  afterEach(async () => {
    if (host) {
      await host.stop();
      host = null;
    }
    if (occupied) {
      await new Promise<void>((resolve) => occupied!.close(() => resolve()));
      occupied = null;
    }
  });

  it("keeps the pipeline running (virtual connections) even when the LAN port bind fails", async () => {
    const { server, port } = await listenOnEphemeralPort();
    occupied = server;

    const snapshot = buildSnapshot();
    const { config } = await makeConfig(port);
    host = new RemoteHostServer(config, buildDelegate(snapshot));

    const onError = vi.fn();
    await host.start();

    // 端口被占用：LAN 没监听，但管道（命令/广播/虚拟连接）仍然就绪。
    expect(host.isRunning).toBe(true);
    expect(host.isLanListening).toBe(false);
    expect(host.lastErrorMessage).toBeTruthy();

    // 虚拟连接仍可用：attach 会回 hello，broadcast 能 fanout。
    const sent: string[] = [];
    const connection = host.attachVirtualConnection({
      send: (text) => sent.push(text),
      isOpen: () => true
    });
    expect(sent.map((entry) => JSON.parse(entry).type)).toContain("hello");

    host.broadcast({ type: "panel_state", kind: "snapshot", sessionId: null, revision: 1, snapshot } satisfies PanelStateEnvelope);
    expect(sent.some((entry) => JSON.parse(entry).type === "panel_state")).toBe(true);

    host.detachVirtualConnection(connection);
    void onError;
  });

  it("binds the LAN listener when the port is free", async () => {
    const { server, port } = await listenOnEphemeralPort();
    // free the port immediately, then reuse it for the host
    await new Promise<void>((resolve) => server.close(() => resolve()));

    const { config } = await makeConfig(port);
    host = new RemoteHostServer(config, buildDelegate(buildSnapshot()));
    await host.start();

    expect(host.isRunning).toBe(true);
    expect(host.isLanListening).toBe(true);
    expect(host.lastErrorMessage).toBeNull();
  });
});

describe("RemoteHostServer attachment upload (recovery frame)", () => {
  let host: RemoteHostServer | null = null;

  afterEach(async () => {
    if (host) {
      await host.stop();
      host = null;
    }
  });

  afterAll(async () => {
    await rm(path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME), { recursive: true, force: true });
  });

  async function newHost(): Promise<{ server: RemoteHostServer; port: number }> {
    const { server: probe, port } = await listenOnEphemeralPort();
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    const { config } = await makeConfig(port);
    const server = new RemoteHostServer(config, buildDelegate(buildSnapshot()));
    await server.start();
    host = server;
    return { server, port };
  }

  it("stores an uploaded attachment and replies with its host path over a virtual connection", async () => {
    const { server } = await newHost();
    const sent: string[] = [];
    const connection = server.attachVirtualConnection({ send: (text) => sent.push(text), isOpen: () => true });

    server.deliverFrame(connection, JSON.stringify({
      type: "recovery_request",
      requestId: "11111111-1111-4111-8111-111111111111",
      op: "uploadAttachment",
      filename: "shot.png",
      contentBase64: base64("png-bytes")
    }));

    const response = await waitForFrame(sent, "recovery_response");
    expect(response.status).toBe("ok");
    expect(response.requestId).toBe("11111111-1111-4111-8111-111111111111");
    const upload = response.attachmentUpload as { filename: string; path: string };
    expect(upload.filename).toBe("shot.png");
    expect(upload.path).toContain(ATTACHMENT_DIRECTORY_NAME);
  });

  it("returns an error for unsupported recovery ops", async () => {
    const { server } = await newHost();
    const sent: string[] = [];
    const connection = server.attachVirtualConnection({ send: (text) => sent.push(text), isOpen: () => true });

    server.deliverFrame(connection, JSON.stringify({
      type: "recovery_request",
      requestId: "22222222-2222-4222-8222-222222222222",
      op: "catalog"
    }));

    const response = await waitForFrame(sent, "recovery_response");
    expect(response.status).toBe("error");
    expect(response.requestId).toBe("22222222-2222-4222-8222-222222222222");
  });

  it("rejects a disallowed attachment type with an error response", async () => {
    const { server } = await newHost();
    const sent: string[] = [];
    const connection = server.attachVirtualConnection({ send: (text) => sent.push(text), isOpen: () => true });

    server.deliverFrame(connection, JSON.stringify({
      type: "recovery_request",
      requestId: "33333333-3333-4333-8333-333333333333",
      op: "uploadAttachment",
      filename: "evil.exe",
      contentBase64: base64("MZ")
    }));

    const response = await waitForFrame(sent, "recovery_response");
    expect(response.status).toBe("error");
    expect(typeof response.message).toBe("string");
  });
});

describe("RemoteHostServer HTTP endpoints (wss+auth 契约)", () => {
  let host: RemoteHostServer | null = null;
  let pairing: PairingService | null = null;
  let port = 0;

  afterEach(async () => {
    if (host) {
      await host.stop();
      host = null;
    }
    pairing = null;
  });

  afterAll(async () => {
    await rm(path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME), { recursive: true, force: true });
  });

  async function startHost(): Promise<void> {
    const { server: probe, port: found } = await listenOnEphemeralPort();
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    const made = await makeConfig(found);
    pairing = made.pairing;
    host = new RemoteHostServer(made.config, buildDelegate(buildSnapshot()));
    await host.start();
    expect(host.isLanListening).toBe(true);
    port = found;
  }

  it("serves /health without auth and reports proto:2 + pair:true", async () => {
    await startHost();
    const res = await httpsJson(port, "GET", "/health");
    expect(res.status).toBe(200);
    expect(res.body.proto).toBe(2);
    expect(res.body.pair).toBe(true);
    expect(res.body.name).toBe("test-host");
    expect(res.body.authRequired).toBe(true);
  });

  it("rejects /connect_info and /attachments without a Bearer token (401)", async () => {
    await startHost();
    const connectInfo = await httpsJson(port, "GET", "/connect_info");
    expect(connectInfo.status).toBe(401);
    expect(connectInfo.body.error).toBe("unauthorized");

    const upload = await httpsJson(port, "POST", "/attachments", {
      body: { filename: "doc.txt", contentBase64: base64("x") }
    });
    expect(upload.status).toBe(401);
  });

  it("rejects a wrong Bearer token with 401", async () => {
    await startHost();
    const res = await httpsJson(port, "GET", "/connect_info", { token: "not-a-real-token" });
    expect(res.status).toBe(401);
  });

  it("/pair redeems the 6-digit code and the issued token authenticates", async () => {
    await startHost();
    expect(pairing).not.toBeNull();
    const { code } = pairing!.ensurePairingCode();

    const res = await httpsJson(port, "POST", "/pair", { body: { code, deviceName: "测试手机" } });
    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe("string");
    expect(res.body.fp).toBe(sharedIdentity!.fingerprintHex);
    expect(res.body.name).toBe("test-host");
    expect(res.body.eps).toEqual([
      { a: "2409:8a55::1234", p: port },
      { a: "203.0.113.5", p: 50443 }
    ]);

    // 兑换来的 token 能过 Bearer 鉴权。
    const connectInfo = await httpsJson(port, "GET", "/connect_info", { token: res.body.token as string });
    expect(connectInfo.status).toBe(200);
    expect(connectInfo.body.name).toBe("test-host");
    expect(Array.isArray(connectInfo.body.eps)).toBe(true);

    // 码一次性：重放被拒。
    const replay = await httpsJson(port, "POST", "/pair", { body: { code, deviceName: "replay" } });
    expect(replay.status).toBe(403);
  });

  it("/pair rejects a wrong code with 403", async () => {
    await startHost();
    pairing!.ensurePairingCode();
    const res = await httpsJson(port, "POST", "/pair", { body: { code: "000000", deviceName: "x" } });
    // 000000 与生成码撞车的概率存在但极低；撞车时用另一个错误码重试。
    if (res.status === 200) {
      const retry = await httpsJson(port, "POST", "/pair", { body: { code: "999999", deviceName: "x" } });
      expect([403, 429]).toContain(retry.status);
      return;
    }
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("invalid_pairing_code");
  });

  it("/pair rejects an oversized body with 413", async () => {
    await startHost();
    pairing!.ensurePairingCode();
    const res = await httpsJson(port, "POST", "/pair", {
      body: { code: "123456", deviceName: "x".repeat(5000) }
    });
    expect(res.status).toBe(413);
    expect(res.body.error).toBe("payload_too_large");
  });

  it("returns 429 for a banned IP on every endpoint (契约 §4.2)", async () => {
    await startHost();
    // 同一 IP 11 次 Bearer 失败 → 封禁 60s；之后连 /health 也是 429。
    for (let i = 0; i < 11; i += 1) {
      await httpsJson(port, "GET", "/connect_info", { token: "bad" });
    }
    const res = await httpsJson(port, "GET", "/health");
    expect(res.status).toBe(429);
  });

  it("accepts an attachment upload with a valid token and returns 201", async () => {
    await startHost();
    const { token } = pairing!.issueToken("tester", "code");
    const res = await httpsJson(port, "POST", "/attachments", {
      token,
      body: { filename: "doc.txt", contentBase64: base64("file-contents") }
    });
    expect(res.status).toBe(201);
    const body = res.body as { filename: string; path: string };
    expect(body.filename).toBe("doc.txt");
    expect(body.path).toContain(ATTACHMENT_DIRECTORY_NAME);
  });

  it("rejects a disallowed extension with 415 when authorized", async () => {
    await startHost();
    const { token } = pairing!.issueToken("tester", "code");
    const res = await httpsJson(port, "POST", "/attachments", {
      token,
      body: { filename: "malware.exe", contentBase64: base64("MZ") }
    });
    expect(res.status).toBe(415);
    expect(res.body.error).toBe("attachment_type_not_allowed");
  });

  it("refuses the WS upgrade without a token (401 before 101) and connects with one", async () => {
    await startHost();
    const { token } = pairing!.issueToken("ws-tester", "code");

    // 无 token：upgrade 在 101 前被 401 拒掉。
    const denied = await new Promise<number>((resolve) => {
      const ws = new WebSocket(`wss://127.0.0.1:${port}/chat`, { rejectUnauthorized: false });
      ws.once("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0));
      ws.once("error", () => resolve(-1));
      ws.once("open", () => resolve(101));
    });
    expect(denied).toBe(401);

    // 合法 token：握手成功，第一条帧是 hello。
    const hello = await new Promise<Record<string, unknown>>((resolve, reject) => {
      const ws = new WebSocket(`wss://127.0.0.1:${port}/chat`, {
        rejectUnauthorized: false,
        headers: { Authorization: `Bearer ${token}` }
      });
      ws.once("error", reject);
      ws.once("message", (data) => {
        resolve(JSON.parse(data.toString("utf8")) as Record<string, unknown>);
        ws.close();
      });
    });
    expect(hello.type).toBe("hello");
  });
});
