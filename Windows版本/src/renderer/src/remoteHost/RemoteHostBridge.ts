// RemoteHostBridge（渲染进程）—— 对应 Mac 的 RemoteVNCWiring / PanelStateBroadcaster
// 的「面板真相 → snapshot」与「command → 面板方法」桥接。
//
// 职责：
//   1. 订阅 chatStore / projectStore / settingsStore，把「活的面板状态」组装成
//      PanelStateSnapshot，节流推给主进程广播。
//   2. 接收主进程转发来的手机命令（18 个 op），调用 chatStore 已有方法，回结果。
//
// 一期取舍（已在方案文档登记）：
//   - 协议强制 UUID，而 chatStore 用 `prefix-uuid` id，这里统一 strip 前缀还原 UUID。
//   - 没有独立 composer store（桌面 composer 是组件本地状态），bridge 自持一个
//     composer 对象供手机镜像与发送；桌面输入框与手机 composer 暂不双向统一。
//   - models / capabilities 由 settings 派生的最小集合。

import { isChatRunStatusRunning } from "@shared/chat";
import type {
  ChatCLI,
  ChatMessage,
  ChatMessageAttachment,
  ChatPermissionMode,
  ChatReasoningEffort,
  ChatSessionRecord,
  PermissionDecision,
  ProjectSnapshot,
  QueuedChatRequest
} from "@shared/chat";
import type { AppSettings } from "@shared/settings";
import type { RemoteHostApplyCommandRequest } from "@shared/ipc";
import type {
  ChatMessageAttachmentDTO,
  CommandAck,
  PanelStateSnapshot,
  RemoteCommand
} from "@shared/remoteProtocol";
import { useChatStore } from "../stores/chatStore";
import { useProjectStore } from "../stores/projectStore";
import { useSettingsStore } from "../stores/settingsStore";

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SNAPSHOT_THROTTLE_MS = 90;

/** chatStore 的 `prefix-uuid` id 还原成裸 UUID（协议 / iOS 客户端要求 UUID）。 */
function toUUID(id: string): string {
  if (UUID_REGEX.test(id)) return id;
  const stripped = id.replace(/^[a-z]+-/i, "");
  return UUID_REGEX.test(stripped) ? stripped : id;
}

/** 还原不出裸 UUID 时返回 null —— 避免把非 UUID 串发给严格按 UUID 解码的客户端。 */
function toUUIDOrNull(id: string | null | undefined): string | null {
  if (!id) return null;
  const uuid = toUUID(id);
  return UUID_REGEX.test(uuid) ? uuid : null;
}

/** iOS ISO8601DateFormatter 不接受毫秒小数；`Date.toISOString()` 输出 `.SSSZ`，统一抹掉。 */
function toIsoSecond(value: string): string {
  return value.replace(/\.\d+Z$/, "Z");
}

type ComposerState = {
  text: string;
  cli: ChatCLI | null;
  modelID: string | null;
  contextModelID: string | null;
  permissionMode: ChatPermissionMode | null;
  reasoningEffort: ChatReasoningEffort | null;
  attachments: ChatMessageAttachment[];
};

interface CommandOutcome {
  ack: CommandAck;
  shouldUpdateFocusedSessionId: boolean;
  newFocusedSessionId: string | null;
  shouldPushSnapshotForFocus: boolean;
}

class RemoteHostBridge {
  private enabled = false;
  private throttleTimer: number | null = null;
  private unsubscribers: Array<() => void> = [];
  private readonly composer: ComposerState = {
    text: "",
    cli: null,
    modelID: null,
    contextModelID: null,
    permissionMode: null,
    reasoningEffort: null,
    attachments: []
  };
  // 每次组装 snapshot 时重建：裸 UUID → chatStore 原始 id，便于命令回译。
  private sessionByUuid = new Map<string, string>();
  private requestByUuid = new Map<string, string>();

  install(): () => void {
    const remoteHost = window.codevoke?.remoteHost;
    if (!remoteHost) {
      return () => undefined;
    }

    this.unsubscribers.push(remoteHost.onStatus((status) => {
      const wasEnabled = this.enabled;
      this.enabled = status.enabled && status.running;
      if (this.enabled && !wasEnabled) {
        void this.pushSnapshotNow();
      }
    }));

    this.unsubscribers.push(remoteHost.onApplyCommand((payload) => {
      void this.handleApplyCommand(payload);
    }));

    const schedule = () => this.schedulePush();
    this.unsubscribers.push(useChatStore.subscribe(schedule));
    this.unsubscribers.push(useProjectStore.subscribe(schedule));
    this.unsubscribers.push(useSettingsStore.subscribe(schedule));

    void remoteHost.getStatus().then((status) => {
      this.enabled = status.enabled && status.running;
      if (this.enabled) void this.pushSnapshotNow();
    }).catch(() => undefined);

    return () => this.dispose();
  }

