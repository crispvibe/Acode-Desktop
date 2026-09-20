import { create } from "zustand";
import {
  projectListResponseSchema,
  projectSchema,
  type AddProjectRequest,
  type Project,
  type ProjectBridge,
  type RemoveProjectRequest,
  type SelectProjectRequest,
  type TouchProjectRequest
} from "@shared/project";
import {
  scanFileTreeRequestSchema,
  scanFileTreeResponseSchema,
  type FileTreeBridge,
  type FileTreeEntry,
  type ScanFileTreeRequest
} from "@shared/fileTree";

type CodevokeProjectsApi = NonNullable<Window["codevoke"]> & {
  projects?: ProjectBridge;
  files?: FileTreeBridge;
};

export interface FileTreeDirectoryState {
  entries: FileTreeEntry[];
  isLoading: boolean;
  error: string | null;
  truncated: boolean;
  loadedAt: string | null;
}

export interface ProjectStoreState {
  projects: Project[];
  selectedProjectId: string | null;
  expandedDirectoryKeys: Record<string, boolean>;
  directories: Record<string, FileTreeDirectoryState>;
  isLoadingProjects: boolean;
  projectError: string | null;
  selectedProject: () => Project | null;
  refreshProjects: () => Promise<void>;
  addProject: (request: AddProjectRequest) => Promise<Project | null>;
  removeProject: (request: RemoveProjectRequest) => Promise<void>;
  touchProject: (request: TouchProjectRequest) => Promise<Project | null>;
  selectProject: (request: SelectProjectRequest) => Promise<void>;
  refreshDirectory: (request?: Partial<ScanFileTreeRequest>) => Promise<void>;
  toggleDirectory: (entry: FileTreeEntry) => Promise<void>;
  clearProjectError: () => void;
}

function directoryKey(projectId: string, relativePath: string): string {
  return `${projectId}:${relativePath}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Unknown project error";
}

function getCodevokeBridge(): CodevokeProjectsApi {
  const bridge = window.codevoke as CodevokeProjectsApi | undefined;
  if (!bridge?.projects || !bridge.files) {
    throw new Error("Project API is not available yet");
  }
  return bridge;
}

export const useProjectStore = create<ProjectStoreState>((set, get) => ({
  projects: [],
  selectedProjectId: null,
  expandedDirectoryKeys: {},
  directories: {},
  isLoadingProjects: false,
  projectError: null,

  selectedProject() {
    const { projects, selectedProjectId } = get();
    return projects.find((project) => project.id === selectedProjectId) ?? projects[0] ?? null;
  },

  async refreshProjects() {
    set({ isLoadingProjects: true, projectError: null });
    try {
      const result = projectListResponseSchema.parse(await getCodevokeBridge().projects?.list());
      set({
        projects: result.projects,
        selectedProjectId: result.selectedProjectId ?? result.projects[0]?.id ?? null,
        isLoadingProjects: false,
        projectError: null
      });
    } catch (error) {
      set({ isLoadingProjects: false, projectError: errorMessage(error) });
    }
  },

  async addProject(request) {
    try {
      const project = projectSchema.parse(await getCodevokeBridge().projects?.add(request));
      await get().refreshProjects();
      return project;
    } catch (error) {
      set({ projectError: errorMessage(error) });
      return null;
    }
  },

  async removeProject(request) {
    try {
      const result = projectListResponseSchema.parse(await getCodevokeBridge().projects?.remove(request));
      set({
        projects: result.projects,
        selectedProjectId: result.selectedProjectId ?? result.projects[0]?.id ?? null,
        projectError: null
      });
    } catch (error) {
      set({ projectError: errorMessage(error) });
    }
  },

  async touchProject(request) {
    try {
      const project = projectSchema.parse(await getCodevokeBridge().projects?.touch(request));
      await get().refreshProjects();
      return project;
    } catch (error) {
      set({ projectError: errorMessage(error) });
      return null;
    }
  },

  async selectProject(request) {
    try {
      const result = projectListResponseSchema.parse(await getCodevokeBridge().projects?.select(request));
      set({
        projects: result.projects,
        selectedProjectId: result.selectedProjectId ?? result.projects[0]?.id ?? null,
        projectError: null
      });
      await get().refreshDirectory({ path: "" });
    } catch (error) {
      set({ projectError: errorMessage(error) });
    }
  },

  async refreshDirectory(request = {}) {
    const project = get().selectedProject();
    if (!project) {
      return;
    }

    const parsedRequest = scanFileTreeRequestSchema.parse({
      projectId: request.projectId ?? project.id,
      path: request.path ?? "",
      maxEntries: request.maxEntries
    });
    const key = directoryKey(parsedRequest.projectId, parsedRequest.path);

    set((state) => ({
      directories: {
        ...state.directories,
        [key]: {
          entries: state.directories[key]?.entries ?? [],
          isLoading: true,
          error: null,
          truncated: false,
          loadedAt: state.directories[key]?.loadedAt ?? null
        }
      }
    }));

    try {
      const result = scanFileTreeResponseSchema.parse(await getCodevokeBridge().files?.scan(parsedRequest));
      const resultKey = directoryKey(result.projectId, result.relativePath);
      set((state) => ({
        directories: {
          ...state.directories,
          [resultKey]: {
            entries: result.entries,
            isLoading: false,
            error: null,
            truncated: result.truncated,
            loadedAt: new Date().toISOString()
          }
        }
      }));
    } catch (error) {
      set((state) => ({
        directories: {
          ...state.directories,
          [key]: {
            entries: state.directories[key]?.entries ?? [],
            isLoading: false,
            error: errorMessage(error),
            truncated: false,
            loadedAt: state.directories[key]?.loadedAt ?? null
          }
        }
      }));
    }
  },

  async toggleDirectory(entry) {
    if (entry.kind !== "directory") {
      return;
    }

    const key = directoryKey(entry.projectId, entry.relativePath);
    const willExpand = !get().expandedDirectoryKeys[key];
    set((state) => ({
      expandedDirectoryKeys: {
        ...state.expandedDirectoryKeys,
        [key]: willExpand
      }
    }));

    if (willExpand && !get().directories[key]?.loadedAt) {
      await get().refreshDirectory({
        projectId: entry.projectId,
        path: entry.relativePath
      });
    }
  },

  clearProjectError() {
    set({ projectError: null });
  }
}));

export { directoryKey as projectDirectoryKey };
