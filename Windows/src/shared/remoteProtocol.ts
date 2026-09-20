import { z } from "zod";

const uuidSchema = z.string().uuid();
const isoDateStringSchema = z.string().datetime({ offset: true });

export const remoteVNCFrameType = {
  command: "command",
  commandAck: "command_ack",
  panelState: "panel_state",
  resume: "resume",
  recoveryRequest: "recovery_request",
  recoveryResponse: "recovery_response"
} as const;

/**
 * 附件上传相关上限，对齐 Mac 的 `RemoteRecoveryLimits`（ChatCore）。
 * - 文件最大 10MB；base64 后约 13.34MB；文本帧再留 64KB JSON 头部余量。
 */
export const remoteRecoveryLimits = {
  maximumAttachmentBytes: 10 * 1024 * 1024,
  get maximumAttachmentContentBase64Length(): number {
    return Math.floor((this.maximumAttachmentBytes + 2) / 3) * 4;
  },
  get maximumTextFrameUTF8Bytes(): number {
    return this.maximumAttachmentContentBase64Length + 64 * 1024;
  }
} as const;

export const chatMessageAttachmentSchema = z.object({
  id: uuidSchema.optional(),
  kind: z.enum(["file", "image"]).optional(),
  filename: z.string(),
  path: z.string(),
  mimeType: z.string().optional(),
  byteSize: z.number().int().nonnegative().optional(),
  thumbnailData: z.string().nullable().optional()
}).passthrough();

export type ChatMessageAttachmentDTO = z.infer<typeof chatMessageAttachmentSchema>;

export const chatMessageSchema = z.object({
  id: uuidSchema.or(z.string().min(1)),
  kind: z.string().min(1),
  text: z.string().default(""),
  createdAt: z.string()
}).passthrough();

export const panelProjectSchema = z.object({
  id: uuidSchema,
  name: z.string(),
  path: z.string(),
  defaultCLI: z.string(),
  createdAt: isoDateStringSchema,
  updatedAt: isoDateStringSchema,
  lastOpenedAt: isoDateStringSchema.nullable()
});

export const panelModelSchema = z.object({
  id: z.string(),
  title: z.string(),
  cli: z.string(),
  isDefault: z.boolean()
});

export const panelSessionSchema = z.object({
  id: uuidSchema,
  cli: z.string(),
  projectId: uuidSchema.nullable(),
  projectName: z.string(),
  projectPath: z.string(),
  title: z.string(),
  modelID: z.string(),
  runStatus: z.string(),
  statusText: z.string(),
  createdAt: isoDateStringSchema,
  updatedAt: isoDateStringSchema,
  lastCompletedAt: isoDateStringSchema.nullable(),
  queuedCount: z.number().int().nonnegative()
});

export const panelQueuedRequestSchema = z.object({
  id: uuidSchema,
  text: z.string(),
  displayText: z.string(),
  cli: z.string(),
  modelID: z.string(),
  permissionMode: z.string(),
  reasoningEffort: z.string(),
  projectId: uuidSchema,
  attachments: z.array(chatMessageAttachmentSchema)
});

export const panelStreamingTextSchema = z.object({
  messageId: uuidSchema,
  text: z.string(),
  status: z.string(),
  requestId: z.string().nullable()
});

export const panelComposerSchema = z.object({
  text: z.string(),
  cli: z.string(),
  modelID: z.string(),
  contextModelID: z.string().nullable(),
  permissionMode: z.string(),
  reasoningEffort: z.string(),
  attachments: z.array(chatMessageAttachmentSchema),
  isEnabled: z.boolean(),
  placeholder: z.string()
});

export const panelCapabilitySchema = z.object({
  cli: z.string(),
  executableAvailable: z.boolean(),
  supportsStreamJSONInput: z.boolean(),
  supportsAppServer: z.boolean(),
  errorMessage: z.string().nullable()
});

export const panelStateSnapshotSchema = z.object({
  revision: z.number().int().positive(),
  sessionId: uuidSchema.nullable(),
  projects: z.array(panelProjectSchema),
  models: z.array(panelModelSchema),
  sessions: z.array(panelSessionSchema),
  currentSessionId: uuidSchema.nullable(),
  messages: z.array(chatMessageSchema),
  queuedRequests: z.array(panelQueuedRequestSchema),
  streamingTexts: z.array(panelStreamingTextSchema),
  status: z.string(),
  statusText: z.string(),
  isAwaitingFirstModelOutput: z.boolean(),
  isLoadingHistory: z.boolean(),
  tokensUsed: z.number().int().nonnegative(),
  tokensTotal: z.number().int().nonnegative(),
  activeRunStartedAt: isoDateStringSchema.nullable(),
  isMirroringRemoteSession: z.boolean(),
  composer: panelComposerSchema,
  capabilities: z.array(panelCapabilitySchema)
});