  private dispose(): void {
    for (const unsubscribe of this.unsubscribers) unsubscribe();
    this.unsubscribers = [];
    if (this.throttleTimer !== null) {
      window.clearTimeout(this.throttleTimer);
      this.throttleTimer = null;
    }
  }

  private schedulePush(): void {
    if (!this.enabled || this.throttleTimer !== null) return;
    this.throttleTimer = window.setTimeout(() => {
      this.throttleTimer = null;
      void this.pushSnapshotNow();
    }, SNAPSHOT_THROTTLE_MS);
  }

  private async pushSnapshotNow(): Promise<void> {
    const remoteHost = window.codevoke?.remoteHost;
    if (!remoteHost) return;
    const snapshot = this.buildSnapshot();
    if (!snapshot) return;
    try {
      await remoteHost.pushSnapshot(snapshot);
    } catch {
      // 推送失败不致命，下次状态变化会重试。
    }
  }

  // MARK: - snapshot 组装

  private buildSnapshot(): PanelStateSnapshot | null {
    const chat = useChatStore.getState();
    const settings = useSettingsStore.getState().settings;
    const projectState = useProjectStore.getState();

    this.sessionByUuid.clear();
    this.requestByUuid.clear();

    const defaultCLI: ChatCLI = settings?.defaultCLI ?? "claude";
    const projects = projectState.projects.map((project) => ({
      id: project.id,
      name: project.name,
      path: project.path,
      defaultCLI,
      createdAt: toIsoSecond(project.createdAt),
      updatedAt: toIsoSecond(project.updatedAt),
      lastOpenedAt: project.lastOpenedAt ? toIsoSecond(project.lastOpenedAt) : null
    }));
    const projectIdByPath = new Map(projects.map((project) => [project.path, project.id] as const));

    const sessions = chat.sessions.map((session) => {
      const id = toUUID(session.id);
      this.sessionByUuid.set(id, session.id);
      for (const queued of session.queuedRequests) {
        this.requestByUuid.set(toUUID(queued.id), queued.id);
      }
      return {
        id,
        cli: session.cli,
        projectId: projectIdByPath.get(session.projectPath) ?? null,
        projectName: session.projectName,
        projectPath: session.projectPath,
        title: session.title,
        modelID: session.modelID,
        runStatus: session.runStatus,
        statusText: session.statusText,
        createdAt: toIsoSecond(session.createdAt),
        updatedAt: toIsoSecond(session.updatedAt),
        lastCompletedAt: session.lastCompletedAt ? toIsoSecond(session.lastCompletedAt) : null,
        queuedCount: session.queuedRequests.length
      };
    });

    const sessionId = chat.currentSession ? toUUID(chat.currentSession.id) : null;

    const queuedRequests = chat.queuedRequests
      .map((queued) => {
        this.requestByUuid.set(toUUID(queued.id), queued.id);
        return this.mapQueuedRequest(queued);
      })
      .filter((value): value is NonNullable<typeof value> => value !== null);

    // 对齐 ChatCore `ChatMessage` 的 CodingKeys：iOS 端严格按 UUID/日期/kind 解码，
    // requestID、interactiveRequest、attachments 都是权限交互所需的字段。
    const messages = chat.messages.map((message) => ({
      id: toUUID(message.id),
      sessionID: toUUIDOrNull(message.sessionID),
      kind: message.kind,
      text: message.text,
      createdAt: toIsoSecond(message.createdAt),
      title: message.title ?? "",
      subtitle: message.subtitle ?? "",
      status: message.status ?? "",
      parentUserMessageID: toUUIDOrNull(message.parentUserMessageID),
      requestId: message.requestID ?? null,
      requestID: message.requestID ?? null,
      isStreaming: message.isStreaming ?? false,
      interactiveRequest: message.interactiveRequest ?? null,
      attachments: (message.attachments ?? []).map(toAttachmentDTO)
    }));

    const streamingTexts = chat.messages
      .filter((message) => message.isStreaming)
      .map((message) => ({
        messageId: toUUID(message.id),
        text: message.text,
        status: message.status ?? "streaming",
        requestId: message.requestID ?? null
      }));

    return {
      revision: 1,
      sessionId,
      projects,
      models: buildModels(settings),
      sessions,
      currentSessionId: sessionId,
      messages,
      queuedRequests,
      streamingTexts,
      status: chat.status,
      statusText: chat.statusText,
      isAwaitingFirstModelOutput: chat.isAwaitingFirstModelOutput,
      isLoadingHistory: false,
      tokensUsed: chat.tokensUsed,
      tokensTotal: chat.tokensTotal,
      activeRunStartedAt: chat.runtime.activeRunStartedAt ? toIsoSecond(chat.runtime.activeRunStartedAt) : null,
      isMirroringRemoteSession: false,
      composer: this.buildComposer(chat.currentSession, chat.status, settings),
      capabilities: buildCapabilities()
    };
  }

