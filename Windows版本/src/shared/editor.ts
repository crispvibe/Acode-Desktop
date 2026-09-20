import { z } from "zod";

export const EDITOR_TEXT_MAX_BYTES = 5 * 1024 * 1024;
export const EDITOR_BINARY_SNIFF_BYTES = 4096;

export const editorIpcChannels = {
  selectFile: "editor:select-file",
  openFile: "editor:open-file",
  saveFile: "editor:save-file",
  statFile: "editor:stat-file"
} as const;

export const editorErrorCodeSchema = z.enum([
  "binary_file",
  "file_modified_externally",
  "file_not_found",
  "file_too_large",
  "invalid_path",
  "not_file",
  "permission_denied",
  "unauthorized_path",
  "unsupported_encoding",
  "unknown"
]);

export type EditorErrorCode = z.infer<typeof editorErrorCodeSchema>;

export const editorFilePathSchema = z.string().trim().min(1);

export const editorFileStatSchema = z.object({
  path: z.string(),
  title: z.string(),
  byteCount: z.number().int().nonnegative(),
  modifiedAt: z.number().int().nonnegative()
});

export type EditorFileStat = z.infer<typeof editorFileStatSchema>;

export const editorFileSelectionSchema = z.object({
  canceled: z.boolean(),
  path: z.string().nullable()
});

export type EditorFileSelection = z.infer<typeof editorFileSelectionSchema>;

export const editorOpenFileRequestSchema = z.object({
  path: editorFilePathSchema
});

export type EditorOpenFileRequest = z.infer<typeof editorOpenFileRequestSchema>;

export const editorOpenFileResultSchema = editorFileStatSchema.extend({
  text: z.string()
});

export type EditorOpenFileResult = z.infer<typeof editorOpenFileResultSchema>;

export const editorSaveFileRequestSchema = z.object({
  path: editorFilePathSchema,
  text: z.string(),
  expectedText: z.string()
});

export type EditorSaveFileRequest = z.infer<typeof editorSaveFileRequestSchema>;

export const editorSaveFileResultSchema = editorFileStatSchema;

export type EditorSaveFileResult = z.infer<typeof editorSaveFileResultSchema>;

export const editorCursorPositionSchema = z.object({
  line: z.number().int().min(1),
  column: z.number().int().min(1)
});

export type EditorCursorPosition = z.infer<typeof editorCursorPositionSchema>;

export interface EditorTab {
  id: string;
  path: string;
  title: string;
  text: string;
  savedText: string;
  cursor: EditorCursorPosition;
  dirty: boolean;
  loading: boolean;
  error: string | null;
  byteCount: number;
  modifiedAt: number | null;
  openedAt: number;
  lastActiveAt: number;
}

export interface EditorCloseConfirmation {
  tabId: string;
  title: string;
}

export function createEditorTabId(filePath: string): string {
  return `editor:${filePath}`;
}
