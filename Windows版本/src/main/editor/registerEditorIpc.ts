import { BrowserWindow, dialog, ipcMain, type OpenDialogOptions } from "electron";
import {
  editorIpcChannels,
  editorFileSelectionSchema,
  editorOpenFileRequestSchema,
  editorOpenFileResultSchema,
  editorSaveFileRequestSchema,
  editorSaveFileResultSchema,
  editorFileStatSchema
} from "../../shared/editor.js";
import type { ProjectStore } from "../projects/projectStore.js";
import type { AppSettingsService } from "../settings/service.js";
import { createEditorFileService, type EditorFileService } from "./fileService.js";

export interface EditorIpcDependencies {
  projectStore: ProjectStore;
  settingsService: AppSettingsService;
}

function createEditorService({ projectStore, settingsService }: EditorIpcDependencies): EditorFileService {
  return createEditorFileService(async () => {
    const [projects, settings] = await Promise.all([
      projectStore.loadProjects(),
      settingsService.read()
    ]);

    return {
      projectRoots: projects.map((project) => project.path),
      authorizedRoots: settings.authorizedFolders.map((folder) => folder.path)
    };
  });
}

export function registerEditorIpcHandlers(dependencies: EditorIpcDependencies): void {
  const editorFileService = createEditorService(dependencies);

  ipcMain.handle(editorIpcChannels.selectFile, async (event) => {
    const projectList = await dependencies.projectStore.listProjects();
    const selectedProject = projectList.projects.find((project) => project.id === projectList.selectedProjectId);
    const owner = BrowserWindow.fromWebContents(event.sender) ?? undefined;
    const options: OpenDialogOptions = {
      defaultPath: selectedProject?.path,
      properties: ["openFile", "dontAddToRecent"]
    };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    return editorFileSelectionSchema.parse({
      canceled: result.canceled,
      path: result.filePaths[0] ?? null
    });
  });

  ipcMain.handle(editorIpcChannels.openFile, async (_event, rawRequest: unknown) => {
    const request = editorOpenFileRequestSchema.parse(rawRequest);
    return editorOpenFileResultSchema.parse(await editorFileService.openEditorFile(request));
  });

  ipcMain.handle(editorIpcChannels.saveFile, async (_event, rawRequest: unknown) => {
    const request = editorSaveFileRequestSchema.parse(rawRequest);
    return editorSaveFileResultSchema.parse(await editorFileService.saveEditorFile(request));
  });

  ipcMain.handle(editorIpcChannels.statFile, async (_event, rawRequest: unknown) => {
    const request = editorOpenFileRequestSchema.parse(rawRequest);
    return editorFileStatSchema.parse(await editorFileService.statEditorFile(request));
  });
}
