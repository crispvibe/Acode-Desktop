import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import type {
  ChatBackendEvent,
  ChatMessageAttachment,
  ChatMessageKind,
  ChatRunOptions,
  ChatSessionRecord
} from "../../shared/chat.js";
import { chatCLIDefaultCommands, chatCLIDisplayNames, type ChatCLI } from "../../shared/chat.js";

/// 除 claude/codex 外接入的 7 个大厂 CLI。
export type GenericCLIKind = Exclude<ChatCLI, "claude" | "codex">;

type JSONRecord = Record<string, unknown>;

/// 一条 CLI 的完整运行描述：二进制、参数、逐行事件映射。
/// parseLine 是纯函数，可脱离 spawn 单测。
export interface GenericCLIRunSpec {
  kind: GenericCLIKind;
  displayName: string;
  command: string;
  args: string[];
  /// stdout 上非 JSON 行是否算模型正文（kimi/agy/kiro 的 stream-json 未完全核验，
  /// 文本兜底成立时开）；为 false 时非 JSON 行降级为 rawOutput（对齐 claude 处理）。
  plainStdoutIsResponse: boolean;
  parseLine: (line: string, state: GenericStreamState) => ChatBackendEvent[];
}

/// stream-json 解析的跨行状态：assistant 文本去重（delta vs 全量快照两种上游都兼容）、
/// tool_use→tool_result 配对去重、终态 result 去重。
export interface GenericStreamState {
  assistantText: string;
  sawAssistantOutput: boolean;
  emittedItemIDs: Set<string>;
  sawTerminalResult: boolean;
}

export function createGenericStreamState(): GenericStreamState {
  return {
    assistantText: "",
    sawAssistantOutput: false,
    emittedItemIDs: new Set(),
    sawTerminalResult: false
  };
}

