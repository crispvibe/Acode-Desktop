import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  projectListResponseSchema,
  projectSchema,
  type Project,
  type ProjectListResponse
} from "../../shared/project.js";
import { resolveExistingDirectory } from "../security/pathGuards.js";

const PROJECTS_FILE_NAME = "projects.json";
const SELECTED_PROJECT_FILE_NAME = "selected-project.json";

const storedProjectsSchema = projectSchema.array().catch([]);

function nowISO(): string {
  return new Date().toISOString();
}

function projectNameFromPath(projectPath: string): string {
  const parsed = path.parse(projectPath);
  const baseName = path.basename(projectPath);
  return baseName || parsed.root || projectPath;
}

async function readJsonFile(filePath: string): Promise<unknown> {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    return JSON.parse(raw) as unknown;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw error;
  }
}

async function writeJsonFile(filePath: string, value: unknown): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  const body = `${JSON.stringify(value, null, 2)}\n`;
  await fs.writeFile(tempPath, body, { encoding: "utf8", mode: 0o600 });
  await fs.rename(tempPath, filePath);
}

export class ProjectStore {
  readonly storageRoot: string;
  readonly projectsPath: string;
  readonly selectedProjectPath: string;

  constructor(userDataRoot: string) {
    this.storageRoot = path.join(userDataRoot, "projects");
    this.projectsPath = path.join(this.storageRoot, PROJECTS_FILE_NAME);
    this.selectedProjectPath = path.join(this.storageRoot, SELECTED_PROJECT_FILE_NAME);
  }

  async loadProjects(): Promise<Project[]> {
    const value = await readJsonFile(this.projectsPath);
    return storedProjectsSchema.parse(value);
  }

  async saveProjects(projects: Project[]): Promise<void> {
    const parsed = projectSchema.array().parse(projects);
    await writeJsonFile(this.projectsPath, parsed);
  }

  async loadSelectedProjectId(): Promise<string | null> {
    const value = await readJsonFile(this.selectedProjectPath);
    const parsed = projectListResponseSchema.shape.selectedProjectId.safeParse(
      typeof value === "object" && value !== null ? (value as { selectedProjectId?: unknown }).selectedProjectId : value
    );
    return parsed.success ? parsed.data ?? null : null;
  }

  async saveSelectedProjectId(projectId: string | null): Promise<void> {
    await writeJsonFile(this.selectedProjectPath, { selectedProjectId: projectId });
  }

  async listProjects(): Promise<ProjectListResponse> {
    const projects = await this.loadProjects();
    const selectedProjectId = await this.loadSelectedProjectId();
    const hasSelectedProject = selectedProjectId ? projects.some((project) => project.id === selectedProjectId) : false;
    const fallbackProjectId = projects[0]?.id ?? null;
    const nextSelectedProjectId = hasSelectedProject ? selectedProjectId : fallbackProjectId;

    if (nextSelectedProjectId !== selectedProjectId) {
      await this.saveSelectedProjectId(nextSelectedProjectId);
    }

    return projectListResponseSchema.parse({
      projects,
      selectedProjectId: nextSelectedProjectId
    });
  }

  async getProject(projectId: string): Promise<Project | null> {
    const projects = await this.loadProjects();
    return projects.find((project) => project.id === projectId) ?? null;
  }

  async addProject(rawProjectPath: string): Promise<Project> {
    const guardedPath = await resolveExistingDirectory(rawProjectPath);
    const projects = await this.loadProjects();
    const existingIndex = projects.findIndex((project) => project.path === guardedPath.realPath);
    const timestamp = nowISO();

    if (existingIndex >= 0) {
      const existing = {
        ...projects[existingIndex],
        updatedAt: timestamp,
        lastOpenedAt: timestamp
      };
      projects[existingIndex] = existing;
      await this.saveProjects(projects);
      await this.saveSelectedProjectId(existing.id);
      return projectSchema.parse(existing);
    }

    const project: Project = {
      id: randomUUID(),
      name: projectNameFromPath(guardedPath.realPath),
      path: guardedPath.realPath,
      createdAt: timestamp,
      updatedAt: timestamp,
      lastOpenedAt: timestamp
    };
    const nextProjects = [...projects, project];
    await this.saveProjects(nextProjects);
    await this.saveSelectedProjectId(project.id);
    return projectSchema.parse(project);
  }

  async removeProject(projectId: string): Promise<ProjectListResponse> {
    const projects = await this.loadProjects();
    const nextProjects = projects.filter((project) => project.id !== projectId);
    await this.saveProjects(nextProjects);

    const selectedProjectId = await this.loadSelectedProjectId();
    if (selectedProjectId === projectId || !nextProjects.some((project) => project.id === selectedProjectId)) {
      await this.saveSelectedProjectId(nextProjects[0]?.id ?? null);
    }

    return this.listProjects();
  }

  async touchProject(projectId: string): Promise<Project> {
    const projects = await this.loadProjects();
    const index = projects.findIndex((project) => project.id === projectId);
    if (index < 0) {
      throw new Error("Project not found");
    }

    const timestamp = nowISO();
    const project = {
      ...projects[index],
      updatedAt: timestamp,
      lastOpenedAt: timestamp
    };
    projects[index] = project;
    await this.saveProjects(projects);
    await this.saveSelectedProjectId(project.id);
    return projectSchema.parse(project);
  }

  async selectProject(projectId: string | null): Promise<ProjectListResponse> {
    if (projectId) {
      const project = await this.getProject(projectId);
      if (!project) {
        throw new Error("Project not found");
      }
    }

    await this.saveSelectedProjectId(projectId);
    return this.listProjects();
  }
}

export function createProjectStore(userDataRoot: string): ProjectStore {
  return new ProjectStore(userDataRoot);
}
