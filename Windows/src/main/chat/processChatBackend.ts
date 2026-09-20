import { randomUUID } from "node:crypto";
import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, realpathSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type {
  ChatBackendEvent,
  ChatInteractiveRequest,
  ChatInteractiveResponse,
  ChatMessageAttachment,
  ChatMessageKind,
  ChatPermissionDecision,
  ChatRunOptions,
  ChatStartRequest
} from "../../shared/chat.js";
import { readJSONLLines } from "./jsonlReader.js";

type JSONRecord = Record<string, unknown>;
type EmitChatEvent = (event: ChatBackendEvent) => void;
type PendingCodexRequest = "initialize" | "openThread" | "startTurn" | "interrupt" | "compact";

interface PendingApproval {
  id: unknown;
  method: string;
  requestedPermissions: JSONRecord | null;
}

interface PendingInteractive {
  id: unknown;
  method: string;
}

/// One AskUserQuestion question parsed from a `can_use_tool` control_request,
/// retaining the option-id → label map so a user's selection can be turned back
/// into the `answers` map the CLI expects in `updatedInput`.
interface ParsedAskQuestion {
  text: string;
  optionLabelsByID: Map<string, string>;
}

/// A pending tool-permission / AskUserQuestion gate awaiting our control_response.
/// `input`/`toolUseID` are echoed back verbatim so the CLI runs the tool with the
/// original (or answer-augmented) input — mirrors the Mac backend's PendingControlRequest.
interface PendingClaudeControl {
  requestID: string;
  toolName: string;
  input: JSONRecord;
  toolUseID: string | null;
  questions: ParsedAskQuestion[];
}

interface ClaudeContentBlock {
  id: string | null;
  type: string;
  name: string | null;
}

interface ClaudeStreamState {
  didReceiveAssistantTextDelta: boolean;
  didReceiveStreamEventAssistantTextDelta: boolean;
  topLevelAssistantText: string;
  emittedContentItemIDs: Set<string>;
  activeBlocks: Map<number, ClaudeContentBlock>;
}

interface ClaudeAttemptFlags {
  effort: boolean;
  partialMessages: boolean;
  brief: boolean;
  permissionPromptTool: boolean;
}

interface ProcessResult {
  code: number | null;
  signal: NodeJS.Signals | null;
}

interface ClaudeAttemptResult {
  result: ProcessResult;
  diagnostics: string;
}

function createClaudeStreamState(): ClaudeStreamState {
  return {
    didReceiveAssistantTextDelta: false,
    didReceiveStreamEventAssistantTextDelta: false,
    topLevelAssistantText: "",
    emittedContentItemIDs: new Set(),
    activeBlocks: new Map()
  };
}

export class ChatProcessRun {
  private child: ChildProcessWithoutNullStreams | null = null;
  private didEmitTerminalEvent = false;
  private didReceiveVisibleOutput = false;
  private didReceiveStderr = false;
  private didInterrupt = false;
  private nextCodexID = 1;
  private pendingCodexRequests = new Map<string, PendingCodexRequest>();
  private pendingApprovals = new Map<string, PendingApproval>();
  private pendingInteractiveRequests = new Map<string, PendingInteractive>();
  private pendingClaudeControls = new Map<string, PendingClaudeControl>();
  private pendingClaudeBackgroundTasks = 0;
  private claudeStreamState = createClaudeStreamState();
  private claudeDidReceiveSuccessfulResult = false;
  private claudeDidReceiveAssistantContent = false;
  private claudeDidReceiveErrorResult = false;
  private claudeDiagnostics: string[] = [];
  private claudeDiagnosticsTruncated = false;
  private stderrTail: string[] = [];
  private activeThreadID: string | null = null;
  private activeTurnID: string | null = null;
  private waitingForCompactResult = false;

  constructor(
    private readonly request: ChatStartRequest,
    private readonly emit: EmitChatEvent
  ) {}

  get runID(): string {
    return this.request.runID;
  }

  async start(): Promise<void> {
    this.emit({ type: "updateStreamingStatus", status: `启动 ${this.request.options.cli}` });
    try {
      if (this.request.options.cli === "codex") {
        await this.startCodex();
      } else {
        await this.startClaudeWithFallbacks();
      }
    } catch (error) {
      this.emitTerminal({
        type: "failed",
        message: error instanceof Error ? error.message : String(error)
      });
    } finally {
      this.closeStdin();
      this.child = null;
      this.pendingCodexRequests.clear();
      this.pendingApprovals.clear();
      this.pendingInteractiveRequests.clear();
      this.pendingClaudeControls.clear();
    }
  }

  interrupt(): void {
    if (this.didEmitTerminalEvent) {
      return;
    }
    this.didInterrupt = true;
    if (this.request.options.cli === "codex" && this.activeThreadID && this.activeTurnID) {
      const id = this.sendCodexRequest("turn/interrupt", {
        threadId: this.activeThreadID,
        turnId: this.activeTurnID
      });
      this.pendingCodexRequests.set(String(id), "interrupt");
    }
    this.emitTerminal({ type: "failed", message: `${this.request.options.cli} 已停止。` });
    this.stopProcess();
  }

  respondToPermission(requestID: string, decision: ChatPermissionDecision): boolean {
    if (this.request.options.cli === "codex") {
      const approval = this.pendingApprovals.get(requestID);
      if (!approval) {
        return false;
      }
      this.pendingApprovals.delete(requestID);
      return this.sendCodexResponse(approval.id, this.codexApprovalResult(approval, decision));
    }

    // Claude control_response envelope — request_id lives inside `response`, and the
    // innermost `response` carries the PermissionResult (behavior/updatedInput).
    const pending = this.pendingClaudeControls.get(requestID);
    const inner: JSONRecord = {};
    if (decision !== "deny") {
      inner.behavior = "allow";
      inner.updatedInput = pending?.input ?? {};
      if (decision === "allowForSession" && pending?.toolName) {
        inner.updatedPermissions = [
          {
            type: "addRules",
            rules: [{ toolName: pending.toolName }],
            behavior: "allow",
            destination: "session"
          }
        ];
      }
    } else {
      inner.behavior = "deny";
      inner.message = "用户拒绝了该操作。";
    }
    if (pending?.toolUseID) {
      inner.toolUseID = pending.toolUseID;
    }
    const didWrite = this.writeClaudeControlResponse(requestID, inner);
    if (didWrite) {
      this.pendingClaudeControls.delete(requestID);
    }
    return didWrite;
  }

  respondToInteractiveRequest(response: ChatInteractiveResponse): boolean {
    if (this.request.options.cli === "codex") {
      const pending = this.pendingInteractiveRequests.get(response.requestID);
      if (!pending) {
        return false;
      }
      this.pendingInteractiveRequests.delete(response.requestID);
      // A single, well-formed JSON-RPC result — no `method` field, no snake_case duplicates.
      const result: JSONRecord = { selectedOptionIds: response.selectedOptionIDs };
      const custom = response.customText?.trim();
      if (custom) {
        result.text = custom;
      } else if (response.selectedOptionIDs.length > 0) {
        result.answer = response.selectedOptionIDs.join(", ");
      }
      return this.sendCodexResponse(pending.id, result);
    }

    const pending = this.pendingClaudeControls.get(response.requestID);
    if (!pending || pending.questions.length === 0) {
      // No control gate recorded: best-effort send the answer as a plain user
      // message so the turn isn't left hanging.
      const answer = response.customText?.trim() || response.selectedOptionIDs.join(", ");
      if (!answer.trim()) {
        return false;
      }
      return this.writeClaudeUserMessage(answer, response.requestID, null);
    }

    // Map selected option IDs (formatted "q{qi}o{oi}") back to per-question answer labels.
    const labelsByQuestion = new Map<number, string[]>();
    for (const optionID of response.selectedOptionIDs) {
      for (const [index, question] of pending.questions.entries()) {
        const label = question.optionLabelsByID.get(optionID);
        if (label) {
          labelsByQuestion.set(index, [...(labelsByQuestion.get(index) ?? []), label]);
          break;
        }
      }
    }
    const answers: JSONRecord = {};
    for (const [index, question] of pending.questions.entries()) {
      const labels = labelsByQuestion.get(index);
      if (labels && labels.length > 0) {
        answers[question.text] = labels.join(", ");
      }
    }
    // Free-text reply: answer the first question not already covered by an option pick.
    const custom = response.customText?.trim();
    if (custom) {
      const firstUnanswered = pending.questions.find((question) => answers[question.text] === undefined);
      if (firstUnanswered) {
        answers[firstUnanswered.text] = custom;
      } else if (pending.questions[0] && Object.keys(answers).length === 0) {
        answers[pending.questions[0].text] = custom;
      }
    }
    if (Object.keys(answers).length === 0) {
      return false;
    }
    const updatedInput: JSONRecord = { ...pending.input, answers };
    const inner: JSONRecord = { behavior: "allow", updatedInput };
    if (pending.toolUseID) {
      inner.toolUseID = pending.toolUseID;
    }
    const didWrite = this.writeClaudeControlResponse(response.requestID, inner);
    if (didWrite) {
      this.pendingClaudeControls.delete(response.requestID);
    }
    return didWrite;
  }

  sendCompact(): boolean {
    if (this.request.options.cli === "codex") {
      const id = this.sendCodexRequest("compact", {});
      this.pendingCodexRequests.set(String(id), "compact");
      return true;
    }
    // Claude：以 stream-json 用户消息写入 /compact 斜杠命令。当前 turn 的 result 行
    // 到达时不能关 stdin（claude 是长驻进程，关了就把排队中的压缩干掉了），要等
    // 压缩自己的 result 再关——见 handleClaudeLine 的 result 处理。
    if (!this.request.options.supportsStreamJSONInput) {
      return false;
    }
    const didWrite = this.writeClaudeUserMessage("/compact", null, null);
    if (didWrite) {
      this.waitingForCompactResult = true;
    }
    return didWrite;
  }

