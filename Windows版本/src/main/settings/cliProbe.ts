import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { chatCLIDefaultCommands } from "../../shared/chat.js";
import { resolveSpawnTarget } from "../chat/genericCliBackend.js";
import {
  cliKindSchema,
  cliProbeResultSchema,
  type CLIKind,
  type CLIProbeResult
} from "../../shared/settings.js";

const execFileAsync = promisify(execFile);

export async function probeCLI(rawKind: unknown, command?: string): Promise<CLIProbeResult> {
  const kind = cliKindSchema.parse(rawKind);
  // npm 全局安装的 CLI 在 Windows 上是 .cmd shim，where.exe 能解析到具体路径。
  const targetCommand = command?.trim() || chatCLIDefaultCommands[kind];
  const errors: string[] = [];

  const resolvedPath = await resolveCommandPath(targetCommand).catch((error: unknown) => {
    errors.push(toErrorMessage("where", error));
    return null;
  });

  // 探测阶段优先用 where.exe 解析到的真实路径：Windows 上 .cmd shim 不能直接 execFile，
  // runForText 内部走 resolveSpawnTarget（.cmd → powershell 单引号 shim）。
  const commandForRun = resolvedPath ?? targetCommand;

  const version = await runForText(commandForRun, ["--version"]).catch((error: unknown) => {
    errors.push(toErrorMessage("--version", error));
    return null;
  });

  const help = await runForText(commandForRun, ["--help"]).catch((error: unknown) => {
    errors.push(toErrorMessage("--help", error));
    return null;
  });

  const appServerHelp = kind === "codex"
    ? await runForText(commandForRun, ["app-server", "--help"]).catch((error: unknown) => {
      errors.push(toErrorMessage("app-server --help", error));
      return null;
    })
    : null;

  // dsh 官方零安装路径：本地没有 dsh 但 PATH 里有 npx 时，用
  // `npx -y @deepseek-ai/dsh` 探测版本；首次运行要下载包，超时放宽到 30s。
  let npxFallback: { path: string; version: string | null; help: string | null } | null = null;
  if (kind === "dsh" && !resolvedPath) {
    const npxPath = await resolveCommandPath("npx").catch(() => null);
    if (npxPath) {
      npxFallback = {
        path: npxPath,
        version: await runForText("npx", ["-y", "@deepseek-ai/dsh", "--version"], 30_000).catch((error: unknown) => {
          errors.push(toErrorMessage("npx -y @deepseek-ai/dsh --version", error));
          return null;
        }),
        help: null
      };
    }
  }

  const appServerText = appServerHelp ?? "";
  return cliProbeResultSchema.parse({
    kind,
    command: targetCommand,
    resolvedPath: resolvedPath ?? npxFallback?.path ?? null,
    found: Boolean(resolvedPath) || Boolean(npxFallback?.version),
    version: version ?? npxFallback?.version ?? null,
    help: help ?? npxFallback?.help ?? null,
    capabilities: {
      appServer: Boolean(appServerHelp),
      appServerHelp: Boolean(appServerHelp),
      appServerHost: /\b--host\b/.test(appServerText),
      appServerPort: /\b--port\b/.test(appServerText)
    },
    errors
  });
}

async function resolveCommandPath(command: string): Promise<string | null> {
  const resolver = process.platform === "win32" ? "where.exe" : "which";
  const output = await runForText(resolver, [command]);
  return output?.split(/\r?\n/).map((line) => line.trim()).find(Boolean) ?? null;
}

async function runForText(command: string, args: string[], timeoutMs = 5000): Promise<string | null> {
  const target = await resolveSpawnTarget(command, args);
  const result = await execFileAsync(target.file, target.args, {
    timeout: timeoutMs,
    windowsHide: true,
    maxBuffer: 512 * 1024
  });
  const text = `${result.stdout ?? ""}${result.stderr ? `\n${result.stderr}` : ""}`.trim();
  return text.length > 0 ? text.slice(0, 16000) : null;
}

function toErrorMessage(stage: string, error: unknown): string {
  if (error instanceof Error) {
    return `${stage}: ${error.message}`;
  }
  return `${stage}: ${String(error)}`;
}
