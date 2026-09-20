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
  remoteHostStatus: "remote-host:status",
  // WAN 直连：配对载荷 / 设备吊销 / endpoint 诊断刷新
  remoteHostGetPairing: "remote-host:get-pairing",
  remoteHostRevokeDevice: "remote-host:revoke-device",
  remoteHostRefreshEndpoints: "remote-host:refresh-endpoints",
  // GitHub Releases 自动更新
  updateGetStatus: "update:get-status",
  updateCheck: "update:check",
  updateQuitAndInstall: "update:quit-and-install",
  updateOpenReleases: "update:open-releases",
  updateStatusChanged: "update:status-changed"
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

/** 已配对设备（主进程 → 渲染进程；不含 token 哈希）。 */
export const remoteHostPairedDeviceSchema = z.object({
  deviceId: z.string(),
  deviceName: z.string(),
  createdAt: z.string(),
  lastSeen: z.string().nullable(),
  via: z.enum(["qr", "code"])
});

export type RemoteHostPairedDevice = z.infer<typeof remoteHostPairedDeviceSchema>;

/** WAN 候选 endpoint（契约 §4.4 eps + 状态）。 */
export const wanEndpointSchema = z.object({
  a: z.string(),
  p: z.number().int().nonnegative(),
  kind: z.enum(["ipv6", "ipv4-mapped", "lan"]),
  status: z.enum(["ok", "unverified"])
});

export type WanEndpoint = z.infer<typeof wanEndpointSchema>;

/** WanEndpointPublisher 诊断快照（契约 §5.3）。 */
export const wanDiagnosticsSchema = z.object({
  endpoints: z.array(wanEndpointSchema),
  gatewayIPv4: z.string().nullable(),
  externalIPv4: z.string().nullable(),
  cgnatIPv4: z.boolean(),
  mappingMethod: z.enum(["nat-pmp", "upnp", "none"]),
  notes: z.array(z.string()),
  lastRefreshAt: z.string().nullable()
});

export type WanDiagnostics = z.infer<typeof wanDiagnosticsSchema>;

/** 远程 host 运行状态（主进程 → 渲染进程 / 设置页）。 */
export const remoteHostStatusSchema = z.object({
  enabled: z.boolean(),
  running: z.boolean(),
  port: z.number().int().nonnegative(),
  lanAddress: z.string().nullable(),
  activeConnectionCount: z.number().int().nonnegative(),
  lastError: z.string().nullable(),
  /** 自签证书 SPKI-SHA256 hex（配对指纹；轮换即失效需重新配对）。 */
  fingerprint: z.string().nullable(),
  /** WAN endpoint 诊断；未启动时为 null。 */
  wan: wanDiagnosticsSchema.nullable(),
  pairedDevices: z.array(remoteHostPairedDeviceSchema)
});

export type RemoteHostStatus = z.infer<typeof remoteHostStatusSchema>;

/** 配对信息（QR 内容 + 连接串 + 屏显 6 位码）。服务未运行时返回 null。 */
export const remoteHostPairingInfoSchema = z.object({
  /** acode://pair?d=<base64url(JSON)>，QR 与「复制连接串」共用。 */
  pairingUri: z.string(),
  code: z.string().length(6),
  codeExpiresAt: z.string(),
  fingerprintHex: z.string()
});

export type RemoteHostPairingInfo = z.infer<typeof remoteHostPairingInfoSchema>;

export const remoteHostRevokeDeviceRequestSchema = z.object({
  deviceId: z.string().min(1)
});

export type RemoteHostRevokeDeviceRequest = z.infer<typeof remoteHostRevokeDeviceRequestSchema>;

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
  /** 取配对信息（QR 载荷 + 6 位码）；服务未运行时返回 null。 */
  getPairing: () => Promise<RemoteHostPairingInfo | null>;
  /** 吊销已配对设备。 */
  revokeDevice: (deviceId: string) => Promise<RemoteHostStatus>;
  /** 强制刷新 WAN endpoint 诊断。 */
  refreshEndpoints: () => Promise<RemoteHostStatus>;
  onStatus: (listener: (status: RemoteHostStatus) => void) => () => void;
  onApplyCommand: (listener: (payload: RemoteHostApplyCommandRequest) => void) => () => void;
}

// ---- GitHub Releases 自动更新（electron-updater）IPC 负载 ----

/** 更新检测阶段。 */
export const updatePhaseSchema = z.enum([
  "idle",
  "checking",
  "available",
  "downloading",
  "downloaded",
  "up-to-date",
  "error"
]);

export type UpdatePhase = z.infer<typeof updatePhaseSchema>;

/** 自动更新状态（主进程 → 渲染进程 / 设置页）。 */
export const updateStatusSchema = z.object({
  phase: updatePhaseSchema,
  /** false = dev/未打包环境，不执行检查。 */
  supported: z.boolean(),
  /** true = 便携版（PORTABLE_EXECUTABLE_DIR）：只检测不自动安装，提示去 Releases 手动下载。 */
  portable: z.boolean(),
  /** 检测到的新版本号（available/downloading/downloaded 时有值）。 */
  version: z.string().nullable(),
  /** 更新说明纯文本；渲染层按纯文本输出，不做 HTML 渲染。 */
  releaseNotes: z.string().nullable(),
  /** 下载进度 0-100；非下载中为 null。 */
  progressPercent: z.number().nullable(),
  /** 最近一次检查/下载错误消息。 */
  error: z.string().nullable(),
  /** GitHub Releases 页面地址（便携版手动下载入口）。 */
  releasesUrl: z.string()
});

export type UpdateStatus = z.infer<typeof updateStatusSchema>;

export interface UpdateBridge {
  getStatus: () => Promise<UpdateStatus>;
  /** 手动触发检查；返回当前状态，后续进展经 onStatus 推送。 */
  check: () => Promise<UpdateStatus>;
  /** 下载完成后重启安装；非 downloaded 阶段为 no-op。 */
  quitAndInstall: () => Promise<void>;
  /** 系统浏览器打开 Releases 页面（便携版下载入口）。 */
  openReleases: () => Promise<void>;
  onStatus: (listener: (status: UpdateStatus) => void) => () => void;
}
