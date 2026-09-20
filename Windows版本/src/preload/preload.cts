import { contextBridge, ipcRenderer } from "electron";
import type {
  AppInfo,
  DesktopNotificationRequest,
  ProjectDirectorySelection,
  RemoteHostApplyCommandRequest,
  RemoteHostBridge,
  RemoteHostCommandResult,
  RemoteHostStatus,
  WindowControlAction
} from "../shared/ipc";
import type { PanelStateSnapshot } from "../shared/remoteProtocol";
import type {
  AddProjectRequest,
  Project,
  ProjectListResponse,
  RemoveProjectRequest,
  SelectProjectRequest,
  TouchProjectRequest
} from "../shared/project";
import type { ScanFileTreeRequest, ScanFileTreeResponse } from "../shared/fileTree";
import type {
  EditorFileSelection,
  EditorFileStat,
  EditorOpenFileResult,
  EditorSaveFileResult
} from "../shared/editor";
import type {
  AppSettings,
  AppSettingsUpdate,
  CLIKind,
  CLIProbeResult,
  CLIProfile,
  CLIProfileCreateInput,
  CLIProfileUpdateInput
} from "../shared/settings";
import type {
  ChatBackendEventEnvelope,
  ChatInteractiveResponseRequest,
  ChatPermissionResponseRequest,
  ChatRunIDRequest,
  ChatSessionSnapshot,
  ChatStartRequest
} from "../shared/chat";

const ipcChannels = {
  appInfo: "app:info",
  selectProjectDirectory: "project:select-directory",
  windowControl: "window:control",
  projectList: "project:list",
  projectAdd: "project:add",
  projectRemove: "project:remove",
  projectTouch: "project:touch",
  projectSelect: "project:select",
  fileTreeScan: "file-tree:scan",
  editorSelectFile: "editor:select-file",
  editorOpenFile: "editor:open-file",
  editorSaveFile: "editor:save-file",
  editorStatFile: "editor:stat-file",
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
  remoteHostGetStatus: "remote-host:get-status",
  remoteHostSetEnabled: "remote-host:set-enabled",
  remoteHostPushSnapshot: "remote-host:push-snapshot",
  remoteHostApplyCommand: "remote-host:apply-command",
  remoteHostCommandResult: "remote-host:command-result",
  remoteHostStatus: "remote-host:status"
} as const;

function toAppInfo(value: unknown): AppInfo {
  if (!value || typeof value !== "object") {
    throw new Error("Invalid app info response");
  }

  const info = value as Record<string, unknown>;
  if (typeof info.version !== "string" || typeof info.platform !== "string" || typeof info.arch !== "string") {
    throw new Error("Invalid app info response");
  }

  return {
    version: info.version,
    platform: info.platform,
    arch: info.arch
  };
}

function toProjectDirectorySelection(value: unknown): ProjectDirectorySelection {
  if (!value || typeof value !== "object") {
    throw new Error("Invalid project directory response");
  }

  const selection = value as Record<string, unknown>;
  if (typeof selection.canceled !== "boolean") {
    throw new Error("Invalid project directory response");
  }

  if (selection.path !== null && typeof selection.path !== "string") {
    throw new Error("Invalid project directory response");
  }

  return {
    canceled: selection.canceled,
    path: selection.path
  };
}

function toChatBackendEventEnvelope(value: unknown): ChatBackendEventEnvelope {
  if (!value || typeof value !== "object") {
    throw new Error("Invalid chat event envelope");
  }
  const envelope = value as Record<string, unknown>;
  if (typeof envelope.runID !== "string" || !envelope.event || typeof envelope.event !== "object") {
    throw new Error("Invalid chat event envelope");
  }
  return envelope as unknown as ChatBackendEventEnvelope;
}

const chatEventListeners = new Set<(event: ChatBackendEventEnvelope) => void>();
const remoteHostStatusListeners = new Set<(status: RemoteHostStatus) => void>();
const remoteHostApplyCommandListeners = new Set<(payload: RemoteHostApplyCommandRequest) => void>();

ipcRenderer.on(ipcChannels.chatEvent, (_event, rawEnvelope: unknown) => {
  let envelope: ChatBackendEventEnvelope;
  try {
    envelope = toChatBackendEventEnvelope(rawEnvelope);
  } catch {
    return;
  }
  for (const listener of chatEventListeners) {
    listener(envelope);
  }
});