  private mapQueuedRequest(queued: QueuedChatRequest) {
    return {
      id: toUUID(queued.id),
      text: queued.text,
      displayText: queued.displayText,
      cli: queued.cli,
      modelID: queued.modelID,
      permissionMode: queued.permissionMode,
      reasoningEffort: queued.reasoningEffort,
      projectId: queued.project.id,
      attachments: queued.attachments.map(toAttachmentDTO)
    };
  }

  private buildComposer(session: ChatSessionRecord | null, status: string, settings: AppSettings | null) {
    const cli = this.composer.cli ?? session?.cli ?? settings?.defaultCLI ?? "claude";
    const modelID = this.composer.modelID ?? session?.modelID ?? settings?.model ?? "default";
    const permissionMode = this.composer.permissionMode ?? session?.permissionMode ?? "ask";
    const reasoningEffort = this.composer.reasoningEffort ?? session?.reasoningEffort ?? "medium";
    return {
      text: this.composer.text,
      cli,
      modelID,
      contextModelID: this.composer.contextModelID,
      permissionMode,
      reasoningEffort,
      attachments: this.composer.attachments.map(toAttachmentDTO),
      isEnabled: !isChatRunStatusRunning(status as never),
      placeholder: session ? "输入消息…" : "请选择项目后开始对话"
    };
  }

  // MARK: - 命令应用

  private async handleApplyCommand(payload: RemoteHostApplyCommandRequest): Promise<void> {
    const remoteHost = window.codevoke?.remoteHost;
    if (!remoteHost) return;
    let outcome: CommandOutcome;
    try {
      outcome = this.dispatchCommand(payload.command);
    } catch (error) {
      outcome = {
        ack: errorAck(payload.command, error instanceof Error ? error.message : "操作失败，请重试。"),
        shouldUpdateFocusedSessionId: false,
        newFocusedSessionId: null,
        shouldPushSnapshotForFocus: false
      };
    }
    // 命令多半已改动 chatStore；先把最新 snapshot 同步推给主进程，
    // 这样服务端在 shouldPushSnapshotForFocus 时拿到的是命令后的状态。
    await this.pushSnapshotNow();
    try {
      await remoteHost.sendCommandResult({
        requestId: payload.requestId,
        ack: outcome.ack,
        newFocusedSessionId: outcome.newFocusedSessionId,
        shouldUpdateFocusedSessionId: outcome.shouldUpdateFocusedSessionId,
        shouldPushSnapshotForFocus: outcome.shouldPushSnapshotForFocus
      });
    } catch {
      // 主进程已断开，忽略。
    }
  }

