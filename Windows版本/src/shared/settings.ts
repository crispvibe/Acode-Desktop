import { z } from "zod";
import { chatCLIValues, type ChatCLI } from "./chat.js";

/// 与 shared/chat.ts 的 ChatCLI 同源：settings 域的 CLI 列表即 chat 域契约。
export const cliKindSchema = z.enum(chatCLIValues);
export type CLIKind = z.infer<typeof cliKindSchema>;

/// 各 CLI 的 base_url / 密钥落到的环境变量名；没有对应概念的平台留空，不伪造注入。
/// profileService（main）与 chatStore（renderer）共用这张表，保持一致。
export interface CLILaunchEnvNames {
  baseURLEnv?: string;
  apiKeyEnv?: string;
  authTokenEnv?: string;
}

const cliLaunchEnvTable: Record<CLIKind, CLILaunchEnvNames> = {
  claude: { baseURLEnv: "ANTHROPIC_BASE_URL", authTokenEnv: "ANTHROPIC_AUTH_TOKEN" },
  codex: { baseURLEnv: "OPENAI_BASE_URL", apiKeyEnv: "OPENAI_API_KEY" },
  cursor: { baseURLEnv: "CURSOR_API_ENDPOINT", apiKeyEnv: "CURSOR_API_KEY" },
  gemini: { apiKeyEnv: "GEMINI_API_KEY" },
  qwen: { baseURLEnv: "OPENAI_BASE_URL", apiKeyEnv: "OPENAI_API_KEY" },
  copilot: { apiKeyEnv: "GH_TOKEN" },
  kimi: { baseURLEnv: "KIMI_BASE_URL", apiKeyEnv: "KIMI_API_KEY" },
  agy: {},
  kiro: { apiKeyEnv: "KIRO_API_KEY" }
};

export function cliLaunchEnvFor(kind: CLIKind | ChatCLI): CLILaunchEnvNames {
  return cliLaunchEnvTable[kind] ?? {};
}

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

/// 全局规则目标 = 全部 9 家 CLI（与 cliKindSchema 同源）。
export const globalRuleTargetSchema = cliKindSchema;
export type GlobalRuleTarget = z.infer<typeof globalRuleTargetSchema>;

export const globalRuleSchema = z.object({
  enabled: z.boolean().default(true),
  path: z.string().default(""),
  content: z.string().default("")
});

export type GlobalRule = z.infer<typeof globalRuleSchema>;

/// 单个规则条目：缺键补默认值，整条损坏（非对象等）时 catch 回空条目，保证旧配置能 parse。
const globalRuleEntrySchema = globalRuleSchema
  .catch({ enabled: true, path: "", content: "" })
  .default({});

export const globalRulesSchema = z.object({
  claude: globalRuleEntrySchema,
  codex: globalRuleEntrySchema,
  cursor: globalRuleEntrySchema,
  gemini: globalRuleEntrySchema,
  qwen: globalRuleEntrySchema,
  copilot: globalRuleEntrySchema,
  kimi: globalRuleEntrySchema,
  agy: globalRuleEntrySchema,
  kiro: globalRuleEntrySchema
});

export type GlobalRules = z.infer<typeof globalRulesSchema>;

/// 更新补丁里的 globalRules：键级 optional（不带 default），避免 zod 把没传的键补成空规则
/// 覆盖掉已存内容——patch 里出现的键就是调用方真正要改的键。
export const globalRulesPatchSchema = z.object({
  claude: globalRuleSchema.partial().optional(),
  codex: globalRuleSchema.partial().optional(),
  cursor: globalRuleSchema.partial().optional(),
  gemini: globalRuleSchema.partial().optional(),
  qwen: globalRuleSchema.partial().optional(),
  copilot: globalRuleSchema.partial().optional(),
  kimi: globalRuleSchema.partial().optional(),
  agy: globalRuleSchema.partial().optional(),
  kiro: globalRuleSchema.partial().optional()
});

export type GlobalRulesPatch = z.infer<typeof globalRulesPatchSchema>;

/// 按 patch 中出现的键逐条合并；patch 没带的键保持原值。
export function mergeGlobalRules(base: GlobalRules, patch: GlobalRulesPatch | undefined): GlobalRules {
  const merged = { ...base };
  for (const target of chatCLIValues) {
    const entry = patch?.[target];
    if (entry) {
      merged[target] = { ...base[target], ...entry };
    }
  }
  return merged;
}

/// 各 CLI 全局指令文件相对用户主目录的路径（"/" 分隔）；null = 该 CLI 无全局指令文件机制，
/// UI 标"不支持"禁用，不硬写。依据官方文档核实：agy（Antigravity）与 gemini 共用
/// ~/.gemini/GEMINI.md；cursor 走 ~/.cursor/rules/*.mdc（需 alwaysApply frontmatter，
/// 写盘时自动补）；kiro 走 ~/.kiro/steering/ 下的 AGENTS.md。
export const globalRuleFilePaths: Record<GlobalRuleTarget, string | null> = {
  claude: ".claude/CLAUDE.md",
  codex: ".codex/AGENTS.md",
  cursor: ".cursor/rules/acode.mdc",
  gemini: ".gemini/GEMINI.md",
  qwen: ".qwen/QWEN.md",
  copilot: ".copilot/copilot-instructions.md",
  kimi: ".kimi-code/AGENTS.md",
  agy: ".gemini/GEMINI.md",
  kiro: ".kiro/steering/AGENTS.md"
};

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

/// cursor/gemini/qwen/copilot/kimi/agy/kiro 共用的通用 profile：没有 kind 专属字段，
/// 靠 base 字段（executablePath/baseUrl/model/env/secretRefs）表达。
export const genericCLIProfileSchema = cliProfileBaseSchema.extend({
  kind: z.enum(["cursor", "gemini", "qwen", "copilot", "kimi", "agy", "kiro"])
});

export type GenericCLIProfile = z.infer<typeof genericCLIProfileSchema>;

export const cliProfileSchema = z.discriminatedUnion("kind", [
  claudeCLIProfileSchema,
  codexCLIProfileSchema,
  genericCLIProfileSchema
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
  .partial()
  .extend({ globalRules: globalRulesPatchSchema.optional() });

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
    globalRules: mergeGlobalRules(DEFAULT_APP_SETTINGS.globalRules, raw.globalRules)
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
