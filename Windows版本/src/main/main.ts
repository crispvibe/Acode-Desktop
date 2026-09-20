import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  nativeTheme,
  Notification as ElectronNotification,
  shell,
  type OpenDialogOptions
} from "electron";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  ipcChannels,
  desktopNotificationRequestSchema,
  projectDirectorySchema,
  settingsCLIProbeRequestSchema,
  settingsProfileIdRequestSchema,
  settingsProfileSecretClearRequestSchema,
  settingsProfileSecretSetRequestSchema,
  settingsProfileUpdateRequestSchema,
  settingsAuthorizedFolderRemoveRequestSchema,
  windowControlActionSchema,
  remoteHostSetEnabledRequestSchema,
  remoteHostPushSnapshotRequestSchema,
  remoteHostCommandResultSchema,
  type RemoteHostApplyCommandRequest,
  type RemoteHostStatus
} from "../shared/ipc.js";
import {
  addProjectRequestSchema,
  removeProjectRequestSchema,
  selectProjectRequestSchema,
  touchProjectRequestSchema
} from "../shared/project.js";
import { scanFileTreeRequestSchema } from "../shared/fileTree.js";
import { cliKindSchema, cliProfileCreateInputSchema } from "../shared/settings.js";
import { createProjectStore } from "./projects/projectStore.js";
import { createFileTreeService } from "./fileTree/fileTreeService.js";
import { registerEditorIpcHandlers } from "./editor/registerEditorIpc.js";
import { registerChatIpcHandlers } from "./chat/registerChatIpc.js";
import { ChatSessionStore } from "./chat/chatSessionStore.js";
import { AppSettingsService, CLIProfileService, probeCLI } from "./settings/service.js";
import { RemoteHostController } from "./remoteHost/RemoteHostController.js";
import { resolveExistingDirectory } from "./security/pathGuards.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow: BrowserWindow | null = null;

const isDevelopment = Boolean(process.env.VITE_DEV_SERVER_URL);
const projectStore = createProjectStore(app.getPath("userData"));
const settingsService = new AppSettingsService();
const fileTreeService = createFileTreeService(projectStore, settingsService);
const profileService = new CLIProfileService();
const chatSessionStore = new ChatSessionStore(app.getPath("userData"));

const remoteHostController = new RemoteHostController({
  userDataDir: app.getPath("userData"),
  requestApplyCommand: (payload: RemoteHostApplyCommandRequest): boolean => {
    if (!mainWindow || mainWindow.webContents.isDestroyed()) {
      return false;
    }
    mainWindow.webContents.send(ipcChannels.remoteHostApplyCommand, payload);
    return true;
  },
  publishStatus: (status: RemoteHostStatus): void => {
    for (const window of BrowserWindow.getAllWindows()) {
      window.webContents.send(ipcChannels.remoteHostStatus, status);
    }
  }
});

if (process.platform === "win32") {
  app.setAppUserModelId("com.acode.windows");
}

function resolvePreloadPath(): string {
  return path.join(__dirname, "../preload/preload.cjs");
}

function resolveRendererEntry(): string {
  return path.join(__dirname, "../renderer/index.html");
}

function resolveWindowIconPath(): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "icon.png");
  }
  return path.join(app.getAppPath(), "build/icon.png");
}

function normalizeStoredPath(value: string): string {
  const normalized = path.normalize(value);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function displayNameForPath(value: string): string {
  return path.basename(value) || value;
}

function attachWindowDiagnostics(window: BrowserWindow): void {
  window.webContents.on("did-finish-load", () => {
    if (!window.isVisible()) {
      window.show();
    }
  });

  if (!isDevelopment) {
    return;
  }

  window.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    console.log(`[renderer:${level}] ${sourceId}:${line} ${message}`);
  });

  window.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
    console.error(`[renderer:load-failed] ${errorCode} ${errorDescription} ${validatedURL}`);
  });

  window.webContents.on("render-process-gone", (_event, details) => {
    console.error("[renderer:gone]", details);
  });
}