  private dispatchCommand(command: RemoteCommand): CommandOutcome {
    const chat = useChatStore.getState();
    const args = command.args;

    switch (command.op) {
      case "focusProject": {
        const project = this.projectSnapshotById(args.projectId);
        chat.activateProject(project);
        return this.focusOutcome(command);
      }
      case "focusSession": {
        const targetUuid = args.sessionId ?? command.sessionId ?? null;
        const originalId = targetUuid ? this.sessionByUuid.get(targetUuid) : null;
        if (originalId) chat.loadSession(originalId);
        return this.focusOutcome(command, targetUuid ?? null);
      }
      case "newDraftSession": {
        const project = this.projectSnapshotById(args.projectId) ?? this.currentProjectSnapshot();
        chat.newConversation(project);
        return this.focusOutcome(command);
      }
      case "composerSet":
        this.composer.text = args.text ?? "";
        return okOutcome(command);
      case "composerSetCLI":
        this.composer.cli = (args.cli as ChatCLI | undefined) ?? this.composer.cli;
        return okOutcome(command);
      case "composerSetModel":
        this.composer.modelID = args.modelID ?? this.composer.modelID;
        this.composer.contextModelID = args.contextModelID ?? this.composer.contextModelID;
        return okOutcome(command);
      case "composerSetPermissionMode":
        this.composer.permissionMode = asPermissionMode(args.permissionMode) ?? this.composer.permissionMode;
        return okOutcome(command);
      case "composerSetReasoningEffort":
        this.composer.reasoningEffort = asReasoningEffort(args.reasoningEffort) ?? this.composer.reasoningEffort;
        return okOutcome(command);
      case "composerAttach":
        if (args.attachment) {
          this.composer.attachments = [...this.composer.attachments, fromAttachmentDTO(args.attachment)];
        }
        return okOutcome(command);
      case "composerRemoveAttach":
        // 下发的 DTO id 是裸 UUID，composer 内存里是 `attachment-<uuid>`，比较前先归一。
        this.composer.attachments = this.composer.attachments.filter((attachment) => toUUID(attachment.id) !== args.attachmentId);
        return okOutcome(command);
      case "composerSend":
        return this.handleComposerSend(command);
      case "stop":
        chat.stop();
        return okOutcome(command);
      case "flushQueue":
        chat.startNextQueuedRequestIfNeeded();
        return okOutcome(command);
      case "interruptAndStartNext":
        chat.stop();
        return okOutcome(command);
      case "cancelQueued": {
        const originalId = args.requestId ? this.requestByUuid.get(args.requestId) : null;
        if (originalId) chat.cancelQueuedRequest(originalId);
        return okOutcome(command);
      }
      case "editQueued":
        // 一期不支持队列内编辑，回 ok 但不动作。
        return okOutcome(command);
      case "respondPermission": {
        const requestID = args.permissionRequestId ?? args.requestId ?? "";
        const decision = asPermissionDecision(args.decision);
        if (requestID) chat.respondToPermission(requestID, decision);
        return okOutcome(command);
      }
      case "respondInteractive": {
        const response = args.interactiveResponse;
        const requestID = args.interactiveRequestId ?? (response?.requestId as string | undefined) ?? "";
        if (requestID && response) {
          chat.respondToInteractiveRequest({
            requestID,
            selectedOptionIDs: Array.isArray((response as { selectedOptionIDs?: unknown }).selectedOptionIDs)
              ? ((response as { selectedOptionIDs: string[] }).selectedOptionIDs)
              : [],
            customText: typeof (response as { customText?: unknown }).customText === "string"
              ? (response as { customText: string }).customText
              : null
          });
        }
        return okOutcome(command);
      }
      case "requestSnapshot":
        return { ...okOutcome(command), shouldPushSnapshotForFocus: true };
      case "refreshCapabilities":
        return { ...okOutcome(command), shouldPushSnapshotForFocus: true };
      default:
        return okOutcome(command);
    }
  }

  private handleComposerSend(command: RemoteCommand): CommandOutcome {
    const chat = useChatStore.getState();
    const project = this.currentProjectSnapshot();
    if (!project) {
      return {
        ack: errorAck(command, "请先在电脑端选择项目。"),
        shouldUpdateFocusedSessionId: false,
        newFocusedSessionId: null,
        shouldPushSnapshotForFocus: false
      };
    }
    const text = (command.args.text ?? this.composer.text).trim();
    const attachments = this.composer.attachments;
    if (!text && attachments.length === 0) {
      return {
        ack: errorAck(command, "消息内容不能为空。"),
        shouldUpdateFocusedSessionId: false,
        newFocusedSessionId: null,
        shouldPushSnapshotForFocus: false
      };
    }
    const sent = chat.send({
      text,
      project,
      attachments,
      cli: this.composer.cli ?? undefined,
      modelID: this.composer.modelID ?? undefined,
      contextModelID: this.composer.contextModelID,
      permissionMode: this.composer.permissionMode ?? undefined,
      reasoningEffort: this.composer.reasoningEffort ?? undefined
    });
    this.composer.text = "";
    this.composer.attachments = [];
    return {
      ack: sent ? okAck(command) : errorAck(command, "发送失败，请重试。"),
      shouldUpdateFocusedSessionId: true,
      newFocusedSessionId: this.currentSessionUuid(),
      shouldPushSnapshotForFocus: true
    };
  }

