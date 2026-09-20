import { create } from "zustand";
import type {
  ChatBackendEvent,
  ChatBridge,
  ChatCLI,
  ChatMessage,
  ChatMessageAttachment,
  ChatMessageKind,
  ChatPanelBackend,
  ChatPermissionMode,
  ChatReasoningEffort,
  ChatRunOptions,
  ChatRunStatus,
  ChatSessionRecord,
  ChatSessionSnapshot,
  InteractiveResponse,
  InteractiveStatus,
  PermissionDecision,
  ProjectSnapshot,
  QueuedChatRequest,
  SessionActivity,
  SessionMode
} from "@shared/chat";
import { chatCLIDefaultCommands, chatCLISupportsInteractiveControls, contextWindowForModel, isChatRunStatusRunning } from "@shared/chat";
import { cliLaunchEnvFor } from "@shared/settings";
import type { AppSettings, CLIProfile, PermissionMode, ReasoningEffort } from "@shared/settings";
import { useSettingsStore } from "./settingsStore";

interface SendChatRequestInput {
  text: string;
  backendText?: string;
  appendRuleText?: string | null;
  attachments?: ChatMessageAttachment[];
  project: ProjectSnapshot;
  cli?: ChatCLI;
  modelID?: string;
  contextModelID?: string | null;
  permissionMode?: ChatPermissionMode;
  reasoningEffort?: ChatReasoningEffort;
  sessionMode?: SessionMode;
  resumeSessionID?: string | null;
  prioritizeBeforeQueuedRequests?: boolean;
}

interface ChatStoreRuntime {
  backend: ChatPanelBackend | null;
  activeRunRequest: QueuedChatRequest | null;
  activeRunStartedAt: string | null;
  activeParentUserMessageID: string | null;
  activeAssistantMessageID: string | null;
  activeStreamingMessageIDs: Record<string, string>;
  shouldStartQueuedRequestAfterBackendEnds: boolean;
  isUserStopping: boolean;
  runGeneration: number;
  didAutoCompact: boolean;
}

export interface ChatPanelStoreState {
  messages: ChatMessage[];
  queuedRequests: QueuedChatRequest[];
  sessions: ChatSessionRecord[];
  sessionMessages: Record<string, ChatMessage[]>;
  currentSession: ChatSessionRecord | null;
  status: ChatRunStatus;
  statusText: string;
  tokensUsed: number;
  tokensTotal: number;
  isAwaitingFirstModelOutput: boolean;
  structureRevision: number;
  activity: SessionActivity | null;
  runtime: ChatStoreRuntime;
}

export interface ChatPanelStoreActions {
  setBackend: (backend: ChatPanelBackend | null) => void;
  send: (input: SendChatRequestInput) => boolean;
  queue: (request: QueuedChatRequest, atFront?: boolean) => void;
  hydrateSessions: (snapshot: ChatSessionSnapshot) => void;
  cancelQueuedRequest: (id: string) => void;
  loadSession: (sessionID: string) => boolean;
  deleteSession: (sessionID: string) => void;
  activateProject: (project: ProjectSnapshot | null) => boolean;
  applyEvent: (event: ChatBackendEvent) => void;
  appendDelta: (event: Extract<ChatBackendEvent, { type: "appendDelta" }>) => boolean;
  backendStreamDidEnd: () => void;
  startNextQueuedRequestIfNeeded: () => boolean;
  stop: () => void;
  respondToPermission: (requestID: string, decision: PermissionDecision) => Promise<boolean>;
  respondToInteractiveRequest: (response: InteractiveResponse) => Promise<boolean>;
  newConversation: (project: ProjectSnapshot | null) => void;
  reset: () => void;
}

export type ChatPanelStore = ChatPanelStoreState & ChatPanelStoreActions;

export function createIpcChatBackend(chat: ChatBridge): ChatPanelBackend {
  let activeRunID: string | null = null;

  return {
    async *start(prompt: string, options: ChatRunOptions, session: ChatSessionRecord | null, attachments: ChatMessageAttachment[] = []) {
      const runID = crypto.randomUUID();
      activeRunID = runID;
      const pendingEvents: ChatBackendEvent[] = [];
      let didReceiveTerminalEvent = false;
      let wake: (() => void) | null = null;

      const unsubscribe = chat.onEvent((envelope) => {
        if (envelope.runID !== runID) {
          return;
        }
        pendingEvents.push(envelope.event);
        if (envelope.event.type === "finished" || envelope.event.type === "failed") {
          didReceiveTerminalEvent = true;
        }
        wake?.();
      });

      try {
        await chat.start({ runID, prompt, attachments, options, session });
        while (!didReceiveTerminalEvent || pendingEvents.length > 0) {
          const event = pendingEvents.shift();
          if (event) {
            yield event;
            continue;
          }
          await new Promise<void>((resolve) => {
            wake = resolve;
          });
          wake = null;
        }
      } finally {
        unsubscribe();
        if (activeRunID === runID) {
          activeRunID = null;
        }
      }
    },

    interrupt() {
      if (activeRunID) {
        void chat.interrupt({ runID: activeRunID });
      }
    },

    respondToPermission(requestID: string, decision: PermissionDecision) {
      if (!activeRunID) {
        return false;
      }
      // 回真实的 invoke 结果（不支持的 CLI / 写 stdin 失败在主进程返回 false），
      // 让 store 能把卡片标成失败而不是乐观翻转成已允许。
      return chat.respondToPermission({ runID: activeRunID, requestID, decision }).catch(() => false);
    },

    respondToInteractiveRequest(requestID: string, response: InteractiveResponse) {
      if (!activeRunID) {
        return false;
      }
      return chat.respondToInteractiveRequest({ runID: activeRunID, response: { ...response, requestID } }).catch(() => false);
    },

    sendCompact() {
      if (!activeRunID) {
        return false;
      }
      return chat.sendCompact({ runID: activeRunID }).catch(() => false);
    }
  };
}

function nowISO(): string {
  return new Date().toISOString();
}

function createID(prefix: string): string {
  return `${prefix}-${crypto.randomUUID()}`;
}

