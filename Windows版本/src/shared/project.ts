import { z } from "zod";

export const projectIdSchema = z.string().uuid();

export const projectSchema = z.object({
  id: projectIdSchema,
  name: z.string().min(1),
  path: z.string().min(1),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastOpenedAt: z.string().datetime().nullable()
});

export const projectListResponseSchema = z.object({
  projects: z.array(projectSchema),
  selectedProjectId: projectIdSchema.nullable().optional()
});

export const addProjectRequestSchema = z.object({
  path: z.string().min(1)
});

export const removeProjectRequestSchema = z.object({
  projectId: projectIdSchema
});

export const touchProjectRequestSchema = z.object({
  projectId: projectIdSchema
});

export const selectProjectRequestSchema = z.object({
  projectId: projectIdSchema.nullable()
});

export type Project = z.infer<typeof projectSchema>;
export type ProjectListResponse = z.infer<typeof projectListResponseSchema>;
export type AddProjectRequest = z.infer<typeof addProjectRequestSchema>;
export type RemoveProjectRequest = z.infer<typeof removeProjectRequestSchema>;
export type TouchProjectRequest = z.infer<typeof touchProjectRequestSchema>;
export type SelectProjectRequest = z.infer<typeof selectProjectRequestSchema>;

export interface ProjectBridge {
  list: () => Promise<ProjectListResponse>;
  add: (request: AddProjectRequest) => Promise<Project>;
  remove: (request: RemoveProjectRequest) => Promise<ProjectListResponse>;
  touch: (request: TouchProjectRequest) => Promise<Project>;
  select: (request: SelectProjectRequest) => Promise<ProjectListResponse>;
}
