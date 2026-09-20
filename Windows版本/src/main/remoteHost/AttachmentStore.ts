// AttachmentStore（Windows host 附件落盘）—— 移植自 Mac
// `RemoteChatRouter.storeUploadedAttachment`。
//
// 手机端把图片/文件 base64 上传过来（HTTP `POST /attachments` 直连，或隧道 /
// WebRTC 的 `recovery_request{op:uploadAttachment}` 帧），host 校验后写入系统临时
// 目录，并把绝对路径回给手机；手机再用该 path 走 `composerAttach` 命令把附件挂到
// composer 上发送。校验顺序与上限严格对齐 Mac，保证两端行为一致。

import { mkdir, rm, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";

import { remoteRecoveryLimits } from "../../shared/remoteProtocol.js";

export interface StoredAttachment {
  filename: string;
  /** host 端临时文件的绝对路径，回给手机后用于 composerAttach。 */
  path: string;
}

/** 校验/落盘失败信息：code/message 对齐 Mac，statusCode 供 HTTP 端点直接使用。 */
export interface AttachmentStoreFailure {
  code: string;
  message: string;
  statusCode: number;
}

export type StoreAttachmentResult =
  | { ok: true; value: StoredAttachment }
  | { ok: false; error: AttachmentStoreFailure };

/** host 端落盘根目录（系统临时目录下的固定子目录）。 */
export const ATTACHMENT_DIRECTORY_NAME = "CodevokeRemoteChatAttachments";

/** 附件落盘根目录的绝对路径。 */
export function attachmentRootDirectory(): string {
  return path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME);
}

/**
 * 清空附件落盘根目录（host 启动/停用时调用）。
 * 上传的文件只在「写入 → 手机 composerAttach → composerSend 时 CLI 读取」这段窗口内有用，
 * host 重启/停用后即为无主垃圾；Windows 的 %TEMP% 不会自动回收，故在生命周期边界统一清理。
 * 失败不致命（目录可能正被占用），静默忽略。
 */
export async function cleanupAttachmentStore(): Promise<void> {
  try {
    await rm(attachmentRootDirectory(), { recursive: true, force: true });
  } catch {
    // ignore：清理失败不影响 host 运行，下次生命周期边界再试。
  }
}

/** 默认单附件上限 10MB，对齐 Mac `RemoteRecoveryLimits.maximumAttachmentBytes`。 */
export const DEFAULT_MAX_ATTACHMENT_BYTES = remoteRecoveryLimits.maximumAttachmentBytes;

const MAX_FILENAME_LENGTH = 180;

/**
 * 允许的附件扩展名白名单（对齐 Mac Audit B-P1-6）：图片、常见文档、结构化文本、
 * 源码。无扩展名的纯文本文件放行。
 */
const ALLOWED_EXTENSIONS = new Set<string>([
  // images
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic",
  // documents
  "pdf", "txt", "md", "rtf", "csv",
  // structured text / data
  "json", "yaml", "yml", "toml", "xml", "html", "htm",
  // source code
  "swift", "py", "rb", "go", "rs", "js", "ts", "tsx", "jsx",
  "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "kts",
  "sh", "bash", "zsh", "fish", "lua", "sql", "ini", "conf",
  "log"
]);

function failure(code: string, message: string, statusCode: number): StoreAttachmentResult {
  return { ok: false, error: { code, message, statusCode } };
}

/** 取 basename 并把路径分隔符 / 危险字符替换为下划线，避免目录穿越（对齐 Mac sanitizedFilename）。 */
export function sanitizeFilename(rawValue: string): string {
  const fallback = "attachment";
  // 同时按 "/" 与 "\" 取最后一段，兼容 Windows 路径分隔符。
  const segments = rawValue.split(/[/\\]/);
  const base = segments[segments.length - 1] ?? rawValue;
  const trimmed = base.trim();
  const value = trimmed.length === 0 ? fallback : trimmed;
  // 替换路径分隔符、盘符冒号、NUL 与换行符。
  return value.replace(/[/\\:\0\r\n]/g, "_");
}

function isAllowedExtension(filename: string): boolean {
  const dot = filename.lastIndexOf(".");
  if (dot <= 0 || dot === filename.length - 1) return true; // 无扩展名（或以点结尾）：当作纯文本放行
  const ext = filename.slice(dot + 1).toLowerCase();
  return ALLOWED_EXTENSIONS.has(ext);
}

/** 用 base64 编码长度反推解码字节是否在上限内，避免先解码超大串再判断。 */
function isBase64WithinDecodedLimit(encodedLength: number, maxBytes: number): boolean {
  const maximumEncodedLength = Math.floor((maxBytes + 2) / 3) * 4;
  return encodedLength <= maximumEncodedLength;
}

/** 严格 base64 校验：仅允许标准字母表与正确填充，对齐 Mac `Data(base64Encoded:)` 的严格性。 */
function decodeStrictBase64(contentBase64: string): Buffer | null {
  if (contentBase64.length === 0) return Buffer.alloc(0);
  if (contentBase64.length % 4 !== 0) return null;
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(contentBase64)) return null;
  const buffer = Buffer.from(contentBase64, "base64");
  // Buffer 的解码较宽松：用「重新编码后长度一致」做二次校验，排除被静默丢弃的非法输入。
  if (buffer.toString("base64").length !== contentBase64.length) return null;
  return buffer;
}

/**
 * 校验并落盘一个上传的附件。校验顺序严格对齐 Mac：文件名 → 文件名长度 →
 * base64 长度 → base64 解码 → 解码字节大小 → 扩展名白名单 → 写盘。
 */
export async function storeUploadedAttachment(
  rawFilename: string,
  contentBase64: string,
  maxBytes: number = DEFAULT_MAX_ATTACHMENT_BYTES
): Promise<StoreAttachmentResult> {
  const filename = sanitizeFilename(rawFilename);
  if (filename.length === 0) {
    return failure("invalid_filename", "文件名不能为空。", 400);
  }
  if (filename.length > MAX_FILENAME_LENGTH) {
    return failure("filename_too_long", "文件名过长，请重命名后再上传。", 400);
  }
  if (!isBase64WithinDecodedLimit(contentBase64.length, maxBytes)) {
    return failure("attachment_too_large", "附件超过大小限制，请压缩后再上传。", 413);
  }
  const data = decodeStrictBase64(contentBase64);
  if (!data) {
    return failure("invalid_content", "文件内容格式不正确，请重新上传。", 400);
  }
  if (data.length > maxBytes) {
    return failure("attachment_too_large", "附件超过大小限制，请压缩后再上传。", 413);
  }
  if (!isAllowedExtension(filename)) {
    return failure("attachment_type_not_allowed", "暂不支持这种附件类型。", 415);
  }
  try {
    const directory = path.join(tmpdir(), ATTACHMENT_DIRECTORY_NAME, randomUUID());
    const fileURL = path.join(directory, filename);
    await mkdir(directory, { recursive: true });
    try {
      await writeFile(fileURL, data, { flag: "wx" });
    } catch (error) {
      // host 停用会清空附件根目录；若与上传并发把父目录删掉（ENOENT），重建一次再写。
      if ((error as NodeJS.ErrnoException)?.code === "ENOENT") {
        await mkdir(directory, { recursive: true });
        await writeFile(fileURL, data, { flag: "wx" });
      } else {
        throw error;
      }
    }
    return { ok: true, value: { filename, path: fileURL } };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return failure("upload_failed", message, 400);
  }
}
