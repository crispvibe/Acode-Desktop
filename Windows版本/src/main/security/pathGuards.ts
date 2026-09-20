import fs from "node:fs/promises";
import path from "node:path";

export class PathGuardError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PathGuardError";
  }
}

export interface GuardedPath {
  inputPath: string;
  resolvedPath: string;
  realPath: string;
}

export interface GuardedAllowedPath extends GuardedPath {
  rootPath: string;
  relativePath: string;
}

const WINDOWS_DRIVE_OR_UNC = /^(?:[a-zA-Z]:[\\/]|[\\/]{2}[^\\/])/;

function assertPlainPath(value: string, label: string): void {
  if (value.length === 0) {
    throw new PathGuardError(`${label} is required`);
  }

  if (value.includes("\0")) {
    throw new PathGuardError(`${label} contains an invalid character`);
  }
}

function hasParentSegment(value: string): boolean {
  return value.split(/[\\/]+/).some((segment) => segment === "..");
}

function isWindowsAbsolute(value: string): boolean {
  return WINDOWS_DRIVE_OR_UNC.test(value);
}

function normalizeForCompare(value: string): string {
  const normalized = path.normalize(value);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function assertAbsolutePath(inputPath: string, message: string): void {
  if (!path.isAbsolute(inputPath) && !isWindowsAbsolute(inputPath)) {
    throw new PathGuardError(message);
  }
}

export function isPathInside(parentPath: string, childPath: string): boolean {
  const parent = normalizeForCompare(parentPath);
  const child = normalizeForCompare(childPath);
  const relative = path.relative(parent, child);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export async function resolveExistingDirectory(inputPath: string): Promise<GuardedPath> {
  assertPlainPath(inputPath, "Path");

  assertAbsolutePath(inputPath, "Project path must be absolute");

  if (hasParentSegment(inputPath)) {
    throw new PathGuardError("Project path cannot contain parent directory segments");
  }

  const lstat = await fs.lstat(inputPath);
  if (lstat.isSymbolicLink()) {
    throw new PathGuardError("Project path cannot be a symbolic link or junction");
  }

  const realPath = await fs.realpath(inputPath);
  const stat = await fs.stat(realPath);
  if (!stat.isDirectory()) {
    throw new PathGuardError("Project path must be a directory");
  }

  return {
    inputPath,
    resolvedPath: path.resolve(inputPath),
    realPath
  };
}

async function assertNoSymlinkSegments(rootRealPath: string, targetResolvedPath: string): Promise<void> {
  const relative = path.relative(rootRealPath, targetResolvedPath);
  if (relative === "") {
    return;
  }

  let currentPath = rootRealPath;
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    currentPath = path.join(currentPath, segment);
    const lstat = await fs.lstat(currentPath);
    if (lstat.isSymbolicLink()) {
      throw new PathGuardError("不能通过符号链接或 junction 访问文件。");
    }
  }
}

export async function resolveExistingFileInsideAllowedRoots(
  inputPath: string,
  rawRootPaths: Iterable<string>
): Promise<GuardedAllowedPath> {
  const filePath = inputPath.trim();
  assertPlainPath(filePath, "文件路径");
  assertAbsolutePath(filePath, "只能打开已添加项目或授权目录内的绝对文件路径。");

  if (hasParentSegment(filePath)) {
    throw new PathGuardError("文件路径不能包含上级目录片段。");
  }

  const resolvedPath = path.resolve(filePath);
  const roots: GuardedPath[] = [];
  for (const rawRootPath of rawRootPaths) {
    try {
      roots.push(await resolveExistingDirectory(rawRootPath));
    } catch {
      // Stale project or settings entries should not widen access or block other valid roots.
    }
  }

  const candidateRoots = roots
    .map((root) => {
      if (isPathInside(root.realPath, resolvedPath)) {
        return { root, lexicalRootPath: root.realPath };
      }
      if (isPathInside(root.resolvedPath, resolvedPath)) {
        return { root, lexicalRootPath: root.resolvedPath };
      }
      return null;
    })
    .filter((root): root is { root: GuardedPath; lexicalRootPath: string } => root !== null);
  if (candidateRoots.length === 0) {
    throw new PathGuardError("该文件不在已添加项目或授权目录内。");
  }

  const fileLstat = await fs.lstat(resolvedPath);
  if (fileLstat.isSymbolicLink()) {
    throw new PathGuardError("不能打开符号链接或 junction 文件。");
  }

  const realPath = await fs.realpath(resolvedPath);

  for (const { root, lexicalRootPath } of candidateRoots) {
    if (!isPathInside(root.realPath, realPath)) {
      continue;
    }

    await assertNoSymlinkSegments(lexicalRootPath, resolvedPath);

    return {
      inputPath: filePath,
      resolvedPath,
      realPath,
      rootPath: root.realPath,
      relativePath: toProjectRelativePath(root.realPath, realPath)
    };
  }

  throw new PathGuardError("该文件不在已添加项目或授权目录内。");
}

export async function resolveChildPathInsideRoot(rootPath: string, requestedPath = ""): Promise<GuardedPath> {
  assertPlainPath(rootPath, "Project root");

  const root = await resolveExistingDirectory(rootPath);
  const rawPath = requestedPath;
  const relativeRequest = rawPath.length === 0 ? "." : rawPath;

  assertPlainPath(relativeRequest, "Requested path");

  if (hasParentSegment(relativeRequest)) {
    throw new PathGuardError("Requested path cannot contain parent directory segments");
  }

  const isAbsoluteRequest = path.isAbsolute(relativeRequest) || isWindowsAbsolute(relativeRequest);
  const resolvedPath = isAbsoluteRequest
    ? path.resolve(relativeRequest)
    : path.resolve(root.realPath, relativeRequest);

  if (!isPathInside(root.realPath, resolvedPath)) {
    throw new PathGuardError("Requested path is outside the project root");
  }

  const lstat = await fs.lstat(resolvedPath);
  if (lstat.isSymbolicLink()) {
    throw new PathGuardError("Requested path cannot be a symbolic link or junction");
  }

  const realPath = await fs.realpath(resolvedPath);
  if (!isPathInside(root.realPath, realPath)) {
    throw new PathGuardError("Requested path resolves outside the project root");
  }

  return {
    inputPath: relativeRequest,
    resolvedPath,
    realPath
  };
}

export function toProjectRelativePath(rootPath: string, childPath: string): string {
  const relative = path.relative(rootPath, childPath);
  return relative === "" ? "" : relative.split(path.sep).join("/");
}
