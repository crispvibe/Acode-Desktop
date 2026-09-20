import { z } from "zod";

export const chatMessageKinds = [
  "user",
  "assistant",
  "reasoning",
  "toolCall",
  "toolResult",
  "command",
  "commandOutput",
  "permissionRequest",
  "interactiveRequest",
  "diff",
  "error",
  "system",
  "result",
  "rawOutput"
] as const;

export type ChatMessageKind = (typeof chatMessageKinds)[number];

export const chatMessageKindSchema = z.enum(chatMessageKinds);

export type ChatRunStatus =
  | "idle"
  | "starting"
  | "streaming"
  | "waitingPermission"
  | "waitingInput"
  | "stopping"
  | "completed"
  | "failed"
  | "unsupportedVersion";

export const runningChatStatuses = [
  "starting",
  "streaming",
  "waitingPermission",
  "waitingInput",
  "stopping"
] as const satisfies readonly ChatRunStatus[];

export function isChatRunStatusRunning(status: ChatRunStatus): boolean {
  return runningChatStatuses.includes(status as (typeof runningChatStatuses)[number]);
}

export const DEFAULT_CONTEXT_WINDOW = 200_000;

/// 与 Mac 端 ChatModelCatalog.contextWindow 保持一致的模型上下文窗口表：
/// GPT-5.5 真实窗口约 272K（登记为 275K）；Claude 的 [1m]/1m/1000k 变体是 1M；
/// 其余模型按 200K 兜底。CLI 明确上报的 context_window 优先于这张表。
export function contextWindowForModel(modelID: string | null | undefined): number {
  const raw = (modelID ?? "").trim().toLowerCase();
  if (!raw) {
    return DEFAULT_CONTEXT_WINDOW;
  }
  const executionID = raw.replace(/\[1m\]/g, "").trim();
  if (executionID === "gpt-5.5" || executionID === "gpt5.5") {
    return 275_000;
  }
  if (executionID === "claude-opus-4-7" || raw.includes("[1m]") || raw.includes("1m") || raw.includes("1000k")) {
    return 1_000_000;
  }
  return DEFAULT_CONTEXT_WINDOW;
}

export type ChatCLI = "claude" | "codex";
export type ChatPermissionMode = "ask" | "autoEdit" | "fullAccess";
export type ChatReasoningEffort = "low" | "medium" | "high" | "xhigh" | "max";
export type SessionMode = "newSession" | "continueLast" | "resume";
export type PermissionDecision = "deny" | "allow" | "allowForSession";
export type ChatMessageAttachmentKind = "file" | "image";

export const chatCLISchema = z.enum(["claude", "codex"]);
export const chatPermissionModeSchema = z.enum(["ask", "autoEdit", "fullAccess"]);
export const chatReasoningEffortSchema = z.enum(["low", "medium", "high", "xhigh", "max"]);
export const sessionModeSchema = z.enum(["newSession", "continueLast", "resume"]);
export const permissionDecisionSchema = z.enum(["deny", "allow", "allowForSession"]);
export const chatMessageAttachmentKindSchema = z.enum(["file", "image"]);

export interface ChatMessageAttachment {
  id: string;
  kind: ChatMessageAttachmentKind;
  filename: string;
  path: string;
  thumbnailData?: string | null;
}

export const chatMessageAttachmentSchema = z.object({
  id: z.string().min(1),
  kind: chatMessageAttachmentKindSchema,
  filename: z.string(),
  path: z.string(),
  thumbnailData: z.string().nullable().optional()
});

export type InteractiveMode = "singleChoice" | "multipleChoice" | "text";
export type InteractiveStatus = "waiting" | "answered" | "cancelled" | "failed";

export interface InteractiveOption {
  id: string;
  label: string;
  detail: string;
}

export const interactiveOptionSchema = z.object({
  id: z.string().min(1),
  label: z.string(),
  detail: z.string()
});

export interface InteractiveRequest {
  id: string;
  title: string;
  prompt: string;
  mode: InteractiveMode;
  options: InteractiveOption[];
  allowCustomInput: boolean;
  placeholder: string;
  status: InteractiveStatus;
}

export const interactiveResponseSchema = z.object({
  requestID: z.string().min(1),
  selectedOptionIDs: z.array(z.string()),
  customText: z.string().nullable().optional()
});

export interface InteractiveResponse {
  requestID: string;
  selectedOptionIDs: string[];
  customText?: string | null;
}

export interface ChatMessage {
  id: string;
  sessionID?: string | null;
  kind: ChatMessageKind;
  title?: string;
  subtitle?: string;
  text: string;
  status?: string;
  createdAt: string;
  parentUserMessageID?: string | null;
  requestID?: string | null;
  isStreaming?: boolean;
  interactiveRequest?: InteractiveRequest | null;
  appendRuleText?: string | null;
  outputTokenCount?: number | null;
  attachments?: ChatMessageAttachment[];
}