const api = {
  async getAppInfo(): Promise<AppInfo> {
    return toAppInfo(await ipcRenderer.invoke(ipcChannels.appInfo));
  },
  async selectProjectDirectory(): Promise<ProjectDirectorySelection> {
    return toProjectDirectorySelection(await ipcRenderer.invoke(ipcChannels.selectProjectDirectory));
  },
  async windowControl(action: WindowControlAction): Promise<void> {
    await ipcRenderer.invoke(ipcChannels.windowControl, action);
  },
  async showDesktopNotification(request: DesktopNotificationRequest): Promise<boolean> {
    return ipcRenderer.invoke(ipcChannels.desktopNotificationShow, request) as Promise<boolean>;
  },
  projects: {
    async list(): Promise<ProjectListResponse> {
      return ipcRenderer.invoke(ipcChannels.projectList) as Promise<ProjectListResponse>;
    },
    async add(request: AddProjectRequest): Promise<Project> {
      return ipcRenderer.invoke(ipcChannels.projectAdd, request) as Promise<Project>;
    },
    async remove(request: RemoveProjectRequest): Promise<ProjectListResponse> {
      return ipcRenderer.invoke(ipcChannels.projectRemove, request) as Promise<ProjectListResponse>;
    },
    async touch(request: TouchProjectRequest): Promise<Project> {
      return ipcRenderer.invoke(ipcChannels.projectTouch, request) as Promise<Project>;
    },
    async select(request: SelectProjectRequest): Promise<ProjectListResponse> {
      return ipcRenderer.invoke(ipcChannels.projectSelect, request) as Promise<ProjectListResponse>;
    }
  },
  files: {
    async scan(request: ScanFileTreeRequest): Promise<ScanFileTreeResponse> {
      return ipcRenderer.invoke(ipcChannels.fileTreeScan, request) as Promise<ScanFileTreeResponse>;
    }
  },
  async selectEditorFile(): Promise<EditorFileSelection> {
    return ipcRenderer.invoke(ipcChannels.editorSelectFile) as Promise<EditorFileSelection>;
  },
  async openEditorFile(path: string): Promise<EditorOpenFileResult> {
    return ipcRenderer.invoke(ipcChannels.editorOpenFile, { path }) as Promise<EditorOpenFileResult>;
  },
  async saveEditorFile(path: string, text: string, expectedText: string): Promise<EditorSaveFileResult> {
    return ipcRenderer.invoke(ipcChannels.editorSaveFile, { path, text, expectedText }) as Promise<EditorSaveFileResult>;
  },
  async statEditorFile(path: string): Promise<EditorFileStat> {
    return ipcRenderer.invoke(ipcChannels.editorStatFile, { path }) as Promise<EditorFileStat>;
  },
  settings: {
    async get(): Promise<AppSettings> {
      return ipcRenderer.invoke(ipcChannels.settingsGet) as Promise<AppSettings>;
    },
    async update(patch: AppSettingsUpdate): Promise<AppSettings> {
      return ipcRenderer.invoke(ipcChannels.settingsUpdate, patch) as Promise<AppSettings>;
    },
    async reset(): Promise<AppSettings> {
      return ipcRenderer.invoke(ipcChannels.settingsReset) as Promise<AppSettings>;
    },
    profiles: {
      async list(kind?: CLIKind): Promise<CLIProfile[]> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileList, kind) as Promise<CLIProfile[]>;
      },
      async create(input: CLIProfileCreateInput): Promise<CLIProfile> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileCreate, input) as Promise<CLIProfile>;
      },
      async update(profileId: string, input: CLIProfileUpdateInput): Promise<CLIProfile> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileUpdate, { profileId, input }) as Promise<CLIProfile>;
      },
      async remove(profileId: string): Promise<boolean> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileRemove, { profileId }) as Promise<boolean>;
      },
      async setDefault(profileId: string): Promise<CLIProfile> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileSetDefault, { profileId }) as Promise<CLIProfile>;
      },
      async setSecret(profileId: string, field: "apiKey" | "authToken", value: string): Promise<CLIProfile> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileSecretSet, { profileId, field, value }) as Promise<CLIProfile>;
      },
      async clearSecret(profileId: string, field: "apiKey" | "authToken"): Promise<CLIProfile> {
        return ipcRenderer.invoke(ipcChannels.settingsProfileSecretClear, { profileId, field }) as Promise<CLIProfile>;
      }
    },
    async probe(kind: CLIKind, command?: string): Promise<CLIProbeResult> {
      return ipcRenderer.invoke(ipcChannels.settingsCLIProbe, { kind, command }) as Promise<CLIProbeResult>;
    },
    async addAuthorizedFolder(): Promise<AppSettings> {
      return ipcRenderer.invoke(ipcChannels.settingsAuthorizedFolderAdd) as Promise<AppSettings>;
    },
    async removeAuthorizedFolder(folderId: string): Promise<AppSettings> {
      return ipcRenderer.invoke(ipcChannels.settingsAuthorizedFolderRemove, { folderId }) as Promise<AppSettings>;
    }
  },
  chat: {
    async start(request: ChatStartRequest): Promise<{ runID: string }> {
      return ipcRenderer.invoke(ipcChannels.chatStart, request) as Promise<{ runID: string }>;
    },
    async interrupt(request: ChatRunIDRequest): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatInterrupt, request) as Promise<boolean>;
    },
    async respondToPermission(request: ChatPermissionResponseRequest): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatPermissionResponse, request) as Promise<boolean>;
    },
    async respondToInteractiveRequest(request: ChatInteractiveResponseRequest): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatInteractiveResponse, request) as Promise<boolean>;
    },
    async sendCompact(request: ChatRunIDRequest): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatCompact, request) as Promise<boolean>;
    },
    async loadSessions(): Promise<ChatSessionSnapshot> {
      return ipcRenderer.invoke(ipcChannels.chatSessionLoad) as Promise<ChatSessionSnapshot>;
    },
    async saveSessions(snapshot: ChatSessionSnapshot): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatSessionSave, snapshot) as Promise<boolean>;
    },
    async deleteSession(sessionID: string): Promise<boolean> {
      return ipcRenderer.invoke(ipcChannels.chatSessionDelete, { sessionID }) as Promise<boolean>;
    },
    onEvent(listener: (event: ChatBackendEventEnvelope) => void): () => void {
      chatEventListeners.add(listener);
      return () => {
        chatEventListeners.delete(listener);
      };
    }
  },
  remoteHost: {
    async getStatus(): Promise<RemoteHostStatus> {
      return ipcRenderer.invoke(ipcChannels.remoteHostGetStatus) as Promise<RemoteHostStatus>;
    },
    async setEnabled(enabled: boolean): Promise<RemoteHostStatus> {
      return ipcRenderer.invoke(ipcChannels.remoteHostSetEnabled, { enabled }) as Promise<RemoteHostStatus>;
    },
    async pushSnapshot(snapshot: PanelStateSnapshot): Promise<void> {
      await ipcRenderer.invoke(ipcChannels.remoteHostPushSnapshot, { snapshot });
    },
    async sendCommandResult(result: RemoteHostCommandResult): Promise<void> {
      await ipcRenderer.invoke(ipcChannels.remoteHostCommandResult, result);
    },
    onStatus(listener: (status: RemoteHostStatus) => void): () => void {
      remoteHostStatusListeners.add(listener);
      return () => {
        remoteHostStatusListeners.delete(listener);
      };
    },
    onApplyCommand(listener: (payload: RemoteHostApplyCommandRequest) => void): () => void {
      remoteHostApplyCommandListeners.add(listener);
      return () => {
        remoteHostApplyCommandListeners.delete(listener);
      };
    }
  } satisfies RemoteHostBridge
};

ipcRenderer.on(ipcChannels.remoteHostStatus, (_event, rawStatus: unknown) => {
  if (!rawStatus || typeof rawStatus !== "object") {
    return;
  }
  const status = rawStatus as RemoteHostStatus;
  for (const listener of remoteHostStatusListeners) {
    listener(status);
  }
});

ipcRenderer.on(ipcChannels.remoteHostApplyCommand, (_event, rawPayload: unknown) => {
  if (!rawPayload || typeof rawPayload !== "object") {
    return;
  }
  const payload = rawPayload as RemoteHostApplyCommandRequest;
  for (const listener of remoteHostApplyCommandListeners) {
    listener(payload);
  }
});

contextBridge.exposeInMainWorld("codevoke", api);
