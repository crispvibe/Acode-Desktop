import {
  ArrowUp,
  Bot,
  Check,
  ChevronDown,
  ChevronRight,
  Copy,
  FileText,
  Loader2,
  Paperclip,
  Square,
  Terminal,
  X
} from "lucide-react";
import { FormEvent, memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import type {
  ChatMessage,
  ChatMessageAttachment,
  InteractiveRequest,
  PermissionDecision,
  ProjectSnapshot,
  QueuedChatRequest
} from "@shared/chat";
import { chatCLIDisplayNames, chatCLIValues, chatCLISupportsInteractiveControls, isChatRunStatusRunning } from "@shared/chat";
import type { CLIKind, PermissionMode, ReasoningEffort } from "@shared/settings";
import { createIpcChatBackend, useChatStore } from "@renderer/src/stores/chatStore";
import { useEditorStore } from "@renderer/src/stores/editorStore";
import { useProjectStore } from "@renderer/src/stores/projectStore";
import { useSettingsStore } from "@renderer/src/stores/settingsStore";

type ComposerPicker = "cli" | "permission" | "model" | "reasoning";

const permissionOptions: Array<{ value: PermissionMode; label: string; detail: string }> = [
  { value: "default", label: "询问", detail: "按 CLI 默认策略请求确认" },
  { value: "plan", label: "计划", detail: "先产出计划再执行" },
  { value: "acceptEdits", label: "自动编辑", detail: "允许安全编辑自动通过" },
  { value: "bypassPermissions", label: "全权限", detail: "跳过权限确认" }
];

const reasoningOptions: Array<{ value: ReasoningEffort; label: string; detail: string }> = [
  { value: "minimal", label: "Minimal", detail: "快速轻量" },
  { value: "low", label: "Low", detail: "低推理" },
  { value: "medium", label: "Medium", detail: "默认平衡" },
  { value: "high", label: "High", detail: "更强推理" }
];

function basename(path: string): string {
  const normalized = path.replaceAll("\\", "/").replace(/\/+$/u, "");
  return normalized.split("/").filter(Boolean).at(-1) ?? "文件";
}

function useCurrentProject(): ProjectSnapshot | null {
  const projects = useProjectStore((state) => state.projects);
  const selectedProjectId = useProjectStore((state) => state.selectedProjectId);

  return useMemo(() => {
    const project = projects.find((item) => item.id === selectedProjectId) ?? null;
    return project
      ? {
          id: project.id,
          name: project.name,
          path: project.path
        }
      : null;
  }, [projects, selectedProjectId]);
}

function kindLabel(kind: ChatMessage["kind"]): string {
  switch (kind) {
    case "toolCall":
      return "tool";
    case "toolResult":
      return "result";
    case "command":
      return "command";
    case "commandOutput":
      return "output";
    case "diff":
      return "diff";
    case "error":
      return "error";
    default:
      return kind;
  }
}

type MessageTextBlock =
  | { kind: "text"; text: string }
  | { kind: "code"; language: string; text: string };

const hiddenTranscriptKinds = new Set<ChatMessage["kind"]>(["result", "rawOutput"]);

const batchableToolNames = new Set(["read", "grep", "glob"]);

/// Normalized tool identity from a message's title/subtitle — parity with the Mac
/// `ChatMessage.toolName` extension so Claude (title="Edit", subtitle="Claude Code")
/// and Codex (title=method/item type, subtitle="Codex") items resolve the same way.
function toolName(message: ChatMessage): string {
  const header = `${message.title ?? ""} ${message.subtitle ?? ""}`.toLowerCase();
  const compact = header.replace(/[_\-\s]/g, "");
  if (compact.includes("multiedit")) return "multiedit";
  if (compact.includes("todowrite")) return "todowrite";
  if (compact.includes("read")) return "read";
  if (compact.includes("grep")) return "grep";
  if (compact.includes("glob")) return "glob";
  if (compact.includes("bash") || compact.includes("commandexecution") || compact.includes("shellexecution")) return "bash";
  if (compact.includes("agent")) return "agent";
  if (compact.includes("write")) return "write";
  if (compact.includes("edit")) return "edit";
  if (compact.includes("diff") || compact.includes("patch") || compact.includes("filechange")) return "diff";
  if (message.kind === "diff") return "diff";
  if (message.kind === "command" || message.kind === "commandOutput") return "bash";
  return "";
}

function toolDisplayLabel(message: ChatMessage): string {
  const name = toolName(message);
  if (name) {
    return name;
  }
  const raw = (message.title || message.subtitle || "").trim();
  return raw || kindLabel(message.kind);
}

// --- Tool payload parsers (port of the Mac AdvancedToolCard extractors) ----------

type JSONObject = Record<string, unknown>;

const nestedPayloadKeys = ["input", "args", "arguments", "params", "data", "item", "message", "content"];

function asJSONObject(value: unknown): JSONObject | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as JSONObject) : null;
}

function jsonObject(text: string): unknown | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
    return null;
  }
  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return null;
  }
}

/// Split text into top-level {}/[] JSON fragments (balanced-brace scan, string aware).
function jsonFragments(text: string): string[] {
  const fragments: string[] = [];
  const stack: string[] = [];
  let start = -1;
  let insideString = false;
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (insideString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === '"') {
        insideString = false;
      }
      continue;
    }
    if (char === '"') {
      insideString = true;
    } else if (char === "{" || char === "[") {
      if (stack.length === 0) {
        start = index;
      }
      stack.push(char);
    } else if (char === "}" || char === "]") {
      const last = stack[stack.length - 1];
      if (!(last === "{" && char === "}") && !(last === "[" && char === "]")) {
        stack.length = 0;
        start = -1;
        continue;
      }
      stack.pop();
      if (stack.length === 0 && start >= 0) {
        fragments.push(text.slice(start, index + 1));
        start = -1;
      }
    }
  }
  return fragments;
}

function firstJSONObject(text: string): unknown | null {
  const direct = jsonObject(text);
  if (direct !== null) {
    return direct;
  }
  for (const fragment of jsonFragments(text)) {
    const object = jsonObject(fragment);
    if (object !== null) {
      return object;
    }
  }
  return null;
}

function caseInsensitiveValue(key: string, object: JSONObject): unknown {
  const lower = key.toLowerCase();
  for (const [entryKey, value] of Object.entries(object)) {
    if (entryKey.toLowerCase() === lower) {
      return value;
    }
  }
  return undefined;
}

function firstStringValue(keys: string[], value: unknown): string | null {
  const dict = asJSONObject(value);
  if (dict) {
    for (const key of keys) {
      const entry = caseInsensitiveValue(key, dict);
      if (typeof entry === "string" && entry.trim()) {
        return entry.trim();
      }
      if (typeof entry === "number") {
        return String(entry);
      }
    }
    for (const key of nestedPayloadKeys) {
      const entry = caseInsensitiveValue(key, dict);
      const nested = entry === undefined ? null : firstStringValue(keys, entry);
      if (nested !== null) {
        return nested;
      }
    }
    for (const entry of Object.values(dict)) {
      const nested = firstStringValue(keys, entry);
      if (nested !== null) {
        return nested;
      }
    }
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      const nested = firstStringValue(keys, entry);
      if (nested !== null) {
        return nested;
      }
    }
  }
  if (typeof value === "string") {
    const nested = jsonObject(value);
    if (nested !== null) {
      return firstStringValue(keys, nested);
    }
  }
  return null;
}

function firstToolStringValue(keys: string[], text: string): string | null {
  const object = firstJSONObject(text);
  return object === null ? null : firstStringValue(keys, object);
}

