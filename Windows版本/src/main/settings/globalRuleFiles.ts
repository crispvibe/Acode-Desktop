import { mkdir, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { globalRuleFilePaths, type GlobalRuleTarget } from "../../shared/settings.js";

/// Cursor 的用户级规则要求 .mdc + frontmatter 才会被自动应用；保存时若用户内容没带
/// frontmatter 就补一个 alwaysApply 头，带了自己 frontmatter 的尊重原样。
const CURSOR_RULE_FRONTMATTER = "---\ndescription: acode global rules\nalwaysApply: true\n---\n\n";

function ensureCursorRuleFrontmatter(content: string): string {
  return content.trimStart().startsWith("---") ? content : `${CURSOR_RULE_FRONTMATTER}${content}`;
}

/// 解析目标 CLI 的全局指令文件绝对路径；无全局机制的 CLI 返回 null。
export function resolveGlobalRuleFilePath(target: GlobalRuleTarget, homeDir: string = os.homedir()): string | null {
  const relativePath = globalRuleFilePaths[target];
  if (!relativePath) {
    return null;
  }
  return path.join(homeDir, ...relativePath.split("/"));
}

/// 把全局规则内容写到对应 CLI 的用户级指令文件，沿用 jsonStore 的原子写惯例
/// （mkdir -p + 写 .tmp + rename）。返回实际写入的绝对路径；不支持的 CLI 返回 null。
export async function writeGlobalRuleFile(
  target: GlobalRuleTarget,
  content: string,
  homeDir: string = os.homedir()
): Promise<string | null> {
  const filePath = resolveGlobalRuleFilePath(target, homeDir);
  if (!filePath) {
    return null;
  }
  const body = target === "cursor" ? ensureCursorRuleFrontmatter(content) : content;
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp`;
  await writeFile(temporaryPath, body, "utf8");
  await rename(temporaryPath, filePath);
  return filePath;
}
