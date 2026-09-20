import type { ScanFileTreeRequest, ScanFileTreeResponse } from "../../shared/fileTree.js";
import type { AppSettingsService } from "../settings/service.js";
import type { ProjectStore } from "../projects/projectStore.js";
import { FileTreeScanner } from "./fileTreeScanner.js";

export class FileTreeService {
  constructor(
    private readonly projectStore: ProjectStore,
    private readonly settingsService?: AppSettingsService,
    private readonly scanner = new FileTreeScanner()
  ) {}

  async scan(request: ScanFileTreeRequest): Promise<ScanFileTreeResponse> {
    const project = await this.projectStore.getProject(request.projectId);
    if (!project) {
      throw new Error("Project not found");
    }

    const settings = await this.settingsService?.read();
    return this.scanner.scanProjectDirectory(project, request, {
      ignoredNames: settings?.ignoredFolders
    });
  }
}

export function createFileTreeService(projectStore: ProjectStore, settingsService?: AppSettingsService): FileTreeService {
  return new FileTreeService(projectStore, settingsService);
}
