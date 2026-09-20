// PanelStateBroadcaster (Windows host) —— 移植自 Mac 的
// `PanelStateBroadcaster.swift` / `PanelSessionRevisionLog`。
//
// 职责：
//   1. 维护每个会话的单调 revision 计数。
//   2. 维护最近 N 条 patch 的环形缓冲（用于 resume 重放）。
//   3. 把相邻两个 snapshot diff 成 PanelStatePatch。
//
// 与 Mac 不同：渲染进程已经把 chatStore 组装成完整 PanelStateSnapshot 推过来，
// 这里只负责 revision 标记 / diff / 重放，不订阅任何 Combine 流。

import type { PanelStatePatch, PanelStateSnapshot } from "../../shared/remoteProtocol.js";

/** 每会话保留的最近 patch 数（对应 Mac 的 PanelStatePatchRetention=128）。 */
export const PANEL_STATE_PATCH_RETENTION = 128;

/** draft（尚未持久化的草稿会话）使用的固定哨兵 key，保证所有 draft 推送共享同一个日志。 */
const DRAFT_SESSION_KEY = "00000000-0000-0000-0000-000000000000";

export type PanelStateEnvelope =
  | { type: "panel_state"; kind: "snapshot"; sessionId: string | null; revision: number; snapshot: PanelStateSnapshot }
  | { type: "panel_state"; kind: "patch"; sessionId: string | null; revision: number; patch: PanelStatePatch };

export type ReplayPayload =
  | { kind: "snapshot"; snapshot: PanelStateSnapshot }
  | { kind: "patches"; patches: PanelStatePatch[] }
  | { kind: "empty" };

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || a === undefined || b === undefined) return a === b;
  if (typeof a !== "object" || typeof b !== "object") return false;
  return JSON.stringify(a) === JSON.stringify(b);
}

/** 把一个 snapshot diff 成 patch；未变的字段省略（undefined）。 */
function diffSnapshot(previous: PanelStateSnapshot, current: PanelStateSnapshot, baseRevision: number): PanelStatePatch {
  const patch: PanelStatePatch = {
    revision: current.revision,
    baseRevision,
    sessionId: current.sessionId
  };
  if (!deepEqual(previous.projects, current.projects)) patch.projects = current.projects;
  if (!deepEqual(previous.models, current.models)) patch.models = current.models;
  if (!deepEqual(previous.sessions, current.sessions)) patch.sessions = current.sessions;
  if (!deepEqual(previous.currentSessionId, current.currentSessionId)) {
    patch.currentSessionId = { value: current.currentSessionId };
  }
  if (!deepEqual(previous.messages, current.messages)) patch.messages = current.messages;
  if (!deepEqual(previous.queuedRequests, current.queuedRequests)) patch.queuedRequests = current.queuedRequests;
  if (!deepEqual(previous.streamingTexts, current.streamingTexts)) patch.streamingTexts = current.streamingTexts;
  if (previous.status !== current.status) patch.status = current.status;
  if (previous.statusText !== current.statusText) patch.statusText = current.statusText;
  if (previous.isAwaitingFirstModelOutput !== current.isAwaitingFirstModelOutput) {
    patch.isAwaitingFirstModelOutput = current.isAwaitingFirstModelOutput;
  }
  if (previous.isLoadingHistory !== current.isLoadingHistory) patch.isLoadingHistory = current.isLoadingHistory;
  if (previous.tokensUsed !== current.tokensUsed) patch.tokensUsed = current.tokensUsed;
  if (previous.tokensTotal !== current.tokensTotal) patch.tokensTotal = current.tokensTotal;
  if (!deepEqual(previous.activeRunStartedAt, current.activeRunStartedAt)) {
    patch.activeRunStartedAt = { value: current.activeRunStartedAt };
  }
  if (previous.isMirroringRemoteSession !== current.isMirroringRemoteSession) {
    patch.isMirroringRemoteSession = current.isMirroringRemoteSession;
  }
  if (!deepEqual(previous.composer, current.composer)) patch.composer = current.composer;
  if (!deepEqual(previous.capabilities, current.capabilities)) patch.capabilities = current.capabilities;
  return patch;
}

/** 单会话 revision / patch 环形缓冲。 */
class PanelSessionRevisionLog {
  currentRevision = 0;
  lastSnapshot: PanelStateSnapshot | null = null;
  private patches: PanelStatePatch[] = [];
  private readonly capacity: number;

  constructor(capacity = PANEL_STATE_PATCH_RETENTION) {
    this.capacity = Math.max(8, capacity);
  }

  private get oldestRetainedBaseRevision(): number | null {
    return this.patches[0]?.baseRevision ?? null;
  }

