import os from "node:os";
import {
  appSettingsUpdateSchema,
  DEFAULT_APP_SETTINGS,
  type AppSettings,
  type GlobalRuleTarget
} from "../../shared/settings.js";
import { resolveGlobalRuleFilePath, writeGlobalRuleFile } from "./globalRuleFiles.js";
import { SettingsJsonStore } from "./jsonStore.js";

export class AppSettingsService {
  /// homeDir 仅用于解析全局规则文件位置，测试可注入临时目录避免写真实用户目录。
  constructor(
    private readonly store = new SettingsJsonStore(),
    private readonly homeDir: string = os.homedir()
  ) {}

  read(): Promise<AppSettings> {
    return this.store.read();
  }

  async update(rawPatch: unknown): Promise<AppSettings> {
    const patch = appSettingsUpdateSchema.parse(rawPatch);
    // 把各目标解析出的真实文件路径回填进 patch，随 settings.json 一起落盘供 UI 展示。
    if (patch.globalRules) {
      for (const target of Object.keys(patch.globalRules) as GlobalRuleTarget[]) {
        const filePath = resolveGlobalRuleFilePath(target, this.homeDir);
        if (filePath) {
          patch.globalRules[target] = { ...patch.globalRules[target], path: filePath };
        }
      }
    }
    const next = await this.store.patch(patch);
    // 启用中的全局规则同步写到对应 CLI 的用户级指令文件；写入失败整体报错给渲染层。
    for (const target of Object.keys(patch.globalRules ?? {}) as GlobalRuleTarget[]) {
      const rule = next.globalRules[target];
      if (rule.enabled) {
        await writeGlobalRuleFile(target, rule.content, this.homeDir);
      }
    }
    return next;
  }

  reset(): Promise<AppSettings> {
    return this.store.write(DEFAULT_APP_SETTINGS);
  }
}

export { probeCLI } from "./cliProbe.js";
export { SettingsJsonStore } from "./jsonStore.js";
export { CLIProfileService } from "./profileService.js";
export { SafeStorageSecretStore } from "./secretStore.js";
