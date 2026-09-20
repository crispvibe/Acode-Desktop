import { describe, expect, it } from "vitest";

import { PanelStateBroadcaster } from "../../../src/main/remoteHost/PanelStateBroadcaster";
import type { PanelStateSnapshot } from "../../../src/shared/remoteProtocol";

const SESSION_A = "11111111-1111-1111-1111-111111111111";

function snap(fields: Partial<PanelStateSnapshot>): PanelStateSnapshot {
  return fields as PanelStateSnapshot;
}

describe("PanelStateBroadcaster null→current resolution", () => {
  it("resolves snapshotFor(null) / resume(null) to the current (last ingested) session", () => {
    const broadcaster = new PanelStateBroadcaster();
    broadcaster.ingest(snap({ sessionId: SESSION_A, currentSessionId: SESSION_A }));

    // 手机首连 resume(null)：应拿到当前活动会话的 snapshot，而不是空的 draft 日志。
    expect(broadcaster.snapshotFor(null)?.sessionId).toBe(SESSION_A);
    const payload = broadcaster.replayPayload(null, null);
    expect(payload.kind).toBe("snapshot");
    if (payload.kind === "snapshot") {
      expect(payload.snapshot.sessionId).toBe(SESSION_A);
    }
  });

  it("serves a patch chain when resuming from an older revision", () => {
    const broadcaster = new PanelStateBroadcaster();
    broadcaster.ingest(snap({ sessionId: SESSION_A, currentSessionId: SESSION_A, status: "idle" }));
    broadcaster.ingest(snap({ sessionId: SESSION_A, currentSessionId: SESSION_A, status: "running" }));

    const payload = broadcaster.replayPayload(SESSION_A, 1);
    expect(payload.kind).toBe("patches");
  });

  it("returns empty when the caller is already at the current revision", () => {
    const broadcaster = new PanelStateBroadcaster();
    broadcaster.ingest(snap({ sessionId: SESSION_A, currentSessionId: SESSION_A }));

    const payload = broadcaster.replayPayload(SESSION_A, 1);
    expect(payload.kind).toBe("empty");
  });

  it("returns empty before anything has been ingested", () => {
    const broadcaster = new PanelStateBroadcaster();
    expect(broadcaster.snapshotFor(null)).toBeNull();
    expect(broadcaster.replayPayload(null, null).kind).toBe("empty");
  });
});