/// cli → 运行参数 + 行解析器。flag 依据各 CLI `--help`/官方文档实测：
/// - cursor: `cursor-agent --help`（2026.09 实测）：-p/--print、--output-format stream-json、
///   --stream-partial-output、--model、--resume [chatId]、--continue、--force/--yolo、
///   --auto-review、--trust、--approve-mcps。
/// - gemini/qwen（0.60 实测 + qwen-code 同系 fork）：-p/--prompt、-o stream-json、-m/--model、
///   --approval-mode default|auto_edit|yolo、-r latest|index（不支持任意 session id → resume 忽略）。
/// - copilot：`copilot -p <prompt> --output-format json -s` JSONL；--allow-all-tools、--model、
///   --resume=<id>、--continue。
/// - kimi（官方文档）：--print -p、--output-format stream-json、--model、--continue、
///   --session <id>；--print 隐含自动批准，不能再传 --yolo/--auto。
/// - agy（官方文档）：-p/--print、--output-format text|json|stream-json、--model（显示名）、
///   --dangerously-skip-permissions；无 resume；已知非 TTY stdout 可能无输出（上游 bug）。
/// - kiro（官方文档）：kiro-cli chat --no-interactive [--output-format stream-json]、
///   --trust-all-tools/--trust-tools=...、--resume/-r、--resume-id <id>、--effort low..max、--model。
export function genericCLIRunSpec(
  cli: GenericCLIKind,
  options: ChatRunOptions,
  session: Pick<ChatSessionRecord, "externalSessionID"> | null,
  prompt: string,
  attachments: ChatMessageAttachment[] = []
): GenericCLIRunSpec {
  const displayName = chatCLIDisplayNames[cli];
  const command = chatCLIDefaultCommands[cli];
  const promptText = promptWithAttachments(prompt, attachments);
  const model = isExplicitModelID(options.modelID) ? options.modelID : null;
  const resumeID = options.resumeSessionID?.trim() || session?.externalSessionID?.trim() || "";
  const resumeRequested = options.sessionMode === "resume" && Boolean(resumeID);
  const continueRequested = options.sessionMode === "continueLast";

  switch (cli) {
    case "cursor": {
      const args = ["-p", "--output-format", "stream-json", "--stream-partial-output", "--trust"];
      if (options.permissionMode === "autoEdit") {
        // 无头模式下 --force 全放行太宽；auto-review 由服务端分类器自动跑安全工具。
        args.push("--auto-review");
      } else if (options.permissionMode === "fullAccess") {
        args.push("--force", "--approve-mcps");
      }
      if (model) {
        args.push("--model", model);
      }
      if (continueRequested) {
        args.push("--continue");
      } else if (resumeRequested) {
        args.push("--resume", resumeID);
      }
      // prompt 是位置参数；-- 防 prompt 以 - 开头被当 flag。
      args.push("--", promptText);
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: false, parseLine: (line, state) => parseStreamJSONLine(line, state, { displayName, plainStdoutIsResponse: false }) };
    }
    case "gemini":
    case "qwen": {
      const args = ["-p", promptText, "-o", "stream-json", "--approval-mode", geminiApprovalMode(options.permissionMode)];
      if (model) {
        args.push("-m", model);
      }
      if (continueRequested) {
        // gemini --resume 只接受 "latest"|index；任意 session id 不支持 → resume 走新会话。
        args.push("-r", "latest");
      }
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: false, parseLine: (line, state) => parseStreamJSONLine(line, state, { displayName, plainStdoutIsResponse: false }) };
    }
    case "copilot": {
      const args = ["-p", promptText, "--output-format", "json", "-s"];
      // 无头模式没有逐工具审批通道，非 ask 一律全量放行（CLI 侧粒度只有 allow/deny）。
      if (options.permissionMode !== "ask") {
        args.push("--allow-all-tools");
      }
      if (model) {
        args.push("--model", model);
      }
      if (continueRequested) {
        args.push("--continue");
      } else if (resumeRequested) {
        args.push(`--resume=${resumeID}`);
      }
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: false, parseLine: parseCopilotLine };
    }
    case "kimi": {
      const args = ["--print", "-p", promptText, "--output-format", "stream-json"];
      if (model) {
        args.push("--model", model);
      }
      if (continueRequested) {
        args.push("--continue");
      } else if (resumeRequested) {
        args.push("--session", resumeID);
      }
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: true, parseLine: (line, state) => parseStreamJSONLine(line, state, { displayName, plainStdoutIsResponse: true }) };
    }
    case "agy": {
      const args = ["-p", promptText, "--output-format", "stream-json"];
      if (options.permissionMode === "fullAccess") {
        args.push("--dangerously-skip-permissions");
      }
      if (model) {
        args.push("--model", model);
      }
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: true, parseLine: (line, state) => parseStreamJSONLine(line, state, { displayName, plainStdoutIsResponse: true }) };
    }
    case "kiro": {
      const args = ["chat", "--no-interactive", "--output-format", "stream-json"];
      if (options.permissionMode === "autoEdit") {
        args.push("--trust-tools=read,grep,write");
      } else if (options.permissionMode === "fullAccess") {
        args.push("--trust-all-tools");
      }
      if (model) {
        args.push("--model", model);
      }
      args.push("--effort", options.reasoningEffort);
      if (continueRequested) {
        args.push("--resume");
      } else if (resumeRequested) {
        args.push("--resume-id", resumeID);
      }
      args.push("--", promptText);
      return { kind: cli, displayName, command, args, plainStdoutIsResponse: true, parseLine: (line, state) => parseStreamJSONLine(line, state, { displayName, plainStdoutIsResponse: true }) };
    }
  }
}

/// Windows 二进制探测：裸命令名经 where.exe 解析；命中 .cmd/.bat shim（npm 全局安装的
/// gemini/qwen/copilot 都是这种）时不能直接 spawn（Node 拒绝无 shell 执行 .cmd），
/// 也不能走 cmd.exe /c（参数里的双引号/元字符无可靠转义，& | 有注入风险）。
/// 走 powershell -Command & 调用运算符：单引号参数串全字面，'→'' 是唯一转义，注入免疫。
export interface SpawnTarget {
  file: string;
  args: string[];
}

const execFileAsync = promisify(execFile);

export async function resolveSpawnTarget(command: string, args: string[]): Promise<SpawnTarget> {
  if (process.platform !== "win32") {
    return { file: command, args };
  }
  const resolved = await resolveWindowsExecutable(command);
  const target = resolved ?? command;
  if (/\.(cmd|bat)$/i.test(target)) {
    return powershellShim(target, args);
  }
  return { file: target, args };
}