  private focusOutcome(command: RemoteCommand, explicitFocus?: string | null): CommandOutcome {
    return {
      ack: okAck(command),
      shouldUpdateFocusedSessionId: true,
      newFocusedSessionId: explicitFocus ?? this.currentSessionUuid(),
      shouldPushSnapshotForFocus: true
    };
  }

  private currentSessionUuid(): string | null {
    const session = useChatStore.getState().currentSession;
    return session ? toUUID(session.id) : null;
  }

  private projectSnapshotById(projectId: string | undefined): ProjectSnapshot | null {
    if (!projectId) return null;
    const project = useProjectStore.getState().projects.find((candidate) => candidate.id === projectId);
    return project ? { id: project.id, name: project.name, path: project.path } : null;
  }

  private currentProjectSnapshot(): ProjectSnapshot | null {
    const chat = useChatStore.getState();
    const projects = useProjectStore.getState();
    if (chat.currentSession) {
      const matched = projects.projects.find((project) => project.path === chat.currentSession?.projectPath);
      if (matched) return { id: matched.id, name: matched.name, path: matched.path };
    }
    const selected = projects.selectedProject();
    return selected ? { id: selected.id, name: selected.name, path: selected.path } : null;
  }
}

function okAck(command: RemoteCommand): CommandAck {
  return { type: "command_ack", commandId: command.commandId, status: "ok", message: null, sessionId: command.sessionId ?? null };
}

function errorAck(command: RemoteCommand, message: string): CommandAck {
  return { type: "command_ack", commandId: command.commandId, status: "error", message, sessionId: command.sessionId ?? null };
}

function okOutcome(command: RemoteCommand): CommandOutcome {
  return { ack: okAck(command), shouldUpdateFocusedSessionId: false, newFocusedSessionId: null, shouldPushSnapshotForFocus: false };
}

function toAttachmentDTO(attachment: ChatMessageAttachment): ChatMessageAttachmentDTO {
  return {
    // iOS 端按非空 UUID 解码 id；还原不出时生成一个，避免整条 envelope 解码失败。
    id: toUUIDOrNull(attachment.id) ?? crypto.randomUUID(),
    kind: attachment.kind,
    filename: attachment.filename,
    path: attachment.path,
    thumbnailData: attachment.thumbnailData ?? null
  };
}

function fromAttachmentDTO(dto: ChatMessageAttachmentDTO): ChatMessageAttachment {
  return {
    id: dto.id ?? crypto.randomUUID(),
    kind: dto.kind ?? "file",
    filename: dto.filename,
    path: dto.path,
    thumbnailData: dto.thumbnailData ?? null
  };
}

function asPermissionMode(value: string | undefined): ChatPermissionMode | null {
  return value === "ask" || value === "autoEdit" || value === "fullAccess" ? value : null;
}

function asReasoningEffort(value: string | undefined): ChatReasoningEffort | null {
  return value === "low" || value === "medium" || value === "high" || value === "xhigh" || value === "max" ? value : null;
}

function asPermissionDecision(value: string | undefined): PermissionDecision {
  return value === "deny" || value === "allow" || value === "allowForSession" ? value : "allow";
}

function buildModels(settings: AppSettings | null) {
  const defaultCLI: ChatCLI = settings?.defaultCLI ?? "claude";
  const models: Array<{ id: string; title: string; cli: string; isDefault: boolean }> = [];
  for (const cli of ["claude", "codex"] as const) {
    const profiles = settings?.profiles.filter((profile) => profile.kind === cli && profile.enabled) ?? [];
    const distinct = [...new Set(profiles.map((profile) => profile.model?.trim()).filter((model): model is string => Boolean(model)))];
    if (distinct.length === 0) distinct.push("default");
    distinct.forEach((model, index) => {
      models.push({ id: model, title: model, cli, isDefault: index === 0 && cli === defaultCLI });
    });
  }
  return models;
}

function buildCapabilities() {
  return [
    { cli: "claude", executableAvailable: true, supportsStreamJSONInput: true, supportsAppServer: false, errorMessage: null },
    { cli: "codex", executableAvailable: true, supportsStreamJSONInput: true, supportsAppServer: true, errorMessage: null }
  ];
}

let installedBridge: RemoteHostBridge | null = null;

/** 在渲染进程启动后调用一次；返回卸载函数。 */
export function installRemoteHostBridge(): () => void {
  if (installedBridge) {
    return () => undefined;
  }
  const bridge = new RemoteHostBridge();
  installedBridge = bridge;
  const dispose = bridge.install();
  return () => {
    dispose();
    installedBridge = null;
  };
}
