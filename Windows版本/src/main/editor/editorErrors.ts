import type { EditorErrorCode } from "../../shared/editor.js";

export class EditorFileError extends Error {
  readonly code: EditorErrorCode;

  constructor(code: EditorErrorCode, message: string) {
    super(message);
    this.name = "EditorFileError";
    this.code = code;
  }
}

export function toEditorFileError(error: unknown): EditorFileError {
  if (error instanceof EditorFileError) {
    return error;
  }

  if (error && typeof error === "object" && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (code === "ENOENT") {
      return new EditorFileError("file_not_found", "文件不存在。");
    }
    if (code === "EACCES" || code === "EPERM") {
      return new EditorFileError("permission_denied", "没有权限读取或写入该文件。");
    }
  }

  const message = error instanceof Error ? error.message : "编辑器文件操作失败。";
  return new EditorFileError("unknown", message);
}
