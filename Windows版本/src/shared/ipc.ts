import { z } from "zod";
import { cliKindSchema, secretFieldSchema } from "./settings.js";
import { commandAckSchema, commandSchema, panelStateSnapshotSchema, type PanelStateSnapshot } from "./remoteProtocol.js";

export const ipcChannels = {
  appInfo: "app:info",
  selectProjectDirectory: "project:select-directory",
  windowControl: "window:control",
  projectList: "project:list",
  projectAdd: "project:add",
  projectRemove: "project:remove",
  projectTouch: "project:touch",
  projectSelect: "project:select",
  fileTreeScan: "file-tree:scan",
  settingsGet: "settings:get",
  settingsUpdate: "settings:update",
  settingsReset: "settings:reset",
  settingsProfileList: "settings:profile:list",
  settingsProfileCreate: "settings:profile:create",
  settingsProfileUpdate: "settings:profile:update",
  settingsProfileRemove: "settings:profile:remove",
  settingsProfileSetDefault: "settings:profile:set-default",
  settingsProfileSecretSet: "settings:profile:secret:set",
  settingsProfileSecretClear: "settings:profile:secret:clear",
  settingsCLIProbe: "settings:cli:probe",
  settingsAuthorizedFolderAdd: "settings:authorized-folder:add",
  settingsAuthorizedFolderRemove: "settings:authorized-folder:remove",
  chatStart: "chat:start",
  chatInterrupt: "chat:interrupt",
  chatPermissionResponse: "chat:permission-response",
  chatInteractiveResponse: "chat:interactive-response",
  chatCompact: "chat:compact",
  chatSessionLoad: "chat-session:load",
  chatSessionSave: "chat-session:save",
  chatSessionDelete: "chat-session:delete",
  chatEvent: "chat:event",
  desktopNotificationShow: "desktop-notification:show",
  // 远程 host（手机连 Windows）相关
  remoteHostGetStatus: "remote-host:get-status",
  remoteHostSetEnabled: "remote-host:set-enabled",
  remoteHostPushSnapshot: "remote-host:push-snapshot",
  remoteHostApplyCommand: "remote-host:apply-command",
  remoteHostCommandResult: "remote-host:command-result",
  remoteHostStatus: "remote-host:status"
} as const;

export const appInfoSchema = z.object({
  version: z.string(),
  platform: z.string(),
  arch: z.string()
});

export type AppInfo = z.infer<typeof appInfoSchema>;

export const desktopNotificationRequestSchema = z.object({
  title: z.string().min(1).max(120),
  body: z.string().max(512).default("")
});

export type DesktopNotificationRequest = z.infer<typeof desktopNotificationRequestSchema>;

export const projectDirectorySchema = z.object({
  canceled: z.boolean(),
  path: z.string().nullable()
});

export type ProjectDirectorySelection = z.infer<typeof projectDirectorySchema>;

export const windowControlActionSchema = z.enum(["minimize", "toggleMaximize", "close"]);

export type WindowControlAction = z.infer<typeof windowControlActionSchema>;

export const settingsProfileUpdateRequestSchema = z.object({
  profileId: z.string().min(1),
  input: z.unknown()
});

export const settingsProfileIdRequestSchema = z.object({
  profileId: z.string().min(1)
});

export const settingsProfileSecretSetRequestSchema = z.object({
  profileId: z.string().min(1),
  field: secretFieldSchema,
  value: z.string()
});

export const settingsProfileSecretClearRequestSchema = z.object({
  profileId: z.string().min(1),
  field: secretFieldSchema
});

export const settingsCLIProbeRequestSchema = z.object({
  kind: cliKindSchema,
  command: z.string().optional()
});

export const settingsAuthorizedFolderRemoveRequestSchema = z.object({
  folderId: z.string().min(1)
});

export type SettingsProfileUpdateRequest = z.infer<typeof settingsProfileUpdateRequestSchema>;
export type SettingsProfileIdRequest = z.infer<typeof settingsProfileIdRequestSchema>;
export type SettingsProfileSecretSetRequest = z.infer<typeof settingsProfileSecretSetRequestSchema>;
export type SettingsProfileSecretClearRequest = z.infer<typeof settingsProfileSecretClearRequestSchema>;
export type SettingsCLIProbeRequest = z.infer<typeof settingsCLIProbeRequestSchema>;
export type SettingsAuthorizedFolderRemoveRequest = z.infer<typeof settingsAuthorizedFolderRemoveRequestSchema>;

// ---- 远程 host（手机连 Windows）IPC 负载 ----

/** 远程 host 运行状态（主进程 → 渲染进程 / 设置页）。 */
export const remoteHostStatusSchema = z.object({
  enabled: z.boolean(),
  running: z.boolean(),
  port: z.number().int().nonnegative(),
  lanAddress: z.string().nullable(),
  activeConnectionCount: z.number().int().nonnegative(),
  lastError: z.string().nullable()
});

export type RemoteHostStatus = z.infer<typeof remoteHostStatusSchema>;

export const remoteHostSetEnabledRequestSchema = z.object({
  enabled: z.boolean()
});

export type RemoteHostSetEnabledRequest = z.infer<typeof remoteHostSetEnabledRequestSchema>;

/** 渲染进程把组装好的面板快照推给主进程广播。 */
export const remoteHostPushSnapshotRequestSchema = z.object({
  snapshot: panelStateSnapshotSchema
});

export type RemoteHostPushSnapshotRequest = z.infer<typeof remoteHostPushSnapshotRequestSchema>;

/** 主进程把手机来的命令转给渲染进程执行。 */
export const remoteHostApplyCommandRequestSchema = z.object({
  requestId: z.string().min(1),
  // 内部 IPC：放宽为非空字符串（chatStore 会话 id 经 toUUID 一般为裸 UUID，但不强校验以免误拒）。
  focusedSessionId: z.string().min(1).nullable(),
  command: commandSchema
});

export type RemoteHostApplyCommandRequest = z.infer<typeof remoteHostApplyCommandRequestSchema>;

/** 渲染进程执行命令后回给主进程的结果。 */
export const remoteHostCommandResultSchema = z.object({
  requestId: z.string().min(1),
  ack: commandAckSchema,
  // 内部 IPC：放宽为非空字符串，避免非 UUID 会话 id 导致 parse 抛错、命令被拖到超时。
  newFocusedSessionId: z.string().min(1).nullable().optional(),
  shouldUpdateFocusedSessionId: z.boolean().default(false),
  shouldPushSnapshotForFocus: z.boolean().default(false)
});

export type RemoteHostCommandResult = z.infer<typeof remoteHostCommandResultSchema>;

export interface RemoteHostBridge {
  getStatus: () => Promise<RemoteHostStatus>;
  setEnabled: (enabled: boolean) => Promise<RemoteHostStatus>;
  pushSnapshot: (snapshot: PanelStateSnapshot) => Promise<void>;
  sendCommandResult: (result: RemoteHostCommandResult) => Promise<void>;
  onStatus: (listener: (status: RemoteHostStatus) => void) => () => void;
  onApplyCommand: (listener: (payload: RemoteHostApplyCommandRequest) => void) => () => void;
}