async function resolveWindowsExecutable(command: string): Promise<string | null> {
  // 已经是带扩展名的路径就原样用（用户 profile 里可能填了完整 .cmd 路径）。
  if (path.extname(command) || command.includes("\\") || command.includes("/")) {
    return command;
  }
  try {
    const { stdout } = await execFileAsync("where.exe", [command], { timeout: 5000, windowsHide: true });
    const candidates = stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    // .exe 优先（无需 shim），其次任意可执行结果（.cmd/.bat 走 powershell shim）。
    return candidates.find((candidate) => /\.(exe|com)$/i.test(candidate)) ?? candidates[0] ?? null;
  } catch {
    return null;
  }
}

function powershellShim(command: string, args: string[]): SpawnTarget {
  const quote = (value: string) => `'${value.replace(/'/g, "''")}'`;
  const invocation = `& ${quote(command)} ${args.map(quote).join(" ")}`.trimEnd();
  return {
    file: "powershell.exe",
    args: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", invocation]
  };
}

// ---------------------------------------------------------------------------
// 通用 stream-json 行 → ChatBackendEvent 映射
// 覆盖 claude 系（cursor/kimi）+ gemini 系（gemini/qwen）+ agy/kiro 已知事件形状；
// 不认识的 JSON 事件一律丢弃（对齐 codex default 分支），非 JSON 行按 spec 降级。
// ---------------------------------------------------------------------------

function parseStreamJSONLine(line: string, state: GenericStreamState, spec?: Pick<GenericCLIRunSpec, "displayName" | "plainStdoutIsResponse">): ChatBackendEvent[] {
  const displayName = spec?.displayName ?? "CLI";
  const object = parseJSONObject(line);
  if (!object) {
    if (spec?.plainStdoutIsResponse && line.trim()) {
      return [{ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: displayName, text: `${line}\n`, status: "streaming" }];
    }
    return [{ type: "appendMessage", kind: "rawOutput", title: "raw", subtitle: displayName, text: line, status: "stream" }];
  }

  const events: ChatBackendEvent[] = [];
  const sessionID = stringValue(object.session_id) ?? stringValue(object.sessionId) ?? stringValue(object.sessionID);
  if (sessionID) {
    events.push({ type: "sessionID", externalSessionID: sessionID });
  }
  const usage = tokenUsageEvent(object);
  if (usage) {
    events.push(usage);
  }

  const type = (stringValue(object.type) ?? stringValue(object.event) ?? "raw").toLowerCase();
  const subtype = stringValue(object.subtype)?.toLowerCase() ?? "";
  const role = stringValue(object.role)?.toLowerCase() ?? "";

  // user 回声 / 控制帧不展示。
  if (type === "user" || type === "control_request" || type === "control_cancel_request" || role === "user") {
    return events;
  }

  // 会话初始化：system.subtype=init（claude/cursor）、type=init（gemini/agy）。
  if ((type === "system" && subtype === "init") || type === "init") {
    const model = stringValue(object.model) ?? stringValue(object.model_id);
    events.push({ type: "updateStreamingStatus", status: model ? `${displayName} · ${model}` : `${displayName} 已连接` });
    return events;
  }

  // claude/cursor/kimi：assistant 事件带 message.content[] 内容块。
  if (type === "assistant") {
    events.push(...assistantMessageEvents(object, state, displayName));
    return events;
  }

  // gemini/agy：message 事件按 role 区分。
  if (type === "message") {
    if (role === "assistant") {
      events.push(...assistantTextEvents(stringValue(object.content) ?? stringValue(object.text), state, displayName));
    }
    return events;
  }

  // cursor：tool_call 事件按 subtype started/completed 区分。
  if (type === "tool_call" || type === "toolcall") {
    events.push(...cursorToolCallEvents(object, subtype, state, displayName));
    return events;
  }

  // gemini/copilot-扁平：tool_use / tool_result。
  if (type === "tool_use" || type === "tooluse" || type === "tool_start") {
    events.push(...toolUseEvents(object, state, displayName));
    return events;
  }
  if (type === "tool_result" || type === "toolresult" || type === "tool_end" || type === "tool_output") {
    events.push(...toolResultEvents(object, displayName));
    return events;
  }

  // agy：step_update 表示一次工具/推理步骤。
  if (type === "step_update" || type === "stepupdate" || type === "step") {
    const step = recordValue(object.step) ?? object;
    const title = stringValue(step.name) ?? stringValue(step.tool_name) ?? stringValue(step.title) ?? "step";
    const text = stringValue(step.output) ?? stringValue(step.text) ?? compactText(step);
    events.push({ type: "appendMessage", kind: "toolCall", title, subtitle: displayName, text, status: "done", requestID: requestIDOf(object) });
    return events;
  }

  // 终态：result / turn_end / done / completed。
  if (type === "result" || type === "turn_end" || type === "done" || type === "completed") {
    events.push(...terminalResultEvents(object, subtype, state, displayName));
    return events;
  }

  // 错误事件：error / *_error / exception。
  if (type === "error" || type.endsWith("_error") || type === "exception" || type === "session.error") {
    const text = errorTextOf(object);
    events.push({ type: "appendMessage", kind: "error", title: displayName, subtitle: type, text, status: "failed", requestID: requestIDOf(object) });
    return events;
  }

  // 兜底：带 text/content 的不明事件当 assistant 输出，纯协议帧丢弃。
  const looseText = stringValue(object.delta) ?? (typeof object.content === "string" ? object.content : null) ?? stringValue(object.text);
  if (looseText && (type.includes("delta") || type.includes("chunk") || type.includes("text") || type === "raw")) {
    events.push(...assistantTextEvents(looseText, state, displayName));
  }
  return events;
}