  /// Claude CLI flags evolve between releases: --effort / --include-partial-messages /
  /// --brief / --permission-prompt-tool may not exist on older versions. Retry the run
  /// without a rejected flag (matching the Mac backend's fallback ladder) instead of
  /// dying on "unknown option" — the run keeps working, just with less streaming fidelity.
  private async startClaudeWithFallbacks(): Promise<void> {
    const flags: ClaudeAttemptFlags = { effort: true, partialMessages: true, brief: true, permissionPromptTool: true };
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const outcome = await this.runClaudeAttempt(flags);
      const diagnostics = outcome.diagnostics.toLowerCase();
      const rejected = !this.didInterrupt && !this.didEmitTerminalEvent && outcome.result.code !== null && outcome.result.code !== 0;
      if (rejected && flags.permissionPromptTool && claudeFlagRejected(diagnostics, "permission-prompt-tool")) {
        flags.permissionPromptTool = false;
        this.emitClaudeFallbackNotice("当前 Claude Code 没有接受 --permission-prompt-tool，本次已改用默认权限处理重试。");
        continue;
      }
      if (rejected && flags.brief && claudeFlagRejected(diagnostics, "brief")) {
        flags.brief = false;
        this.emitClaudeFallbackNotice("当前 Claude Code 没有接受 --brief，本次已关闭内嵌用户交互工具后重试。");
        continue;
      }
      if (rejected && flags.partialMessages && claudeFlagRejected(diagnostics, "include-partial-messages")) {
        flags.partialMessages = false;
        this.emitClaudeFallbackNotice("当前 Claude Code 没有接受 --include-partial-messages，本次已自动改用普通 stream-json 重试。");
        continue;
      }
      if (rejected && flags.effort && claudeFlagRejected(diagnostics, "effort")) {
        flags.effort = false;
        this.emitClaudeFallbackNotice("当前 Claude Code 没有接受 --effort，本次已自动改用默认思考强度重试。");
        continue;
      }
      this.finishClaudeRun(outcome.result);
      return;
    }
  }

  private emitClaudeFallbackNotice(text: string): void {
    this.emit({
      type: "appendMessage",
      kind: "system",
      title: "Claude Code",
      subtitle: "fallback",
      text,
      status: "retry"
    });
  }

  private async runClaudeAttempt(flags: ClaudeAttemptFlags): Promise<ClaudeAttemptResult> {
    const options = this.request.options;
    // Per-attempt state: a rejected-flag retry re-runs from scratch.
    this.claudeStreamState = createClaudeStreamState();
    this.pendingClaudeControls.clear();
    this.pendingClaudeBackgroundTasks = 0;
    this.claudeDidReceiveSuccessfulResult = false;
    this.claudeDidReceiveAssistantContent = false;
    this.claudeDidReceiveErrorResult = false;
    this.didReceiveVisibleOutput = false;
    this.didReceiveStderr = false;
    this.claudeDiagnostics = [];
    this.claudeDiagnosticsTruncated = false;
    this.stderrTail = [];

    const child = this.spawnCLI("claude", this.claudeArguments(options, this.request.session, flags));
    this.child = child;

    if (options.supportsStreamJSONInput) {
      const didWrite = this.writeClaudeUserMessage(this.request.prompt, null, null, this.request.attachments);
      if (!didWrite) {
        this.emitTerminal({ type: "failed", message: "Claude Code stream-json 输入写入失败。" });
        this.stopProcess();
      }
    }

    const result = await this.consumeChildStreams(child, (line) => this.handleClaudeLine(line, child), "Claude Code");
    return { result, diagnostics: claudeAttemptDiagnostics(this.claudeDiagnostics, this.stderrTail, this.claudeDiagnosticsTruncated) };
  }

  private handleClaudeLine(line: string, child: ChildProcessWithoutNullStreams): void {
    // Tool-permission / AskUserQuestion gating runs over the stdin/stdout control
    // channel; it must be intercepted before generic event parsing so we can record
    // the request context needed to build a correct control_response.
    const controlEvents = this.claudeControlRequestEvents(line);
    if (controlEvents) {
      for (const event of controlEvents) {
        this.emitAndMark(event);
      }
      return;
    }

    this.appendClaudeDiagnostic(diagnosticTextFromClaudeLine(line));
    const transition = claudeBackgroundTaskTransition(line);
    if (transition === "started") {
      this.pendingClaudeBackgroundTasks += 1;
    } else if (transition === "completed") {
      this.pendingClaudeBackgroundTasks = Math.max(0, this.pendingClaudeBackgroundTasks - 1);
    }

    for (const event of eventsFromClaudeLine(line, this.claudeStreamState)) {
      if (isAssistantOutput(event)) {
        this.claudeDidReceiveAssistantContent = true;
      }
      if (isErrorOutput(event)) {
        this.claudeDidReceiveErrorResult = true;
      }
      this.emitAndMark(event);
    }

    // claude 在 --input-format stream-json 下是长驻进程：一轮 turn 输出完 result 后不会
    // 自己退出，而是继续等 stdin 上的下一条 user message。每条 send 都是新进程、不复用，
    // 所以终态 result 到达后要主动 EOF stdin。自动压缩与后台任务是例外。
    if (!isTerminalClaudeResultLine(line)) {
      return;
    }
    if (this.waitingForCompactResult) {
      // 刚写入了 /compact：这条 result 属于被打断的上一轮，吞掉关闭动作，
      // 等压缩完成后的下一条 result 再关 stdin。
      this.waitingForCompactResult = false;
      return;
    }
    if (this.pendingClaudeBackgroundTasks > 0) {
      // Bash run_in_background 还在跑：claude 保持存活并会在任务通知到达时自动续跑，
      // 这时候关 stdin / 停进程会把后台任务杀掉。
      this.emit({ type: "updateStreamingStatus", status: "后台任务进行中…" });
      return;
    }
    if (isSuccessfulTerminalResultLine(line)) {
      this.claudeDidReceiveSuccessfulResult = true;
      this.emitTerminal({ type: "finished" });
      this.closeStdin();
      this.stopProcessSoon(child);
      return;
    }
    this.closeStdin();
  }

  private finishClaudeRun(result: ProcessResult): void {
    if (this.didEmitTerminalEvent) {
      return;
    }
    const diagnostics = claudeAttemptDiagnostics(this.claudeDiagnostics, this.stderrTail, this.claudeDiagnosticsTruncated);
    const withDiagnostics = (message: string) => (diagnostics ? `${message}\n${diagnostics}` : message);
    if (this.didInterrupt || result.signal) {
      this.emitTerminal({ type: "failed", message: withDiagnostics("Claude Code 已停止。") });
      return;
    }
    if (this.claudeDidReceiveSuccessfulResult || (this.claudeDidReceiveAssistantContent && !this.claudeDidReceiveErrorResult)) {
      this.emitTerminal({ type: "finished" });
      return;
    }
    if (result.code === 0) {
      this.emitTerminal({ type: "failed", message: withDiagnostics("Claude Code 没有输出任何对话内容。请检查认证配置或模型设置。") });
      return;
    }
    this.emitTerminal({ type: "failed", message: withDiagnostics(`Claude Code 退出码：${result.code ?? "unknown"}`) });
  }

  /// Parse a `can_use_tool` control_request line, record its context for the eventual
  /// control_response, and return the UI event (permission card or interactive picker).
  /// Returns null for non-control lines so the caller falls through to normal parsing;
  /// control_cancel_request clears the pending gate.
  private claudeControlRequestEvents(line: string): ChatBackendEvent[] | null {
    const object = parseJSONObject(line);
    const type = object ? stringValue(object.type) : null;
    if (type === "control_cancel_request") {
      const requestID = object ? stringValue(object.request_id) ?? stringValue(object.id) : null;
      if (requestID) {
        this.pendingClaudeControls.delete(requestID);
      }
      return [];
    }
    if (!object || type !== "control_request") {
      return null;
    }
    const request = recordValue(object.request);
    if (!request || stringValue(request.subtype) !== "can_use_tool") {
      return [];
    }

    const requestID = stringValue(object.request_id) ?? stringValue(object.id) ?? randomUUID();
    const toolName = stringValue(request.tool_name) ?? "tool";
    const displayName = stringValue(request.display_name) ?? toolName;
    const input = recordValue(request.input) ?? {};
    const toolUseID = stringValue(request.tool_use_id);

    if (isAskUserQuestionName(toolName)) {
      const [interactive, questions] = buildAskUserRequest(requestID, input);
      this.pendingClaudeControls.set(requestID, { requestID, toolName, input, toolUseID, questions });
      return [{ type: "interactiveRequest", request: interactive }];
    }

    this.pendingClaudeControls.set(requestID, { requestID, toolName, input, toolUseID, questions: [] });
    return [{ type: "permissionRequest", id: requestID, title: displayName, text: permissionPromptText(displayName, input) }];
  }

  private writeClaudeControlResponse(requestID: string, inner: JSONRecord): boolean {
    return this.writeJSONObject({
      type: "control_response",
      response: {
        subtype: "success",
        request_id: requestID,
        response: inner
      }
    });
  }

  private async startCodex(): Promise<void> {
    const effort = this.request.options.reasoningEffort === "max" ? "xhigh" : this.request.options.reasoningEffort;
    const child = this.spawnCLI("codex", ["app-server", "-c", `model_reasoning_effort="${effort}"`, "--listen", "stdio://"]);
    this.child = child;
    const initializeID = this.sendCodexRequest("initialize", {
      clientInfo: {
        name: "acode",
        title: "acode",
        version: "0.1.0"
      },
      capabilities: {
        experimentalApi: true
      }
    });
    this.pendingCodexRequests.set(String(initializeID), "initialize");

    const result = await this.consumeChildStreams(child, (line) => {
      for (const event of this.eventsFromCodexLine(line)) {
        this.emitAndMark(event);
      }
    }, "Codex");
    this.finishFromProcessResult(result, "Codex");
  }

  private spawnCLI(command: "claude" | "codex", args: string[]): ChildProcessWithoutNullStreams {
    const executablePath = this.request.options.executablePath.trim() || command;
    return spawn(executablePath, args, {
      cwd: this.request.options.workingDirectory?.trim() || this.request.options.projectPath,
      env: this.processEnvironment(),
      shell: false,
      windowsHide: true
    });
  }

  private async consumeChildStreams(
    child: ChildProcessWithoutNullStreams,
    onStdoutLine: (line: string) => void,
    stderrTitle: string
  ): Promise<ProcessResult> {
    const closePromise = this.waitForClose(child);
    const stdoutPromise = (async () => {
      for await (const line of readJSONLLines(child.stdout)) {
        onStdoutLine(line);
      }
    })();
    const stderrPromise = (async () => {
      for await (const line of readJSONLLines(child.stderr, { maxLineBytes: 256 * 1024 })) {
        const text = line.trim();
        if (!text) {
          continue;
        }
        this.didReceiveStderr = true;
        this.stderrTail.push(text);
        if (this.stderrTail.length > 200) {
          this.stderrTail.splice(0, this.stderrTail.length - 160);
        }
        this.emit({
          type: "appendMessage",
          kind: "commandOutput",
          title: "stderr",
          subtitle: stderrTitle,
          text,
          status: "stream"
        });
      }
    })();

    const result = await closePromise;
    await Promise.allSettled([stdoutPromise, stderrPromise]);
    return result;
  }

  private waitForClose(child: ChildProcessWithoutNullStreams): Promise<ProcessResult> {
    return new Promise((resolve) => {
      child.once("error", (error) => {
        this.emitTerminal({ type: "failed", message: `启动 CLI 失败：${error.message}` });
      });
      child.once("close", (code, signal) => resolve({ code, signal }));
    });
  }

  private finishFromProcessResult(result: ProcessResult, title: string): void {
    if (this.didEmitTerminalEvent) {
      return;
    }
    if (this.didInterrupt || result.signal) {
      this.emitTerminal({ type: "failed", message: `${title} 已停止。` });
      return;
    }
    if (result.code === 0) {
      if (this.didReceiveVisibleOutput || this.didReceiveStderr) {
        this.emitTerminal({ type: "finished" });
      } else {
        this.emitTerminal({ type: "failed", message: `${title} 没有输出任何对话内容。请检查认证配置或模型设置。` });
      }
      return;
    }
    this.emitTerminal({ type: "failed", message: `${title} 退出码：${result.code ?? "unknown"}` });
  }

  private appendClaudeDiagnostic(text: string | null): void {
    const trimmed = text?.trim();
    if (!trimmed) {
      return;
    }
    this.claudeDiagnostics.push(trimmed);
    if (this.claudeDiagnostics.length > 80) {
      this.claudeDiagnostics.splice(0, this.claudeDiagnostics.length - 60);
      this.claudeDiagnosticsTruncated = true;
    }
  }

  private claudeArguments(options: ChatRunOptions, session: { externalSessionID?: string | null } | null, flags: ClaudeAttemptFlags): string[] {
    const args: string[] = [];
    const resumeID = options.resumeSessionID?.trim() || session?.externalSessionID?.trim() || "";
    if (options.sessionMode === "continueLast") {
      args.push("--continue");
    } else if (options.sessionMode === "resume" && resumeID) {
      args.push("--resume", resumeID);
    }

    if (options.supportsStreamJSONInput) {
      args.push("-p");
    } else {
      args.push("-p", promptWithAttachments(this.request.prompt, this.request.attachments));
    }
    args.push("--output-format", "stream-json");
    if (options.supportsStreamJSONInput) {
      args.push("--input-format", "stream-json", "--replay-user-messages");
    }
    args.push("--verbose");
    if (flags.brief) {
      args.push("--brief");
    }
    if (flags.partialMessages) {
      args.push("--include-partial-messages");
    }
    args.push("--permission-mode", claudePermissionMode(options.permissionMode));
    if (options.supportsStreamJSONInput && flags.permissionPromptTool) {
      // Route tool-permission and AskUserQuestion gating to our stdin/stdout control
      // channel so we can answer with a proper control_response. Without this the CLI
      // either resolves silently or waits for a TTY that doesn't exist and aborts.
      args.push("--permission-prompt-tool", "stdio");
    }
    if (flags.effort) {
      args.push("--effort", options.reasoningEffort);
    }
    if (options.modelID.toLowerCase().startsWith("claude-")) {
      args.push("--model", options.modelID);
    }
    return args;
  }

  private writeClaudeUserMessage(
    text: string,
    parentToolUseID: string | null,
    toolUseResult: JSONRecord | null,
    attachments: ChatMessageAttachment[] = []
  ): boolean {
    const trimmed = promptWithAttachments(text, attachments).trim();
    if (!trimmed) {
      return false;
    }
    const object: JSONRecord = {
      type: "user",
      uuid: randomUUID(),
      message: {
        role: "user",
        content: trimmed
      },
      shouldQuery: true
    };
    const sessionID = this.request.session?.externalSessionID?.trim();
    if (sessionID) {
      object.session_id = sessionID;
    }
    if (parentToolUseID) {
      object.parent_tool_use_id = parentToolUseID;
    }
    if (toolUseResult) {
      object.tool_use_result = toolUseResult;
    }
    return this.writeJSONObject(object);
  }

  private eventsFromCodexLine(line: string): ChatBackendEvent[] {
    const object = parseJSONObject(line);
    if (!object) {
      return [];
    }
    if (recordValue(object.error)) {
      return this.eventsFromCodexError(recordValue(object.error) ?? {}, object);
    }

    const id = object.id;
    const idKey = requestKey(id);
    const pending = idKey ? this.pendingCodexRequests.get(idKey) : undefined;
    if (pending && idKey) {
      this.pendingCodexRequests.delete(idKey);
      return this.eventsFromCodexResponse(object, pending);
    }

    const method = stringValue(object.method);
    if (!method) {
      return [];
    }
    if (id !== undefined && id !== null) {
      if (isCodexApprovalRequest(method)) {
        return this.eventsFromCodexApprovalRequest(object, id, method);
      }
      if (isCodexInteractiveRequest(method, object)) {
        return this.eventsFromCodexInteractiveRequest(object, id, method);
      }
      if (isCodexFileReadRequest(method)) {
        return this.eventsFromCodexReadFileRequest(object, id, method);
      }
      this.sendCodexErrorResponse(id, -32601, `acode Windows 暂不支持 Codex server request: ${method}`);
      return [{ type: "appendMessage", kind: "rawOutput", title: method, subtitle: "unsupported request", text: compactText(object), status: "unsupported", requestID: requestKey(id) ?? null }];
    }
    return this.eventsFromCodexNotification(object, method);
  }

  /// Codex 的 fs/read、fs/readFile 一类 server request：在工作区内代读文件并回传内容，
  /// 而不是回 -32601 让工具失败。路径限制在项目目录内、限 5MB UTF-8 文本（对齐 Mac）。
  private eventsFromCodexReadFileRequest(object: JSONRecord, id: unknown, method: string): ChatBackendEvent[] {
    const params = recordValue(object.params) ?? {};
    const rawPath = codexReadFilePath(params);
    const requestID = requestKey(id) ?? null;
    if (!rawPath) {
      const message = "Codex readFile request missing path";
      const didWrite = this.sendCodexErrorResponse(id, -32602, message);
      return [{
        type: "appendMessage",
        kind: "toolResult",
        title: method,
        subtitle: didWrite ? "invalid request" : "response failed",
        text: message,
        status: "failed",
        requestID
      }];
    }
    try {
      const filePath = resolveCodexProjectFile(rawPath, this.request.options.projectPath);
      const text = readCodexProjectTextFile(filePath);
      const didWrite = this.sendCodexResponse(id, { content: text, text, path: filePath });
      return [{
        type: "appendMessage",
        kind: "toolResult",
        title: method,
        subtitle: didWrite ? path.basename(filePath) : "response failed",
        text: `read ${filePath}`,
        status: didWrite ? "done" : "failed",
        requestID
      }];
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const didWrite = this.sendCodexErrorResponse(id, -32000, message);
      return [{
        type: "appendMessage",
        kind: "toolResult",
        title: method,
        subtitle: didWrite ? "read failed" : "response failed",
        text: message,
        status: "failed",
        requestID
      }];
    }
  }

  private eventsFromCodexResponse(object: JSONRecord, pending: PendingCodexRequest): ChatBackendEvent[] {
    if (pending === "initialize") {
      this.sendCodexNotification("initialized");
      this.requestCodexThread();
      return [{ type: "updateStreamingStatus", status: "initialized" }];
    }
    if (pending === "openThread") {
      const result = recordValue(object.result);
      const threadID = result ? threadIDFrom(result) : null;
      if (!threadID) {
        this.emitTerminal({ type: "failed", message: "Codex thread/start 未返回 thread id。" });
        this.stopProcess();
        return [];
      }
      this.activeThreadID = threadID;
      this.requestCodexTurnStart(threadID);
      return [
        { type: "sessionID", externalSessionID: threadID },
        { type: "updateStreamingStatus", status: "thread ready" }
      ];
    }
    if (pending === "startTurn") {
      const result = recordValue(object.result);
      const turnID = result ? turnIDFrom(result) : null;
      if (turnID) {
        this.activeTurnID = turnID;
      }
      return [{ type: "updateStreamingStatus", status: "turn started" }];
    }
    if (pending === "interrupt") {
      this.emitTerminal({ type: "finished" });
      return [];
    }
    return [];
  }

  private eventsFromCodexNotification(object: JSONRecord, method: string): ChatBackendEvent[] {
    const params = recordValue(object.params) ?? {};
    switch (method) {
      case "thread/started": {
        const threadID = threadIDFrom(params);
        if (!threadID) {
          return [];
        }
        this.activeThreadID = threadID;
        return [{ type: "sessionID", externalSessionID: threadID }];
      }
      case "turn/started": {
        const turnID = turnIDFrom(params);
        if (turnID) {
          this.activeTurnID = turnID;
        }
        return [{ type: "updateStreamingStatus", status: "streaming" }];
      }
      case "item/agentMessage/delta":
        return [{ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Codex", text: deltaText(params), status: "streaming", requestID: itemIDFrom(params) }];
      case "item/reasoning/textDelta":
      case "item/reasoning/summaryTextDelta":
        return nonEmptyDelta("reasoning", "reasoning", params, this.outputRequestID(method, params));
      case "item/plan/delta":
        return nonEmptyDelta("toolCall", "plan", params, this.outputRequestID(method, params));
      case "command/exec/outputDelta":
      case "item/commandExecution/outputDelta":
        return nonEmptyDelta("commandOutput", itemTitle(params, "command output"), params, this.outputRequestID(method, params));
      case "item/fileChange/outputDelta":
        return nonEmptyDelta("diff", itemTitle(params, "file change"), params, this.outputRequestID(method, params));
      case "turn/diff/updated": {
        const text = diffText(params)?.trim();
        return text ? [{ type: "appendDelta", kind: "diff", title: "diff", subtitle: "Codex", text, status: "streaming", requestID: this.outputRequestID(method, params) }] : [];
      }
      case "item/started":
      case "item/completed": {
        const itemType = itemTypeFrom(params).toLowerCase();
        if (shouldSuppressCodexItemType(itemType)) {
          return [];
        }
        const completed = method === "item/completed";
        const kind = kindForCodexItem(params, completed);
        if (kind === "diff") {
          // A diff item only renders once it carries the completed diff payload — the
          // streaming fileChange/outputDelta events already feed the interim card.
          const text = completed ? diffText(params)?.trim() : null;
          if (!text) {
            return [];
          }
          return [{
            type: "appendMessage",
            kind: "diff",
            title: itemTitle(params, "file change"),
            subtitle: "Codex",
            text,
            status: "done",
            requestID: itemIDFrom(params)
          }];
        }
        return [{
          type: "appendMessage",
          kind,
          title: itemTitle(params, completed ? "item completed" : "item started"),
          subtitle: "Codex",
          text: compactText(params),
          status: completed ? "done" : "streaming",
          requestID: itemIDFrom(params)
        }];
      }
      case "thread/tokenUsage/updated": {
        const usage = recordValue(params.usage);
        return [{
          type: "tokenUsage",
          used: intValue(params.used) ?? intValue(usage?.used) ?? 0,
          total: intValue(params.total) ?? intValue(usage?.total) ?? 0,
          output: intValue(params.output) ?? intValue(usage?.output) ?? null
        }];
      }
      case "mcpServer/startupStatus/updated":
      case "thread/status/changed":
      case "remoteControl/status/changed":
      case "account/rateLimits/updated":
      case "session/configured":
      case "session/connected":
        return [];
      case "turn/completed": {
        const turn = recordValue(params.turn);
        const error = turn?.error;
        if (error !== undefined && error !== null) {
          this.emitTerminal({ type: "failed", message: codexErrorText(error) });
        } else {
          this.emitTerminal({ type: "finished" });
        }
        this.stopProcess();
        return [];
      }
      case "error":
        return this.eventsFromCodexError(params, object);
      default:
        return [];
    }
  }

  private eventsFromCodexApprovalRequest(object: JSONRecord, id: unknown, method: string): ChatBackendEvent[] {
    const requestID = requestKey(id) ?? randomUUID();
    const params = recordValue(object.params) ?? {};
    this.pendingApprovals.set(requestID, {
      id,
      method,
      requestedPermissions: recordValue(params.permissions)
    });
    return [{ type: "permissionRequest", id: requestID, title: titleForApprovalMethod(method), text: approvalText(method, params) }];
  }

  private eventsFromCodexInteractiveRequest(object: JSONRecord, id: unknown, method: string): ChatBackendEvent[] {
    const requestID = requestKey(id) ?? randomUUID();
    const params = recordValue(object.params) ?? {};
    this.pendingInteractiveRequests.set(requestID, { id, method });
    const options = codexInteractiveOptions(params);
    const multiple = boolValue(params.multiple) ?? boolValue(params.multiSelect) ?? boolValue(params.multi_select) ?? false;
    return [{
      type: "interactiveRequest",
      request: {
        id: requestID,
        title: stringValue(params.title) ?? "需要选择",
        prompt: stringValue(params.prompt) ?? stringValue(params.question) ?? stringValue(params.message) ?? stringValue(params.text) ?? "请选择后继续。",
        mode: options.length === 0 ? "text" : multiple ? "multipleChoice" : "singleChoice",
        options,
        allowCustomInput: boolValue(params.allowCustomInput) ?? boolValue(params.allow_custom_input) ?? false,
        placeholder: stringValue(params.placeholder) ?? "输入回复",
        status: "waiting"
      }
    }];
  }

  private eventsFromCodexError(error: JSONRecord, envelope: JSONRecord): ChatBackendEvent[] {
    const message = codexErrorText(error);
    if (boolValue(envelope.willRetry) === true) {
      return [
        { type: "updateStreamingStatus", status: stringValue(error.message) ?? "reconnecting" },
        { type: "appendMessage", kind: "commandOutput", title: "codex", subtitle: "retrying", text: message, status: "retry" }
      ];
    }
    this.emitTerminal({ type: "failed", message });
    this.stopProcess();
    return [];
  }

  private requestCodexThread(): void {
    const options = this.request.options;
    const resumeID = options.resumeSessionID?.trim() || this.request.session?.externalSessionID?.trim() || "";
    const params: JSONRecord = {
      cwd: options.projectPath,
      approvalPolicy: codexApprovalPolicy(options.permissionMode),
      sandbox: codexSandbox(options.permissionMode),
      serviceName: "acode"
    };
    if (isExplicitModelID(options.modelID)) {
      params.model = options.modelID;
    }
    const method = options.sessionMode === "resume" && resumeID ? "thread/resume" : "thread/start";
    if (method === "thread/resume") {
      params.threadId = resumeID;
    }
    const id = this.sendCodexRequest(method, params);
    this.pendingCodexRequests.set(String(id), "openThread");
  }

  private requestCodexTurnStart(threadID: string): void {
    const options = this.request.options;
    const params: JSONRecord = {
      threadId: threadID,
      input: [{
        type: "text",
        text: promptWithAttachments(this.request.prompt, this.request.attachments),
        text_elements: []
      }],
      cwd: options.projectPath,
      approvalPolicy: codexApprovalPolicy(options.permissionMode)
    };
    if (isExplicitModelID(options.modelID)) {
      params.model = options.modelID;
    }
    const id = this.sendCodexRequest("turn/start", params);
    this.pendingCodexRequests.set(String(id), "startTurn");
  }

  private codexApprovalResult(approval: PendingApproval, decision: ChatPermissionDecision): JSONRecord {
    if (approval.method === "item/permissions/requestApproval") {
      return {
        permissions: decision === "deny" ? {} : approval.requestedPermissions ?? {},
        scope: decision === "allowForSession" ? "session" : "turn"
      };
    }
    if (approval.method === "applyPatchApproval" || approval.method === "execCommandApproval") {
      return { decision: decision === "deny" ? "denied" : "approved" };
    }
    return { decision: codexApprovalDecision(decision) };
  }

  private outputRequestID(method: string, params: JSONRecord): string {
    return outputIDFrom(params) ?? `${this.activeTurnID ?? this.activeThreadID ?? "turn"}-${method}`;
  }

  private sendCodexRequest(method: string, params: unknown): number {
    const id = this.nextCodexID;
    this.nextCodexID += 1;
    this.writeJSONObject({ id, method, params });
    return id;
  }

  private sendCodexNotification(method: string, params?: unknown): boolean {
    return this.writeJSONObject(params === undefined ? { method } : { method, params });
  }

  private sendCodexResponse(id: unknown, result: JSONRecord): boolean {
    return this.writeJSONObject({ id, result });
  }

  private sendCodexErrorResponse(id: unknown, code: number, message: string): boolean {
    return this.writeJSONObject({ id, error: { code, message } });
  }

  private writeJSONObject(object: JSONRecord): boolean {
    if (!this.child?.stdin.writable) {
      return false;
    }
    this.child.stdin.write(`${JSON.stringify(object)}\n`);
    return true;
  }

  private closeStdin(): void {
    if (this.child?.stdin.writable) {
      this.child.stdin.end();
    }
  }

  private stopProcess(): void {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    this.closeStdin();
    if (process.platform === "win32") {
      this.stopWindowsProcessTree(child);
      return;
    }
    child.kill("SIGINT");
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGTERM");
      }
    }, 800);
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
    }, 2200);
  }

  private stopProcessSoon(child: ChildProcessWithoutNullStreams): void {
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        this.stopProcess();
      }
    }, 120);
  }

  private stopWindowsProcessTree(child: ChildProcessWithoutNullStreams): void {
    const pid = child.pid;
    if (!pid) {
      child.kill();
      return;
    }
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        execFile("taskkill", ["/PID", String(pid), "/T"], { windowsHide: true }, () => {});
      }
    }, 500);
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) {
        execFile("taskkill", ["/PID", String(pid), "/T", "/F"], { windowsHide: true }, () => {});
      }
    }, 1800);
  }

  private emitAndMark(event: ChatBackendEvent): void {
    if (isVisibleOutput(event)) {
      this.didReceiveVisibleOutput = true;
    }
    if (event.type === "finished" || event.type === "failed") {
      this.emitTerminal(event);
      return;
    }
    this.emit(event);
  }

  private emitTerminal(event: Extract<ChatBackendEvent, { type: "finished" | "failed" }>): void {
    if (this.didEmitTerminalEvent) {
      return;
    }
    this.didEmitTerminalEvent = true;
    this.emit(event);
  }

  private processEnvironment(): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env, ...this.request.options.environment };
    for (const key of ["CODEX_CI", "CODEX_SANDBOX", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_SHELL"]) {
      delete env[key];
    }
    return env;
  }
}

