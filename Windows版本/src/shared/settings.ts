import { z } from "zod";

export const cliKindSchema = z.enum(["claude", "codex"]);
export type CLIKind = z.infer<typeof cliKindSchema>;

export const permissionModeSchema = z.enum(["default", "plan", "acceptEdits", "bypassPermissions"]);
export type PermissionMode = z.infer<typeof permissionModeSchema>;

export const reasoningEffortSchema = z.enum(["minimal", "low", "medium", "high"]);
export type ReasoningEffort = z.infer<typeof reasoningEffortSchema>;

export const windowsTerminalSchema = z.enum(["windowsTerminal", "powershell", "cmd", "gitBash"]);
export type WindowsTerminal = z.infer<typeof windowsTerminalSchema>;

export const windowsShellSchema = z.enum(["powershell", "cmd", "gitBash"]);
export type WindowsShell = z.infer<typeof windowsShellSchema>;

export const cliWireApiSchema = z.enum(["auto", "responses", "chatCompletions"]);
export type CLIWireApi = z.infer<typeof cliWireApiSchema>;

export const authorizedFolderSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  path: z.string().min(1),
  createdAt: z.string().min(1)
});

export type AuthorizedFolder = z.infer<typeof authorizedFolderSchema>;

export const appendRuleSchema = z.object({
  enabled: z.boolean().default(false),
  content: z.string().default("")
});

export type AppendRule = z.infer<typeof appendRuleSchema>;

export const globalRuleTargetSchema = z.enum(["claude", "codex"]);
export type GlobalRuleTarget = z.infer<typeof globalRuleTargetSchema>;

export const globalRuleSchema = z.object({
  enabled: z.boolean().default(true),
  path: z.string().default(""),
  content: z.string().default("")
});

export type GlobalRule = z.infer<typeof globalRuleSchema>;

export const globalRulesSchema = z.object({
  claude: globalRuleSchema.default({}),
  codex: globalRuleSchema.default({})
});

export type GlobalRules = z.infer<typeof globalRulesSchema>;

export const secretFieldSchema = z.enum(["apiKey", "authToken"]);
export type SecretField = z.infer<typeof secretFieldSchema>;

export const secretValueRefSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  updatedAt: z.string().min(1)
});

export type SecretValueRef = z.infer<typeof secretValueRefSchema>;

export const profileSecretRefsSchema = z.object({
  apiKey: secretValueRefSchema.optional(),
  authToken: secretValueRefSchema.optional()
}).default({});

export type ProfileSecretRefs = z.infer<typeof profileSecretRefsSchema>;

const cliProfileBaseSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  enabled: z.boolean().default(true),
  isDefault: z.boolean().default(false),
  executablePath: z.string().optional(),
  baseUrl: z.string().optional(),
  model: z.string().optional(),
  permissionMode: permissionModeSchema.optional(),
  reasoningEffort: reasoningEffortSchema.optional(),
  workingDirectory: z.string().optional(),
  env: z.record(z.string()).default({}),
  secretRefs: profileSecretRefsSchema,
  createdAt: z.string().min(1),
  updatedAt: z.string().min(1)
});

export const claudeCLIProfileSchema = cliProfileBaseSchema.extend({
  kind: z.literal("claude"),
  configPath: z.string().optional()
});

export type ClaudeCLIProfile = z.infer<typeof claudeCLIProfileSchema>;

export const codexCLIProfileSchema = cliProfileBaseSchema.extend({
  kind: z.literal("codex"),
  wireApi: cliWireApiSchema.default("auto"),
  appServer: z.object({
    enabled: z.boolean().default(false),
    host: z.string().default("127.0.0.1"),
    port: z.number().int().positive().max(65535).optional()
  }).default({})
});

export type CodexCLIProfile = z.infer<typeof codexCLIProfileSchema>;

export const cliProfileSchema = z.discriminatedUnion("kind", [
  claudeCLIProfileSchema,
  codexCLIProfileSchema
]);

export type CLIProfile = z.infer<typeof cliProfileSchema>;

