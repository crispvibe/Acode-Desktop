import fs from "node:fs/promises";
import path from "node:path";
import {
  scanFileTreeRequestSchema,
  scanFileTreeResponseSchema,
  type FileTreeEntry,
  type ScanFileTreeRequest,
  type ScanFileTreeResponse
} from "../../shared/fileTree.js";
import type { Project } from "../../shared/project.js";
import {
  isPathInside,
  resolveChildPathInsideRoot,
  toProjectRelativePath
} from "../security/pathGuards.js";

export const defaultIgnoredFileTreeNames = new Set([
  ".git",
  ".hg",
  ".svn",
  ".DS_Store",
  "node_modules",
  "dist",
  "build",
  ".dart_tool",
  ".idea",
  ".vscode",
  "vendor",
  "DerivedData",
  ".build",
  ".swiftpm",
  ".next",
  ".cache",
  "__pycache__",
  ".venv"
]);

const collator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: "base"
});

function depthOf(relativePath: string): number {
  if (relativePath.length === 0) {
    return 0;
  }
  return relativePath.split("/").filter(Boolean).length;
}

function compareEntries(left: FileTreeEntry, right: FileTreeEntry): number {
  if (left.kind !== right.kind) {
    return left.kind === "directory" ? -1 : 1;
  }
  return collator.compare(left.name, right.name);
}

export interface FileTreeScannerOptions {
  ignoredNames?: Iterable<string>;
}

export interface FileTreeScanOptions {
  ignoredNames?: Iterable<string>;
}

export class FileTreeScanner {
  readonly ignoredNames: Set<string>;

  constructor(options: FileTreeScannerOptions = {}) {
    this.ignoredNames = new Set(options.ignoredNames ?? defaultIgnoredFileTreeNames);
  }

  async scanProjectDirectory(
    project: Project,
    request: ScanFileTreeRequest,
    options: FileTreeScanOptions = {}
  ): Promise<ScanFileTreeResponse> {
    const parsedRequest = scanFileTreeRequestSchema.parse(request);
    const guardedDirectory = await resolveChildPathInsideRoot(project.path, parsedRequest.path);
    const directoryStat = await fs.stat(guardedDirectory.realPath);
    if (!directoryStat.isDirectory()) {
      throw new Error("Requested path is not a directory");
    }

    const dirents = await fs.readdir(guardedDirectory.realPath, { withFileTypes: true });
    const entries: FileTreeEntry[] = [];
    const ignoredNames = new Set(options.ignoredNames ?? this.ignoredNames);
    let accepted = 0;
    let truncated = false;

    for (const dirent of dirents) {
      if (ignoredNames.has(dirent.name)) {
        continue;
      }

      const candidatePath = path.join(guardedDirectory.realPath, dirent.name);
      const lstat = await fs.lstat(candidatePath);
      if (lstat.isSymbolicLink()) {
        continue;
      }

      const isDirectory = lstat.isDirectory();
      const isFile = lstat.isFile();
      if (!isDirectory && !isFile) {
        continue;
      }

      const realPath = await fs.realpath(candidatePath);
      if (!isPathInside(project.path, realPath)) {
        continue;
      }

      if (accepted >= parsedRequest.maxEntries) {
        truncated = true;
        continue;
      }

      const relativePath = toProjectRelativePath(project.path, realPath);
      entries.push({
        id: `${project.id}:${relativePath}`,
        projectId: project.id,
        name: dirent.name,
        path: realPath,
        relativePath,
        kind: isDirectory ? "directory" : "file",
        depth: depthOf(relativePath),
        hasChildren: isDirectory
      });
      accepted += 1;
    }

    entries.sort(compareEntries);

    return scanFileTreeResponseSchema.parse({
      projectId: project.id,
      rootPath: project.path,
      directoryPath: guardedDirectory.realPath,
      relativePath: toProjectRelativePath(project.path, guardedDirectory.realPath),
      entries,
      truncated
    });
  }
}

export function createFileTreeScanner(options?: FileTreeScannerOptions): FileTreeScanner {
  return new FileTreeScanner(options);
}