export const interactiveRequestSchema = z.object({
  id: z.string().min(1),
  title: z.string(),
  prompt: z.string(),
  mode: z.enum(["singleChoice", "multipleChoice", "text"]),
  options: z.array(interactiveOptionSchema),
  allowCustomInput: z.boolean(),
  placeholder: z.string(),
  status: z.enum(["waiting", "answered", "cancelled", "failed"])
});

export const chatMessageSchema = z.object({
  id: z.string().min(1),
  sessionID: z.string().nullable().optional(),
  kind: chatMessageKindSchema,
  title: z.string().optional(),
  subtitle: z.string().optional(),
  text: z.string(),
  status: z.string().optional(),
  createdAt: z.string(),
  parentUserMessageID: z.string().nullable().optional(),
  requestID: z.string().nullable().optional(),
  isStreaming: z.boolean().optional(),
  interactiveRequest: interactiveRequestSchema.nullable().optional(),
  appendRuleText: z.string().nullable().optional(),
  outputTokenCount: z.number().nullable().optional(),
  attachments: z.array(chatMessageAttachmentSchema).optional()
});

export interface ChatSessionSummary {
  id: string;
  title: string;
  projectPath: string | null;
  cli: "claude" | "codex";
  status: ChatRunStatus;
  updatedAt: string;
}

export interface ProjectSnapshot {
  id: string;
  name: string;
  path: string;
}

export const projectSnapshotSchema = z.object({
  id: z.string().min(1),
  name: z.string(),
  path: z.string().min(1)
});

export interface QueuedChatRequest {
  id: string;
  text: string;
  displayText: string;
  appendRuleText?: string | null;
  attachments: ChatMessageAttachment[];
  project: ProjectSnapshot;
  cli: ChatCLI;
  modelID: string;
  contextModelID?: string | null;
  permissionMode: ChatPermissionMode;
  reasoningEffort: ChatReasoningEffort;
  sessionMode: SessionMode;
  resumeSessionID?: string | null;
  createdAt: string;
}

export const projectSnapshotForChatSchema = z.object({
  id: z.string().min(1),
  name: z.string(),
  path: z.string().min(1)
});

export const queuedChatRequestSchema = z.object({
  id: z.string().min(1),
  text: z.string(),
  displayText: z.string(),
  appendRuleText: z.string().nullable().optional(),
  attachments: z.array(chatMessageAttachmentSchema),
  project: projectSnapshotForChatSchema,
  cli: chatCLISchema,
  modelID: z.string().min(1),
  contextModelID: z.string().nullable().optional(),
  permissionMode: chatPermissionModeSchema,
  reasoningEffort: chatReasoningEffortSchema,
  sessionMode: sessionModeSchema,
  resumeSessionID: z.string().nullable().optional(),
  createdAt: z.string()
});

export interface ChatSessionRecord {
  id: string;
  cli: ChatCLI;
  projectName: string;
  projectPath: string;
  title: string;
  modelID: string;
  permissionMode: ChatPermissionMode;
  reasoningEffort: ChatReasoningEffort;
  externalSessionID?: string | null;
  createdAt: string;
  updatedAt: string;
  runStatus: ChatRunStatus;
  statusText: string;
  queuedRequests: QueuedChatRequest[];
  lastCompletedAt?: string | null;
  activeRunStartedAt?: string | null;
  activeRunRequest?: QueuedChatRequest | null;
}

export const chatSessionRecordSchema = z.object({
  id: z.string().min(1),
  cli: chatCLISchema,
  projectName: z.string(),
  projectPath: z.string(),
  title: z.string(),
  modelID: z.string().min(1),
  permissionMode: chatPermissionModeSchema,
  reasoningEffort: chatReasoningEffortSchema,
  externalSessionID: z.string().nullable().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
  runStatus: z.enum([
    "idle",
    "starting",
    "streaming",
    "waitingPermission",
    "waitingInput",
    "stopping",
    "completed",
    "failed",
    "unsupportedVersion"
  ]),
  statusText: z.string(),
  queuedRequests: z.array(queuedChatRequestSchema),
  lastCompletedAt: z.string().nullable().optional(),
  activeRunStartedAt: z.string().nullable().optional(),
  activeRunRequest: queuedChatRequestSchema.nullable().optional()
});

export const chatSessionSnapshotSchema = z.object({
  sessions: z.array(chatSessionRecordSchema).default([]),
  sessionMessages: z.record(z.array(chatMessageSchema)).default({}),
  currentSessionId: z.string().nullable().optional()
});

export interface ChatSessionSnapshot {
  sessions: ChatSessionRecord[];
  sessionMessages: Record<string, ChatMessage[]>;
  currentSessionId?: string | null;
}

export interface ChatRunOptions {
  cli: ChatCLI;
  executablePath: string;
  projectPath: string;
  workingDirectory?: string | null;
  modelID: string;
  permissionMode: ChatPermissionMode;
  reasoningEffort: ChatReasoningEffort;
  sessionMode: SessionMode;
  resumeSessionID?: string | null;
  supportsStreamJSONInput: boolean;
  environment?: Record<string, string>;
  baseURL?: string | null;
}