/// First filesystem-ish path in free text — supports Unix (/a/b), relative (a/b/c.ext)
/// and Windows (C:\\a\\b) separators so host paths render on every platform.
function firstPathInText(text: string): string | null {
  const pattern = /(?:^|[\s`'"(]|^)(\/[^\s`"'<>|]+|[A-Za-z]:[\\/][^\s`"'<>|]+|[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+)/gu;
  for (const match of text.matchAll(pattern)) {
    const candidate = (match[1] ?? "").replace(/[.,;:。），]+$/u, "");
    if (candidate.includes(".") || candidate.startsWith("/") || /^[A-Za-z]:/u.test(candidate)) {
      return candidate;
    }
  }
  return null;
}

interface ReadToolPayload {
  path: string | null;
  startLine: number;
  lines: string[];
}

interface SearchToolPayload {
  mode: "grep" | "glob";
  title: string;
  rows: string[];
}

interface TerminalToolPayload {
  command: string | null;
  output: string;
  exitCode: string | null;
}

interface AgentToolPayload {
  title: string;
  kind: string | null;
  prompt: string | null;
}

interface TodoToolItem {
  content: string;
  status: string;
}

function searchRowsFrom(value: unknown): string[] {
  const dict = asJSONObject(value);
  if (dict) {
    for (const key of ["matches", "files", "results", "output", "result"]) {
      const entry = caseInsensitiveValue(key, dict);
      if (entry === undefined) {
        continue;
      }
      const rows = searchRowsFrom(entry);
      if (rows.length > 0) {
        return rows;
      }
    }
    for (const entry of Object.values(dict)) {
      const rows = searchRowsFrom(entry);
      if (rows.length > 0) {
        return rows;
      }
    }
  }
  if (Array.isArray(value)) {
    return value.flatMap(searchRowsFrom);
  }
  if (typeof value === "string") {
    const nested = jsonObject(value);
    if (nested !== null) {
      const rows = searchRowsFrom(nested);
      if (rows.length > 0) {
        return rows;
      }
    }
    return value.split("\n").filter((line) => line.trim() !== "");
  }
  if (typeof value === "number") {
    return [String(value)];
  }
  return [];
}

function readToolPayload(message: ChatMessage, resultText?: string): ReadToolPayload | null {
  if (toolName(message) !== "read") {
    return null;
  }
  const source = resultText?.trim() ? `${message.text}\n${resultText}` : message.text;
  const path =
    firstToolStringValue(["file_path", "filePath", "path", "target_file", "targetFile"], source) ?? firstPathInText(source);
  const startLineRaw = firstToolStringValue(["start_line", "startLine", "line", "offset"], source);
  const startLine = Math.max(1, Number.parseInt(startLineRaw?.trim() ?? "", 10) || 1);
  const content =
    firstToolStringValue(["content", "text", "output", "result"], source) ??
    (resultText?.trim() && !jsonObject(resultText) ? resultText : "") ??
    (jsonObject(message.text) ? "" : message.text);
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  if (lines.length === 0 && !path) {
    return null;
  }
  return { path, startLine, lines: lines.length > 0 ? lines : [""] };
}

function searchToolPayload(message: ChatMessage, resultText?: string): SearchToolPayload | null {
  const name = toolName(message);
  if (name !== "grep" && name !== "glob") {
    return null;
  }
  const source = resultText?.trim() ? `${message.text}\n${resultText}` : message.text;
  const pattern = firstToolStringValue(["pattern", "query", "regex", "glob"], source);
  const object = firstJSONObject(source);
  let rows = object !== null ? searchRowsFrom(object) : [];
  if (rows.length === 0) {
    rows = source
      .replace(/\r\n/g, "\n")
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line !== "" && !line.startsWith("{") && !line.endsWith("}"));
    if (rows.length === 0 && jsonObject(source)) {
      rows = [];
    }
  }
  const title = pattern ? `pattern: ${pattern}` : name === "glob" ? "文件列表" : "匹配结果";
  return { mode: name === "glob" ? "glob" : "grep", title, rows };
}

function cleanedTerminalOutput(value: string | null): string {
  if (!value) {
    return "";
  }
  const lines = value.replace(/\r\n/g, "\n").split("\n").filter((line) => !line.trim().startsWith("["));
  return lines.join("\n").trim();
}

function terminalToolPayload(message: ChatMessage, resultText?: string): TerminalToolPayload | null {
  const name = toolName(message);
  if (name !== "bash" && message.kind !== "command" && message.kind !== "commandOutput") {
    return null;
  }
  const command = firstToolStringValue(["command", "cmd", "shell_command", "shellCommand"], message.text);
  const output =
    cleanedTerminalOutput(firstToolStringValue(["stdout", "stderr", "output", "result", "error"], resultText?.trim() ? `${message.text}\n${resultText}` : message.text)) ||
    cleanedTerminalOutput(resultText ?? null) ||
    (message.kind === "commandOutput" ? cleanedTerminalOutput(message.text) : "");
  const exitCode = firstToolStringValue(["exit_code", "exitCode", "code", "status_code", "statusCode"], resultText?.trim() ? `${message.text}\n${resultText}` : message.text);
  return { command, output, exitCode };
}

function agentToolPayload(message: ChatMessage): AgentToolPayload | null {
  if (toolName(message) !== "agent" && !`${message.title ?? ""} ${message.subtitle ?? ""}`.toLowerCase().includes("agent")) {
    return null;
  }
  const kind = firstToolStringValue(["subagent_type", "subagentType", "agentType", "agent_type"], message.text);
  const description = firstToolStringValue(["description", "summary", "title"], message.text);
  const promptRaw = firstToolStringValue(["prompt", "instruction", "instructions"], message.text);
  return { title: description ?? "Agent task", kind, prompt: promptRaw ? promptRaw.slice(0, 420) : null };
}

function todoTaskRows(text: string): TodoToolItem[] {
  const fromObject = (value: unknown): TodoToolItem[] => {
    const dict = asJSONObject(value);
    if (dict) {
      const todos = caseInsensitiveValue("todos", dict);
      if (Array.isArray(todos)) {
        const rows = todos.map(todoTaskRow).filter((row): row is TodoToolItem => row !== null);
        if (rows.length > 0) {
          return rows;
        }
      }
      for (const key of nestedPayloadKeys) {
        const entry = caseInsensitiveValue(key, dict);
        if (entry === undefined) {
          continue;
        }
        const rows = fromObject(entry);
        if (rows.length > 0) {
          return rows;
        }
      }
      for (const entry of Object.values(dict)) {
        const rows = fromObject(entry);
        if (rows.length > 0) {
          return rows;
        }
      }
    }
    if (Array.isArray(value)) {
      const rows = value.map(todoTaskRow).filter((row): row is TodoToolItem => row !== null);
      if (rows.length > 0) {
        return rows;
      }
      for (const entry of value) {
        const rows = fromObject(entry);
        if (rows.length > 0) {
          return rows;
        }
      }
    }
    if (typeof value === "string") {
      const nested = jsonObject(value);
      if (nested !== null) {
        return fromObject(nested);
      }
    }
    return [];
  };

  const direct = jsonObject(text);
  if (direct !== null) {
    const rows = fromObject(direct);
    if (rows.length > 0) {
      return rows;
    }
  }
  for (const fragment of jsonFragments(text)) {
    const object = jsonObject(fragment);
    if (object === null) {
      continue;
    }
    const rows = fromObject(object);
    if (rows.length > 0) {
      return rows;
    }
  }
  // Plain-text fallback: pull every `"content": "..."` literal.
  const rows: TodoToolItem[] = [];
  for (const match of text.matchAll(/"content"\s*:\s*"((?:\\.|[^"\\])*)"/g)) {
    try {
      const content = String(JSON.parse(`"${match[1]}"`)).trim();
      if (content) {
        rows.push({ content, status: "" });
      }
    } catch {
      // ignore malformed escapes
    }
  }
  return rows;
}

function todoTaskRow(value: unknown): TodoToolItem | null {
  const dict = asJSONObject(value);
  if (!dict) {
    return null;
  }
  const content = ["content", "title", "task", "demand"]
    .map((key) => caseInsensitiveValue(key, dict))
    .find((entry): entry is string => typeof entry === "string" && entry.trim() !== "");
  if (!content) {
    return null;
  }
  const status = caseInsensitiveValue("status", dict);
  return { content, status: typeof status === "string" ? status : "" };
}

function todoToolPayload(message: ChatMessage): TodoToolItem[] | null {
  const header = `${message.title ?? ""} ${message.subtitle ?? ""}`.toLowerCase().replace(/[_\-\s]/g, "");
  const isTodo = header.includes("todowrite") || message.text.toLowerCase().includes('"todos"');
  return isTodo ? todoTaskRows(message.text) : null;
}