export type PanelStateSnapshot = z.infer<typeof panelStateSnapshotSchema>;

export const nullableUUIDWrapperSchema = z.object({
  value: uuidSchema.nullable()
});

export const nullableDateWrapperSchema = z.object({
  value: isoDateStringSchema.nullable()
});

export const panelStatePatchSchema = z.object({
  revision: z.number().int().positive(),
  baseRevision: z.number().int().nonnegative(),
  sessionId: uuidSchema.nullable(),
  projects: z.array(panelProjectSchema).optional(),
  models: z.array(panelModelSchema).optional(),
  sessions: z.array(panelSessionSchema).optional(),
  currentSessionId: nullableUUIDWrapperSchema.optional(),
  messages: z.array(chatMessageSchema).optional(),
  queuedRequests: z.array(panelQueuedRequestSchema).optional(),
  streamingTexts: z.array(panelStreamingTextSchema).optional(),
  status: z.string().optional(),
  statusText: z.string().optional(),
  isAwaitingFirstModelOutput: z.boolean().optional(),
  isLoadingHistory: z.boolean().optional(),
  tokensUsed: z.number().int().nonnegative().optional(),
  tokensTotal: z.number().int().nonnegative().optional(),
  activeRunStartedAt: nullableDateWrapperSchema.optional(),
  isMirroringRemoteSession: z.boolean().optional(),
  composer: panelComposerSchema.optional(),
  capabilities: z.array(panelCapabilitySchema).optional()
});

export type PanelStatePatch = z.infer<typeof panelStatePatchSchema>;

export const panelStateEnvelopeSchema = z.object({
  type: z.literal(remoteVNCFrameType.panelState),
  kind: z.enum(["snapshot", "patch"]),
  sessionId: uuidSchema.nullable(),
  revision: z.number().int().positive(),
  snapshot: panelStateSnapshotSchema.nullable().optional(),
  patch: panelStatePatchSchema.nullable().optional()
}).superRefine((value, context) => {
  if (value.kind === "snapshot" && !value.snapshot) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "snapshot envelope requires snapshot" });
  }
  if (value.kind === "patch" && !value.patch) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "patch envelope requires patch" });
  }
});

export type PanelStateEnvelope = z.infer<typeof panelStateEnvelopeSchema>;

export const commandOpSchema = z.enum([
  "focusSession",
  "focusProject",
  "newDraftSession",
  "composerSet",
  "composerSetCLI",
  "composerSetModel",
  "composerSetPermissionMode",
  "composerSetReasoningEffort",
  "composerAttach",
  "composerRemoveAttach",
  "composerSend",
  "stop",
  "flushQueue",
  "interruptAndStartNext",
  "cancelQueued",
  "editQueued",
  "respondPermission",
  "respondInteractive",
  "requestSnapshot",
  "refreshCapabilities"
]);

export type CommandOp = z.infer<typeof commandOpSchema>;

export const interactiveResponseSchema = z.object({
  requestId: z.string().optional(),
  value: z.unknown().optional()
}).passthrough();

export const commandArgsSchema = z.object({
  text: z.string().optional(),
  cli: z.string().optional(),
  modelID: z.string().optional(),
  contextModelID: z.string().optional(),
  permissionMode: z.string().optional(),
  reasoningEffort: z.string().optional(),
  projectId: uuidSchema.optional(),
  sessionId: uuidSchema.optional(),
  requestId: z.string().optional(),
  permissionRequestId: z.string().optional(),
  decision: z.string().optional(),
  interactiveRequestId: z.string().optional(),
  interactiveResponse: interactiveResponseSchema.optional(),
  attachment: chatMessageAttachmentSchema.optional(),
  attachmentId: uuidSchema.optional(),
  sessionMode: z.string().optional(),
  resumeSessionID: z.string().optional(),
  appendRuleText: z.string().optional(),
  startQueuedAfterStop: z.boolean().optional(),
  expectedProjectId: uuidSchema.optional(),
  expectedSessionId: uuidSchema.optional()
}).passthrough();

export type CommandArgs = z.infer<typeof commandArgsSchema>;