export const cliProfileCreateInputSchema = z.object({
  kind: cliKindSchema,
  name: z.string().min(1),
  executablePath: z.string().optional(),
  baseUrl: z.string().optional(),
  model: z.string().optional(),
  permissionMode: permissionModeSchema.optional(),
  reasoningEffort: reasoningEffortSchema.optional(),
  workingDirectory: z.string().optional(),
  env: z.record(z.string()).optional(),
  configPath: z.string().optional(),
  wireApi: cliWireApiSchema.optional(),
  appServer: codexCLIProfileSchema.shape.appServer.optional()
});

export type CLIProfileCreateInput = z.infer<typeof cliProfileCreateInputSchema>;

export const cliProfileUpdateInputSchema = cliProfileCreateInputSchema
  .omit({ kind: true })
  .partial()
  .extend({
    enabled: z.boolean().optional(),
    secretRefs: profileSecretRefsSchema.optional()
  });

export type CLIProfileUpdateInput = z.infer<typeof cliProfileUpdateInputSchema>;

export const defaultIgnoredFolders = [
  ".DS_Store",
  ".build",
  ".cache",
  ".dart_tool",
  ".git",
  ".hg",
  ".idea",
  ".next",
  ".svn",
  ".venv",
  ".vscode",
  "DerivedData",
  "__pycache__",
  "build",
  "dist",
  "node_modules",
  "vendor"
] as const;

export const appSettingsSchema = z.object({
  schemaVersion: z.literal(1).default(1),
  defaultCLI: cliKindSchema.default("claude"),
  permissionMode: permissionModeSchema.default("default"),
  reasoningEffort: reasoningEffortSchema.default("medium"),
  model: z.string().default(""),
  ignoredFolders: z.array(z.string().min(1)).default([...defaultIgnoredFolders]),
  authorizedFolders: z.array(authorizedFolderSchema).default([]),
  appendRule: appendRuleSchema.default({}),
  globalRules: globalRulesSchema.default({}),
  terminal: windowsTerminalSchema.default("windowsTerminal"),
  shell: windowsShellSchema.default("powershell"),
  profiles: z.array(cliProfileSchema).default([]),
  updatedAt: z.string().min(1).default(() => new Date().toISOString())
});

export type AppSettings = z.infer<typeof appSettingsSchema>;

export const appSettingsUpdateSchema = appSettingsSchema
  .omit({ schemaVersion: true, updatedAt: true })
  .partial();

export type AppSettingsUpdate = z.infer<typeof appSettingsUpdateSchema>;

export const DEFAULT_APP_SETTINGS: AppSettings = appSettingsSchema.parse({});

export function normalizeAppSettings(value: unknown): AppSettings {
  if (!value || typeof value !== "object") {
    return appSettingsSchema.parse(DEFAULT_APP_SETTINGS);
  }

  const raw = value as Partial<AppSettings>;

  return appSettingsSchema.parse({
    ...DEFAULT_APP_SETTINGS,
    ...raw,
    appendRule: {
      ...DEFAULT_APP_SETTINGS.appendRule,
      ...raw.appendRule
    },
    globalRules: {
      claude: {
        ...DEFAULT_APP_SETTINGS.globalRules.claude,
        ...raw.globalRules?.claude
      },
      codex: {
        ...DEFAULT_APP_SETTINGS.globalRules.codex,
        ...raw.globalRules?.codex
      }
    }
  });
}

export const cliProbeCapabilitySchema = z.object({
  appServer: z.boolean().default(false),
  appServerHost: z.boolean().default(false),
  appServerPort: z.boolean().default(false),
  appServerHelp: z.boolean().default(false)
});

export type CLIProbeCapability = z.infer<typeof cliProbeCapabilitySchema>;

export const cliProbeResultSchema = z.object({
  kind: cliKindSchema,
  command: z.string().min(1),
  resolvedPath: z.string().nullable(),
  found: z.boolean(),
  version: z.string().nullable(),
  help: z.string().nullable(),
  capabilities: cliProbeCapabilitySchema,
  errors: z.array(z.string()).default([])
});

export type CLIProbeResult = z.infer<typeof cliProbeResultSchema>;