/// Hide protocol noise the way the Mac transcript does — result/success envelopes, raw
/// protocol blobs, and operational chatter never reach the conversation.
function shouldHideMessage(message: ChatMessage): boolean {
  const title = (message.title ?? "").trim().toLowerCase();
  const subtitle = (message.subtitle ?? "").trim().toLowerCase();
  const text = message.text.trim();
  if (message.kind === "result") {
    return true;
  }
  if (message.kind === "rawOutput") {
    if (!text) {
      return true;
    }
    if (isProtocolBlob(text)) {
      return true;
    }
    if (title === "raw" && subtitle === "claude code" && isClaudeProtocolRawLine(text)) {
      return true;
    }
  }
  if (message.kind === "rawOutput" || message.kind === "toolCall" || message.kind === "toolResult" || message.kind === "diff") {
    const noisePrefixes = ["mcpserver/", "account/ratelimits", "thread/status", "thread/tokenusage", "remotecontrol/", "session/configured", "session/connected"];
    if (noisePrefixes.some((prefix) => title.startsWith(prefix))) {
      return true;
    }
    if ((title.endsWith("/updated") || title.endsWith("/changed")) && title.includes("/")) {
      return true;
    }
    const compactTitle = title.replace(/[_\-\s]/g, "");
    if (compactTitle === "userinput" || compactTitle === "stderr" || compactTitle.includes("usermessage") || compactTitle.includes("reasoning")) {
      return true;
    }
  }
  return false;
}

function isProtocolBlob(text: string): boolean {
  if (!text.startsWith("{") || !text.endsWith("}")) {
    return false;
  }
  const lower = text.toLowerCase();
  return lower.includes('"session_id"') || lower.includes('"uuid"') || lower.includes('"type":"system"') || lower.includes('"type": "system"') || lower.includes('"status":"requesting"') || lower.includes('"status": "requesting"');
}

function isClaudeProtocolRawLine(text: string): boolean {
  const compact = text.replace(/\s+/g, "");
  if (!compact.startsWith("{")) {
    return false;
  }
  return [
    '"type":"stream_event"',
    '"type":"message_start"',
    '"type":"message_delta"',
    '"type":"message_stop"',
    '"type":"content_block_start"',
    '"type":"content_block_delta"',
    '"type":"content_block_stop"',
    '"type":"input_json_delta"',
    '"type":"signature_delta"',
    '"type":"ping"'
  ].some((marker) => compact.includes(marker));
}

const toolPathKeys = ["file_path", "filePath", "filepath", "path", "filename", "notebook_path"];

function extractToolFilePath(text: string): string | null {
  const trimmed = text.trim();
  if (!trimmed) {
    return null;
  }
  if (trimmed.startsWith("{")) {
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      for (const key of toolPathKeys) {
        const value = parsed[key];
        if (typeof value === "string" && value.trim()) {
          return value.trim();
        }
      }
    } catch {
      // fall through to regex below
    }
  }
  for (const key of toolPathKeys) {
    const match = new RegExp(`"${key}"\\s*:\\s*"([^"]+)"`, "u").exec(trimmed);
    if (match?.[1]) {
      return match[1];
    }
  }
  return null;
}

function toolHeaderSummary(message: ChatMessage): string | null {
  const path = extractToolFilePath(message.text);
  if (path) {
    return basename(path);
  }
  const firstLine = message.text.split("\n").map((line) => line.trim()).find(Boolean);
  if (!firstLine) {
    return null;
  }
  return firstLine.length > 80 ? `${firstLine.slice(0, 80)}…` : firstLine;
}

const fileChangeToolNames = new Set(["edit", "write", "multiedit", "multi_edit", "create", "create_file", "new_file", "notebookedit"]);

function isFileChangeMessage(message: ChatMessage): boolean {
  return message.kind === "diff" || fileChangeToolNames.has(toolName(message).toLowerCase());
}

type DiffLine = { marker: "+" | "-" | " "; text: string };

const maxDiffPreviewLines = 300;

function capDiffLines(lines: DiffLine[]): DiffLine[] {
  return lines.length > maxDiffPreviewLines ? lines.slice(0, maxDiffPreviewLines) : lines;
}

// Turns a file-change tool payload into red/green diff lines, mirroring the Mac code-preview card:
// Edit → old_string(-)/new_string(+); MultiEdit → each edit; Write → content(+); diff kind → +/- prefixes.
function buildDiffLines(message: ChatMessage): DiffLine[] {
  const text = message.text.trim();
  const pushBlock = (lines: DiffLine[], value: unknown, marker: DiffLine["marker"]) => {
    String(value)
      .split("\n")
      .forEach((line) => lines.push({ marker, text: line }));
  };

  if (text.startsWith("{")) {
    try {
      const parsed = JSON.parse(text) as Record<string, unknown>;
      const lines: DiffLine[] = [];
      if (Array.isArray(parsed.edits)) {
        for (const entry of parsed.edits) {
          const edit = entry as Record<string, unknown>;
          if (typeof edit.old_string === "string" && edit.old_string) pushBlock(lines, edit.old_string, "-");
          if (typeof edit.new_string === "string" && edit.new_string) pushBlock(lines, edit.new_string, "+");
        }
        if (lines.length > 0) return capDiffLines(lines);
      }
      if (typeof parsed.old_string === "string" || typeof parsed.new_string === "string") {
        if (typeof parsed.old_string === "string" && parsed.old_string) pushBlock(lines, parsed.old_string, "-");
        if (typeof parsed.new_string === "string" && parsed.new_string) pushBlock(lines, parsed.new_string, "+");
        if (lines.length > 0) return capDiffLines(lines);
      }
      if (typeof parsed.content === "string") {
        pushBlock(lines, parsed.content, "+");
        return capDiffLines(lines);
      }
    } catch {
      // fall through to raw handling
    }
  }

  const raw = text.split("\n");
  if (message.kind === "diff") {
    const lines = raw
      .filter(
        (line) =>
          !line.startsWith("diff --git") && !line.startsWith("+++") && !line.startsWith("---") && !line.startsWith("@@")
      )
      .map<DiffLine>((line) => {
        if (line.startsWith("+")) return { marker: "+", text: line.slice(1) };
        if (line.startsWith("-")) return { marker: "-", text: line.slice(1) };
        return { marker: " ", text: line.startsWith(" ") ? line.slice(1) : line };
      });
    return capDiffLines(lines);
  }
  return capDiffLines(raw.map<DiffLine>((line) => ({ marker: " ", text: line })));
}

interface ToolInvocation {
  primary: ChatMessage;
  responses: ChatMessage[];
}

type RenderItem =
  | { type: "message"; message: ChatMessage }
  | { type: "toolInvocation"; id: string; invocation: ToolInvocation }
  | { type: "toolBatch"; id: string; invocations: ToolInvocation[] };

function isToolInvocationStart(message: ChatMessage): boolean {
  return message.kind === "toolCall" || message.kind === "command";
}

function isToolInvocationBoundary(message: ChatMessage): boolean {
  switch (message.kind) {
    case "toolResult":
    case "commandOutput":
    case "diff":
    case "system":
      return false;
    default:
      return true;
  }
}

/// requestID or an embedded call/item id used to pair a tool call with its result —
/// mirrors Mac `toolCorrelationID`.
function toolCorrelationID(message: ChatMessage): string | null {
  const requestID = message.requestID?.trim();
  if (requestID) {
    return requestID;
  }
  if (message.kind === "toolResult") {
    const resultID = firstToolStringValue(["tool_use_id", "toolUseId"], message.text);
    if (resultID) {
      return resultID;
    }
  }
  return firstToolStringValue(["call_id", "callId", "item_id", "itemId", "command_id", "commandId", "id"], message.text);
}

function isToolInvocationFeedback(primary: ChatMessage, candidate: ChatMessage): boolean {
  const pairOk =
    (primary.kind === "command" && candidate.kind === "commandOutput") ||
    (primary.kind === "toolCall" && (candidate.kind === "toolResult" || candidate.kind === "diff"));
  if (!pairOk) {
    return false;
  }
  const primaryID = toolCorrelationID(primary);
  const candidateID = toolCorrelationID(candidate);
  if (primaryID && candidateID) {
    return primaryID === candidateID;
  }
  return !primary.requestID && !candidate.requestID;
}

