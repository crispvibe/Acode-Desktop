import { z } from "zod";
import { projectIdSchema } from "./project.js";

export const fileTreeEntryKindSchema = z.enum(["directory", "file"]);

export const fileTreeEntrySchema = z.object({
  id: z.string().min(1),
  projectId: projectIdSchema,
  name: z.string().min(1),
  path: z.string().min(1),
  relativePath: z.string(),
  kind: fileTreeEntryKindSchema,
  depth: z.number().int().min(0),
  hasChildren: z.boolean()
});

export const scanFileTreeRequestSchema = z.object({
  projectId: projectIdSchema,
  path: z.string().optional().default(""),
  maxEntries: z.number().int().min(1).max(2_000).optional().default(500)
});

export const scanFileTreeResponseSchema = z.object({
  projectId: projectIdSchema,
  rootPath: z.string().min(1),
  directoryPath: z.string().min(1),
  relativePath: z.string(),
  entries: z.array(fileTreeEntrySchema),
  truncated: z.boolean()
});

export type FileTreeEntryKind = z.infer<typeof fileTreeEntryKindSchema>;
export type FileTreeEntry = z.infer<typeof fileTreeEntrySchema>;
export type ScanFileTreeRequest = z.input<typeof scanFileTreeRequestSchema>;
export type NormalizedScanFileTreeRequest = z.output<typeof scanFileTreeRequestSchema>;
export type ScanFileTreeResponse = z.infer<typeof scanFileTreeResponseSchema>;

export interface FileTreeBridge {
  scan: (request: ScanFileTreeRequest) => Promise<ScanFileTreeResponse>;
}
