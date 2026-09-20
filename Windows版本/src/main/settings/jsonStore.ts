import { app } from "electron";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  appSettingsSchema,
  appSettingsUpdateSchema,
  normalizeAppSettings,
  type AppSettings,
  type AppSettingsUpdate
} from "../../shared/settings.js";

export class SettingsJsonStore {
  readonly filePath: string;

  constructor(filePath = path.join(app.getPath("userData"), "settings.json")) {
    this.filePath = filePath;
  }

  async read(): Promise<AppSettings> {
    try {
      const content = await readFile(this.filePath, "utf8");
      const parsed: unknown = JSON.parse(content);
      return normalizeAppSettings(parsed);
    } catch (error: unknown) {
      if (isNodeError(error) && error.code === "ENOENT") {
        const settings = normalizeAppSettings(undefined);
        await this.write(settings);
        return settings;
      }
      throw error;
    }
  }

  async write(settings: AppSettings): Promise<AppSettings> {
    const normalized = appSettingsSchema.parse({
      ...settings,
      updatedAt: new Date().toISOString()
    });
    await mkdir(path.dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
    await rename(temporaryPath, this.filePath);
    return normalized;
  }

  async update(updater: (settings: AppSettings) => AppSettings): Promise<AppSettings> {
    const current = await this.read();
    return this.write(updater(current));
  }

  async patch(rawPatch: unknown): Promise<AppSettings> {
    const patch: AppSettingsUpdate = appSettingsUpdateSchema.parse(rawPatch);
    return this.update((settings) => normalizeAppSettings({
      ...settings,
      ...patch,
      appendRule: patch.appendRule ? {
        ...settings.appendRule,
        ...patch.appendRule
      } : settings.appendRule,
      globalRules: patch.globalRules ? {
        claude: {
          ...settings.globalRules.claude,
          ...patch.globalRules.claude
        },
        codex: {
          ...settings.globalRules.codex,
          ...patch.globalRules.codex
        }
      } : settings.globalRules
    }));
  }
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
