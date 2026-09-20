// GitHub Releases 自动更新 —— electron-updater，无需自建服务器、无需代码签名。
// 状态机：idle → checking → available → downloading → downloaded
//                         → up-to-date / error
// 便携版（PORTABLE_EXECUTABLE_DIR）不支持自更新：只检测版本，
// 有新版本时由渲染层提示用户去 Releases 页面手动下载。
// dev/未打包（!app.isPackaged）不注册事件也不检查。
import { app, BrowserWindow, ipcMain, shell } from "electron";
import electronUpdater from "electron-updater";
import type { ProgressInfo, UpdateInfo } from "electron-updater";
import { ipcChannels, type UpdateStatus } from "../../shared/ipc.js";

// electron-updater 是 CJS 且 autoUpdater 经 defineProperty getter 导出，
// ESM 下命名导入不可用，必须走默认导入取 module.exports。
const { autoUpdater } = electronUpdater;

const RELEASES_URL = "https://github.com/crispvibe/Acode-Desktop/releases/latest";

let registered = false;

const status: UpdateStatus = {
  phase: "idle",
  supported: false,
  portable: false,
  version: null,
  releaseNotes: null,
  progressPercent: null,
  error: null,
  releasesUrl: RELEASES_URL
};

function setStatus(patch: Partial<UpdateStatus>): void {
  Object.assign(status, patch);
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.webContents.isDestroyed()) {
      window.webContents.send(ipcChannels.updateStatusChanged, { ...status });
    }
  }
}

/** UpdateInfo.releaseNotes 可能是 string | ReleaseNoteInfo[]，统一归一成纯文本。 */
function releaseNotesToText(notes: UpdateInfo["releaseNotes"]): string | null {
  if (typeof notes === "string") {
    return notes.length > 0 ? notes : null;
  }
  if (Array.isArray(notes)) {
    const text = notes.map((note) => note.note).filter(Boolean).join("\n\n");
    return text.length > 0 ? text : null;
  }
  return null;
}

function toErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function runCheck(): Promise<void> {
  if (!status.supported) {
    return;
  }
  // 已在检查/下载中时不打断（重复触发 checkForUpdates 会中断下载）。
  if (status.phase === "checking" || status.phase === "downloading") {
    return;
  }
  setStatus({ phase: "checking", error: null });
  try {
    await autoUpdater.checkForUpdates();
  } catch (error: unknown) {
    // 'error' 事件一般已先行广播，重复设置同态无副作用；
    // 若 rejection 未伴随 error 事件，此处兜底防卡在 checking。
    setStatus({ phase: "error", error: toErrorMessage(error), progressPercent: null });
  }
}

/** 注册更新 IPC 与 autoUpdater 事件；app.whenReady 后、窗口创建前调用。 */
export function registerAppUpdater(): void {
  if (registered) {
    return;
  }
  registered = true;

  status.supported = app.isPackaged;
  status.portable = Boolean(process.env.PORTABLE_EXECUTABLE_DIR);

  ipcMain.handle(ipcChannels.updateGetStatus, () => ({ ...status }));

  ipcMain.handle(ipcChannels.updateCheck, () => {
    void runCheck();
    return { ...status };
  });

  ipcMain.handle(ipcChannels.updateQuitAndInstall, () => {
    if (status.phase === "downloaded" && !status.portable) {
      autoUpdater.quitAndInstall();
    }
  });

  ipcMain.handle(ipcChannels.updateOpenReleases, async () => {
    await shell.openExternal(RELEASES_URL);
  });

  if (!status.supported) {
    return;
  }

  autoUpdater.logger = console;
  // 安装版自动下载；便携版只检测不下载。
  autoUpdater.autoDownload = !status.portable;
  autoUpdater.autoInstallOnAppQuit = true;

  autoUpdater.on("checking-for-update", () => {
    setStatus({ phase: "checking", error: null });
  });
  autoUpdater.on("update-available", (info: UpdateInfo) => {
    setStatus({
      phase: "available",
      version: info.version,
      releaseNotes: releaseNotesToText(info.releaseNotes),
      progressPercent: null,
      error: null
    });
  });
  autoUpdater.on("update-not-available", () => {
    setStatus({ phase: "up-to-date", version: null, releaseNotes: null, progressPercent: null });
  });
  autoUpdater.on("download-progress", (progress: ProgressInfo) => {
    setStatus({ phase: "downloading", progressPercent: Math.round(progress.percent) });
  });
  autoUpdater.on("update-downloaded", (info: UpdateInfo) => {
    setStatus({
      phase: "downloaded",
      version: info.version,
      releaseNotes: releaseNotesToText(info.releaseNotes),
      progressPercent: 100
    });
  });
  autoUpdater.on("error", (error: Error) => {
    setStatus({ phase: "error", error: toErrorMessage(error), progressPercent: null });
  });
}

/** 启动后静默检查一次；dev/未打包为 no-op。窗口创建后调用。 */
export function checkAppUpdatesOnStart(): void {
  void runCheck();
}