  /** 记录一个新 snapshot，标记 revision 并（如有上一个）计算并保存 diff patch。 */
  record(snapshot: PanelStateSnapshot): PanelStateSnapshot {
    const nextRevision = this.currentRevision + 1;
    const stamped: PanelStateSnapshot = { ...snapshot, revision: nextRevision };
    if (this.lastSnapshot) {
      const patch = diffSnapshot(this.lastSnapshot, stamped, this.currentRevision);
      this.patches.push(patch);
      if (this.patches.length > this.capacity) {
        this.patches.splice(0, this.patches.length - this.capacity);
      }
    }
    this.lastSnapshot = stamped;
    this.currentRevision = nextRevision;
    return stamped;
  }

  /**
   * 返回 baseRevision >= lastRevision 且 revision <= currentRevision 的 patch 链。
   * 若链不完整（最旧保留 patch 的 baseRevision 已大于 lastRevision）返回 null，
   * 调用方应改发完整 snapshot。
   */
  patchesSince(lastRevision: number): PanelStatePatch[] | null {
    if (lastRevision > this.currentRevision) return [];
    if (lastRevision === this.currentRevision) return [];
    const oldestBase = this.oldestRetainedBaseRevision;
    if (oldestBase === null) return null;
    if (oldestBase > lastRevision) return null;
    return this.patches.filter((p) => p.baseRevision >= lastRevision);
  }
}

export class PanelStateBroadcaster {
  private logs = new Map<string, PanelSessionRevisionLog>();
  /**
   * 最近一次 ingest 的会话 key（即「当前会话」）。手机首连 `resume(null)` / 请求 null
   * 时用它解析为当前会话——对应 Mac 的 `lookup.controller(for: nil)`（取当前 controller）。
   * 渲染进程是单一来源、每次只推当前会话的 snapshot，所以「当前」= 最近一次 ingest。
   */
  private currentKey: string | null = null;

  private logFor(sessionId: string | null): PanelSessionRevisionLog {
    const key = sessionId ?? DRAFT_SESSION_KEY;
    let log = this.logs.get(key);
    if (!log) {
      log = new PanelSessionRevisionLog();
      this.logs.set(key, log);
    }
    return log;
  }

  /** 把请求里的 sessionId（可能为 null）解析为实际日志 key：null → 当前会话。 */
  private resolveKey(sessionId: string | null): string | null {
    if (sessionId !== null) return sessionId;
    return this.currentKey;
  }

  /**
   * 接收渲染进程推来的（已按会话 scope 好的）snapshot，标记 revision 并产出要广播的
   * 信封：首个为 snapshot，之后优先发增量 patch。
   */
  ingest(snapshot: PanelStateSnapshot): PanelStateEnvelope {
    const sessionId = snapshot.sessionId ?? snapshot.currentSessionId ?? null;
    const scoped: PanelStateSnapshot = { ...snapshot, sessionId };
    const log = this.logFor(sessionId);
    this.currentKey = sessionId ?? DRAFT_SESSION_KEY;
    const hadPrevious = log.lastSnapshot !== null;
    const stamped = log.record(scoped);
    if (hadPrevious) {
      const chain = log.patchesSince(stamped.revision - 1);
      const patch = chain && chain.length > 0 ? chain[chain.length - 1] : null;
      if (patch) {
        return { type: "panel_state", kind: "patch", sessionId, revision: patch.revision, patch };
      }
    }
    return { type: "panel_state", kind: "snapshot", sessionId, revision: stamped.revision, snapshot: stamped };
  }

  /** 当前已记录的最新 snapshot（用于 requestSnapshot / resume 兜底）。null → 当前会话。 */
  snapshotFor(sessionId: string | null): PanelStateSnapshot | null {
    const key = this.resolveKey(sessionId);
    if (key === null) return null;
    return this.logs.get(key)?.lastSnapshot ?? null;
  }

  /** resume 路径：给定 (sessionId, lastRevision) 返回 patch 链或完整 snapshot。null → 当前会话。 */
  replayPayload(sessionId: string | null, lastRevision: number | null): ReplayPayload {
    const key = this.resolveKey(sessionId);
    if (key === null) return { kind: "empty" };
    const log = this.logFor(key);
    if (lastRevision !== null && lastRevision !== undefined) {
      const chain = log.patchesSince(lastRevision);
      if (chain && (chain.length > 0 || lastRevision === log.currentRevision)) {
        return chain.length > 0 ? { kind: "patches", patches: chain } : { kind: "empty" };
      }
    }
    const snapshot = log.lastSnapshot;
    return snapshot ? { kind: "snapshot", snapshot } : { kind: "empty" };
  }
}
