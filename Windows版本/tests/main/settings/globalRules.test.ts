import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

// jsonStore 顶层 import electron 拿 userData 目录，测试环境没有 Electron，mock 掉。
vi.mock("electron", () => ({
  app: { getPath: () => "/tmp" }
}));

import { chatCLIValues } from "../../../src/shared/chat";
import {
  appSettingsSchema,
  appSettingsUpdateSchema,
  DEFAULT_APP_SETTINGS,
  globalRuleFilePaths,
  globalRulesSchema,
  mergeGlobalRules,
  normalizeAppSettings,
  type GlobalRuleTarget
} from "../../../src/shared/settings";
import { resolveGlobalRuleFilePath, writeGlobalRuleFile } from "../../../src/main/settings/globalRuleFiles";
import { SettingsJsonStore } from "../../../src/main/settings/jsonStore";
import { AppSettingsService } from "../../../src/main/settings/service";

const EMPTY_RULE = { enabled: true, path: "", content: "" };

const tempDirs: string[] = [];

afterEach(async () => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) await rm(dir, { recursive: true, force: true });
  }
});

async function makeTempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "acode-global-rules-test-"));
  tempDirs.push(dir);
  return dir;
}

describe("globalRules schema 兼容性", () => {
  it("旧配置只有 claude/codex 两键时其余 7 家补默认值", () => {
    const parsed = appSettingsSchema.parse({
      globalRules: {
        claude: { enabled: false, path: "p", content: "A" },
        codex: { enabled: true, path: "", content: "B" }
      }
    });
    expect(parsed.globalRules.claude).toEqual({ enabled: false, path: "p", content: "A" });
    expect(parsed.globalRules.codex.content).toBe("B");
    for (const cli of chatCLIValues.filter((item) => item !== "claude" && item !== "codex")) {
      expect(parsed.globalRules[cli]).toEqual(EMPTY_RULE);
    }
  });

  it("整条损坏的规则条目 catch 回空条目而不是让整个配置 parse 失败", () => {
    const parsed = globalRulesSchema.parse({ claude: 42, codex: { content: "x" } });
    expect(parsed.claude).toEqual(EMPTY_RULE);
    expect(parsed.codex.content).toBe("x");
  });

  it("update schema 不补全没传的键，避免空规则覆盖已存内容", () => {
    const patch = appSettingsUpdateSchema.parse({ globalRules: { claude: { content: "x" } } });
    expect(Object.keys(patch.globalRules ?? {})).toEqual(["claude"]);
    expect(patch.globalRules?.codex).toBeUndefined();
  });

  it("mergeGlobalRules 只覆盖 patch 里出现的键", () => {
    const base = mergeGlobalRules(DEFAULT_APP_SETTINGS.globalRules, { codex: { content: "C" } });
    const merged = mergeGlobalRules(base, { kimi: { content: "K" } });
    expect(merged.kimi.content).toBe("K");
    expect(merged.codex.content).toBe("C");
    expect(merged.gemini).toEqual(EMPTY_RULE);
  });

  it("normalizeAppSettings 兼容旧版两键数据", () => {
    const normalized = normalizeAppSettings({
      globalRules: { codex: { enabled: false, path: "p", content: "C" } }
    });
    expect(normalized.globalRules.codex).toEqual({ enabled: false, path: "p", content: "C" });
    expect(normalized.globalRules.kiro).toEqual(EMPTY_RULE);
  });
});

describe("全局规则文件路径", () => {
  const expected: Record<GlobalRuleTarget, string> = {
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

  it("9 家 CLI 全部解析到官方约定的全局指令文件", () => {
    for (const cli of chatCLIValues) {
      expect(resolveGlobalRuleFilePath(cli, "/home/u")).toBe(
        path.join("/home/u", ...expected[cli].split("/"))
      );
    }
  });
});

describe("writeGlobalRuleFile", () => {
  it("按 jsonStore 惯例 mkdir + tmp + rename 写文件", async () => {
    const home = await makeTempDir();
    const filePath = await writeGlobalRuleFile("qwen", "Q 规则", home);
    expect(filePath).toBe(path.join(home, ".qwen", "QWEN.md"));
    expect(await readFile(filePath!, "utf8")).toBe("Q 规则");
  });

  it("cursor 保存时自动补 alwaysApply frontmatter，自带 frontmatter 则尊重原样", async () => {
    const home = await makeTempDir();
    const filePath = path.join(home, ".cursor", "rules", "acode.mdc");

    await writeGlobalRuleFile("cursor", "规则内容", home);
    const written = await readFile(filePath, "utf8");
    expect(written).toContain("alwaysApply: true");
    expect(written).toContain("规则内容");

    const custom = "---\ndescription: custom\nalwaysApply: true\n---\n\n自带";
    await writeGlobalRuleFile("cursor", custom, home);
    expect(await readFile(filePath, "utf8")).toBe(custom);
  });
});

describe("AppSettingsService 全局规则同步", () => {
  it("保存时写对应 CLI 文件并把真实路径回填进设置", async () => {
    const dir = await makeTempDir();
    const home = path.join(dir, "home");
    const service = new AppSettingsService(new SettingsJsonStore(path.join(dir, "settings.json")), home);

    const next = await service.update({ globalRules: { kimi: { content: "K 规则" } } });
    const expectedPath = path.join(home, ".kimi-code", "AGENTS.md");
    expect(next.globalRules.kimi.content).toBe("K 规则");
    expect(next.globalRules.kimi.path).toBe(expectedPath);
    expect(await readFile(expectedPath, "utf8")).toBe("K 规则");
    // 未 patch 的目标不写文件
    await expect(access(path.join(home, ".codex", "AGENTS.md"))).rejects.toThrow();
  });

  it("enabled=false 的规则只落设置不写文件，且不擦除其他目标", async () => {
    const dir = await makeTempDir();
    const home = path.join(dir, "home");
    const service = new AppSettingsService(new SettingsJsonStore(path.join(dir, "settings.json")), home);

    await service.update({ globalRules: { codex: { content: "C 规则" } } });
    const codexPath = path.join(home, ".codex", "AGENTS.md");
    expect(await readFile(codexPath, "utf8")).toBe("C 规则");

    const next = await service.update({ globalRules: { codex: { enabled: false, content: "C2" }, gemini: { content: "G" } } });
    expect(next.globalRules.codex.enabled).toBe(false);
    // disabled 不写盘，文件保持上次内容
    expect(await readFile(codexPath, "utf8")).toBe("C 规则");
    expect(await readFile(path.join(home, ".gemini", "GEMINI.md"), "utf8")).toBe("G");
  });
});
