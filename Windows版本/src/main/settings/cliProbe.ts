import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  cliKindSchema,
  cliProbeResultSchema,
  type CLIKind,
  type CLIProbeResult
} from "../../shared/settings.js";

const execFileAsync = promisify(execFile);

const defaultCommands: Record<CLIKind, string> = {
  claude: "claude",
  codex: "codex"
};

export async function probeCLI(rawKind: unknown, command?: string): Promise<CLIProbeResult> {
  const kind = cliKindSchema.parse(rawKind);
  const targetCommand = command?.trim() || defaultCommands[kind];
  const errors: string[] = [];

  const resolvedPath = await resolveCommandPath(targetCommand).catch((error: unknown) => {
    errors.push(toErrorMessage("where", error));
    return null;
  });

  const version = await runForText(targetCommand, ["--version"]).catch((error: unknown) => {
    errors.push(toErrorMessage("--version", error));
    return null;
  });

  const help = await runForText(targetCommand, ["--help"]).catch((error: unknown) => {
    errors.push(toErrorMessage("--help", error));
    return null;
  });

  const appServerHelp = kind === "codex"
    ? await runForText(targetCommand, ["app-server", "--help"]).catch((error: unknown) => {
      errors.push(toErrorMessage("app-server --help", error));
      return null;
    })
    : null;

  const appServerText = appServerHelp ?? "";
  return cliProbeResultSchema.parse({
    kind,
    command: targetCommand,
    resolvedPath,
    found: Boolean(resolvedPath),
    version,
    help,
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

async function runForText(command: string, args: string[]): Promise<string | null> {
  const result = await execFileAsync(command, args, {
    timeout: 5000,
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