async function createMainWindow(): Promise<void> {
  mainWindow = new BrowserWindow({
    width: 1320,
    height: 760,
    minWidth: 1320,
    minHeight: 760,
    frame: false,
    show: false,
    title: "acode",
    icon: resolveWindowIconPath(),
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#101014" : "#f4f4f2",
    webPreferences: {
      preload: resolvePreloadPath(),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true
    }
  });

  if (process.platform === "win32") {
    mainWindow.setBackgroundMaterial("mica");
  }

  mainWindow.once("ready-to-show", () => {
    mainWindow?.show();
  });

  attachWindowDiagnostics(mainWindow);

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://") || url.startsWith("http://")) {
      void shell.openExternal(url);
    }
    return { action: "deny" };
  });

  mainWindow.webContents.on("will-navigate", (event, url) => {
    const allowedDevUrl = process.env.VITE_DEV_SERVER_URL;
    if (allowedDevUrl && url.startsWith(allowedDevUrl)) {
      return;
    }

    if (!allowedDevUrl && url.startsWith("file://")) {
      return;
    }

    event.preventDefault();
  });

  if (isDevelopment && process.env.VITE_DEV_SERVER_URL) {
    await mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
    if (process.env.CODEVOKE_OPEN_DEVTOOLS === "1") {
      mainWindow.webContents.openDevTools({ mode: "detach" });
    }
  } else {
    await mainWindow.loadFile(resolveRendererEntry());
  }
}