// ---------------------------------------------------------------------------
// Claude line → event mapping (parity with ClaudeCodeProcessBackend.swift)
// ---------------------------------------------------------------------------

function eventsFromClaudeLine(line: string, streamState: ClaudeStreamState): ChatBackendEvent[] {
  const object = parseJSONObject(line);
  if (!object) {
    if (isClaudeProtocolRawLine(line)) {
      return [];
    }
    return [{ type: "appendMessage", kind: "rawOutput", title: "raw", subtitle: "Claude Code", text: line, status: "stream" }];
  }

  const events: ChatBackendEvent[] = [];
  const sessionID = stringValue(object.session_id) ?? stringValue(object.sessionId);
  if (sessionID) {
    events.push({ type: "sessionID", externalSessionID: sessionID });
  }
  const usage = tokenUsageEvent(object);
  if (usage) {
    events.push(usage);
  }

  const type = stringValue(object.type) ?? stringValue(object.event) ?? "raw";
  if (type === "user") {
    return events;
  }
  // control_request / control_cancel_request are handled by the instance loop
  // (pending control-request state is needed to build a correct control_response).
  if (type === "control_request" || type === "control_cancel_request") {
    return events;
  }
  const errorText = claudeErrorText(object, type);
  if (errorText) {
    events.push({
      type: "appendMessage",
      kind: "error",
      title: "Claude Code",
      subtitle: type,
      text: errorText,
      status: "failed",
      requestID: stringValue(object.request_id) ?? stringValue(object.id)
    });
    return events;
  }
  if (type === "system") {
    const statusText = claudeSystemStatusText(object);
    if (statusText) {
      events.push({ type: "updateStreamingStatus", status: statusText });
    }
    const compactError = claudeCompactErrorText(object);
    if (compactError) {
      events.push({ type: "appendMessage", kind: "error", title: "Claude Code", subtitle: "compact", text: compactError, status: "failed" });
    }
    const subtype = stringValue(object.subtype);
    if (subtype === "init") {
      const summary = claudeInitSummary(object);
      if (summary) {
        events.push({ type: "appendMessage", kind: "system", title: "Mac tools", subtitle: "agent", text: summary, status: "done" });
      }
    } else if (subtype) {
      events.push({ type: "appendMessage", kind: "system", title: "system", subtitle: subtype, text: compactText(object), status: "done" });
    }
    return events;
  }
  if (type === "stream_event") {
    events.push(...claudeStreamEvents(object, streamState));
    return events;
  }
  if (type === "assistant") {
    const assistantEvents = claudeAssistantEvents(object, streamState);
    if (assistantEvents.some(isAssistantOutput)) {
      streamState.didReceiveAssistantTextDelta = true;
    }
    events.push(...assistantEvents);
    return events;
  }
  if (type === "result") {
    const subtype = stringValue(object.subtype) ?? "";
    const resultText = stringValue(object.result) ?? stringValue(object.message);
    if (!streamState.didReceiveAssistantTextDelta && resultText) {
      streamState.didReceiveAssistantTextDelta = true;
      events.push({ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Claude Code", text: resultText, status: "streaming" });
    }
    if (subtype === "success") {
      return events;
    }
    events.push({ type: "appendMessage", kind: "error", title: "result", subtitle: subtype, text: resultText ?? compactText(object), status: "done" });
    return events;
  }
  const requestID = stringValue(object.request_id) ?? stringValue(object.id);
  const interactive = claudeInteractiveRequestFrom(object, requestID, type);
  if (interactive) {
    events.push({ type: "interactiveRequest", request: interactive });
    return events;
  }
  if (type.toLowerCase().includes("tool")) {
    events.push({
      type: "appendMessage",
      kind: type.toLowerCase().includes("result") ? "toolResult" : "toolCall",
      title: type,
      subtitle: stringValue(object.name) ?? "",
      text: compactText(object),
      status: "done",
      requestID
    });
  }
  return events;
}

/// Claude Code 真正可识别的权限/审批请求只有 control_request（在实例层提前拦截）。
/// 旧实现用 type.includes("permission"/"approval") 模糊匹配，任何带子串的事件都会
/// 被当成"待响应权限请求"，在 UI 上挂出永等不到回复的死按钮。与 Mac 端白名单对齐，
/// 这里不再对任意 type 生成 permissionRequest。
function claudeStreamEvents(object: JSONRecord, streamState: ClaudeStreamState): ChatBackendEvent[] {
  const event = recordValue(object.event) ?? object;
  const type = stringValue(event.type) ?? stringValue(object.event) ?? "";
  const blockIndex = intValue(event.index);
  const activeBlock = blockIndex !== null ? streamState.activeBlocks.get(blockIndex) : undefined;

  const usage = tokenUsageEvent(event);
  if (usage) {
    return [usage];
  }

  if (type === "content_block_start") {
    const contentBlock = recordValue(event.content_block);
    if (!contentBlock) {
      return [];
    }
    const blockType = stringValue(contentBlock.type) ?? "content_block";
    const block: ClaudeContentBlock = {
      id: stringValue(contentBlock.id),
      type: blockType,
      name: stringValue(contentBlock.name)
    };
    if (blockIndex !== null) {
      streamState.activeBlocks.set(blockIndex, block);
    }
    if (blockType === "text" || blockType === "thinking") {
      return [];
    }
    // AskUserQuestion is surfaced (and answered) via its can_use_tool control_request,
    // so suppress the streaming tool_use card to avoid showing it twice.
    if (isAskUserQuestionName(block.name)) {
      return [];
    }
    const kind = kindForClaudeBlockType(blockType);
    if (kind === "rawOutput") {
      return [];
    }
    return [{
      type: "appendMessage",
      kind,
      title: block.name ?? blockType,
      subtitle: "Claude Code",
      // Keep the streamed input JSON parseable: deltas append raw partial_json chunks,
      // so the card text must start empty rather than with the block-header JSON.
      text: "",
      status: "streaming",
      requestID: block.id
    }];
  }

  if (type === "content_block_delta") {
    const delta = recordValue(event.delta);
    const deltaType = stringValue(delta?.type) ?? "";
    if (deltaType === "text_delta") {
      const text = stringValue(delta?.text);
      if (!text) {
        return [];
      }
      const kind = kindForClaudeDelta(activeBlock, "assistant");
      if (kind === "assistant") {
        streamState.didReceiveAssistantTextDelta = true;
        streamState.didReceiveStreamEventAssistantTextDelta = true;
      }
      return [{
        type: "appendDelta",
        kind,
        title: activeBlock?.type ?? "",
        subtitle: activeBlock?.name ?? "Claude Code",
        text,
        status: "streaming",
        requestID: activeBlock?.id ?? null
      }];
    }
    if (deltaType === "thinking_delta") {
      const text = stringValue(delta?.thinking) ?? stringValue(delta?.text);
      if (!text) {
        return [];
      }
      return [{ type: "appendDelta", kind: "reasoning", title: "thinking", subtitle: "Claude Code", text, status: "streaming", requestID: activeBlock?.id ?? null }];
    }
    if (deltaType === "input_json_delta" && activeBlock) {
      const text = stringValue(delta?.partial_json);
      if (!text || isAskUserQuestionName(activeBlock.name)) {
        return [];
      }
      return [{
        type: "appendDelta",
        kind: "toolCall",
        title: activeBlock.type,
        subtitle: activeBlock.name ?? "",
        text,
        status: "streaming",
        requestID: activeBlock.id
      }];
    }
    return [];
  }

  if (type === "content_block_stop") {
    if (blockIndex !== null) {
      streamState.activeBlocks.delete(blockIndex);
    }
    if (!activeBlock || activeBlock.type === "text" || activeBlock.type === "thinking") {
      return [];
    }
    if (isAskUserQuestionName(activeBlock.name)) {
      return [];
    }
    return [{ type: "finishStreamingMessage", kind: kindForClaudeBlockType(activeBlock.type), requestID: activeBlock.id, status: "done" }];
  }

  return [];
}

function claudeAssistantEvents(object: JSONRecord, streamState: ClaudeStreamState): ChatBackendEvent[] {
  const events: ChatBackendEvent[] = [];
  if (!streamState.didReceiveStreamEventAssistantTextDelta) {
    const text = claudeAssistantText(object);
    if (text) {
      const delta = topLevelClaudeDelta(text, streamState.topLevelAssistantText);
      streamState.topLevelAssistantText = text;
      if (delta) {
        events.push({ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Claude Code", text: delta, status: "streaming" });
      }
    }
  }
  const message = recordValue(object.message);
  const content = message?.content;
  if (!Array.isArray(content)) {
    return events;
  }
  for (const raw of content) {
    const item = recordValue(raw);
    if (!item) {
      continue;
    }
    const type = stringValue(item.type) ?? "content";
    if (type === "text" || type === "thinking") {
      continue;
    }
    const id = stringValue(item.id) ?? stringValue(item.tool_use_id) ?? compactText(item);
    if (streamState.emittedContentItemIDs.has(id)) {
      continue;
    }
    streamState.emittedContentItemIDs.add(id);
    // AskUserQuestion is rendered/answered via its can_use_tool control_request; drop
    // the assistant-side copy so the picker isn't shown twice.
    if (isAskUserQuestionName(stringValue(item.name)) || item.questions !== undefined) {
      continue;
    }
    events.push(...claudeContentItemEvents(item));
  }
  return events;
}

function claudeContentItemEvents(item: JSONRecord): ChatBackendEvent[] {
  const type = stringValue(item.type) ?? "content";
  const id = stringValue(item.id);
  const interactive = claudeInteractiveRequestFrom(item, id, stringValue(item.name) ?? type);
  if (interactive) {
    return [{ type: "interactiveRequest", request: interactive }];
  }
  switch (type) {
    case "text": {
      const text = stringValue(item.text);
      return text ? [{ type: "appendDelta", kind: "assistant", title: "assistant", subtitle: "Claude Code", text, status: "streaming" }] : [];
    }
    case "thinking": {
      const text = stringValue(item.thinking) ?? stringValue(item.text);
      return text ? [{ type: "appendDelta", kind: "reasoning", title: "thinking", subtitle: "Claude Code", text, status: "streaming", requestID: id }] : [];
    }
    case "tool_result": {
      const requestID = stringValue(item.tool_use_id) ?? id;
      return [{
        type: "appendMessage",
        kind: "toolResult",
        title: "tool_result",
        subtitle: stringValue(item.name) ?? "",
        text: compactText(item),
        status: "done",
        requestID
      }];
    }
    case "tool_use": {
      const name = stringValue(item.name);
      return [{
        type: "appendMessage",
        kind: "toolCall",
        title: name ?? "tool_use",
        subtitle: "Claude Code",
        text: toolCallText(name, item.input),
        status: "done",
        requestID: id
      }];
    }
    default:
      return [];
  }
}

function topLevelClaudeDelta(text: string, previous: string): string {
  if (!previous) {
    return text;
  }
  if (text.startsWith(previous)) {
    return text.slice(previous.length);
  }
  return text === previous ? "" : text;
}

function claudeAssistantText(object: JSONRecord): string | null {
  const delta = recordValue(object.delta);
  const direct = stringValue(delta?.text) ?? stringValue(delta?.content);
  if (direct) {
    return direct;
  }
  const message = recordValue(object.message);
  const content = message?.content;
  if (!Array.isArray(content)) {
    return null;
  }
  const parts: string[] = [];
  for (const raw of content) {
    const item = recordValue(raw);
    if (item && stringValue(item.type) === "text") {
      const text = stringValue(item.text);
      if (text) {
        parts.push(text);
      }
    }
  }
  return parts.length > 0 ? parts.join("") : null;
}

function kindForClaudeBlockType(blockType: string): ChatMessageKind {
  const lower = blockType.toLowerCase();
  if (lower.includes("result")) {
    return "toolResult";
  }
  if (lower.includes("diff") || lower.includes("edit") || lower.includes("patch")) {
    return "diff";
  }
  if (lower.includes("command") || lower.includes("bash")) {
    return "command";
  }
  if (lower.includes("tool") || lower.includes("mcp") || lower.includes("server")) {
    return "toolCall";
  }
  return "rawOutput";
}

function kindForClaudeDelta(block: ClaudeContentBlock | undefined, defaultKind: ChatMessageKind): ChatMessageKind {
  if (!block) {
    return defaultKind;
  }
  const lower = block.type.toLowerCase();
  if (lower === "text") {
    return "assistant";
  }
  if (lower.includes("result")) {
    return "toolResult";
  }
  if (lower.includes("diff") || lower.includes("edit") || lower.includes("patch")) {
    return "diff";
  }
  if (lower.includes("command") || lower.includes("bash")) {
    return "commandOutput";
  }
  if (lower.includes("tool") || lower.includes("mcp") || lower.includes("server")) {
    return "toolCall";
  }
  return "rawOutput";
}

function isAskUserQuestionName(name: string | null | undefined): boolean {
  if (!name) {
    return false;
  }
  return name.toLowerCase().replace(/[_\-\s]/g, "").includes("askuserquestion");
}

function permissionPromptText(toolName: string, input: JSONRecord): string {
  const command = stringValue(input.command);
  if (command) {
    return command;
  }
  const pathValue = stringValue(input.file_path) ?? stringValue(input.path);
  if (pathValue) {
    return pathValue;
  }
  const summary = compactText(input);
  return summary || `请求使用 ${toolName}`;
}

/// Build the interactive picker plus the option-id → label map used to translate the
/// user's selection back into the AskUserQuestion `answers` object.
function buildAskUserRequest(requestID: string, input: JSONRecord): [ChatInteractiveRequest, ParsedAskQuestion[]] {
  const rawQuestions = Array.isArray(input.questions) ? input.questions.map(recordValue).filter((q): q is JSONRecord => Boolean(q)) : [];
  const multiQuestion = rawQuestions.length > 1;
  const parsed: ParsedAskQuestion[] = [];
  const options: Array<{ id: string; label: string; detail: string }> = [];
  const prompts: string[] = [];
  let anyMultiSelect = false;

  rawQuestions.forEach((question, questionIndex) => {
    const questionText = stringValue(question.question) ?? stringValue(question.prompt) ?? stringValue(question.message) ?? `问题 ${questionIndex + 1}`;
    const header = stringValue(question.header);
    const multiSelect = boolValue(question.multiSelect) ?? boolValue(question.multi_select) ?? false;
    if (multiSelect) {
      anyMultiSelect = true;
    }
    prompts.push(questionText);

    const labelsByID = new Map<string, string>();
    const rawOptions = Array.isArray(question.options) ? question.options : Array.isArray(question.choices) ? question.choices : [];
    rawOptions.forEach((rawOption, optionIndex) => {
      const optionID = `q${questionIndex}o${optionIndex}`;
      let label: string;
      let detail = "";
      const text = stringValue(rawOption);
      const dict = recordValue(rawOption);
      if (text) {
        label = text;
      } else if (dict) {
        label = stringValue(dict.label) ?? stringValue(dict.title) ?? stringValue(dict.value) ?? `选项 ${optionIndex + 1}`;
        detail = stringValue(dict.description) ?? stringValue(dict.detail) ?? "";
      } else {
        label = `选项 ${optionIndex + 1}`;
      }
      labelsByID.set(optionID, label);
      const displayLabel = multiQuestion ? `${header ?? `问题 ${questionIndex + 1}`}：${label}` : label;
      options.push({ id: optionID, label: displayLabel, detail });
    });
    parsed.push({ text: questionText, optionLabelsByID: labelsByID });
  });

  const request: ChatInteractiveRequest = {
    id: requestID,
    title: (rawQuestions.length === 1 ? stringValue(rawQuestions[0].header) : null) ?? "需要选择",
    prompt: prompts.join("\n\n"),
    mode: options.length === 0 ? "text" : anyMultiSelect || multiQuestion ? "multipleChoice" : "singleChoice",
    options,
    allowCustomInput: options.length === 0,
    placeholder: "输入自定义回复",
    status: "waiting"
  };
  return [request, parsed];
}

/// Generic interactive-shape detector for tool_use / misc objects carrying questions or
/// options (parity with the Mac `interactiveRequest(from:)` parser).
function claudeInteractiveRequestFrom(object: JSONRecord, fallbackID: string | null | undefined, fallbackTitle: string): ChatInteractiveRequest | null {
  const input = recordValue(object.input);
  const source = input ?? object;
  const name = [stringValue(object.name), stringValue(object.tool_name), stringValue(object.type), fallbackTitle]
    .filter((value): value is string => Boolean(value))
    .join(" ")
    .toLowerCase();
  const normalizedName = name.replace(/[_\-\s]/g, "");
  const isAskUserQuestion = normalizedName.includes("askuserquestion");
  const isSendUserMessage = normalizedName.includes("sendusermessage") || normalizedName.includes("requestuserinput") || normalizedName.includes("requestinput");
  const questions = (Array.isArray(source.questions) ? source.questions : []).map(recordValue).filter((q): q is JSONRecord => Boolean(q));
  const hasChoiceShape = source.options !== undefined || source.choices !== undefined || questions.length > 0;
  if (
    !hasChoiceShape &&
    !isAskUserQuestion &&
    !isSendUserMessage &&
    !normalizedName.includes("question") &&
    !normalizedName.includes("choice") &&
    !normalizedName.includes("input")
  ) {
    return null;
  }
  if (name.includes("permission") || name.includes("approval")) {
    return null;
  }
  const id = fallbackID ?? stringValue(source.id) ?? stringValue(source.request_id) ?? randomUUID();
  const questionSource = questions[0] ?? source;
  const prompt = claudeInteractivePrompt(source, questions);
  const options = questions.length > 0 ? claudeInteractiveOptionsFromQuestions(questions) : codexInteractiveOptions(source);
  const mode =
    options.length === 0
      ? "text"
      : questions.length > 1 || questions.some(isMultipleChoiceQuestion) || isMultipleChoiceQuestion(source)
        ? "multipleChoice"
        : "singleChoice";
  return {
    id,
    title: stringValue(questionSource.header) ?? stringValue(source.title) ?? stringValue(object.name) ?? "需要选择",
    prompt,
    mode,
    options,
    allowCustomInput:
      boolValue(questionSource.allowCustomInput) ?? boolValue(source.allowCustomInput) ?? boolValue(source.allow_custom_input) ?? (isAskUserQuestion || isSendUserMessage),
    placeholder: stringValue(questionSource.placeholder) ?? stringValue(source.placeholder) ?? "输入自定义回复",
    status: "waiting"
  };
}

function claudeInteractivePrompt(source: JSONRecord, questions: JSONRecord[]): string {
  if (questions.length > 0) {
    return questions
      .map((question, index) => stringValue(question.question) ?? stringValue(question.prompt) ?? stringValue(question.message) ?? stringValue(question.text) ?? `问题 ${index + 1}`)
      .join("\n\n");
  }
  return stringValue(source.prompt) ?? stringValue(source.question) ?? stringValue(source.message) ?? stringValue(source.text) ?? "请选择后继续。";
}

function claudeInteractiveOptionsFromQuestions(questions: JSONRecord[]): Array<{ id: string; label: string; detail: string }> {
  const multi = questions.length > 1;
  const options: Array<{ id: string; label: string; detail: string }> = [];
  questions.forEach((question, questionIndex) => {
    const labelPrefix = multi ? stringValue(question.header) ?? `问题 ${questionIndex + 1}` : null;
    const idPrefix = multi ? `q${questionIndex + 1}` : null;
    const rawOptions = Array.isArray(question.options) ? question.options : Array.isArray(question.choices) ? question.choices : [];
    rawOptions.forEach((rawOption, optionIndex) => {
      const text = stringValue(rawOption);
      const dict = recordValue(rawOption);
      let id: string;
      let label: string;
      let detail = "";
      if (text) {
        id = text;
        label = text;
      } else if (dict) {
        id = stringValue(dict.id) ?? stringValue(dict.value) ?? stringValue(dict.label) ?? `option-${optionIndex + 1}`;
        label = stringValue(dict.label) ?? stringValue(dict.title) ?? stringValue(dict.text) ?? id;
        detail = stringValue(dict.detail) ?? stringValue(dict.description) ?? "";
      } else {
        id = `option-${optionIndex + 1}`;
        label = `选项 ${optionIndex + 1}`;
      }
      options.push({
        id: idPrefix ? `${idPrefix}:${id}` : id,
        label: labelPrefix ? `${labelPrefix}：${label}` : label,
        detail
      });
    });
  });
  return options;
}

function isMultipleChoiceQuestion(question: JSONRecord): boolean {
  return boolValue(question.multiple) === true || boolValue(question.multiSelect) === true || boolValue(question.multi_select) === true;
}

function isTerminalClaudeResultLine(line: string): boolean {
  const compact = line.replace(/\s+/g, "");
  return isTerminalClaudeResult(compact);
}

function isSuccessfulTerminalResultLine(line: string): boolean {
  const compact = line.replace(/\s+/g, "");
  return isTerminalClaudeResult(compact) && compact.includes('"subtype":"success"');
}

function isTerminalClaudeResult(compactLine: string): boolean {
  return (
    compactLine.includes('"type":"result"') &&
    !compactLine.includes('"stop_reason":"tool_use"') &&
    !compactLine.includes('"terminal_reason":"tool_use"')
  );
}

/// Detect a `system` event that starts or completes a background task (Bash
/// run_in_background): `task_started` means a task is now running;
/// `task_notification`/`task_completed` means one finished (and the model auto-continues).
function claudeBackgroundTaskTransition(line: string): "started" | "completed" | "none" {
  const compact = line.replace(/\s+/g, "");
  if (!compact.includes('"type":"system"')) {
    return "none";
  }
  if (compact.includes('"subtype":"task_started"')) {
    return "started";
  }
  if (compact.includes('"subtype":"task_notification"') || compact.includes('"subtype":"task_completed"')) {
    return "completed";
  }
  return "none";
}

function isClaudeProtocolRawLine(line: string): boolean {
  const compact = line.trim().replace(/\s+/g, "");
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

function diagnosticTextFromClaudeLine(line: string): string | null {
  const object = parseJSONObject(line);
  if (!object) {
    return isClaudeProtocolRawLine(line) ? null : line;
  }
  const type = stringValue(object.type) ?? stringValue(object.event) ?? "raw";
  const errorText = claudeErrorText(object, type);
  if (errorText) {
    return errorText;
  }
  if (type === "result") {
    const subtype = stringValue(object.subtype) ?? "";
    if (subtype === "success") {
      return null;
    }
    return stringValue(object.result) ?? stringValue(object.message) ?? compactText(object);
  }
  const lower = type.toLowerCase();
  if (lower.includes("error") || lower.includes("fail")) {
    return compactText(object);
  }
  return null;
}

function claudeSystemStatusText(object: JSONRecord): string | null {
  const compactResult = stringValue(object.compact_result)?.toLowerCase();
  if (compactResult === "failed") {
    return "上下文压缩失败";
  }
  const status = stringValue(object.status)?.toLowerCase();
  switch (status) {
    case "compacting":
      return "正在压缩上下文";
    case "requesting":
      return "正在请求 Claude Code";
    case "queued":
      return "Claude Code 请求排队中";
    default:
      return null;
  }
}

function claudeCompactErrorText(object: JSONRecord): string | null {
  const compactResult = stringValue(object.compact_result)?.toLowerCase();
  if (compactResult !== "failed") {
    return null;
  }
  return stringValue(object.compact_error) ?? "Claude Code 上下文压缩失败。";
}

function claudeErrorText(object: JSONRecord, type: string): string | null {
  const lower = type.toLowerCase();
  if (!(lower === "error" || lower.endsWith("_error") || lower.includes("exception") || lower.includes("failed"))) {
    return null;
  }
  const direct = stringValue(object.message) ?? stringValue(object.error);
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

function claudeInitSummary(object: JSONRecord): string {
  const servers = Array.isArray(object.mcp_servers) ? object.mcp_servers : [];
  const connected = servers
    .map((server) => recordValue(server))
    .filter((server): server is JSONRecord => server !== null && (stringValue(server.status) ?? "").toLowerCase() === "connected")
    .map((server) => stringValue(server.name))
    .filter((name): name is string => Boolean(name));
  if (connected.length === 0) {
    return "";
  }
  return [`Mac tools: ${connected.length} connected`, ...connected.map((name) => `- ${name}`)].join("\n");
}

/// Detect a rejected CLI flag in stderr/stdout diagnostics (Mac's flag-fallback ladder).
function claudeFlagRejected(lowercasedDiagnostics: string, flag: string): boolean {
  return (
    lowercasedDiagnostics.includes(`--${flag}`) ||
    lowercasedDiagnostics.includes(`unknown option '${flag}'`) ||
    lowercasedDiagnostics.includes(`unknown option: ${flag}`) ||
    lowercasedDiagnostics.includes(`unexpected argument '--${flag}'`) ||
    (lowercasedDiagnostics.includes("unrecognized") && lowercasedDiagnostics.includes(flag))
  );
}

function claudeAttemptDiagnostics(diagnostics: string[], stderrTail: string[], truncated: boolean): string {
  const output = [...diagnostics, ...stderrTail].join("\n").trim();
  return truncated ? `... stdout diagnostics truncated to last 60 entries ...\n${output}` : output;
}

function isAssistantOutput(event: ChatBackendEvent): boolean {
  return (
    (event.type === "appendDelta" || event.type === "appendMessage") &&
    event.kind === "assistant" &&
    event.text.length > 0
  );
}

function isErrorOutput(event: ChatBackendEvent): boolean {
  return (event.type === "appendMessage" && event.kind === "error") || event.type === "failed";
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function claudePermissionMode(mode: ChatRunOptions["permissionMode"]): string {
  if (mode === "ask") {
    return "default";
  }
  return mode === "fullAccess" ? "bypassPermissions" : "acceptEdits";
}

function codexApprovalPolicy(mode: ChatRunOptions["permissionMode"]): string {
  if (mode === "ask") {
    return "on-request";
  }
  return mode === "fullAccess" ? "never" : "on-failure";
}

function codexSandbox(mode: ChatRunOptions["permissionMode"]): string {
  return mode === "fullAccess" ? "danger-full-access" : "workspace-write";
}

function isExplicitModelID(modelID: string): boolean {
  const normalized = modelID.trim().toLowerCase();
  return normalized.length > 0 && normalized !== "default";
}

function codexApprovalDecision(decision: ChatPermissionDecision): string {
  if (decision === "deny") {
    return "decline";
  }
  return decision === "allowForSession" ? "acceptForSession" : "accept";
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
  const item = recordValue(object.item);
  if (item) {
    const itemText = stringValue(item.text) ?? stringValue(item.message) ?? stringValue(item.delta) ?? stringValue(item.content);
    if (itemText) {
      return itemText;
    }
  }
  return JSON.stringify(object);
}

const fileChangeToolNames = new Set(["edit", "write", "multiedit", "create", "create_file", "new_file", "notebookedit"]);

// File-change tools need their structured input (file_path + old/new_string or content) preserved
// so the renderer can draw a proper diff card — compactText would flatten Write down to bare
// content and drop the path. Everything else stays on compactText to keep tool noise short.
function toolCallText(name: string | null | undefined, input: unknown): string {
  if (name && fileChangeToolNames.has(name.toLowerCase())) {
    const record = recordValue(input);
    if (record) {
      return JSON.stringify(record);
    }
  }
  return compactText(input);
}

function tokenUsageEvent(object: JSONRecord): ChatBackendEvent | null {
  const usage = recordValue(object.usage) ?? recordValue(recordValue(object.message)?.usage);
  if (!usage) {
    return null;
  }
  // Anthropic usage 字段语义：input/cache_creation/cache_read 三者互不相交，真实占用
  // 上下文窗口的 prompt token = input + cache_creation + cache_read。只数 input+output
  // 会把命中缓存的长会话低估 90% 以上，自动压缩永远不会触发。
  const input = intValue(usage.input_tokens) ?? intValue(usage.input) ?? 0;
  const output = intValue(usage.output_tokens) ?? intValue(usage.output) ?? 0;
  const cacheRead = intValue(usage.cache_read_input_tokens) ?? 0;
  const cacheCreation = intValue(usage.cache_creation_input_tokens) ?? 0;
  const used = input + output + cacheRead + cacheCreation;
  // total 只信任 CLI 明确给出的 context_window；硬编码 200K 会把 1M Claude 模型和
  // 275K GPT 模型的占用比例全部算错。total=0 时由 renderer 按模型目录兜底。
  const total = intValue(usage.context_window) ?? 0;
  return used > 0 || total > 0 ? { type: "tokenUsage", used, total, output } : null;
}

// ---------------------------------------------------------------------------
// Codex helpers
// ---------------------------------------------------------------------------

function isCodexApprovalRequest(method: string): boolean {
  return [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "applyPatchApproval",
    "execCommandApproval"
  ].includes(method);
}

function isCodexInteractiveRequest(method: string, object: JSONRecord): boolean {
  const params = recordValue(object.params) ?? {};
  const normalized = method.toLowerCase().replace(/_/g, "");
  return !normalized.includes("approval")
    && !normalized.includes("permission")
    && (normalized.includes("ask")
      || normalized.includes("question")
      || normalized.includes("choice")
      || normalized.includes("input")
      || Array.isArray(params.options)
      || Array.isArray(params.choices)
      || Array.isArray(params.questions));
}

function isCodexFileReadRequest(method: string): boolean {
  const normalized = method.toLowerCase().replace(/_/g, "");
  return normalized.includes("readfile") || normalized === "fs/read" || normalized.endsWith("/read");
}

function codexReadFilePath(params: JSONRecord): string | null {
  const direct = stringValue(params.path) ?? stringValue(params.filePath) ?? stringValue(params.filepath) ?? stringValue(params.uri);
  if (direct) {
    return direct.startsWith("file://") ? direct.slice("file://".length) : direct;
  }
  const file = recordValue(params.file);
  return file ? codexReadFilePath(file) : null;
}

const maxReadableFileBytes = 5 * 1024 * 1024;

function resolveCodexProjectFile(rawPath: string, projectPath: string): string {
  const projectRoot = realpathSync(projectPath);
  const candidate = path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(projectRoot, rawPath);
  const resolved = existsSync(candidate) ? realpathSync(candidate) : candidate;
  const relative = path.relative(projectRoot, resolved);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`Codex readFile 越过项目目录：${resolved}`);
  }
  if (!existsSync(resolved) || statSync(resolved).isDirectory()) {
    throw new Error(`Codex readFile 找不到文本文件：${resolved}`);
  }
  return resolved;
}

function readCodexProjectTextFile(filePath: string): string {
  if (statSync(filePath).size > maxReadableFileBytes) {
    throw new Error(`Codex readFile 文件过大，暂不支持读取超过 5 MB 的文件：${filePath}`);
  }
  const data = readFileSync(filePath);
  if (data.length > maxReadableFileBytes) {
    throw new Error(`Codex readFile 文件过大，暂不支持读取超过 5 MB 的文件：${filePath}`);
  }
  if (data.subarray(0, 4096).includes(0)) {
    throw new Error(`Codex readFile 检测到二进制文件，已拒绝读取：${filePath}`);
  }
  return data.toString("utf8");
}

function requestKey(value: unknown): string | null {
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    return String(value);
  }
  return null;
}

function threadIDFrom(object: JSONRecord): string | null {
  const thread = recordValue(object.thread);
  return stringValue(object.threadId) ?? stringValue(object.thread_id) ?? stringValue(thread?.id) ?? stringValue(thread?.threadId);
}

function turnIDFrom(object: JSONRecord): string | null {
  const turn = recordValue(object.turn);
  return stringValue(object.turnId) ?? stringValue(object.turn_id) ?? stringValue(turn?.id) ?? stringValue(turn?.turnId);
}

function itemIDFrom(object: JSONRecord): string | null {
  const item = recordValue(object.item);
  return stringValue(object.itemId) ?? stringValue(object.item_id) ?? stringValue(object.id) ?? stringValue(item?.id) ?? stringValue(item?.itemId);
}

function outputIDFrom(object: JSONRecord): string | null {
  const item = recordValue(object.item);
  return stringValue(object.itemId)
    ?? stringValue(object.item_id)
    ?? stringValue(object.callId)
    ?? stringValue(object.call_id)
    ?? stringValue(object.commandId)
    ?? stringValue(object.command_id)
    ?? stringValue(object.outputId)
    ?? stringValue(object.output_id)
    ?? stringValue(object.id)
    ?? (item ? outputIDFrom(item) : null);
}

function itemTitle(object: JSONRecord, fallback: string): string {
  const item = recordValue(object.item);
  return stringValue(object.title) ?? stringValue(object.name) ?? stringValue(object.type) ?? stringValue(item?.title) ?? stringValue(item?.name) ?? stringValue(item?.type) ?? fallback;
}

function itemTypeFrom(object: JSONRecord): string {
  const item = recordValue(object.item);
  return stringValue(object.type) ?? stringValue(object.itemType) ?? stringValue(object.item_type) ?? stringValue(item?.type) ?? stringValue(item?.itemType) ?? stringValue(item?.item_type) ?? "";
}

function deltaText(object: JSONRecord): string {
  return stringValue(object.delta) ?? stringValue(object.text) ?? stringValue(object.content) ?? compactText(object);
}

function diffText(object: JSONRecord): string | null {
  const direct = stringValue(object.diff) ?? stringValue(object.patch);
  if (direct) {
    return decodedDiffText(direct) ?? direct;
  }
  const item = recordValue(object.item);
  if (item) {
    return diffText(item);
  }
  const value = stringValue(object.delta) ?? stringValue(object.text) ?? stringValue(object.content);
  return value ? decodedDiffText(value) ?? value : null;
}

function decodedDiffText(value: string): string | null {
  const trimmed = value.trim();
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) {
    return null;
  }
  const object = parseJSONObject(trimmed);
  if (!object) {
    return null;
  }
  const diff = stringValue(object.diff) ?? stringValue(object.patch);
  if (diff) {
    return diff;
  }
  const item = recordValue(object.item);
  return item ? diffText(item) : null;
}

function nonEmptyDelta(kind: ChatMessageKind, title: string, params: JSONRecord, requestID: string): ChatBackendEvent[] {
  const text = deltaText(params);
  if (!text) {
    return [];
  }
  return [{ type: "appendDelta", kind, title, subtitle: "Codex", text, status: "streaming", requestID }];
}

function shouldSuppressCodexItemType(itemType: string): boolean {
  const normalized = itemType.replace(/[_\-\s]/g, "");
  return normalized.includes("usermessage")
    || normalized === "userinput"
    || normalized === "stderr"
    || normalized.includes("reasoning")
    || normalized.includes("plan");
}

function kindForCodexItem(object: JSONRecord, completed: boolean): ChatMessageKind {
  const item = recordValue(object.item);
  const haystack = [
    stringValue(object.type),
    stringValue(object.name),
    stringValue(item?.type),
    stringValue(item?.name)
  ].filter((value): value is string => Boolean(value)).join(" ").toLowerCase();
  const normalized = haystack.replace(/_/g, "");
  if (normalized.includes("agentmessage") || normalized.includes("assistantmessage")) {
    return "assistant";
  }
  if (haystack.includes("diff") || haystack.includes("patch") || haystack.includes("filechange") || haystack.includes("file_change")) {
    return "diff";
  }
  if (haystack.includes("command") || haystack.includes("exec") || haystack.includes("shell")) {
    return completed ? "commandOutput" : "command";
  }
  return completed ? "toolResult" : "toolCall";
}

function titleForApprovalMethod(method: string): string {
  if (method === "item/commandExecution/requestApproval" || method === "execCommandApproval") {
    return "命令执行权限";
  }
  if (method === "item/fileChange/requestApproval" || method === "applyPatchApproval") {
    return "文件修改权限";
  }
  if (method === "item/permissions/requestApproval") {
    return "额外权限请求";
  }
  return method;
}

function approvalText(method: string, params: JSONRecord): string {
  if (method === "item/commandExecution/requestApproval") {
    return [stringValue(params.command) ?? "未知命令", stringValue(params.cwd) ? `cwd: ${stringValue(params.cwd)}` : null, stringValue(params.reason)]
      .filter((value): value is string => Boolean(value))
      .join("\n");
  }
  if (method === "item/fileChange/requestApproval") {
    return [stringValue(params.grantRoot) ? `root: ${stringValue(params.grantRoot)}` : "文件修改", stringValue(params.reason)]
      .filter((value): value is string => Boolean(value))
      .join("\n");
  }
  return compactText(params);
}

function codexInteractiveOptions(params: JSONRecord): Array<{ id: string; label: string; detail: string }> {
  const rawOptions = Array.isArray(params.options) ? params.options : Array.isArray(params.choices) ? params.choices : Array.isArray(params.questions) ? params.questions : [];
  return rawOptions.map((option, index) => {
    const text = stringValue(option);
    if (text) {
      return { id: text, label: text, detail: "" };
    }
    const object = recordValue(option) ?? {};
    const id = stringValue(object.id) ?? stringValue(object.value) ?? stringValue(object.label) ?? `option-${index + 1}`;
    return {
      id,
      label: stringValue(object.label) ?? stringValue(object.title) ?? stringValue(object.text) ?? id,
      detail: stringValue(object.detail) ?? stringValue(object.description) ?? ""
    };
  });
}

function codexErrorText(error: unknown): string {
  if (typeof error === "string" && error.trim()) {
    return friendlyCodexErrorText(error);
  }
  const object = recordValue(error);
  if (!object) {
    return "Codex 运行失败。";
  }
  const message = stringValue(object.message);
  const additionalDetails = stringValue(object.additionalDetails);
  const errorInfo = stringValue(object.codexErrorInfo);
  const combined = [message, additionalDetails, errorInfo].filter((value): value is string => Boolean(value?.trim())).join("\n");
  if (combined) {
    return friendlyCodexErrorText(combined);
  }
  return friendlyCodexErrorText(compactText(object));
}

function friendlyCodexErrorText(raw: string): string {
  const lower = raw.toLowerCase();
  if (lower.includes("unauthorized") || lower.includes("access token could not be refreshed") || lower.includes("please sign in again")) {
    return "Codex 中转站认证失败。\n\nCodex 无法通过当前 ~/.codex/auth.json 里的 OPENAI_API_KEY 访问配置的模型服务。\n\n处理方式：\n1. 到设置页检查 Codex 的 base_url、OPENAI_API_KEY、model 和 wire_api。\n2. 保存配置后新开一个 Codex 会话再试。";
  }
  if (lower.includes("nodename nor servname provided") || lower.includes("failed to lookup address information") || lower.includes("timeout waiting for child process")) {
    return "Codex 网络连接失败。\n\n这通常是代理没有生效、代理不可达，或当前中转站地址无法解析。请确认设置页的 HTTP_PROXY / HTTPS_PROXY 和 Codex base_url 已保存，并新开 Codex 会话重试。";
  }
  return raw || "Codex 运行失败。";
}

function promptWithAttachments(prompt: string, attachments: ChatMessageAttachment[] = []): string {
  const text = prompt.trim();
  if (attachments.length === 0) {
    return text;
  }

  const attachmentLines = attachments.map((attachment) => `- ${attachment.filename}: ${attachment.path}`);
  const lead = text || "请根据以下附件继续处理。";
  return `${lead}\n\n附件:\n${attachmentLines.join("\n")}`;
}

function isVisibleOutput(event: ChatBackendEvent): boolean {
  if (event.type === "appendDelta" || event.type === "permissionRequest" || event.type === "interactiveRequest" || event.type === "failed") {
    return true;
  }
  return event.type === "appendMessage" && event.kind !== "system" && event.kind !== "rawOutput" && event.text.length > 0;
}