export const commandSchema = z.object({
  type: z.literal(remoteVNCFrameType.command),
  commandId: uuidSchema,
  op: commandOpSchema,
  sessionId: uuidSchema.nullable().optional(),
  args: commandArgsSchema.default({})
});

export type RemoteCommand = z.infer<typeof commandSchema>;

export const commandAckSchema = z.object({
  type: z.literal(remoteVNCFrameType.commandAck),
  commandId: uuidSchema,
  status: z.enum(["ok", "rejected", "error"]),
  message: z.string().nullable().optional(),
  sessionId: uuidSchema.nullable().optional()
});

export type CommandAck = z.infer<typeof commandAckSchema>;

// iOS Codable 会省略 nil 字段、Android JSONObject.put(k, null) 也会移除键，
// 因此 sessionId/lastRevision 在客户端可能是缺省而不是 null，这里按 nullish 收。
export const resumeRequestSchema = z.object({
  type: z.literal(remoteVNCFrameType.resume),
  sessionId: uuidSchema.nullish(),
  lastRevision: z.number().int().nonnegative().nullish()
});

export type ResumeRequest = z.infer<typeof resumeRequestSchema>;

export function makeCommand(op: CommandOp, args: CommandArgs = {}, sessionId: string | null = null): RemoteCommand {
  return commandSchema.parse({
    type: remoteVNCFrameType.command,
    commandId: crypto.randomUUID(),
    op,
    sessionId,
    args
  });
}

export function makeResumeRequest(sessionId: string | null, lastRevision: number | null): ResumeRequest {
  return resumeRequestSchema.parse({
    type: remoteVNCFrameType.resume,
    sessionId,
    lastRevision
  });
}

// MARK: - Recovery RPC（client ↔ host）—— 对齐 Mac `RemoteRecoveryRequest/Response`
//
// 一期 Windows host 仅实现 `uploadAttachment`（图片/文件附件上传）；catalog/sessions/
// messages/projectFiles 等历史浏览在 Windows 走 panel_state 推送，不经此通道，故对
// 其余 op 返回明确错误，避免手机端静默卡住。

export const recoveryOpSchema = z.enum([
  "catalog",
  "sessions",
  "messages",
  "projectFiles",
  "uploadAttachment"
]);

export type RecoveryOp = z.infer<typeof recoveryOpSchema>;

export const recoveryRequestSchema = z.object({
  type: z.literal(remoteVNCFrameType.recoveryRequest),
  requestId: uuidSchema,
  op: recoveryOpSchema,
  projectId: uuidSchema.nullable().optional(),
  cli: z.string().nullable().optional(),
  sessionId: uuidSchema.nullable().optional(),
  limit: z.number().int().nullable().optional(),
  before: z.number().int().nullable().optional(),
  page: z.boolean().nullable().optional(),
  path: z.string().nullable().optional(),
  filename: z.string().nullable().optional(),
  contentBase64: z.string().nullable().optional()
}).passthrough();

export type RecoveryRequest = z.infer<typeof recoveryRequestSchema>;

/** 附件落盘后的回执（filename + host 端临时文件绝对路径）。 */
export const recoveryAttachmentUploadSchema = z.object({
  filename: z.string(),
  path: z.string()
});

export type RecoveryAttachmentUpload = z.infer<typeof recoveryAttachmentUploadSchema>;

export interface RecoveryResponse {
  type: typeof remoteVNCFrameType.recoveryResponse;
  requestId: string;
  status: "ok" | "error";
  message?: string | null;
  attachmentUpload?: RecoveryAttachmentUpload | null;
}

export function recoveryOkResponse(
  requestId: string,
  fields: { attachmentUpload?: RecoveryAttachmentUpload } = {}
): RecoveryResponse {
  return {
    type: remoteVNCFrameType.recoveryResponse,
    requestId,
    status: "ok",
    ...(fields.attachmentUpload ? { attachmentUpload: fields.attachmentUpload } : {})
  };
}

export function recoveryErrorResponse(requestId: string, message: string): RecoveryResponse {
  return {
    type: remoteVNCFrameType.recoveryResponse,
    requestId,
    status: "error",
    message
  };
}

// MARK: - HTTP 附件直传（LAN 直连）—— 对齐 Mac `RemoteAttachmentUpload{Request,Response}DTO`

export const attachmentUploadRequestSchema = z.object({
  filename: z.string(),
  contentBase64: z.string()
});

export type AttachmentUploadRequest = z.infer<typeof attachmentUploadRequestSchema>;

export interface AttachmentUploadResponse {
  filename: string;
  path: string;
}
