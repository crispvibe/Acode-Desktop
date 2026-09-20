import { constants } from "node:fs";
import { access, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { basename } from "node:path";
import {
  EDITOR_BINARY_SNIFF_BYTES,
  EDITOR_TEXT_MAX_BYTES,
  type EditorFileStat,
  type EditorOpenFileRequest,
  type EditorOpenFileResult,
  type EditorSaveFileRequest,
  type EditorSaveFileResult
} from "../../shared/editor.js";
import { PathGuardError, resolveExistingFileInsideAllowedRoots } from "../security/pathGuards.js";
import { EditorFileError, toEditorFileError } from "./editorErrors.js";

export interface EditorAccessRoots {
  projectRoots: string[];
  authorizedRoots: string[];
}

async function readRegularFileStat(filePath: string, enforceTextSizeLimit: boolean): Promise<EditorFileStat> {
  let fileStat;
  try {
    fileStat = await stat(filePath);
  } catch (error) {
    throw toEditorFileError(error);
  }

  if (!fileStat.isFile()) {
    throw new EditorFileError("not_file", "只能打开普通文件。");
  }

  if (enforceTextSizeLimit && fileStat.size > EDITOR_TEXT_MAX_BYTES) {
    throw new EditorFileError("file_too_large", "文件超过 5 MB，已拒绝作为文本打开。");
  }

  return {
    path: filePath,
    title: basename(filePath),
    byteCount: fileStat.size,
    modifiedAt: Math.max(0, Math.trunc(fileStat.mtimeMs))
  };
}

async function assertReadableTextFile(filePath: string, byteCount: number): Promise<Buffer> {
  await access(filePath, constants.R_OK);
  const buffer = await readFile(filePath);
  if (buffer.byteLength !== byteCount && buffer.byteLength > EDITOR_TEXT_MAX_BYTES) {
    throw new EditorFileError("file_too_large", "文件超过 5 MB，已拒绝作为文本打开。");
  }
  const sniffLength = Math.min(buffer.length, EDITOR_BINARY_SNIFF_BYTES);
  if (buffer.subarray(0, sniffLength).includes(0)) {
    throw new EditorFileError("binary_file", "疑似二进制文件，已拒绝打开。");
  }
  return buffer;
}

function decodeUtf8(buffer: Buffer): string {
  const text = buffer.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(buffer)) {
    throw new EditorFileError("unsupported_encoding", "仅支持 UTF-8 文本文件。");
  }
  return text;
}

async function readTextFile(filePath: string): Promise<{ stat: EditorFileStat; text: string }> {
  const fileStat = await readRegularFileStat(filePath, true);
  const buffer = await assertReadableTextFile(filePath, fileStat.byteCount);
  return {
    stat: fileStat,
    text: decodeUtf8(buffer)
  };
}

function toFileServiceError(error: unknown): EditorFileError {
  if (error instanceof PathGuardError) {
    return new EditorFileError("unauthorized_path", error.message);
  }
  return toEditorFileError(error);
}

export class EditorFileService {
  constructor(private readonly accessRoots: () => Promise<EditorAccessRoots>) {}

  private async resolveAllowedFilePath(rawPath: string): Promise<string> {
    const roots = await this.accessRoots();
    const guardedPath = await resolveExistingFileInsideAllowedRoots(rawPath, [
      ...roots.projectRoots,
      ...roots.authorizedRoots
    ]);
    return guardedPath.realPath;
  }

  async statEditorFile(request: EditorOpenFileRequest): Promise<EditorFileStat> {
    try {
      return readRegularFileStat(await this.resolveAllowedFilePath(request.path), false);
    } catch (error) {
      throw toFileServiceError(error);
    }
  }

  async openEditorFile(request: EditorOpenFileRequest): Promise<EditorOpenFileResult> {
    try {
      const result = await readTextFile(await this.resolveAllowedFilePath(request.path));
      return {
        ...result.stat,
        text: result.text
      };
    } catch (error) {
      throw toFileServiceError(error);
    }
  }

  async saveEditorFile(request: EditorSaveFileRequest): Promise<EditorSaveFileResult> {
    try {
      const filePath = await this.resolveAllowedFilePath(request.path);
      const newContent = Buffer.from(request.text, "utf8");
      if (newContent.byteLength > EDITOR_TEXT_MAX_BYTES) {
        throw new EditorFileError("file_too_large", "文件超过 5 MB，已拒绝保存。");
      }

      const current = await readTextFile(filePath);
      if (current.text !== request.expectedText) {
        throw new EditorFileError("file_modified_externally", "文件已被外部修改，保存已取消。");
      }

      const temporaryPath = `${filePath}.codevoke-${process.pid}-${Date.now()}.tmp`;
      try {
        await writeFile(temporaryPath, newContent, { encoding: "utf8", mode: 0o666 });
        await rename(temporaryPath, filePath);
      } catch (error) {
        await unlink(temporaryPath).catch(() => undefined);
        throw error;
      }

      return readRegularFileStat(filePath, false);
    } catch (error) {
      throw toFileServiceError(error);
    }
  }
}

export function createEditorFileService(accessRoots: () => Promise<EditorAccessRoots>): EditorFileService {
  return new EditorFileService(accessRoots);
}