export const chatRunOptionsSchema = z.object({
  cli: chatCLISchema,
  executablePath: z.string().min(1),
  projectPath: z.string().min(1),
  workingDirectory: z.string().nullable().optional(),
  modelID: z.string().min(1),
  permissionMode: chatPermissionModeSchema,
  reasoningEffort: chatReasoningEffortSchema,
  sessionMode: sessionModeSchema,
  resumeSessionID: z.string().nullable().optional(),
  supportsStreamJSONInput: z.boolean(),
  environment: z.record(z.string()).optional(),
  baseURL: z.string().nullable().optional()
});

export const chatSessionRecordIPCSchema = z.object({
  id: z.string().min(1).optional(),
  externalSessionID: z.string().nullable().optional(),
  projectPath: z.string().optional(),
  cli: chatCLISchema.optional()
}).passthrough();

export const chatStartRequestSchema = z.object({
  runID: z.string().min(1),
  prompt: z.string(),
  attachments: z.array(chatMessageAttachmentSchema).default([]),
  options: chatRunOptionsSchema,
  session: chatSessionRecordIPCSchema.nullable()
});

export const chatRunIDRequestSchema = z.object({
  runID: z.string().min(1)
});

export const chatPermissionResponseRequestSchema = chatRunIDRequestSchema.extend({
  requestID: z.string().min(1),
  decision: permissionDecisionSchema
});

export const chatInteractiveResponseRequestSchema = chatRunIDRequestSchema.extend({
  response: interactiveResponseSchema
});

export interface ChatStartRequest {
  runID: string;
  prompt: string;
  attachments: ChatMessageAttachment[];
  options: ChatRunOptions;
  session: ChatSessionRecord | null;
}
export type ChatRunIDRequest = z.infer<typeof chatRunIDRequestSchema>;
export type ChatPermissionResponseRequest = z.infer<typeof chatPermissionResponseRequestSchema>;
export type ChatInteractiveResponseRequest = z.infer<typeof chatInteractiveResponseRequestSchema>;

export interface SessionActivity {
  status: ChatRunStatus;
  statusText: string;
  queuedCount: number;
  lastCompletedAt?: string | null;
  activeRunStartedAt?: string | null;
}

export type ChatBackendEvent =
  | {
      type: "appendMessage";
      kind: ChatMessageKind;
      title?: string;
      subtitle?: string;
      text: string;
      status?: string;
      requestID?: string | null;
    }
  | {
      type: "appendDelta";
      kind: ChatMessageKind;
      title?: string;
      subtitle?: string;
      text: string;
      status?: string;
      requestID?: string | null;
    }
  | {
      type: "finishStreamingMessage";
      kind: ChatMessageKind;
      requestID?: string | null;
      status?: string;
    }
  | { type: "updateStreamingStatus"; status: string }
  | { type: "sessionID"; externalSessionID: string }
  | { type: "permissionRequest"; id: string; title: string; text: string }
  | { type: "interactiveRequest"; request: InteractiveRequest }
  | { type: "tokenUsage"; used: number; total: number; output?: number | null }
  | { type: "finished" }
  | { type: "failed"; message: string };

export interface ChatPanelBackend {
  start(prompt: string, options: ChatRunOptions, session: ChatSessionRecord | null, attachments?: ChatMessageAttachment[]): AsyncIterable<ChatBackendEvent>;
  interrupt(): void;
  respondToPermission(requestID: string, decision: PermissionDecision): boolean;
  respondToInteractiveRequest(requestID: string, response: InteractiveResponse): boolean;
  sendCompact(): boolean;
}

export interface ChatBackendEventEnvelope {
  runID: string;
  event: ChatBackendEvent;
}

export interface ChatBridge {
  start(request: ChatStartRequest): Promise<{ runID: string }>;
  interrupt(request: ChatRunIDRequest): Promise<boolean>;
  respondToPermission(request: ChatPermissionResponseRequest): Promise<boolean>;
  respondToInteractiveRequest(request: ChatInteractiveResponseRequest): Promise<boolean>;
  sendCompact(request: ChatRunIDRequest): Promise<boolean>;
  loadSessions(): Promise<ChatSessionSnapshot>;
  saveSessions(snapshot: ChatSessionSnapshot): Promise<boolean>;
  deleteSession(sessionID: string): Promise<boolean>;
  onEvent(listener: (envelope: ChatBackendEventEnvelope) => void): () => void;
}

export type ChatInteractiveMode = InteractiveMode;
export type ChatInteractiveStatus = InteractiveStatus;
export type ChatInteractiveOption = InteractiveOption;
export type ChatInteractiveRequest = InteractiveRequest;
export type ChatInteractiveResponse = InteractiveResponse;
export type ChatPermissionDecision = PermissionDecision;
