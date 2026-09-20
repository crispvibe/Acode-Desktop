import { createServer, type Server } from "node:http";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";

import {
  RemoteHostServer,
  type RemoteHostServerDelegate
} from "../../../src/main/remoteHost/RemoteHostServer";
import { ATTACHMENT_DIRECTORY_NAME } from "../../../src/main/remoteHost/AttachmentStore";
import type { PanelStateEnvelope, ReplayPayload } from "../../../src/main/remoteHost/PanelStateBroadcaster";
import type { PanelStateSnapshot } from "../../../src/shared/remoteProtocol";

const base64 = (text: string): string => Buffer.from(text, "utf8").toString("base64");

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
    host = new RemoteHostServer({ port, bindLAN: false }, buildDelegate(snapshot));

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

    host = new RemoteHostServer({ port, bindLAN: false }, buildDelegate(buildSnapshot()));
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
    const server = new RemoteHostServer({ port, bindLAN: false }, buildDelegate(buildSnapshot()));
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

describe("RemoteHostServer attachment upload (HTTP POST /attachments)", () => {
  let host: RemoteHostServer | null = null;
  let baseUrl = "";

  afterEach(async () => {
    if (host) {
      await host.stop();
      host = null;
    }
  });

  afterAll(async () => {
    await rm(path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME), { recursive: true, force: true });
  });

  async function startHost(): Promise<void> {
    const { server: probe, port } = await listenOnEphemeralPort();
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    host = new RemoteHostServer({ port, bindLAN: false }, buildDelegate(buildSnapshot()));
    await host.start();
    expect(host.isLanListening).toBe(true);
    baseUrl = `http://127.0.0.1:${port}`;
  }

  it("accepts an upload and returns 201 with the host path", async () => {
    await startHost();
    const res = await fetch(`${baseUrl}/attachments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: "doc.txt", contentBase64: base64("file-contents") })
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { filename: string; path: string };
    expect(body.filename).toBe("doc.txt");
    expect(body.path).toContain(ATTACHMENT_DIRECTORY_NAME);
  });

  it("rejects a disallowed extension with 415", async () => {
    await startHost();
    const res = await fetch(`${baseUrl}/attachments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: "malware.exe", contentBase64: base64("MZ") })
    });
    expect(res.status).toBe(415);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("attachment_type_not_allowed");
  });
});