function normalizeOptional(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function streamingKey(kind: ChatMessageKind, requestID?: string | null): string {
  return `${kind}:${requestID?.trim() ?? ""}`;
}

function isVisibleModelOutput(kind: ChatMessageKind): boolean {
  return !["system", "result", "rawOutput"].includes(kind);
}

function shouldMirrorStreamingTextIntoMessage(_kind: ChatMessageKind): boolean {
  // Parity with the Mac store: streamed delta text lands on the message itself for every
  // kind — dropping toolCall deltas (the old allow-list) meant streamed tool input JSON
  // never reached the card.
  return true;
}

/// Kinds that can upgrade into each other between the streaming start and the completed
/// appendMessage for the same requestID (e.g. a commandInvocation streaming kind
/// finalizing as commandOutput, or a toolCall completing as toolResult).
function areCompatibleStreamingKinds(streamingKind: ChatMessageKind, completedKind: ChatMessageKind): boolean {
  if (streamingKind === completedKind) {
    return true;
  }
  return (
    (streamingKind === "commandOutput" && completedKind === "command") ||
    (streamingKind === "command" && completedKind === "commandOutput") ||
    (streamingKind === "toolResult" && completedKind === "toolCall") ||
    (streamingKind === "toolCall" && completedKind === "toolResult") ||
    (streamingKind === "toolCall" && completedKind === "diff") ||
    (streamingKind === "diff" && completedKind === "toolCall")
  );
}

function defaultRuntime(): ChatStoreRuntime {
  return {
    backend: null,
    activeRunRequest: null,
    activeRunStartedAt: null,
    activeParentUserMessageID: null,
    activeAssistantMessageID: null,
    activeStreamingMessageIDs: {},
    shouldStartQueuedRequestAfterBackendEnds: false,
    isUserStopping: false,
    runGeneration: 0,
    didAutoCompact: false
  };
}

// 与 Mac ChatPanelState 保持一致的压缩阈值：Codex（GPT）在 app-server 模式下没有
// 原生自动压缩，90% 就由 App 主动发 compact；Claude Code 自带自动压缩，App 只在
// 95% 还没见到 CLI 压缩时兜底（覆盖 1M 窗口模型）。降回 70% 以下后重新武装，
// 长会话可以多次压缩。
const COMPACT_THRESHOLD = 0.9;
const COMPACT_REARM_THRESHOLD = 0.7;
const CLAUDE_COMPACT_FALLBACK_THRESHOLD = 0.95;

function buildActivity(state: Pick<ChatPanelStoreState, "currentSession" | "queuedRequests" | "status" | "statusText" | "runtime">): SessionActivity | null {
  if (!state.currentSession) {
    return null;
  }

  return {
    status: state.status,
    statusText: state.statusText,
    queuedCount: state.queuedRequests.length,
    lastCompletedAt: state.currentSession.lastCompletedAt ?? null,
    activeRunStartedAt: state.runtime.activeRunStartedAt
  };
}

function touchSession(session: ChatSessionRecord | null, patch: Partial<ChatSessionRecord> = {}): ChatSessionRecord | null {
  if (!session) {
    return null;
  }
  return { ...session, ...patch, updatedAt: nowISO() };
}

function upsertSession(sessions: ChatSessionRecord[], session: ChatSessionRecord): ChatSessionRecord[] {
  const withoutCurrent = sessions.filter((candidate) => candidate.id !== session.id);
  return [session, ...withoutCurrent].sort((left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt));
}

function snapshotCurrentSessionMessages(state: ChatPanelStoreState): Record<string, ChatMessage[]> {
  if (!state.currentSession) {
    return state.sessionMessages;
  }
  return {
    ...state.sessionMessages,
    [state.currentSession.id]: state.messages
  };
}

function ensureSession(request: QueuedChatRequest, existing: ChatSessionRecord | null): ChatSessionRecord {
  const effectiveModelID = normalizeOptional(request.contextModelID) ?? request.modelID;
  if (request.sessionMode !== "newSession" && existing && existing.projectPath === request.project.path && existing.cli === request.cli) {
    return {
      ...existing,
      cli: request.cli,
      // A freshly-created draft (no external session yet) adopts the first prompt as its title.
      title: existing.externalSessionID ? existing.title : request.displayText.slice(0, 60) || existing.title,
      modelID: effectiveModelID,
      permissionMode: request.permissionMode,
      reasoningEffort: request.reasoningEffort,
      updatedAt: nowISO()
    };
  }

  const createdAt = nowISO();
  return {
    id: createID("session"),
    cli: request.cli,
    projectName: request.project.name,
    projectPath: request.project.path,
    title: request.displayText.slice(0, 60) || "新对话",
    modelID: effectiveModelID,
    permissionMode: request.permissionMode,
    reasoningEffort: request.reasoningEffort,
    externalSessionID: null,
    createdAt,
    updatedAt: createdAt,
    runStatus: "idle",
    statusText: "就绪",
    queuedRequests: [],
    lastCompletedAt: null,
    activeRunStartedAt: null,
    activeRunRequest: null
  };
}

function normalizeRestoredSession(session: ChatSessionRecord): ChatSessionRecord {
  const wasRunning = isChatRunStatusRunning(session.runStatus);
  return {
    ...session,
    runStatus: wasRunning ? "failed" : session.runStatus,
    statusText: wasRunning ? "已中断（应用已重启）" : session.statusText,
    queuedRequests: wasRunning ? [] : session.queuedRequests,
    activeRunStartedAt: null,
    activeRunRequest: null
  };
}

function normalizeRestoredMessages(messages: ChatMessage[], wasRunning: boolean): ChatMessage[] {
  if (!wasRunning) {
    return messages;
  }

  return messages.map((message) => {
    if (message.isStreaming) {
      return {
        ...message,
        isStreaming: false,
        status: "interrupted"
      };
    }
    if (message.kind === "permissionRequest" && message.status === "waiting") {
      return { ...message, status: "cancelled" };
    }
    if (message.kind === "interactiveRequest" && (message.status === "waiting" || message.interactiveRequest?.status === "waiting")) {
      return {
        ...message,
        status: "cancelled",
        interactiveRequest: message.interactiveRequest ? { ...message.interactiveRequest, status: "cancelled" } : message.interactiveRequest
      };
    }
    return message;
  });
}

type TerminalNotificationKind = "completed" | "failed";

function terminalNotificationKindForSession(session: ChatSessionRecord): TerminalNotificationKind | null {
  if (session.runStatus === "completed" && session.statusText !== "已停止") {
    return "completed";
  }
  if (session.runStatus === "failed" || session.runStatus === "unsupportedVersion") {
    return "failed";
  }
  return null;
}

function notifyTerminalSession(session: ChatSessionRecord, kind: TerminalNotificationKind): void {
  const project = session.projectName.trim() || session.projectPath.trim() || "未知项目";
  const title = session.title.trim() || "未命名对话";
  const statusText = session.statusText.trim();
  const body = kind === "completed" || !statusText
    ? `${project} · ${title}`
    : `${project} · ${title} · ${statusText}`;
  const notificationPromise = window.codevoke?.showDesktopNotification({
    title: kind === "completed" ? "对话已完成" : "对话异常",
    body
  });
  if (!notificationPromise) {
    return;
  }
  void notificationPromise.catch((error: unknown) => {
    console.error("[chat] failed to show desktop notification", error);
  });
}

function createQueuedRequest(input: SendChatRequestInput): QueuedChatRequest | null {
  const attachments = input.attachments ?? [];
  const displayText = input.text.trim() || (attachments.length > 0 ? attachments.map((attachment) => attachment.filename).join(", ") : "");
  const backendText = (input.backendText ?? input.text).trim();
  if (!displayText || (!backendText && attachments.length === 0)) {
    return null;
  }
  const settings = useSettingsStore.getState().settings;
  const cli = input.cli ?? settings?.defaultCLI ?? "claude";
  const profile = selectDefaultProfile(settings, cli);

  return {
    id: createID("request"),
    text: backendText,
    displayText,
    appendRuleText: normalizeOptional(input.appendRuleText),
    attachments,
    project: input.project,
    cli,
    modelID: input.modelID ?? normalizeOptional(profile?.model) ?? normalizeOptional(settings?.model) ?? "default",
    contextModelID: normalizeOptional(input.contextModelID),
    permissionMode: input.permissionMode ?? toChatPermissionMode(profile?.permissionMode ?? settings?.permissionMode),
    reasoningEffort: input.reasoningEffort ?? toChatReasoningEffort(profile?.reasoningEffort ?? settings?.reasoningEffort),
    sessionMode: input.sessionMode ?? "newSession",
    resumeSessionID: normalizeOptional(input.resumeSessionID),
    createdAt: nowISO()
  };
}

function withDerivedState(state: ChatPanelStoreState): Partial<ChatPanelStoreState> {
  const currentSession = touchSession(state.currentSession, {
    runStatus: state.status,
    statusText: state.statusText,
    queuedRequests: state.queuedRequests,
    activeRunRequest: state.runtime.activeRunRequest,
    activeRunStartedAt: state.runtime.activeRunStartedAt
  });
  const nextState = { ...state, currentSession };
  const sessions = currentSession ? upsertSession(state.sessions, currentSession) : state.sessions;
  const sessionMessages = currentSession
    ? {
        ...state.sessionMessages,
        [currentSession.id]: state.messages
      }
    : state.sessionMessages;
  return {
    currentSession,
    sessions,
    sessionMessages,
    activity: buildActivity(nextState)
  };
}

export const useChatPanelStore = create<ChatPanelStore>((set, get) => {
  function bump(patch: Partial<ChatPanelStoreState>): void {
    set((state) => {
      const nextState: ChatPanelStoreState = {
        ...state,
        ...patch,
        structureRevision: state.structureRevision + 1
      };
      return {
        ...patch,
        structureRevision: nextState.structureRevision,
        ...withDerivedState(nextState)
      };
    });
  }

  // ---------------------------------------------------------------------------
  // 流式 delta 合帧（对齐 Mac ChatPanelState.pendingDeltaBuffers + scheduleDeltaFlush）：
  // 逐 token set() 会让整棵消息树重渲，并触发订阅方对全部会话消息做 JSON.stringify，
  // 成本随会话长度平方增长。delta 文本先按 messageID 进 buffer，90ms 合帧一次；
  // 任何非 delta 事件前先 flush 保证顺序；首个可见输出/首块工具输入即时落地。
  // ---------------------------------------------------------------------------
  const DELTA_FLUSH_MS = 90;
  const pendingDeltaBuffers = new Map<string, string>();
  const pendingDeltaStatuses = new Map<string, string>();
  const pendingDeltaRequestIDs = new Map<string, string>();
  let deltaFlushTimer: number | null = null;

  function cancelDeltaFlushTimer(): void {
    if (deltaFlushTimer !== null) {
      window.clearTimeout(deltaFlushTimer);
      deltaFlushTimer = null;
    }
  }

  function scheduleDeltaFlush(): void {
    if (deltaFlushTimer !== null) {
      return;
    }
    deltaFlushTimer = window.setTimeout(() => {
      deltaFlushTimer = null;
      flushPendingDeltas();
    }, DELTA_FLUSH_MS);
  }

  function flushPendingDeltas(): void {
    cancelDeltaFlushTimer();
    if (pendingDeltaBuffers.size === 0) {
      return;
    }
    const buffers = new Map(pendingDeltaBuffers);
    const statuses = new Map(pendingDeltaStatuses);
    const requestIDs = new Map(pendingDeltaRequestIDs);
    pendingDeltaBuffers.clear();
    pendingDeltaStatuses.clear();
    pendingDeltaRequestIDs.clear();

    const state = get();
    let didMutate = false;
    const messages = state.messages.map((message) => {
      const delta = buffers.get(message.id);
      if (delta === undefined) {
        return message;
      }
      didMutate = true;
      return {
        ...message,
        text: shouldMirrorStreamingTextIntoMessage(message.kind) ? `${message.text}${delta}` : message.text,
        status: statuses.get(message.id) ?? message.status,
        requestID: message.requestID ?? requestIDs.get(message.id) ?? null
      };
    });
    if (didMutate) {
      bump({ messages });
    }
  }

  /// 会话切换/重置/新 run 时丢弃未落地的 delta：buffer 按旧会话 messageID 索引，
  /// 换上下文后没有任何目标消息，flush 只会白费一轮。
  function discardPendingDeltas(): void {
    cancelDeltaFlushTimer();
    pendingDeltaBuffers.clear();
    pendingDeltaStatuses.clear();
    pendingDeltaRequestIDs.clear();
  }

  function finishStreamingMessages(itemStatus: string): void {
    flushPendingDeltas();
    set((state) => {
      const messages = state.messages.map((message) => {
        if (message.isStreaming) {
          return { ...message, isStreaming: false, status: itemStatus };
        }
        // 对齐 Mac cancelWaitingInteractiveRequestsOnInterrupt：permission/interactive
        // 卡片不是 isStreaming，run 走到终态后还停在 waiting 的卡片永远等不到回执，
        // 翻成 cancelled 让按钮塌掉，不留给用户一排永远点不动的假按钮。
        if (message.kind === "permissionRequest" && message.status === "waiting") {
          return { ...message, status: "cancelled" };
        }
        if (
          message.kind === "interactiveRequest" &&
          (message.status === "waiting" || message.interactiveRequest?.status === "waiting")
        ) {
          return {
            ...message,
            status: "cancelled",
            interactiveRequest: message.interactiveRequest
              ? { ...message.interactiveRequest, status: "cancelled" as const }
              : message.interactiveRequest
          };
        }
        return message;
      });
      const runtime: ChatStoreRuntime = {
        ...state.runtime,
        activeAssistantMessageID: null,
        activeStreamingMessageIDs: {}
      };
      const nextState = { ...state, messages, runtime, structureRevision: state.structureRevision + 1 };
      return {
        messages,
        runtime,
        structureRevision: nextState.structureRevision,
        ...withDerivedState(nextState)
      };
    });
  }

  /// A completed appendMessage carrying the same requestID as a live streaming message
  /// finalizes that row in place (kind may upgrade command↔commandOutput, toolCall↔toolResult,
  /// toolCall↔diff) instead of appending a duplicate. Returns true when it consumed the event.
  function finishActiveStreamingMessage(event: Extract<ChatBackendEvent, { type: "appendMessage" }>): boolean {
    const state = get();
    const requestID = event.requestID?.trim() || null;
    const exactKey = streamingKey(event.kind, requestID);
    let key = state.runtime.activeStreamingMessageIDs[exactKey] ? exactKey : null;
    if (!key) {
      key =
        Object.keys(state.runtime.activeStreamingMessageIDs).find((candidate) => {
          const [kindPart, ...rest] = candidate.split(":");
          return rest.join(":") === (requestID ?? "") && areCompatibleStreamingKinds(kindPart as ChatMessageKind, event.kind);
        }) ?? null;
    }
    if (!key) {
      return false;
    }
    const messageID = state.runtime.activeStreamingMessageIDs[key];
    const index = state.messages.findIndex((message) => message.id === messageID);
    if (index < 0) {
      return false;
    }
    const messages = state.messages.slice();
    const existing = messages[index];
    const completedText = event.text.trim();
    messages[index] = {
      ...existing,
      kind: event.kind,
      text: completedText && (!existing.text.trim() || existing.kind !== event.kind || event.kind === "diff") ? event.text : existing.text,
      status: event.status ?? "done",
      isStreaming: false
    };
    const activeStreamingMessageIDs = { ...state.runtime.activeStreamingMessageIDs };
    delete activeStreamingMessageIDs[key];
    bump({
      messages,
      isAwaitingFirstModelOutput: false,
      status: isVisibleModelOutput(event.kind) ? "streaming" : state.status,
      statusText: event.status ?? state.statusText,
      runtime: {
        ...state.runtime,
        activeStreamingMessageIDs,
        activeAssistantMessageID: state.runtime.activeAssistantMessageID === messageID ? null : state.runtime.activeAssistantMessageID
      }
    });
    return true;
  }

  function appendError(message: string): void {
    const state = get();
    const sessionID = state.currentSession?.id ?? createID("session");
    bump({
      messages: [
        ...state.messages,
        {
          id: createID("message"),
          sessionID,
          kind: "error",
          title: "error",
          text: message,
          status: "failed",
          createdAt: nowISO(),
          parentUserMessageID: state.runtime.activeParentUserMessageID
        }
      ],
      isAwaitingFirstModelOutput: false
    });
  }

  /// 权限响应落地（对齐 Mac respondToPermission）：写回成功才翻卡片；写回失败
  /// （不支持的 CLI、stdin 已关、requestID 过期）不能让卡片停在 waiting 装活——
  /// 标 failed、补错误消息、run 翻成 failed 让用户可以重发。
  function applyPermissionOutcome(requestID: string, decision: PermissionDecision, didSend: boolean): void {
    if (didSend) {
      const status = decision === "deny" ? "denied" : "allowed";
      // ack 到达时 run 可能已停止/终结，只在仍在跑时才把面板状态推回 streaming。
      const stillRunning = isChatRunStatusRunning(get().status);
      bump({
        messages: get().messages.map((message) =>
          message.kind === "permissionRequest" && message.requestID === requestID ? { ...message, status } : message
        ),
        ...(stillRunning ? { status: "streaming" as const, statusText: status } : {})
      });
      return;
    }
    bump({
      messages: get().messages.map((message) =>
        message.kind === "permissionRequest" && message.requestID === requestID ? { ...message, status: "failed" } : message
      )
    });
    // run 已停止/终结时只塌卡片，不再补错误、不覆盖终态文案。
    if (isChatRunStatusRunning(get().status)) {
      appendError("权限响应写回失败。当前 CLI 不支持会话内权限交互，请改用自动编辑/全权限后重试。");
      bump({ status: "failed", statusText: "权限写回失败" });
    }
  }

  /// 选择题/输入响应落地（对齐 Mac respondToInteractiveRequest 失败路径）。
  function applyInteractiveOutcome(requestID: string, didSend: boolean): void {
    if (didSend) {
      const status: InteractiveStatus = "answered";
      const stillRunning = isChatRunStatusRunning(get().status);
      bump({
        messages: get().messages.map((message) =>
          message.kind === "interactiveRequest" && message.requestID === requestID
            ? {
                ...message,
                status,
                interactiveRequest: message.interactiveRequest ? { ...message.interactiveRequest, status } : message.interactiveRequest
              }
            : message
        ),
        ...(stillRunning ? { status: "streaming" as const, statusText: "已回答" } : {})
      });
      return;
    }
    const failed: InteractiveStatus = "failed";
    bump({
      messages: get().messages.map((message) =>
        message.kind === "interactiveRequest" && message.requestID === requestID
          ? {
              ...message,
              status: failed,
              interactiveRequest: message.interactiveRequest ? { ...message.interactiveRequest, status: failed } : message.interactiveRequest
            }
          : message
      )
    });
    if (isChatRunStatusRunning(get().status)) {
      appendError("交互响应写回失败。当前 CLI 不支持会话内选择题/输入回写。");
      bump({ status: "failed", statusText: "交互写回失败" });
    }
  }

  async function runBackend(request: QueuedChatRequest, generation: number): Promise<void> {
    const state = get();
    const backend = state.runtime.backend;
    const session = state.currentSession;
    if (!backend || !session) {
      appendError("聊天 backend 尚未接线。");
      bump({
        status: "failed",
        statusText: "失败",
        runtime: { ...get().runtime, activeRunRequest: null, activeRunStartedAt: null }
      });
      return;
    }

    // A freshly-created draft has no Claude session yet, so "继续上次" (--continue) would resume
    // an unrelated prior conversation in the same directory (or fail when none exists). Start the
    // first message fresh; follow-ups carry context once externalSessionID is captured.
    const effectiveSessionMode: SessionMode =
      request.sessionMode === "continueLast" && !session.externalSessionID
        ? "newSession"
        : request.sessionMode;

    const options: ChatRunOptions = {
      cli: request.cli,
      executablePath: executableForRequest(request),
      projectPath: request.project.path,
      modelID: request.modelID,
      permissionMode: request.permissionMode,
      reasoningEffort: request.reasoningEffort,
      sessionMode: effectiveSessionMode,
      resumeSessionID: request.resumeSessionID,
      supportsStreamJSONInput: true,
      environment: environmentForRequest(request),
      baseURL: normalizeOptional(profileForRequest(request)?.baseUrl)
    };

    try {
      for await (const event of backend.start(request.text, options, session, request.attachments)) {
        if (get().runtime.runGeneration !== generation) {
          return;
        }
        get().applyEvent(event);
      }
      if (get().runtime.runGeneration === generation) {
        get().backendStreamDidEnd();
      }
    } catch (error) {
      if (get().runtime.runGeneration !== generation) {
        return;
      }
      finishStreamingMessages(get().runtime.isUserStopping ? "stopped" : "failed");
      appendError(error instanceof Error ? error.message : String(error));
      bump({
        status: get().runtime.isUserStopping ? "completed" : "failed",
        statusText: get().runtime.isUserStopping ? "已停止" : "失败",
        isAwaitingFirstModelOutput: false,
        runtime: {
          ...get().runtime,
          activeRunRequest: null,
          activeRunStartedAt: null,
          shouldStartQueuedRequestAfterBackendEnds: false,
          isUserStopping: false
        }
      });
    }
  }

  function startRun(request: QueuedChatRequest): boolean {
    discardPendingDeltas();
    const current = get();
    const session = ensureSession(request, current.currentSession);
    const userMessageID = createID("message");
    const startedAt = nowISO();
    const generation = current.runtime.runGeneration + 1;
    const userMessage: ChatMessage = {
      id: userMessageID,
      sessionID: session.id,
      kind: "user",
      text: request.displayText,
      status: "user",
      createdAt: nowISO(),
      appendRuleText: request.appendRuleText,
      attachments: request.attachments
    };

    bump({
      messages: [...current.messages, userMessage],
      currentSession: {
        ...session,
        runStatus: "starting",
        statusText: `启动 ${request.cli}`,
        activeRunRequest: request,
        activeRunStartedAt: startedAt
      },
      status: "starting",
      statusText: `启动 ${request.cli}`,
      tokensTotal: contextWindowForModel(normalizeOptional(request.contextModelID) ?? request.modelID),
      isAwaitingFirstModelOutput: true,
      runtime: {
        ...current.runtime,
        activeRunRequest: request,
        activeRunStartedAt: startedAt,
        activeParentUserMessageID: userMessageID,
        activeAssistantMessageID: null,
        activeStreamingMessageIDs: {},
        shouldStartQueuedRequestAfterBackendEnds: false,
        isUserStopping: false,
        runGeneration: generation,
        didAutoCompact: false
      }
    });

    void runBackend(request, generation);
    return true;
  }

  return {
    messages: [],
    queuedRequests: [],
    sessions: [],
    sessionMessages: {},
    currentSession: null,
    status: "idle",
    statusText: "就绪",
    tokensUsed: 0,
    tokensTotal: 200_000,
    isAwaitingFirstModelOutput: false,
    structureRevision: 0,
    activity: null,
    runtime: defaultRuntime(),

    setBackend(backend) {
      set((state) => ({ runtime: { ...state.runtime, backend } }));
    },

    send(input) {
      const request = createQueuedRequest(input);
      if (!request) {
        return false;
      }
      const state = get();
      const shouldQueue =
        isChatRunStatusRunning(state.status) ||
        state.runtime.activeRunRequest !== null ||
        (!input.prioritizeBeforeQueuedRequests && state.queuedRequests.length > 0);
      if (shouldQueue) {
        get().queue(request);
        return true;
      }
      return startRun(request);
    },

    queue(request, atFront = false) {
      const state = get();
      bump({
        queuedRequests: atFront ? [request, ...state.queuedRequests] : [...state.queuedRequests, request],
        statusText: "已加入队列"
      });
    },

    hydrateSessions(snapshot) {
      discardPendingDeltas();
      const state = get();
      const backend = state.runtime.backend;
      const staleRunningSessionIDs = new Set(
        snapshot.sessions.filter((session) => isChatRunStatusRunning(session.runStatus)).map((session) => session.id)
      );
      const sessions = snapshot.sessions.map(normalizeRestoredSession);
      const sessionMessages = Object.fromEntries(
        Object.entries(snapshot.sessionMessages).map(([sessionID, messages]) => [
          sessionID,
          normalizeRestoredMessages(messages, staleRunningSessionIDs.has(sessionID))
        ])
      );
      const currentSession = sessions.find((session) => session.id === snapshot.currentSessionId) ?? null;
      set({
        messages: currentSession ? sessionMessages[currentSession.id] ?? [] : [],
        queuedRequests: currentSession?.queuedRequests ?? [],
        sessions,
        sessionMessages,
        currentSession,
        status: currentSession ? currentSession.runStatus : "idle",
        statusText: currentSession ? currentSession.statusText : "就绪",
        tokensUsed: state.tokensUsed,
        tokensTotal: currentSession ? contextWindowForModel(currentSession.modelID) : state.tokensTotal,
        isAwaitingFirstModelOutput: false,
        structureRevision: state.structureRevision + 1,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
      set((loadedState) => withDerivedState(loadedState));
    },

    cancelQueuedRequest(id) {
      const state = get();
      bump({ queuedRequests: state.queuedRequests.filter((request) => request.id !== id) });
    },

    loadSession(sessionID) {
      const state = get();
      if (isChatRunStatusRunning(state.status) || state.runtime.activeRunRequest) {
        return false;
      }
      const session = state.sessions.find((candidate) => candidate.id === sessionID);
      if (!session) {
        return false;
      }
      const wasRunning = isChatRunStatusRunning(session.runStatus);
      const restoredSession = normalizeRestoredSession(session);
      const messages = normalizeRestoredMessages(state.sessionMessages[session.id] ?? [], wasRunning);
      const backend = state.runtime.backend;
      set({
        messages,
        queuedRequests: restoredSession.queuedRequests,
        sessions: state.sessions,
        sessionMessages: {
          ...snapshotCurrentSessionMessages(state),
          [restoredSession.id]: messages
        },
        currentSession: restoredSession,
        status: restoredSession.runStatus,
        statusText: restoredSession.statusText || "已加载历史",
        tokensUsed: 0,
        tokensTotal: contextWindowForModel(restoredSession.modelID),
        isAwaitingFirstModelOutput: false,
        structureRevision: state.structureRevision + 1,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
      set((loadedState) => withDerivedState(loadedState));
      return true;
    },

    deleteSession(sessionID) {
      const state = get();
      const sessionMessages = { ...state.sessionMessages };
      delete sessionMessages[sessionID];
      const sessions = state.sessions.filter((session) => session.id !== sessionID);
      if (state.currentSession?.id !== sessionID) {
        set({ sessions, sessionMessages });
        return;
      }
      const backend = state.runtime.backend;
      discardPendingDeltas();
      set({
        messages: [],
        queuedRequests: [],
        sessions,
        sessionMessages,
        currentSession: null,
        status: "idle",
        statusText: "就绪",
        tokensUsed: state.tokensUsed,
        tokensTotal: state.tokensTotal,
        isAwaitingFirstModelOutput: false,
        structureRevision: state.structureRevision + 1,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
    },

    activateProject(project) {
      const state = get();
      if (isChatRunStatusRunning(state.status) || state.runtime.activeRunRequest) {
        return false;
      }
      if (!project?.path) {
        const backend = state.runtime.backend;
        set({
          messages: [],
          queuedRequests: [],
          sessions: state.sessions,
          sessionMessages: snapshotCurrentSessionMessages(state),
          currentSession: null,
          status: "idle",
          statusText: "请选择项目",
          tokensUsed: state.tokensUsed,
          tokensTotal: state.tokensTotal,
          isAwaitingFirstModelOutput: false,
          structureRevision: state.structureRevision + 1,
          activity: null,
          runtime: { ...defaultRuntime(), backend }
        });
        return true;
      }
      if (state.currentSession?.projectPath === project.path) {
        return true;
      }
      const latestSession = state.sessions
        .filter((session) => session.projectPath === project.path)
        .sort((left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt))[0];
      if (latestSession) {
        return get().loadSession(latestSession.id);
      }
      const backend = state.runtime.backend;
      set({
        messages: [],
        queuedRequests: [],
        sessions: state.sessions,
        sessionMessages: snapshotCurrentSessionMessages(state),
        currentSession: null,
        status: "idle",
        statusText: "就绪",
        tokensUsed: state.tokensUsed,
        tokensTotal: state.tokensTotal,
        isAwaitingFirstModelOutput: false,
        structureRevision: state.structureRevision + 1,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
      return true;
    },

    applyEvent(event) {
      // 顺序保证：非 delta 事件必须看到此前所有 delta 已落地——finish/appendMessage 的
      // 就地完结逻辑依赖 message.text 最新，且 waiting 卡片清理不能赶在 delta 前写。
      if (event.type !== "appendDelta") {
        flushPendingDeltas();
      }
      const state = get();
      switch (event.type) {
        case "appendMessage": {
          const isStreaming = event.status === "streaming" || event.status === "running";
          // A non-streaming appendMessage that matches a live streaming key finalizes
          // that message in place (Mac's finishActiveStreamingMessageIfPossible) —
          // otherwise item/started + item/completed pairs render as duplicate cards.
          if (!isStreaming && finishActiveStreamingMessage(event)) {
            break;
          }
          const message: ChatMessage = {
            id: createID("message"),
            sessionID: state.currentSession?.id ?? null,
            kind: event.kind,
            title: event.title ?? "",
            subtitle: event.subtitle ?? "",
            text: event.text,
            status: event.status ?? "",
            createdAt: nowISO(),
            parentUserMessageID: state.runtime.activeParentUserMessageID,
            requestID: event.requestID ?? null,
            isStreaming
          };
          const runtime = {
            ...state.runtime,
            activeStreamingMessageIDs: { ...state.runtime.activeStreamingMessageIDs }
          };
          if (isStreaming) {
            runtime.activeStreamingMessageIDs[streamingKey(event.kind, event.requestID)] = message.id;
            if (event.kind === "assistant") {
              runtime.activeAssistantMessageID = message.id;
            }
          }
          bump({
            messages: [...state.messages, message],
            runtime,
            isAwaitingFirstModelOutput: false,
            status: isVisibleModelOutput(event.kind) ? "streaming" : state.status,
            statusText: event.status ?? state.statusText
          });
          break;
        }
        case "appendDelta": {
          const revealedFirstOutput = get().appendDelta(event);
          const next = get();
          // delta 进 buffer 时 messages 没变；只在 status/statusText 真的变化时才再 bump
          // 一次——否则每 token 两次 set() 会把合帧收益全部吃回去。
          const nextStatus = revealedFirstOutput || isVisibleModelOutput(event.kind) ? "streaming" : next.status;
          const nextStatusText = event.status ?? "streaming";
          if (next.status !== nextStatus || next.statusText !== nextStatusText) {
            bump({ status: nextStatus, statusText: nextStatusText });
          }
          break;
        }
        case "finishStreamingMessage": {
          const key = streamingKey(event.kind, event.requestID);
          const messageID = state.runtime.activeStreamingMessageIDs[key];
          if (!messageID) {
            break;
          }
          const activeStreamingMessageIDs = { ...state.runtime.activeStreamingMessageIDs };
          delete activeStreamingMessageIDs[key];
          bump({
            messages: state.messages.map((message) =>
              message.id === messageID ? { ...message, isStreaming: false, status: event.status ?? "done" } : message
            ),
            statusText: event.status ?? state.statusText,
            runtime: {
              ...state.runtime,
              activeAssistantMessageID: state.runtime.activeAssistantMessageID === messageID ? null : state.runtime.activeAssistantMessageID,
              activeStreamingMessageIDs
            }
          });
          break;
        }
        case "updateStreamingStatus":
          bump({ statusText: event.status });
          break;
        case "sessionID":
          bump({ currentSession: touchSession(state.currentSession, { externalSessionID: event.externalSessionID }) });
          break;
        case "permissionRequest":
          bump({
            messages: [
              ...state.messages,
              {
                id: createID("message"),
                sessionID: state.currentSession?.id ?? null,
                kind: "permissionRequest",
                title: event.title,
                text: event.text,
                status: "waiting",
                createdAt: nowISO(),
                parentUserMessageID: state.runtime.activeParentUserMessageID,
                requestID: event.id
              }
            ],
            isAwaitingFirstModelOutput: false,
            status: "waitingPermission",
            statusText: "等待权限"
          });
          break;
        case "interactiveRequest":
          bump({
            messages: [
              ...state.messages,
              {
                id: createID("message"),
                sessionID: state.currentSession?.id ?? null,
                kind: "interactiveRequest",
                title: event.request.title,
                text: event.request.prompt,
                status: event.request.status,
                createdAt: nowISO(),
                parentUserMessageID: state.runtime.activeParentUserMessageID,
                requestID: event.request.id,
                interactiveRequest: event.request
              }
            ],
            isAwaitingFirstModelOutput: false,
            status: "waitingInput",
            statusText: "等待输入"
          });
          break;
        case "tokenUsage": {
          // CLI 上报的 total 和模型目录窗口取大者，避免 1M Claude / 275K GPT 被
          // 旧的 200K 假设压扁。
          const modelID = state.currentSession?.modelID
            ?? state.runtime.activeRunRequest?.contextModelID
            ?? state.runtime.activeRunRequest?.modelID
            ?? "";
          const expectedTotal = contextWindowForModel(modelID);
          const tokensTotal = Math.max(event.total > 0 ? event.total : 0, expectedTotal);
          const usage = tokensTotal > 0 ? event.used / tokensTotal : 0;
          const cli = state.currentSession?.cli ?? state.runtime.activeRunRequest?.cli ?? "claude";

          let runtime = state.runtime;
          let statusText = state.statusText;
          if (usage < COMPACT_REARM_THRESHOLD) {
            if (runtime.didAutoCompact) {
              runtime = { ...runtime, didAutoCompact: false };
            }
          } else if (usage >= COMPACT_THRESHOLD) {
            const triggerThreshold = cli === "codex" ? COMPACT_THRESHOLD : CLAUDE_COMPACT_FALLBACK_THRESHOLD;
            if (usage >= triggerThreshold && !runtime.didAutoCompact && chatCLISupportsInteractiveControls(cli)) {
              // sendCompact 的 IPC ack 是异步的：先乐观置位防止下个 tokenUsage 重复触发，
              // 主进程回 false（stdin 已关等）时撤销，恢复成纯提示。
              runtime = { ...runtime, didAutoCompact: true };
              statusText = "上下文接近上限，自动压缩中…";
              void Promise.resolve(state.runtime.backend?.sendCompact() ?? false).then((didSend) => {
                if (!didSend) {
                  const latest = get();
                  if (latest.runtime.didAutoCompact) {
                    bump({ runtime: { ...latest.runtime, didAutoCompact: false }, statusText: "上下文接近上限" });
                  }
                }
              });
            } else if (!runtime.didAutoCompact) {
              // 只有 Claude Code 自带 CLI 侧自动压缩，其余 CLI（含新接入的 7 家）如实提示。
              statusText = cli === "claude" ? "上下文接近上限（CLI 将自动压缩）" : "上下文接近上限";
            }
          }

          bump({
            tokensUsed: event.used,
            tokensTotal,
            statusText,
            runtime,
            messages:
              event.output && state.runtime.activeAssistantMessageID
                ? state.messages.map((message) =>
                    message.id === state.runtime.activeAssistantMessageID ? { ...message, outputTokenCount: event.output } : message
                  )
                : state.messages
          });
          break;
        }
        case "finished":
          finishStreamingMessages(state.runtime.isUserStopping ? "stopped" : "done");
          bump({
            status: "completed",
            statusText: state.runtime.isUserStopping ? "已停止" : "完成",
            isAwaitingFirstModelOutput: false,
            currentSession: touchSession(get().currentSession, { lastCompletedAt: nowISO() }),
            runtime: {
              ...get().runtime,
              activeRunRequest: null,
              activeRunStartedAt: null,
              shouldStartQueuedRequestAfterBackendEnds: !state.runtime.isUserStopping,
              isUserStopping: false
            }
          });
          break;
        case "failed":
          finishStreamingMessages(state.runtime.isUserStopping ? "stopped" : "failed");
          if (!state.runtime.isUserStopping) {
            appendError(event.message);
          }
          bump({
            status: state.runtime.isUserStopping ? "completed" : "failed",
            statusText: state.runtime.isUserStopping ? "已停止" : "失败",
            isAwaitingFirstModelOutput: false,
            runtime: {
              ...get().runtime,
              activeRunRequest: null,
              activeRunStartedAt: null,
              shouldStartQueuedRequestAfterBackendEnds: false,
              isUserStopping: false
            }
          });
          break;
      }
    },

    appendDelta(event) {
      const state = get();
      if (!event.text || !state.currentSession) {
        return false;
      }
      const key = streamingKey(event.kind, event.requestID);
      const activeMessageID = state.runtime.activeStreamingMessageIDs[key];
      const target = activeMessageID ? state.messages.find((message) => message.id === activeMessageID) : undefined;
      const status = event.status ?? "streaming";

      // assistant/reasoning 只允许续写"最后一条可见消息"（工具卡出现后不回头改旧气泡）；
      // 其余 kind 直接按 key 续写。lastVisibleID 只在需要的分支里算，省一次全表反扫。
      const mayAppendToExisting = Boolean(
        target &&
          (event.kind !== "assistant" && event.kind !== "reasoning"
            ? true
            : [...state.messages].reverse().find((message) => isVisibleModelOutput(message.kind) || message.kind === "user")?.id ===
              activeMessageID)
      );

      if (mayAppendToExisting && target && activeMessageID) {
        const revealsFirstOutput = state.isAwaitingFirstModelOutput && isVisibleModelOutput(event.kind);
        // 首个可见输出与流式消息的第一块内容即时落地（对齐 Mac：工具卡出现的同一拍就有
        // 正文，避免"先出标题、隔一拍才有内容"的两段式顿挫）；其余 delta 进 buffer 合帧。
        const isFirstChunk = !pendingDeltaBuffers.has(activeMessageID) && target.text === "";
        if (!isFirstChunk) {
          pendingDeltaBuffers.set(activeMessageID, (pendingDeltaBuffers.get(activeMessageID) ?? "") + event.text);
          pendingDeltaStatuses.set(activeMessageID, status);
          const normalizedRequestID = event.requestID?.trim();
          if (normalizedRequestID) {
            pendingDeltaRequestIDs.set(activeMessageID, normalizedRequestID);
          }
          scheduleDeltaFlush();
          // 即便文本走 buffer，首可见输出的揭示也要即时——否则"等待模型输出"会卡到
          // 下一个非 delta 事件才消失。
          if (revealsFirstOutput) {
            bump({ isAwaitingFirstModelOutput: false });
          }
          return revealsFirstOutput;
        }
        const messages = state.messages.map((message) => {
          if (message.id !== activeMessageID) {
            return message;
          }
          return {
            ...message,
            text: shouldMirrorStreamingTextIntoMessage(message.kind) ? `${message.text}${event.text}` : message.text,
            status,
            requestID: message.requestID ?? event.requestID ?? null
          };
        });
        bump({ messages, isAwaitingFirstModelOutput: revealsFirstOutput ? false : state.isAwaitingFirstModelOutput });
        return revealsFirstOutput;
      }

      const messageID = createID("message");
      const runtime = {
        ...state.runtime,
        activeAssistantMessageID: event.kind === "assistant" ? messageID : state.runtime.activeAssistantMessageID,
        activeStreamingMessageIDs: {
          ...state.runtime.activeStreamingMessageIDs,
          [key]: messageID
        }
      };
      const revealsFirstOutput = state.isAwaitingFirstModelOutput && isVisibleModelOutput(event.kind);
      bump({
        messages: [
          ...state.messages,
          {
            id: messageID,
            sessionID: state.currentSession.id,
            kind: event.kind,
            title: event.title ?? "",
            subtitle: event.subtitle ?? "",
            text: event.text,
            status,
            createdAt: nowISO(),
            parentUserMessageID: state.runtime.activeParentUserMessageID,
            requestID: event.requestID ?? null,
            isStreaming: true
          }
        ],
        runtime,
        isAwaitingFirstModelOutput: revealsFirstOutput ? false : state.isAwaitingFirstModelOutput
      });
      return revealsFirstOutput;
    },

    backendStreamDidEnd() {
      const state = get();
      const shouldStartQueuedRequest = state.runtime.shouldStartQueuedRequestAfterBackendEnds;
      if (isChatRunStatusRunning(state.status)) {
        finishStreamingMessages(state.runtime.isUserStopping ? "stopped" : "done");
      }
      bump({
        status: isChatRunStatusRunning(state.status) ? "completed" : state.status,
        statusText: isChatRunStatusRunning(state.status) ? (state.runtime.isUserStopping ? "已停止" : "完成") : state.statusText,
        isAwaitingFirstModelOutput: false,
        runtime: {
          ...get().runtime,
          activeRunRequest: null,
          activeRunStartedAt: null,
          shouldStartQueuedRequestAfterBackendEnds: false,
          isUserStopping: false
        }
      });
      if (shouldStartQueuedRequest) {
        queueMicrotask(() => {
          get().startNextQueuedRequestIfNeeded();
        });
      }
    },

    startNextQueuedRequestIfNeeded() {
      const state = get();
      if (isChatRunStatusRunning(state.status) || state.runtime.activeRunRequest || state.queuedRequests.length === 0) {
        return false;
      }
      const [request, ...queuedRequests] = state.queuedRequests;
      bump({ queuedRequests });
      return request ? startRun(request) : false;
    },

    stop() {
      const state = get();
      if (!isChatRunStatusRunning(state.status) || state.status === "stopping") {
        return;
      }
      state.runtime.backend?.interrupt();
      bump({
        status: "stopping",
        statusText: "正在停止",
        runtime: {
          ...state.runtime,
          isUserStopping: true,
          shouldStartQueuedRequestAfterBackendEnds: false
        }
      });
    },

    async respondToPermission(requestID, decision) {
      // ack 是 boolean（本地/fake backend）或 Promise<boolean>（IPC invoke 的真实结果）。
      // 只有写回真的成功才翻卡片；失败走 failed 路径，不再乐观翻转。
      const ack = get().runtime.backend?.respondToPermission(requestID, decision) ?? false;
      const didSend = await Promise.resolve(ack).catch(() => false);
      applyPermissionOutcome(requestID, decision, didSend);
      return didSend;
    },

    async respondToInteractiveRequest(response) {
      const ack = get().runtime.backend?.respondToInteractiveRequest(response.requestID, response) ?? false;
      const didSend = await Promise.resolve(ack).catch(() => false);
      applyInteractiveOutcome(response.requestID, didSend);
      return didSend;
    },

    reset() {
      discardPendingDeltas();
      const state = get();
      const backend = state.runtime.backend;
      set({
        messages: [],
        queuedRequests: [],
        sessions: state.sessions,
        sessionMessages: snapshotCurrentSessionMessages(state),
        currentSession: null,
        status: "idle",
        statusText: "就绪",
        tokensUsed: 0,
        tokensTotal: 200_000,
        isAwaitingFirstModelOutput: false,
        structureRevision: 0,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
    },

    newConversation(project) {
      const state = get();
      // Can't swap the active conversation out from under a live run.
      if (isChatRunStatusRunning(state.status) || state.runtime.activeRunRequest) {
        return;
      }
      // Reuse the current empty draft instead of stacking up blank "新对话" entries.
      const current = state.currentSession;
      const isEmptyDraft = Boolean(current) && state.messages.length === 0 && !current?.externalSessionID;
      if (isEmptyDraft && (!project?.path || current?.projectPath === project.path)) {
        return;
      }
      if (!project?.path) {
        get().reset();
        return;
      }
      const settings = useSettingsStore.getState().settings;
      const cli = settings?.defaultCLI ?? "claude";
      const profile = selectDefaultProfile(settings, cli);
      const createdAt = nowISO();
      const draft: ChatSessionRecord = {
        id: createID("session"),
        cli,
        projectName: project.name,
        projectPath: project.path,
        title: "新对话",
        modelID: normalizeOptional(profile?.model) ?? normalizeOptional(settings?.model) ?? "default",
        permissionMode: "ask",
        reasoningEffort: "medium",
        externalSessionID: null,
        createdAt,
        updatedAt: createdAt,
        runStatus: "idle",
        statusText: "就绪",
        queuedRequests: [],
        lastCompletedAt: null,
        activeRunStartedAt: null,
        activeRunRequest: null
      };
      const backend = state.runtime.backend;
      // Snapshot the outgoing conversation's messages before switching so they aren't lost.
      bump({
        messages: [],
        queuedRequests: [],
        sessionMessages: snapshotCurrentSessionMessages(state),
        currentSession: draft,
        status: "idle",
        statusText: "就绪",
        tokensUsed: 0,
        tokensTotal: contextWindowForModel(draft.modelID),
        isAwaitingFirstModelOutput: false,
        activity: null,
        runtime: { ...defaultRuntime(), backend }
      });
    }
  };
});

function selectDefaultProfile(settings: AppSettings | null | undefined, cli: ChatCLI): CLIProfile | null {
  const profiles = settings?.profiles.filter((profile) => profile.kind === cli && profile.enabled) ?? [];
  return profiles.find((profile) => profile.isDefault) ?? profiles[0] ?? null;
}

function executableForRequest(request: QueuedChatRequest): string {
  const profile = profileForRequest(request);
  // cli 字符串与二进制名不同名（cursor→cursor-agent、kiro→kiro-cli），按表回退。
  return normalizeOptional(profile?.executablePath) ?? chatCLIDefaultCommands[request.cli];
}

function profileForRequest(request: QueuedChatRequest): CLIProfile | null {
  const settings = useSettingsStore.getState().settings;
  return selectDefaultProfile(settings, request.cli);
}

function environmentForRequest(request: QueuedChatRequest): Record<string, string> {
  const profile = profileForRequest(request);
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(profile?.env ?? {})) {
    const trimmedKey = key.trim();
    if (trimmedKey && value) {
      env[trimmedKey] = value;
    }
  }

  const baseURL = normalizeOptional(profile?.baseUrl);
  const baseURLEnv = cliLaunchEnvFor(request.cli).baseURLEnv;
  if (baseURL && baseURLEnv && !env[baseURLEnv]) {
    env[baseURLEnv] = baseURL;
  }
  return env;
}

function toChatPermissionMode(mode: PermissionMode | undefined): ChatPermissionMode {
  if (mode === "bypassPermissions") {
    return "fullAccess";
  }
  if (mode === "acceptEdits") {
    return "autoEdit";
  }
  return "ask";
}

function toChatReasoningEffort(effort: ReasoningEffort | undefined): ChatReasoningEffort {
  if (effort === "high") {
    return "high";
  }
  if (effort === "low" || effort === "minimal") {
    return "low";
  }
  return "medium";
}

export const useChatStore = useChatPanelStore;

let chatSessionPersistTimer: number | null = null;
let lastPersistedChatSessionPayload = "";
let didInitializeChatNotificationStatuses = false;
let previousChatNotificationStatuses = new Map<string, ChatRunStatus>();

function notifyChatSessionTerminalTransitions(sessions: ChatSessionRecord[]): void {
  const nextStatuses = new Map(sessions.map((session) => [session.id, session.runStatus]));
  if (!didInitializeChatNotificationStatuses) {
    previousChatNotificationStatuses = nextStatuses;
    didInitializeChatNotificationStatuses = true;
    return;
  }

  for (const session of sessions) {
    const previousStatus = previousChatNotificationStatuses.get(session.id);
    const kind = terminalNotificationKindForSession(session);
    if (previousStatus && isChatRunStatusRunning(previousStatus) && kind) {
      notifyTerminalSession(session, kind);
    }
  }
  previousChatNotificationStatuses = nextStatuses;
}

useChatPanelStore.subscribe((state) => {
  notifyChatSessionTerminalTransitions(state.sessions);
  // 每次 bump 都会因 withDerivedState 的 updatedAt 产生新快照——若在此就
  // JSON.stringify 全量 sessions+messages，流式期间等于每帧做一次 O(transcript)
  // 序列化。改为只标 dirty，400ms 后在定时器里取最新 state 序列化一次。
  if (chatSessionPersistTimer !== null) {
    return;
  }
  chatSessionPersistTimer = window.setTimeout(() => {
    chatSessionPersistTimer = null;
    const latest = useChatPanelStore.getState();
    const snapshot: ChatSessionSnapshot = {
      sessions: latest.sessions,
      sessionMessages: snapshotCurrentSessionMessages(latest),
      currentSessionId: latest.currentSession?.id ?? null
    };
    const payload = JSON.stringify(snapshot);
    if (payload === lastPersistedChatSessionPayload) {
      return;
    }
    lastPersistedChatSessionPayload = payload;
    const savePromise = window.codevoke?.chat.saveSessions(snapshot);
    if (!savePromise) {
      return;
    }
    void savePromise.catch((error: unknown) => {
      console.error("[chat] failed to persist session snapshot", error);
      lastPersistedChatSessionPayload = "";
    });
  }, 400);
});