/// copilot `--output-format json` 的 JSONL：{type:"dotted.name"|"snake_name", data:{...} | 扁平字段}。
/// 事件名来自社区集成与官方 changelog：session.start、assistant.message_delta（增量）、
/// assistant.message（整轮全文，需与已发 delta 去重）、tool_use/tool_result（扁平）、usage、
/// result、session.error/session.idle。
function parseCopilotLine(line: string, state: GenericStreamState): ChatBackendEvent[] {
  const object = parseJSONObject(line);
  if (!object) {
    return line.trim()
      ? [{ type: "appendMessage", kind: "rawOutput", title: "raw", subtitle: "Copilot", text: line, status: "stream" }]
      : [];
  }

  const data = recordValue(object.data) ?? object;
  const type = (stringValue(object.type) ?? stringValue(object.event) ?? "").toLowerCase();
  const events: ChatBackendEvent[] = [];

  const sessionID =
    stringValue(object.session_id) ?? stringValue(object.sessionId) ??
    stringValue(data.session_id) ?? stringValue(data.sessionId);
  if (sessionID) {
    events.push({ type: "sessionID", externalSessionID: sessionID });
  }
  const usage = tokenUsageEvent(data) ?? tokenUsageEvent(object);
  if (usage) {
    events.push(usage);
  }

  switch (type) {
    case "session.start":
    case "session_start":
    case "session.started": {
      events.push({ type: "updateStreamingStatus", status: "Copilot 已连接" });
      return events;
    }
    case "assistant.message_delta":
    case "assistant.delta":
    case "message.delta": {
      const delta = stringValue(data.deltaContent) ?? stringValue(data.delta_content) ?? stringValue(data.delta) ?? stringValue(data.content);
      if (delta) {
        state.assistantText += delta;
        state.sawAssistantOutput = true;
        events.push({ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Copilot", text: delta, status: "streaming" });
      }
      return events;
    }
    case "assistant.message":
    case "assistant_message": {
      events.push(...assistantTextEvents(stringValue(data.content) ?? stringValue(data.text), state, "Copilot"));
      return events;
    }
    case "tool_use":
    case "tool.execution_start":
    case "tool_execution_start": {
      events.push(...toolUseEvents(data, state, "Copilot"));
      return events;
    }
    case "tool_result":
    case "tool.execution_complete":
    case "tool_execution_complete": {
      events.push(...toolResultEvents(data, "Copilot"));
      return events;
    }
    case "usage":
    case "turn.usage":
    case "session.usage": {
      return events;
    }
    case "result":
    case "turn.completed":
    case "session.idle":
    case "session.end": {
      if (state.sawTerminalResult) {
        return events;
      }
      state.sawTerminalResult = true;
      const status = (stringValue(data.status) ?? stringValue(object.status) ?? "").toLowerCase();
      const resultText = stringValue(data.result) ?? stringValue(data.response) ?? stringValue(data.content);
      if (!state.sawAssistantOutput && resultText) {
        state.sawAssistantOutput = true;
        events.push({ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Copilot", text: resultText, status: "streaming" });
      }
      const failed = ["error", "failed", "failure"].includes(status) || boolValue(data.is_error) === true || boolValue(object.is_error) === true;
      events.push(failed
        ? { type: "failed", message: errorTextOf(data) || `Copilot 退出：${status || "error"}` }
        : { type: "finished" });
      return events;
    }
    case "error":
    case "session.error": {
      const text = errorTextOf(data) || errorTextOf(object) || "Copilot 运行失败。";
      events.push({ type: "appendMessage", kind: "error", title: "Copilot", subtitle: type, text, status: "failed", requestID: requestIDOf(object) });
      return events;
    }
    case "abort":
    case "session.abort": {
      events.push({ type: "failed", message: "Copilot 已停止。" });
      return events;
    }
    default:
      return events;
  }
}

// ---------------------------------------------------------------------------
// 各形状共用的事件构造
// ---------------------------------------------------------------------------

/// assistant 文本入口：上游可能是增量 delta 也可能是累计快照，用累计差分兼容两种。
function assistantTextEvents(text: string | null, state: GenericStreamState, displayName: string): ChatBackendEvent[] {
  if (!text) {
    return [];
  }
  const delta = textDelta(state.assistantText, text);
  state.assistantText = text;
  if (!delta) {
    return [];
  }
  state.sawAssistantOutput = true;
  return [{ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: displayName, text: delta, status: "streaming" }];
}

/// claude/cursor/kimi 的 assistant.message.content[] 内容块：
/// text→assistant delta、thinking→reasoning delta、tool_use→toolCall、tool_result→toolResult。
function assistantMessageEvents(object: JSONRecord, state: GenericStreamState, displayName: string): ChatBackendEvent[] {
  const events: ChatBackendEvent[] = [];
  const message = recordValue(object.message);
  const content = message?.content ?? object.content;

  // cursor --stream-partial-output 的增量形态：content 是字符串或 [{type:text,text:chunk}]。
  const directText = typeof content === "string" ? content : null;
  if (directText !== null) {
    events.push(...assistantTextEvents(directText, state, displayName));
  }
  if (!Array.isArray(content)) {
    return events;
  }

  for (const raw of content) {
    const item = recordValue(raw);
    if (!item) {
      continue;
    }
    const itemType = (stringValue(item.type) ?? "text").toLowerCase();
    const id = stringValue(item.id) ?? stringValue(item.tool_use_id);
    if (itemType === "text") {
      events.push(...assistantTextEvents(stringValue(item.text), state, displayName));
      continue;
    }
    if (itemType === "thinking") {
      const text = stringValue(item.thinking) ?? stringValue(item.text);
      if (text) {
        events.push({ type: "appendDelta", kind: "reasoning", title: "thinking", subtitle: displayName, text, status: "streaming", requestID: id });
      }
      continue;
    }
    // 非文本块按 id 去重：同一块可能在多行 assistant 事件里重复出现。
    if (id && state.emittedItemIDs.has(id)) {
      continue;
    }
    if (id) {
      state.emittedItemIDs.add(id);
    }
    if (itemType === "tool_result") {
      events.push({
        type: "appendMessage",
        kind: "toolResult",
        title: "tool_result",
        subtitle: stringValue(item.name) ?? displayName,
        text: compactText(item),
        status: boolValue(item.is_error) === true ? "failed" : "done",
        requestID: stringValue(item.tool_use_id) ?? id
      });
      continue;
    }
    if (itemType === "tool_use" || itemType === "tool_call") {
      const name = stringValue(item.name) ?? "tool";
      events.push({
        type: "appendMessage",
        kind: "toolCall",
        title: name,
        subtitle: displayName,
        text: toolCallText(name, item.input ?? item.parameters ?? item.arguments),
        status: "done",
        requestID: id
      });
      continue;
    }
  }
  return events;
}

/// cursor 的 {type:"tool_call", subtype:"started"|"completed", tool_call:{...}}。
function cursorToolCallEvents(object: JSONRecord, subtype: string, state: GenericStreamState, displayName: string): ChatBackendEvent[] {
  const toolCall = recordValue(object.tool_call) ?? object;
  const requestID = stringValue(object.call_id) ?? stringValue(object.tool_call_id) ?? requestIDOf(toolCall);
  const name = stringValue(toolCall.name) ?? stringValue(recordValue(toolCall.function)?.name) ?? "tool";
  const isCompleted = subtype === "completed" || subtype === "done" || subtype === "finished" || subtype === "result";
  const kind: ChatMessageKind = isCompleted ? "toolResult" : "toolCall";
  if (requestID && state.emittedItemIDs.has(`${kind}:${requestID}`)) {
    return [];
  }
  if (requestID) {
    state.emittedItemIDs.add(`${kind}:${requestID}`);
  }
  const output = stringValue(toolCall.output) ?? stringValue(toolCall.result) ?? stringValue(recordValue(toolCall.result)?.output);
  return [{
    type: "appendMessage",
    kind,
    title: name,
    subtitle: displayName,
    text: isCompleted ? (output ?? compactText(toolCall)) : toolCallText(name, toolCall.input ?? toolCall.args ?? toolCall.arguments ?? toolCall.parameters),
    status: isCompleted ? (boolValue(toolCall.is_error) === true ? "failed" : "done") : "streaming",
    requestID
  }];
}

/// 扁平 tool_use：gemini {tool_name,tool_id,parameters} / copilot {name,input,id} / kiro 变体。
function toolUseEvents(object: JSONRecord, state: GenericStreamState, displayName: string): ChatBackendEvent[] {
  const requestID = stringValue(object.tool_id) ?? stringValue(object.id) ?? requestIDOf(object);
  if (requestID && state.emittedItemIDs.has(`toolCall:${requestID}`)) {
    return [];
  }
  if (requestID) {
    state.emittedItemIDs.add(`toolCall:${requestID}`);
  }
  const name = stringValue(object.tool_name) ?? stringValue(object.name) ?? stringValue(object.tool) ?? "tool";
  return [{
    type: "appendMessage",
    kind: "toolCall",
    title: name,
    subtitle: displayName,
    text: toolCallText(name, object.parameters ?? object.input ?? object.arguments ?? object.args),
    status: "done",
    requestID
  }];
}

function toolResultEvents(object: JSONRecord, displayName: string): ChatBackendEvent[] {
  const statusText = (stringValue(object.status) ?? "").toLowerCase();
  const failed = boolValue(object.is_error) === true || ["error", "failed", "failure", "denied"].includes(statusText);
  return [{
    type: "appendMessage",
    kind: "toolResult",
    title: stringValue(object.tool_name) ?? stringValue(object.name) ?? "tool_result",
    subtitle: displayName,
    text: stringValue(object.output) ?? stringValue(object.content) ?? stringValue(object.result) ?? compactText(object),
    status: failed ? "failed" : "done",
    requestID: stringValue(object.tool_id) ?? stringValue(object.tool_use_id) ?? requestIDOf(object)
  }];
}

/// 终态 result：subtype/status/is_error 任一指明失败都算失败；成功时若全程没流式输出，
/// 用 result 文本兜底一条 assistant 消息（一次性输出的 CLI 走这条路）。
function terminalResultEvents(object: JSONRecord, subtype: string, state: GenericStreamState, displayName: string): ChatBackendEvent[] {
  if (state.sawTerminalResult) {
    return [];
  }
  state.sawTerminalResult = true;
  const events: ChatBackendEvent[] = [];
  const status = (stringValue(object.status) ?? subtype).toLowerCase();
  const resultText = stringValue(object.result) ?? stringValue(object.response) ?? stringValue(object.message);
  if (!state.sawAssistantOutput && resultText) {
    state.sawAssistantOutput = true;
    events.push({ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: displayName, text: resultText, status: "streaming" });
  }
  const failed =
    boolValue(object.is_error) === true ||
    (status.length > 0 && !["success", "succeeded", "ok", "done", "completed"].includes(status));
  if (failed) {
    events.push({ type: "failed", message: errorTextOf(object) || resultText || `${displayName} 退出：${status || "error"}` });
    return events;
  }
  events.push({ type: "finished" });
  return events;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function geminiApprovalMode(mode: ChatRunOptions["permissionMode"]): string {
  if (mode === "fullAccess") {
    return "yolo";
  }
  return mode === "autoEdit" ? "auto_edit" : "default";
}

function isExplicitModelID(modelID: string): boolean {
  const normalized = modelID.trim().toLowerCase();
  return normalized.length > 0 && normalized !== "default";
}

/// 累计差分：上游发全量快照时取后缀增量；上游发纯 delta 时整体返回。
/// （delta 流恰好以前一条 delta 开头属于退化场景，接受极小概率的边界误差换取
///   对 cumulative/delta 两种上游的统一兼容。）
function textDelta(previous: string, text: string): string {
  if (!previous) {
    return text;
  }
  if (text.startsWith(previous)) {
    return text.slice(previous.length);
  }
  return text === previous ? "" : text;
}

function requestIDOf(object: JSONRecord): string | null {
  return stringValue(object.request_id) ?? stringValue(object.requestId) ?? stringValue(object.id) ?? stringValue(object.call_id);
}

function errorTextOf(object: JSONRecord): string {
  const direct = stringValue(object.message) ?? stringValue(object.error) ?? stringValue(object.reason);
  if (direct) {
    return direct;
  }
  const error = recordValue(object.error);
  if (error) {
    const message = stringValue(error.message) ?? stringValue(error.error);
    if (message) {
      const code = stringValue(error.code) ?? stringValue(error.type);
      return [code, message].filter((value): value is string => Boolean(value?.trim())).join(": ");
    }
    return compactText(error);
  }
  return compactText(object);
}

/// token 用量：扁平 usage（copilot/gemini stats）与嵌套 usage 对象都收。
/// used = input + output（无 cache 概念时就是全部占用）；total 只认显式 context_window/total。
function tokenUsageEvent(object: JSONRecord): ChatBackendEvent | null {
  const usage = recordValue(object.usage) ?? recordValue(object.stats) ?? recordValue(recordValue(object.message)?.usage);
  if (!usage) {
    return null;
  }
  const input = intValue(usage.input_tokens) ?? intValue(usage.inputTokens) ?? intValue(usage.input) ?? intValue(usage.prompt_tokens) ?? 0;
  const output = intValue(usage.output_tokens) ?? intValue(usage.outputTokens) ?? intValue(usage.output) ?? intValue(usage.completion_tokens) ?? 0;
  const reportedTotal = intValue(usage.total_tokens) ?? intValue(usage.totalTokens) ?? intValue(usage.total) ?? 0;
  const used = input + output || reportedTotal;
  const total = intValue(usage.context_window) ?? 0;
  return used > 0 || total > 0 ? { type: "tokenUsage", used, total, output } : null;
}

function promptWithAttachments(prompt: string, attachments: ChatMessageAttachment[]): string {
  const text = prompt.trim();
  if (attachments.length === 0) {
    return text;
  }
  const attachmentLines = attachments.map((attachment) => `- ${attachment.filename}: ${attachment.path}`);
  const lead = text || "请根据以下附件继续处理。";
  return `${lead}\n\n附件:\n${attachmentLines.join("\n")}`;
}

const fileChangeToolNames = new Set(["edit", "write", "multiedit", "create", "create_file", "new_file", "notebookedit"]);

function toolCallText(name: string | null | undefined, input: unknown): string {
  if (name && fileChangeToolNames.has(name.toLowerCase())) {
    const record = recordValue(input);
    if (record) {
      return JSON.stringify(record);
    }
  }
  return compactText(input);
}

function parseJSONObject(line: string): JSONRecord | null {
  try {
    const value = JSON.parse(line) as unknown;
    return recordValue(value);
  } catch {
    return null;
  }
}

function recordValue(value: unknown): JSONRecord | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JSONRecord : null;
}

function stringValue(value: unknown): string | null {
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return null;
}

function intValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function boolValue(value: unknown): boolean | null {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    if (["true", "1", "yes"].includes(value.toLowerCase())) {
      return true;
    }
    if (["false", "0", "no"].includes(value.toLowerCase())) {
      return false;
    }
  }
  return null;
}

function compactText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  const object = recordValue(value);
  if (!object) {
    return "";
  }
  const direct = stringValue(object.text) ?? stringValue(object.message) ?? stringValue(object.delta) ?? stringValue(object.content);
  if (direct) {
    return direct;
  }
  return JSON.stringify(object);
}