/// Mirrors the Mac transcript builder: a tool call groups with its matching results
/// (toolInvocationGroup), and runs of ≥2 consecutive read/grep/glob invocations collapse
/// into one batch card (coalesceToolBatches).
function buildRenderItems(messages: ChatMessage[]): RenderItem[] {
  const items: Array<ToolInvocation | ChatMessage> = [];
  const seenErrorTexts = new Set<string>();
  const consumedIDs = new Set<string>();
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (consumedIDs.has(message.id) || shouldHideMessage(message)) {
      continue;
    }
    if (message.kind === "error") {
      const key = message.text.trim();
      if (seenErrorTexts.has(key)) {
        continue;
      }
      seenErrorTexts.add(key);
    }
    if (!isToolInvocationStart(message)) {
      items.push(message);
      continue;
    }
    const responses: ChatMessage[] = [];
    let scan = index + 1;
    while (scan < messages.length) {
      const candidate = messages[scan];
      if (consumedIDs.has(candidate.id) || shouldHideMessage(candidate)) {
        scan += 1;
        continue;
      }
      if (isToolInvocationFeedback(message, candidate)) {
        responses.push(candidate);
        consumedIDs.add(candidate.id);
        scan += 1;
        continue;
      }
      if (isToolInvocationBoundary(candidate) || toolCorrelationID(message) === null || responses.length > 0) {
        break;
      }
      scan += 1;
    }
    if (responses.length === 0) {
      items.push(message);
      continue;
    }
    items.push({ primary: message, responses });
  }

  const result: RenderItem[] = [];
  let run: ToolInvocation[] = [];
  const flush = () => {
    if (run.length >= 2) {
      result.push({ type: "toolBatch", id: `tool-batch-${run[0].primary.id}`, invocations: run });
    } else {
      for (const invocation of run) {
        result.push({ type: "toolInvocation", id: invocation.primary.id, invocation });
      }
    }
    run = [];
  };
  for (const item of items) {
    if (isToolInvocation(item) && batchableToolNames.has(toolName(item.primary).toLowerCase())) {
      run.push(item);
    } else {
      flush();
      if (isToolInvocation(item)) {
        result.push({ type: "toolInvocation", id: item.primary.id, invocation: item });
      } else {
        result.push({ type: "message", message: item });
      }
    }
  }
  flush();
  return result;
}

function isToolInvocation(value: ChatMessage | ToolInvocation): value is ToolInvocation {
  return typeof value === "object" && value !== null && "primary" in value && "responses" in value;
}