function registerIpcHandlers(): void {
  ipcMain.handle(ipcChannels.appInfo, () => ({
    version: app.getVersion(),
    platform: process.platform,
    arch: process.arch
  }));
  ipcMain.handle(ipcChannels.selectProjectDirectory, async () => {
    const options: OpenDialogOptions = {
      properties: ["openDirectory", "createDirectory"],
      title: "Select project folder"
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);

    return projectDirectorySchema.parse({
      canceled: result.canceled,
      path: result.canceled ? null : result.filePaths[0] ?? null
    });
  });

  ipcMain.handle(ipcChannels.projectList, async () => projectStore.listProjects());

  ipcMain.handle(ipcChannels.projectAdd, async (_event, rawRequest: unknown) => {
    const request = addProjectRequestSchema.parse(rawRequest);
    return projectStore.addProject(request.path);
  });

  ipcMain.handle(ipcChannels.projectRemove, async (_event, rawRequest: unknown) => {
    const request = removeProjectRequestSchema.parse(rawRequest);
    return projectStore.removeProject(request.projectId);
  });

  ipcMain.handle(ipcChannels.projectTouch, async (_event, rawRequest: unknown) => {
    const request = touchProjectRequestSchema.parse(rawRequest);
    return projectStore.touchProject(request.projectId);
  });

  ipcMain.handle(ipcChannels.projectSelect, async (_event, rawRequest: unknown) => {
    const request = selectProjectRequestSchema.parse(rawRequest);
    return projectStore.selectProject(request.projectId);
  });

  ipcMain.handle(ipcChannels.fileTreeScan, async (_event, rawRequest: unknown) => {
    const request = scanFileTreeRequestSchema.parse(rawRequest);
    return fileTreeService.scan(request);
  });

  ipcMain.handle(ipcChannels.settingsGet, async () => settingsService.read());

  ipcMain.handle(ipcChannels.settingsUpdate, async (_event, rawPatch: unknown) => settingsService.update(rawPatch));

  ipcMain.handle(ipcChannels.settingsReset, async () => settingsService.reset());

  ipcMain.handle(ipcChannels.settingsAuthorizedFolderAdd, async () => {
    const options: OpenDialogOptions = {
      properties: ["openDirectory"],
      title: "选择授权文件夹"
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);
    const selectedPath = result.canceled ? null : result.filePaths[0] ?? null;
    const current = await settingsService.read();
    if (!selectedPath) {
      return current;
    }

    const guardedPath = await resolveExistingDirectory(selectedPath);
    const normalizedSelectedPath = normalizeStoredPath(guardedPath.realPath);
    if (current.authorizedFolders.some((folder) => normalizeStoredPath(folder.path) === normalizedSelectedPath)) {
      return current;
    }

    return settingsService.update({
      authorizedFolders: [
        ...current.authorizedFolders,
        {
          id: randomUUID(),
          name: displayNameForPath(guardedPath.realPath),
          path: guardedPath.realPath,
          createdAt: new Date().toISOString()
        }
      ]
    });
  });

  ipcMain.handle(ipcChannels.settingsAuthorizedFolderRemove, async (_event, rawRequest: unknown) => {
    const request = settingsAuthorizedFolderRemoveRequestSchema.parse(rawRequest);
    const current = await settingsService.read();
    return settingsService.update({
      authorizedFolders: current.authorizedFolders.filter((folder) => folder.id !== request.folderId)
    });
  });

  ipcMain.handle(ipcChannels.settingsProfileList, async (_event, rawKind?: unknown) => {
    const kind = rawKind === undefined || rawKind === null ? undefined : cliKindSchema.parse(rawKind);
    return profileService.list(kind);
  });

  ipcMain.handle(ipcChannels.settingsProfileCreate, async (_event, rawInput: unknown) => {
    const input = cliProfileCreateInputSchema.parse(rawInput);
    return profileService.create(input);
  });

  ipcMain.handle(ipcChannels.settingsProfileUpdate, async (_event, rawRequest: unknown) => {
    const request = settingsProfileUpdateRequestSchema.parse(rawRequest);
    return profileService.update(request.profileId, request.input);
  });

  ipcMain.handle(ipcChannels.settingsProfileRemove, async (_event, rawRequest: unknown) => {
    const request = settingsProfileIdRequestSchema.parse(rawRequest);
    return profileService.delete(request.profileId);
  });

  ipcMain.handle(ipcChannels.settingsProfileSetDefault, async (_event, rawRequest: unknown) => {
    const request = settingsProfileIdRequestSchema.parse(rawRequest);
    return profileService.setDefault(request.profileId);
  });

  ipcMain.handle(ipcChannels.settingsProfileSecretSet, async (_event, rawRequest: unknown) => {
    const request = settingsProfileSecretSetRequestSchema.parse(rawRequest);
    return profileService.setProfileSecret(request.profileId, request.field, request.value);
  });

  ipcMain.handle(ipcChannels.settingsProfileSecretClear, async (_event, rawRequest: unknown) => {
    const request = settingsProfileSecretClearRequestSchema.parse(rawRequest);
    return profileService.clearProfileSecret(request.profileId, request.field);
  });

  ipcMain.handle(ipcChannels.settingsCLIProbe, async (_event, rawRequest: unknown) => {
    const request = settingsCLIProbeRequestSchema.parse(rawRequest);
    return probeCLI(request.kind, request.command);
  });

  ipcMain.handle(ipcChannels.windowControl, (_event, rawAction: unknown) => {
    const action = windowControlActionSchema.parse(rawAction);
    if (!mainWindow) {
      return;
    }

    if (action === "minimize") {
      mainWindow.minimize();
      return;
    }

    if (action === "toggleMaximize") {
      if (mainWindow.isMaximized()) {
        mainWindow.unmaximize();
      } else {
        mainWindow.maximize();
      }
      return;
    }

    mainWindow.close();
  });

  ipcMain.handle(ipcChannels.desktopNotificationShow, (_event, rawRequest: unknown) => {
    const request = desktopNotificationRequestSchema.parse(rawRequest);
    if (!ElectronNotification.isSupported()) {
      return false;
    }
    new ElectronNotification({ title: request.title, body: request.body }).show();
    return true;
  });

  ipcMain.handle(ipcChannels.remoteHostGetStatus, () => remoteHostController.getStatus());

  ipcMain.handle(ipcChannels.remoteHostSetEnabled, async (_event, rawRequest: unknown) => {
    const request = remoteHostSetEnabledRequestSchema.parse(rawRequest);
    return remoteHostController.setEnabled(request.enabled);
  });

  ipcMain.handle(ipcChannels.remoteHostPushSnapshot, (_event, rawRequest: unknown) => {
    const request = remoteHostPushSnapshotRequestSchema.parse(rawRequest);
    remoteHostController.ingestSnapshot(request.snapshot);
  });

  ipcMain.handle(ipcChannels.remoteHostCommandResult, (_event, rawRequest: unknown) => {
    const request = remoteHostCommandResultSchema.parse(rawRequest);
    remoteHostController.resolveCommandResult(request);
  });

  registerEditorIpcHandlers({ projectStore, settingsService });
  registerChatIpcHandlers(chatSessionStore, profileService);
}

const gotLock = app.requestSingleInstanceLock();

if (!gotLock) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (!mainWindow) {
      return;
    }

    if (mainWindow.isMinimized()) {
      mainWindow.restore();
    }
    mainWindow.focus();
  });

  app.whenReady().then(async () => {
    registerIpcHandlers();
    await createMainWindow();
    await remoteHostController.init().catch((error: unknown) => {
      console.error("Failed to init remote host", error);
    });
  }).catch((error: unknown) => {
    console.error("Failed to start acode Windows", error);
    app.quit();
  });

  app.on("before-quit", () => {
    void remoteHostController.shutdown();
  });
}

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    void createMainWindow();
  }
});
