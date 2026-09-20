import type {
  AppInfo,
  DesktopNotificationRequest,
  ProjectDirectorySelection,
  RemoteHostBridge,
  WindowControlAction
} from "../shared/ipc";
import type { ProjectBridge } from "../shared/project";
import type { FileTreeBridge } from "../shared/fileTree";
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
  CLIProfileUpdateInput,
  SecretField
} from "../shared/settings";
import type { ChatBridge } from "../shared/chat";

declare global {
  interface Window {
    codevoke?: {
      getAppInfo: () => Promise<AppInfo>;
      selectProjectDirectory: () => Promise<ProjectDirectorySelection>;
      windowControl: (action: WindowControlAction) => Promise<void>;
      showDesktopNotification: (request: DesktopNotificationRequest) => Promise<boolean>;
      projects: ProjectBridge;
      files: FileTreeBridge;
      selectEditorFile: () => Promise<EditorFileSelection>;
      openEditorFile: (path: string) => Promise<EditorOpenFileResult>;
      saveEditorFile: (path: string, text: string, expectedText: string) => Promise<EditorSaveFileResult>;
      statEditorFile: (path: string) => Promise<EditorFileStat>;
      settings: {
        get: () => Promise<AppSettings>;
        update: (patch: AppSettingsUpdate) => Promise<AppSettings>;
        reset: () => Promise<AppSettings>;
        profiles: {
          list: (kind?: CLIKind) => Promise<CLIProfile[]>;
          create: (input: CLIProfileCreateInput) => Promise<CLIProfile>;
          update: (profileId: string, input: CLIProfileUpdateInput) => Promise<CLIProfile>;
          remove: (profileId: string) => Promise<boolean>;
          setDefault: (profileId: string) => Promise<CLIProfile>;
          setSecret: (profileId: string, field: SecretField, value: string) => Promise<CLIProfile>;
          clearSecret: (profileId: string, field: SecretField) => Promise<CLIProfile>;
        };
        probe: (kind: CLIKind, command?: string) => Promise<CLIProbeResult>;
        addAuthorizedFolder: () => Promise<AppSettings>;
        removeAuthorizedFolder: (folderId: string) => Promise<AppSettings>;
      };
      chat: ChatBridge;
      remoteHost: RemoteHostBridge;
    };
  }
}

export {};