function parseMessageText(text: string): MessageTextBlock[] {
  const blocks: MessageTextBlock[] = [];
  const fencePattern = /```([^\n`]*)\n?([\s\S]*?)(?:```|$)/g;
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = fencePattern.exec(text)) !== null) {
    if (match.index > cursor) {
      blocks.push({ kind: "text", text: text.slice(cursor, match.index) });
    }
    blocks.push({ kind: "code", language: match[1]?.trim() ?? "", text: match[2] ?? "" });
    cursor = fencePattern.lastIndex;
  }

  if (cursor < text.length) {
    blocks.push({ kind: "text", text: text.slice(cursor) });
  }

  return blocks.length > 0 ? blocks : [{ kind: "text", text }];
}

function isNearScrollBottom(element: HTMLElement): boolean {
  return element.scrollHeight - element.scrollTop - element.clientHeight < 72;
}

export function ChatRuntimePanel() {
  const [input, setInput] = useState("");
  const [attachments, setAttachments] = useState<ChatMessageAttachment[]>([]);
  const [activePicker, setActivePicker] = useState<ComposerPicker | null>(null);
  const [customModel, setCustomModel] = useState("");
  const [expandedReasoningIds, setExpandedReasoningIds] = useState<Set<string>>(() => new Set());
  const [isNearBottom, setIsNearBottom] = useState(true);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const shouldStickToBottomRef = useRef(true);
  const programmaticScrollRef = useRef(false);
  const composerComposingRef = useRef(false);
  const project = useCurrentProject();
  const settings = useSettingsStore((state) => state.settings);
  const settingsLoading = useSettingsStore((state) => state.loading);
  const loadSettings = useSettingsStore((state) => state.load);
  const savePatch = useSettingsStore((state) => state.savePatch);
  const updateProfile = useSettingsStore((state) => state.updateProfile);
  const messages = useChatStore((state) => state.messages);
  const queuedRequests = useChatStore((state) => state.queuedRequests);
  const status = useChatStore((state) => state.status);
  const statusText = useChatStore((state) => state.statusText);
  const tokensUsed = useChatStore((state) => state.tokensUsed);
  const tokensTotal = useChatStore((state) => state.tokensTotal);
  const isAwaitingFirstModelOutput = useChatStore((state) => state.isAwaitingFirstModelOutput);
  const setBackend = useChatStore((state) => state.setBackend);
  const hydrateSessions = useChatStore((state) => state.hydrateSessions);
  const send = useChatStore((state) => state.send);
  const stop = useChatStore((state) => state.stop);
  const cancelQueuedRequest = useChatStore((state) => state.cancelQueuedRequest);
  const activateProject = useChatStore((state) => state.activateProject);
  const respondToInteractiveRequest = useChatStore((state) => state.respondToInteractiveRequest);
  const sessionCLI = useChatStore((state) => state.currentSession?.cli);
  const openFile = useEditorStore((state) => state.openFile);
  const isRunning = isChatRunStatusRunning(status);
  const activeCLI = settings?.defaultCLI ?? "claude";
  // 通用 7 家 CLI 没有会话内交互回写通道：选择题只读展示，不再劫持输入框或渲染假按钮。
  const interactiveCapable = chatCLISupportsInteractiveControls(sessionCLI ?? activeCLI);
  const waitingInteractive = useMemo(
    () =>
      interactiveCapable
        ? messages.find(
            (message) => message.kind === "interactiveRequest" && message.interactiveRequest?.status === "waiting"
          )?.interactiveRequest ?? null
        : null,
    [interactiveCapable, messages]
  );
  const renderItems = useMemo(() => buildRenderItems(messages), [messages]);
  // 稳定引用：内联箭头会让 memo(ChatMessageRow) 的 props 每次渲染都变，整列重渲。
  const handleToggleReasoning = useCallback((id: string) => {
    setExpandedReasoningIds((current) => {
      const next = new Set(current);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);
  const activeProfile = useMemo(() => {
    const profiles = settings?.profiles.filter((profile) => profile.kind === activeCLI && profile.enabled) ?? [];
    return profiles.find((profile) => profile.isDefault) ?? profiles[0] ?? null;
  }, [activeCLI, settings?.profiles]);
  const activePermission = activeProfile?.permissionMode ?? settings?.permissionMode ?? "default";
  const activeReasoning = activeProfile?.reasoningEffort ?? settings?.reasoningEffort ?? "medium";
  const activeModelLabel = activeProfile?.model?.trim() || settings?.model?.trim() || "默认模型";
  const knownModelOptions = useMemo(() => {
    const values = [
      settings?.model,
      activeProfile?.model,
      ...(settings?.profiles.filter((profile) => profile.kind === activeCLI).map((profile) => profile.model) ?? [])
    ]
      .map((value) => value?.trim())
      .filter((value): value is string => Boolean(value));
    return Array.from(new Set(values));
  }, [activeCLI, activeProfile?.model, settings?.model, settings?.profiles]);
  const appendRuleText = settings?.appendRule.enabled ? settings.appendRule.content.trim() : "";
  const messageScrollSignature = useMemo(
    () =>
      messages
        .map((message) => `${message.id}:${message.text.length}:${message.status ?? ""}:${message.isStreaming ? "1" : "0"}`)
        .join("|"),
    [messages]
  );
  const canSend = Boolean(project?.path && (input.trim() || attachments.length > 0));

  useEffect(() => {
    const chat = window.codevoke?.chat;
    setBackend(chat ? createIpcChatBackend(chat) : null);
    if (chat) {
      void chat.loadSessions().then(hydrateSessions).catch((error: unknown) => {
        console.error("[chat] failed to load session snapshot", error);
      });
    }
    return () => {
      setBackend(null);
    };
  }, [hydrateSessions, setBackend]);

  useEffect(() => {
    if (!settings && !settingsLoading) {
      void loadSettings();
    }
  }, [loadSettings, settings, settingsLoading]);

  useEffect(() => {
    activateProject(project);
  }, [activateProject, project?.id, project?.path]);

  useEffect(() => {
    const streamingReasoning = messages.filter((message) => message.kind === "reasoning" && message.isStreaming);
    if (streamingReasoning.length === 0) {
      return;
    }
    setExpandedReasoningIds((current) => {
      const next = new Set(current);
      for (const message of streamingReasoning) {
        next.add(message.id);
      }
      return next;
    });
  }, [messageScrollSignature, messages]);

  useEffect(() => {
    if (!shouldStickToBottomRef.current) {
      return;
    }
    const frame = window.requestAnimationFrame(() => {
      const viewport = viewportRef.current;
      if (!viewport) {
        return;
      }
      // Mark this as a programmatic scroll so the resulting scroll event doesn't bounce back
      // through updateScrollPosition and fight the rAF (which can thrash with tall, variable-height
      // cards like a pending choice question).
      programmaticScrollRef.current = true;
      viewport.scrollTo({ top: viewport.scrollHeight, behavior: "auto" });
      setIsNearBottom(true);
      window.requestAnimationFrame(() => {
        programmaticScrollRef.current = false;
      });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [messageScrollSignature, queuedRequests.length, statusText]);

  function updateScrollPosition() {
    const viewport = viewportRef.current;
    if (!viewport) {
      return;
    }
    const nearBottom = isNearScrollBottom(viewport);
    // programmaticScrollRef 只用来吞掉 scrollTo 自己产生的回波（位置已在底部）；
    // 若用户在同一帧内主动上翻（位置不在底部），必须照常处理，否则 stick 标记会
    // 停在 true 把用户拖回底部。
    if (programmaticScrollRef.current && nearBottom) {
      return;
    }
    shouldStickToBottomRef.current = nearBottom;
    setIsNearBottom(nearBottom);
  }

  function jumpToLatest() {
    const viewport = viewportRef.current;
    if (!viewport) {
      return;
    }
    shouldStickToBottomRef.current = true;
    setIsNearBottom(true);
    viewport.scrollTo({ top: viewport.scrollHeight, behavior: "smooth" });
  }

  function togglePicker(picker: ComposerPicker) {
    setActivePicker((current) => (current === picker ? null : picker));
  }

  async function selectCLI(cli: CLIKind) {
    setActivePicker(null);
    await savePatch({ defaultCLI: cli });
  }

  async function selectPermission(permissionMode: PermissionMode) {
    setActivePicker(null);
    if (activeProfile) {
      await updateProfile(activeProfile.id, { permissionMode });
      return;
    }
    await savePatch({ permissionMode });
  }

  async function selectReasoning(reasoningEffort: ReasoningEffort) {
    setActivePicker(null);
    if (activeProfile) {
      await updateProfile(activeProfile.id, { reasoningEffort });
      return;
    }
    await savePatch({ reasoningEffort });
  }

  async function selectModel(model: string) {
    const normalizedModel = model.trim();
    setActivePicker(null);
    if (activeProfile) {
      await updateProfile(activeProfile.id, { model: normalizedModel });
      return;
    }
    await savePatch({ model: normalizedModel });
  }

  async function handleCustomModelSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const model = customModel.trim();
    if (!model) {
      return;
    }
    setCustomModel("");
    await selectModel(model);
  }

  async function handleAttachFile() {
    const selection = await window.codevoke?.selectEditorFile();
    if (!selection?.path) {
      return;
    }
    const filePath = selection.path;
    setAttachments((current) => {
      if (current.some((attachment) => attachment.path === filePath)) {
        return current;
      }
      return [
        ...current,
        {
          id: `attachment-${crypto.randomUUID()}`,
          kind: "file",
          filename: basename(filePath),
          path: filePath
        }
      ];
    });
  }

  function removeAttachment(id: string) {
    setAttachments((current) => current.filter((attachment) => attachment.id !== id));
  }

  function handleEditQueuedRequest(request: QueuedChatRequest) {
    setInput(request.displayText);
    setAttachments(request.attachments);
    cancelQueuedRequest(request.id);
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const text = input.trim();
    // Answer a pending choice/text question straight from the main composer (parity with Mac),
    // instead of forcing the user down into the inline card.
    if (
      text &&
      waitingInteractive &&
      (waitingInteractive.allowCustomInput || waitingInteractive.mode === "text")
    ) {
      // ack 现在是异步的（IPC invoke 真实结果）：写回成功才清空输入框，
      // 失败时保留原文让用户重试，卡片由 store 走 failed 路径。
      void respondToInteractiveRequest({
        requestID: waitingInteractive.id,
        selectedOptionIDs: [],
        customText: text
      }).then((didRespond) => {
        if (didRespond) {
          setInput("");
          setActivePicker(null);
        }
      });
      return;
    }
    if ((!text && attachments.length === 0) || !project?.path) {
      return;
    }
    const backendText = `${text}${appendRuleText ? `\n\n${appendRuleText}` : ""}`;
    const didSend = send({
      text,
      backendText,
      appendRuleText: appendRuleText || null,
      attachments,
      project,
      cli: activeCLI,
      sessionMode: "continueLast"
    });
    if (didSend) {
      shouldStickToBottomRef.current = true;
      setIsNearBottom(true);
      setInput("");
      setAttachments([]);
      setActivePicker(null);
    }
  }

  return (
    <>
      <div className="conversation" ref={viewportRef} onScroll={updateScrollPosition}>
        {messages.length === 0 ? (
          <div className="chat-empty-state">
            <b>{project ? "新对话" : "选择一个项目"}</b>
            <span>{project ? "输入需求后会在这里显示 Windows 端对话流。" : "添加或选择项目后才能开始会话。"}</span>
          </div>
        ) : (
          renderItems.map((item) =>
            item.type === "toolBatch" ? (
              <ToolBatchCard key={item.id} invocations={item.invocations} onOpenFile={openFile} />
            ) : item.type === "toolInvocation" ? (
              <ToolInvocationCard key={item.id} invocation={item.invocation} onOpenFile={openFile} />
            ) : (
              <ChatMessageRow
                key={item.message.id}
                message={item.message}
                onOpenFile={openFile}
                reasoningExpanded={expandedReasoningIds.has(item.message.id)}
                onToggleReasoning={handleToggleReasoning}
              />
            )
          )
        )}
        {isAwaitingFirstModelOutput ? (
          <div className="chat-loading-row">
            <Loader2 size={14} />
            <span>等待模型输出</span>
          </div>
        ) : null}
        {!isNearBottom ? (
          <button type="button" className="jump-latest-button" onClick={jumpToLatest}>
            回到底部
          </button>
        ) : null}
      </div>

      {queuedRequests.length > 0 ? (
        <QueuedRequestsPanel
          requests={queuedRequests}
          onCancel={cancelQueuedRequest}
          onEdit={handleEditQueuedRequest}
        />
      ) : null}

      <form className="composer-card" onSubmit={handleSubmit}>
        <textarea
          placeholder={
            !project
              ? "先选择项目"
              : waitingInteractive && (waitingInteractive.allowCustomInput || waitingInteractive.mode === "text")
                ? "输入你的选择或回复"
                : "输入你的需求"
          }
          rows={3}
          value={input}
          disabled={!project}
          onChange={(event) => setInput(event.target.value)}
          onCompositionStart={() => {
            composerComposingRef.current = true;
          }}
          onCompositionEnd={() => {
            composerComposingRef.current = false;
          }}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && !composerComposingRef.current) {
              event.preventDefault();
              event.currentTarget.form?.requestSubmit();
            }
          }}
        />
        <ComposerAttachments attachments={attachments} onRemove={removeAttachment} />
        <div className="composer-toolbar">
          <button type="button" className="plain-icon attach-button" onClick={() => void handleAttachFile()} aria-label="添加附件">
            <Paperclip size={18} />
          </button>
          <button type="button" className="composer-select" onClick={() => togglePicker("cli")}>
            <Terminal size={14} />
            <span>{cliLabel(activeCLI)}</span>
            <ChevronDown size={14} />
          </button>
          <button type="button" className="composer-select" onClick={() => togglePicker("permission")}>
            <span>{permissionLabel(activePermission)}</span>
            <ChevronDown size={14} />
          </button>
          <button type="button" className="composer-select model" onClick={() => togglePicker("model")} title={activeModelLabel}>
            <span>{activeModelLabel}</span>
            <ChevronDown size={14} />
          </button>
          <button type="button" className="composer-select compact" onClick={() => togglePicker("reasoning")}>
            <span>{reasoningLabel(activeReasoning)}</span>
            <ChevronDown size={14} />
          </button>
          <span className="chat-runtime-status" title={statusText}>
            {statusText}
            {tokensUsed > 0 ? ` · ${tokensUsed}/${tokensTotal}` : ""}
          </span>
          {isRunning ? (
            <button className="stop-button" type="button" onClick={stop} aria-label="停止当前运行">
              <Square size={13} />
            </button>
          ) : null}
          <button className="send-button" type="submit" disabled={!canSend} aria-label={isRunning ? "加入队列" : "发送"}>
            <ArrowUp size={18} />
          </button>
        </div>
        {activePicker ? (
          <div className="composer-picker-layer">
            {activePicker === "cli" ? (
              <PickerGroup>
                {chatCLIValues.map((cli) => (
                  <PickerOption key={cli} active={activeCLI === cli} label={cliLabel(cli)} onClick={() => void selectCLI(cli)} />
                ))}
              </PickerGroup>
            ) : null}
            {activePicker === "permission" ? (
              <PickerGroup>
                {permissionOptions.map((option) => (
                  <PickerOption
                    key={option.value}
                    active={activePermission === option.value}
                    label={option.label}
                    detail={option.detail}
                    onClick={() => void selectPermission(option.value)}
                  />
                ))}
              </PickerGroup>
            ) : null}
            {activePicker === "reasoning" ? (
              <PickerGroup>
                {reasoningOptions.map((option) => (
                  <PickerOption
                    key={option.value}
                    active={activeReasoning === option.value}
                    label={option.label}
                    detail={option.detail}
                    onClick={() => void selectReasoning(option.value)}
                  />
                ))}
              </PickerGroup>
            ) : null}
            {activePicker === "model" ? (
              <PickerGroup>
                <PickerOption active={activeModelLabel === "默认模型"} label="默认模型" onClick={() => void selectModel("")} />
                {knownModelOptions.map((model) => (
                  <PickerOption key={model} active={activeModelLabel === model} label={model} onClick={() => void selectModel(model)} />
                ))}
                <form className="picker-custom-model" onSubmit={(event) => void handleCustomModelSubmit(event)}>
                  <input
                    value={customModel}
                    onChange={(event) => setCustomModel(event.target.value)}
                    placeholder="输入模型名称"
                  />
                  <button type="submit">使用</button>
                </form>
              </PickerGroup>
            ) : null}
          </div>
        ) : null}
      </form>
    </>
  );
}

function cliLabel(cli: CLIKind): string {
  return chatCLIDisplayNames[cli];
}

function permissionLabel(mode: PermissionMode): string {
  return permissionOptions.find((option) => option.value === mode)?.label ?? "询问";
}

function reasoningLabel(effort: ReasoningEffort): string {
  return reasoningOptions.find((option) => option.value === effort)?.label ?? "Medium";
}

function PickerGroup({ children }: { children: ReactNode }) {
  return <div className="composer-picker-group">{children}</div>;
}

function PickerOption({
  active,
  detail,
  label,
  onClick
}: {
  active: boolean;
  detail?: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button type="button" className={`composer-picker-option ${active ? "active" : ""}`} onClick={onClick} title={label}>
      <span>
        <b>{label}</b>
        {detail ? <small>{detail}</small> : null}
      </span>
      {active ? <Check size={14} /> : null}
    </button>
  );
}

function QueuedRequestsPanel({
  requests,
  onCancel,
  onEdit
}: {
  requests: QueuedChatRequest[];
  onCancel: (id: string) => void;
  onEdit: (request: QueuedChatRequest) => void;
}) {
  return (
    <div className="queued-requests-panel">
      <div className="queued-requests-header">
        <span>{requests.length} 条请求排队中</span>
      </div>
      {requests.map((request) => (
        <div className="queued-request-row" key={request.id}>
          <div>
            <b>{request.displayText}</b>
            <span>
              {cliLabel(request.cli)} · {request.modelID}
            </span>
          </div>
          <button type="button" onClick={() => onEdit(request)}>
            编辑
          </button>
          <button type="button" aria-label="取消排队请求" onClick={() => onCancel(request.id)}>
            <X size={13} />
          </button>
        </div>
      ))}
    </div>
  );
}

function ComposerAttachments({
  attachments,
  onRemove
}: {
  attachments: ChatMessageAttachment[];
  onRemove: (id: string) => void;
}) {
  if (attachments.length === 0) {
    return null;
  }
  return (
    <div className="composer-attachments">
      {attachments.map((attachment) => (
        <span className="composer-attachment-pill" key={attachment.id} title={attachment.path}>
          <FileText size={12} />
          {attachment.filename}
          <button type="button" aria-label={`移除 ${attachment.filename}`} onClick={() => onRemove(attachment.id)}>
            <X size={11} />
          </button>
        </span>
      ))}
    </div>
  );
}

const ChatMessageRow = memo(function ChatMessageRow({
  message,
  onOpenFile,
  onToggleReasoning,
  reasoningExpanded
}: {
  message: ChatMessage;
  onOpenFile: (path: string) => void | Promise<void>;
  onToggleReasoning: (id: string) => void;
  reasoningExpanded: boolean;
}) {
  if (message.kind === "permissionRequest") {
    return <PermissionRequestCard message={message} />;
  }

  if (message.kind === "interactiveRequest" && message.interactiveRequest) {
    return <InteractiveRequestCard request={message.interactiveRequest} />;
  }

  if (message.kind === "user") {
    return (
      <div className="user-message">
        <span>{message.text}</span>
        <MessageAttachmentStrip attachments={message.attachments ?? []} />
        <time>{formatMessageTime(message.createdAt)}</time>
        <div className="bubble-tools">
          <Copy size={14} />
        </div>
      </div>
    );
  }

  if (message.kind === "reasoning") {
    return (
      <div className="assistant-message reasoning-message">
        <div className="assistant-avatar" aria-hidden="true">
          <Bot size={16} />
        </div>
        <div className="assistant-bubble">
          <button type="button" className="thinking-row" onClick={() => onToggleReasoning(message.id)}>
            {reasoningExpanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
            <b>thinking</b>
            {message.isStreaming ? <span>streaming</span> : null}
          </button>
          {reasoningExpanded ? <MessageText text={message.text || "正在整理推理..."} /> : null}
        </div>
      </div>
    );
  }

  if (message.kind === "assistant") {
    return <AssistantMessageCard message={message} />;
  }

  if (message.kind === "system") {
    return <SystemEventCard message={message} />;
  }

  if (hiddenTranscriptKinds.has(message.kind)) {
    return <DiagnosticEventCard message={message} />;
  }

  // Every remaining operational kind (toolCall/toolResult/command/commandOutput/diff/error)
  // routes through the same specialized-card dispatch as grouped invocations.
  return <ToolInvocationCard invocation={{ primary: message, responses: [] }} onOpenFile={onOpenFile} />;
});

function AssistantMessageCard({ message }: { message: ChatMessage }) {
  return (
    <div className="assistant-message">
      <div className="assistant-avatar" aria-hidden="true">
        <Bot size={16} />
      </div>
      <div>
        <div className="assistant-bubble">
          <MessageText text={message.text} />
        </div>
        <time>{formatMessageTime(message.createdAt)}</time>
        <Copy className="copy-below" size={14} />
      </div>
    </div>
  );
}

function MessageText({ text }: { text: string }) {
  return (
    <div className="message-text-blocks">
      {parseMessageText(text).map((block, index) => {
        if (block.kind === "code") {
          return (
            <pre className="chat-code-block" key={`${block.kind}-${index}`}>
              {block.language ? <span>{block.language}</span> : null}
              <code>{block.text}</code>
            </pre>
          );
        }
        return block.text.split(/\n{2,}/u).filter(Boolean).map((paragraph, paragraphIndex) => (
          <p key={`${block.kind}-${index}-${paragraphIndex}`}>{paragraph}</p>
        ));
      })}
    </div>
  );
}

function FileChangeCard({
  message,
  onOpenFile
}: {
  message: ChatMessage;
  onOpenFile: (path: string) => void | Promise<void>;
}) {
  const filePath = extractToolFilePath(message.text);
  const fileName = filePath ? basename(filePath) : message.title || "文件变更";
  const lines = useMemo(() => buildDiffLines(message), [message.text, message.kind]);
  const added = lines.filter((line) => line.marker === "+").length;
  const removed = lines.filter((line) => line.marker === "-").length;

  return (
    <div className="chat-event-row transcript-event-card file-change-card kind-diff">
      <div className="file-change-header">
        <button
          type="button"
          className="file-change-name"
          disabled={!filePath}
          title={filePath ?? fileName}
          onClick={() => {
            if (filePath) {
              void onOpenFile(filePath);
            }
          }}
        >
          <FileText size={12} />
          <span>{fileName}</span>
        </button>
        <span className="file-change-stats">
          {added > 0 ? <em className="add">+{added}</em> : null}
          {removed > 0 ? <em className="del">-{removed}</em> : null}
        </span>
      </div>
      {lines.length > 0 ? (
        <div className="file-change-body">
          {lines.map((line, index) => (
            <div
              key={index}
              className={`diff-line ${line.marker === "+" ? "add" : line.marker === "-" ? "del" : ""}`}
            >
              <span className="diff-ln">{index + 1}</span>
              <span className="diff-mk">{line.marker}</span>
              <span className="diff-tx">{line.text || " "}</span>
            </div>
          ))}
        </div>
      ) : (
        <p className="file-change-empty">{message.isStreaming ? "正在写入…" : "暂无变更预览。"}</p>
      )}
    </div>
  );
}

/// A tool call plus its matching results rendered as one card — routes to the
/// specialized renderer for the tool (Mac's AdvancedToolCard parity).
/// invocation 包装对象每次 buildRenderItems 都是新建的，但内部 primary/responses
/// 引用的是稳定的 message 对象——memo 比较器按底层引用判等，让未变化的工具卡
/// 在流式 flush 时跳过重渲染（卡片内部要做 payload 解析，重渲不便宜）。
const ToolInvocationCard = memo(function ToolInvocationCard({
  invocation,
  onOpenFile
}: {
  invocation: ToolInvocation;
  onOpenFile: (path: string) => void | Promise<void>;
}) {
  const { primary, responses } = invocation;
  const resultText = responses.map((response) => response.text).filter((text) => text.trim()).join("\n");
  const diffResponse = responses.find((response) => response.kind === "diff");

  if (isFileChangeMessage(primary) || diffResponse) {
    const source = diffResponse ?? primary;
    const merged = { ...source, text: diffResponse?.text.trim() ? diffResponse.text : source.text };
    return <FileChangeCard message={merged} onOpenFile={onOpenFile} />;
  }
  const read = readToolPayload(primary, resultText || undefined);
  if (read) {
    return <ReadToolCard payload={read} onOpenFile={onOpenFile} />;
  }
  const search = searchToolPayload(primary, resultText || undefined);
  if (search) {
    return <SearchToolCard payload={search} />;
  }
  const agent = agentToolPayload(primary);
  if (agent) {
    return <AgentToolCard payload={agent} resultText={resultText} />;
  }
  const todos = todoToolPayload(primary);
  if (todos) {
    return <TodoToolCard rows={todos} />;
  }
  const terminal = terminalToolPayload(primary, resultText || undefined);
  if (terminal) {
    return <TerminalToolCard payload={terminal} status={primary.status} isStreaming={Boolean(primary.isStreaming)} />;
  }
  return (
    <div className="chat-event-row transcript-event-card tool-invocation-card">
      <GenericToolRow message={primary} onOpenFile={onOpenFile} />
      {responses.map((response) => (
        <GenericToolRow key={response.id} message={response} onOpenFile={onOpenFile} />
      ))}
    </div>
  );
}, (prev, next) =>
  prev.onOpenFile === next.onOpenFile &&
  prev.invocation.primary === next.invocation.primary &&
  prev.invocation.responses.length === next.invocation.responses.length &&
  prev.invocation.responses.every((response, index) => response === next.invocation.responses[index])
);

function GenericToolRow({ message, onOpenFile }: { message: ChatMessage; onOpenFile: (path: string) => void | Promise<void> }) {
  const [expanded, setExpanded] = useState(message.kind === "error" || message.status === "failed");
  const isError = message.kind === "error" || message.status === "failed";
  const filePath = extractToolFilePath(message.text);
  const summary = toolJSONSummary(message.text) ?? toolHeaderSummary(message);
  return (
    <div className={`generic-tool-row ${isError ? "error" : ""}`}>
      <button type="button" className="generic-tool-header" onClick={() => setExpanded((value) => !value)}>
        {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        <span className="tool-card-name">{toolDisplayLabel(message)}</span>
        {filePath ? (
          <span
            className="tool-card-summary tool-card-file"
            role="link"
            tabIndex={0}
            title={filePath}
            onClick={(event) => {
              event.stopPropagation();
              void onOpenFile(filePath);
            }}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.stopPropagation();
                void onOpenFile(filePath);
              }
            }}
          >
            {summary}
          </span>
        ) : summary ? (
          <span className="tool-card-summary">{summary}</span>
        ) : null}
        {message.status ? <small>{message.status}</small> : null}
      </button>
      {expanded ? (
        <div className="tool-card-body">
          {message.subtitle ? <small className="event-card-subtitle">{message.subtitle}</small> : null}
          {message.text ? <pre>{message.text}</pre> : <p>暂无输出。</p>}
        </div>
      ) : null}
    </div>
  );
}

function toolJSONSummary(text: string): string | null {
  const object = firstJSONObject(text);
  if (object === null) {
    return null;
  }
  const value = firstStringValue(
    ["command", "cmd", "file_path", "filePath", "path", "target_file", "targetFile", "pattern", "query", "description", "summary", "title", "status", "message"],
    object
  ) ?? firstStringValue(["stdout", "stderr", "output", "result", "text", "content"], object);
  if (!value) {
    return null;
  }
  const compact = value.replace(/\n/g, " ").trim();
  return compact.length > 180 ? `${compact.slice(0, 179)}…` : compact;
}

function ReadToolCard({ payload, onOpenFile }: { payload: ReadToolPayload; onOpenFile: (path: string) => void | Promise<void> }) {
  const fileName = payload.path ? basename(payload.path) : "文件";
  const previewLines = payload.lines.slice(0, 80);
  return (
    <div className="chat-event-row transcript-event-card read-tool-card">
      <div className="event-card-header tool-card-header">
        <FileText size={12} />
        {payload.path ? (
          <button type="button" className="tool-card-summary tool-card-file" title={payload.path} onClick={() => void onOpenFile(payload.path!)}>
            {fileName}
          </button>
        ) : (
          <span className="tool-card-name">{fileName}</span>
        )}
        <small>{payload.lines.length} lines</small>
      </div>
      <div className="read-tool-body">
        {previewLines.map((line, index) => (
          <div className="read-tool-line" key={index}>
            <span className="read-tool-ln">{payload.startLine + index}</span>
            <code>{line || " "}</code>
          </div>
        ))}
        {payload.lines.length > 80 ? <p className="read-tool-more">… 还有 {payload.lines.length - 80} 行</p> : null}
      </div>
    </div>
  );
}

function SearchToolCard({ payload }: { payload: SearchToolPayload }) {
  const rows = payload.rows.slice(0, 80);
  return (
    <div className="chat-event-row transcript-event-card search-tool-card">
      <div className="event-card-header tool-card-header">
        {payload.mode === "glob" ? <FileText size={12} /> : <Bot size={12} />}
        <span className="tool-card-name">{payload.title}</span>
        <small>{payload.rows.length} 项</small>
      </div>
      <div className="search-tool-body">
        {rows.length === 0 ? <p>{payload.mode === "glob" ? "无匹配文件" : "无匹配结果"}</p> : null}
        {rows.map((row, index) => (
          <div className="search-tool-line" key={index}>
            <code>{row}</code>
          </div>
        ))}
      </div>
    </div>
  );
}

function TerminalToolCard({ payload, status, isStreaming }: { payload: TerminalToolPayload; status?: string; isStreaming: boolean }) {
  const output = payload.output.split("\n").slice(0, 200).join("\n");
  return (
    <div className="chat-event-row transcript-event-card terminal-tool-card">
      <div className="event-card-header tool-card-header">
        <Terminal size={12} />
        <span className="tool-card-name">{payload.command ?? "command"}</span>
        <small>{payload.exitCode ? `exit ${payload.exitCode}` : (status ?? (isStreaming ? "running" : ""))}</small>
      </div>
      {payload.command ? <pre className="terminal-tool-command">$ {payload.command}</pre> : null}
      {output ? (
        <pre className="terminal-tool-output">{output}</pre>
      ) : (
        <p className="terminal-tool-empty">{isStreaming ? "命令执行中…" : "命令已执行"}</p>
      )}
    </div>
  );
}

function AgentToolCard({ payload, resultText }: { payload: AgentToolPayload; resultText: string }) {
  return (
    <div className="chat-event-row transcript-event-card agent-tool-card">
      <div className="event-card-header tool-card-header">
        <Bot size={12} />
        <span className="tool-card-name">{payload.title}</span>
        {payload.kind ? <small>{payload.kind}</small> : null}
      </div>
      {payload.prompt ? <p className="agent-tool-prompt">{payload.prompt}</p> : null}
      {resultText ? <pre className="agent-tool-result">{resultText.slice(0, 2000)}</pre> : null}
    </div>
  );
}

function TodoToolCard({ rows }: { rows: TodoToolItem[] }) {
  return (
    <div className="chat-event-row transcript-event-card todo-tool-card">
      <div className="event-card-header tool-card-header">
        <Check size={12} />
        <span className="tool-card-name">任务清单</span>
        <small>{rows.length} 项</small>
      </div>
      <div className="todo-tool-body">
        {rows.map((row, index) => (
          <div className={`todo-tool-line status-${row.status || "pending"}`} key={index}>
            <span className="todo-tool-check">{row.status === "completed" ? "☑" : row.status === "in_progress" ? "◐" : "☐"}</span>
            <span>{row.content}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/// Runs of ≥2 read/grep/glob invocations collapse into one batch card (Mac
/// coalesceToolBatches parity) so file-scanning runs stay out of the way.
const ToolBatchCard = memo(function ToolBatchCard({
  invocations,
  onOpenFile
}: {
  invocations: ToolInvocation[];
  onOpenFile: (path: string) => void | Promise<void>;
}) {
  const [expanded, setExpanded] = useState(false);
  const readCount = invocations.filter((invocation) => toolName(invocation.primary).toLowerCase() === "read").length;
  const grepCount = invocations.filter((invocation) => toolName(invocation.primary).toLowerCase() === "grep").length;
  const globCount = invocations.filter((invocation) => toolName(invocation.primary).toLowerCase() === "glob").length;
  const parts = [
    readCount > 0 ? `读取 ${readCount}` : null,
    grepCount > 0 ? `搜索 ${grepCount}` : null,
    globCount > 0 ? `匹配 ${globCount}` : null
  ].filter(Boolean);
  const summary = `${parts.length > 0 ? parts.join(" · ") : "工具"} · 共 ${invocations.length} 步`;

  return (
    <div className="chat-event-row transcript-event-card tool-batch-card">
      <button type="button" className="event-card-header tool-card-header" onClick={() => setExpanded((value) => !value)}>
        {expanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
        <span className="tool-card-name">{summary}</span>
      </button>
      {expanded ? (
        <div className="tool-batch-body">
          {invocations.map((invocation) => (
            <ToolInvocationCard key={invocation.primary.id} invocation={invocation} onOpenFile={onOpenFile} />
          ))}
        </div>
      ) : null}
    </div>
  );
}, (prev, next) =>
  prev.onOpenFile === next.onOpenFile &&
  prev.invocations.length === next.invocations.length &&
  prev.invocations.every(
    (invocation, index) =>
      invocation.primary === next.invocations[index]?.primary &&
      invocation.responses.length === next.invocations[index]?.responses.length &&
      invocation.responses.every((response, responseIndex) => response === next.invocations[index]?.responses[responseIndex])
  )
);

function DiagnosticEventCard({ message }: { message: ChatMessage }) {
  return (
    <div className="chat-event-row transcript-event-card diagnostic-card">
      <div className="event-card-header">
        <span>{kindLabel(message.kind)}</span>
        {message.status ? <small>{message.status}</small> : null}
      </div>
      <p>内部事件已隐藏，避免把原始协议内容直接显示在主对话中。</p>
    </div>
  );
}

/// System messages render as a slim centered line (Mac system bubble) instead of the
/// generic "event hidden" card.
function SystemEventCard({ message }: { message: ChatMessage }) {
  return (
    <div className="chat-event-row transcript-event-card system-event-card">
      <span>{message.text || message.title || "system"}</span>
    </div>
  );
}

function PermissionRequestCard({ message }: { message: ChatMessage }) {
  const respondToPermission = useChatStore((state) => state.respondToPermission);
  const sessionCLI = useChatStore((state) => state.currentSession?.cli);
  const defaultCLI = useSettingsStore((state) => state.settings?.defaultCLI);
  // 通用 CLI 进程侧恒回 false——按钮不可点，只如实展示请求，不做假按钮。
  const capable = chatCLISupportsInteractiveControls(sessionCLI ?? defaultCLI ?? "claude");
  const waiting = capable && message.status === "waiting";

  function respond(decision: PermissionDecision) {
    if (message.requestID) {
      void respondToPermission(message.requestID, decision);
    }
  }

  return (
    <div className="chat-event-row permission-card">
      <span>{message.title || "permission"}</span>
      <p>{message.text}</p>
      <div className="permission-actions">
        <button type="button" disabled={!waiting} onClick={() => respond("deny")}>
          拒绝
        </button>
        <button type="button" disabled={!waiting} onClick={() => respond("allow")}>
          允许一次
        </button>
        <button type="button" disabled={!waiting} onClick={() => respond("allowForSession")}>
          本会话允许
        </button>
      </div>
      {!capable && message.status === "waiting" ? <small>当前 CLI 不支持会话内权限交互，请改用权限模式后重试。</small> : null}
    </div>
  );
}

function InteractiveRequestCard({ request }: { request: InteractiveRequest }) {
  const [selectedOptionIDs, setSelectedOptionIDs] = useState<string[]>([]);
  const [customText, setCustomText] = useState("");
  const respondToInteractiveRequest = useChatStore((state) => state.respondToInteractiveRequest);
  const sessionCLI = useChatStore((state) => state.currentSession?.cli);
  const defaultCLI = useSettingsStore((state) => state.settings?.defaultCLI);
  const capable = chatCLISupportsInteractiveControls(sessionCLI ?? defaultCLI ?? "claude");
  const waiting = capable && request.status === "waiting";
  // text 模式也要求非空：空提交会让后端回 false 走 failed，属于假可点。
  const canSubmit = waiting && (selectedOptionIDs.length > 0 || customText.trim().length > 0);

  function toggleOption(optionID: string) {
    setSelectedOptionIDs((current) => {
      if (request.mode === "singleChoice") {
        return [optionID];
      }
      return current.includes(optionID) ? current.filter((id) => id !== optionID) : [...current, optionID];
    });
  }

  function submit(optionID?: string) {
    if (!waiting) {
      return;
    }
    const optionIDs = optionID ? [optionID] : selectedOptionIDs;
    void respondToInteractiveRequest({
      requestID: request.id,
      selectedOptionIDs: optionIDs,
      customText: customText.trim() || null
    });
  }

  return (
    <div className="chat-event-row interactive-card">
      <span>{request.title}</span>
      <p>{request.prompt}</p>
      {request.options.length > 0 ? (
        <div className="interactive-options">
          {request.options.map((option) => {
            const active = selectedOptionIDs.includes(option.id);
            return (
              <button
                key={option.id}
                type="button"
                className={active ? "active" : ""}
                disabled={!waiting}
                onClick={() => {
                  toggleOption(option.id);
                  if (request.mode === "singleChoice" && !request.allowCustomInput) {
                    submit(option.id);
                  }
                }}
              >
                <b>{option.label}</b>
                {option.detail ? <small>{option.detail}</small> : null}
              </button>
            );
          })}
        </div>
      ) : null}
      {request.allowCustomInput || request.mode === "text" ? (
        <textarea
          value={customText}
          disabled={!waiting}
          placeholder={request.placeholder || "输入回复"}
          onChange={(event) => setCustomText(event.target.value)}
        />
      ) : null}
      <div className="permission-actions">
        <button type="button" disabled={!canSubmit} onClick={() => submit()}>
          提交
        </button>
      </div>
      {!capable && request.status === "waiting" ? <small>当前 CLI 不支持会话内交互，此问题仅供参考。</small> : null}
    </div>
  );
}

function MessageAttachmentStrip({ attachments }: { attachments: ChatMessageAttachment[] }) {
  const openFile = useEditorStore((state) => state.openFile);
  if (attachments.length === 0) {
    return null;
  }
  return (
    <div className="message-attachments">
      {attachments.map((attachment) => (
        <button key={attachment.id} type="button" onClick={() => void openFile(attachment.path)} title={attachment.path}>
          <FileText size={12} />
          {attachment.filename}
        </button>
      ))}
    </div>
  );
}

function formatMessageTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).format(date);
}
