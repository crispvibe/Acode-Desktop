import Darwin
import Foundation

/// 按 CLI 分发后端的工厂。Claude/Codex 走各自的专用实现，DeepSeek Harness 走
/// AcpProcessBackend（ACP v1 JSON-RPC stdio），其余大厂 CLI
/// （Cursor Agent / Gemini / Qwen / Copilot / Kimi / Antigravity / Kiro）
/// 全部由 StreamJSONProcessBackend 以参数化方式驱动。
enum ChatBackendFactory {
    static func makeBackend(for cli: CLIType) -> ChatProcessBackend {
        switch cli.visibleValue {
        case .codex:
            return CodexAppServerBackend()
        case .claude, .custom:
            return ClaudeCodeProcessBackend()
        case .cursor:
            return StreamJSONProcessBackend(kind: .cursor)
        case .gemini:
            return StreamJSONProcessBackend(kind: .gemini)
        case .qwen:
            return StreamJSONProcessBackend(kind: .qwen)
        case .copilot:
            return StreamJSONProcessBackend(kind: .copilot)
        case .kimi:
            return StreamJSONProcessBackend(kind: .kimi)
        case .agy:
            return StreamJSONProcessBackend(kind: .agy)
        case .kiro:
            return StreamJSONProcessBackend(kind: .kiro)
        case .dsh:
            return AcpProcessBackend()
        }
    }
}

/// 各家 CLI 的 print/headless 模式参数与事件形态。`arguments` 中实际用到的
/// flag 均已对照各 CLI 的 `--help` / 官方文档确认（详见实现注释）。
enum StreamJSONCLIKind: String, CaseIterable {
    case cursor
    case gemini
    case qwen
    case copilot
    case kimi
    case agy
    case kiro

    var cli: CLIType {
        CLIType(rawValue: rawValue) ?? .custom
    }

    var displayName: String {
        cli.displayName
    }

    /// print 模式的完整启动参数。
    /// - cursor-agent: `-p <prompt> --output-format stream-json --stream-partial-output`
    ///   （--stream-partial-output 才有增量 assistant 事件）；`--resume <chatId>` /
    ///   `--continue` 续会话；`--force` 自动批准工具；`--trust` 跳过工作区信任确认；
    ///   `--approve-mcps` 避免 headless 下卡在 MCP 批准。
    /// - gemini / qwen（qwen 为 gemini-cli fork，参数一致）:
    ///   `-p <prompt> -o stream-json --approval-mode <mode>`；
    ///   `--resume <id|latest>` 续会话；`-m` 指定模型。
    /// - copilot: `-p <prompt> --output-format json -s --no-ask-user`
    ///   （JSONL 事件流；-s 关闭统计尾部，--no-ask-user 禁止交互提问阻塞）；
    ///   `--allow-all-tools` 自动批准；`--resume=<id>` / `--continue` 续会话。
    /// - kimi: `-p <prompt> --output-format stream-json`（print 模式自动批准工具）；
    ///   `-r <session_id>` / `--continue` 续会话（resume flag 来自 kimi 自己输出的
    ///   session.resume_hint：`kimi -r session_<uuid>`）。
    /// - agy: `-p <prompt> --output-format stream-json`（NDJSON 事件）；
    ///   `--mode=accept-edits` / `--dangerously-skip-permissions` 控制权限；
    ///   resume flag 未经官方文档确认，安全起见忽略。
    /// - kiro: `chat --no-interactive --output-format stream-json --agent-engine v3`
    ///   （stream-json 仅在 V2/V3 engine 可用）；`--trust-all-tools` 免确认；
    ///   `--resume-id <id>` / `--resume` 续会话；`--effort` 支持 low~max。
    func arguments(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?) -> [String] {
        let resumeID = options.resumeSessionID?.nonEmptyTrimmed ?? session?.externalSessionID?.nonEmptyTrimmed
        let model = modelArgument(for: options.modelID)
        var args: [String] = []

        switch self {
        case .cursor:
            args = ["-p", prompt, "--output-format", "stream-json", "--stream-partial-output", "--trust", "--approve-mcps"]
            switch options.sessionMode {
            case .continueLast:
                args.append("--continue")
            case .resume:
                if let resumeID { args.append(contentsOf: ["--resume", resumeID]) }
            case .newSession:
                break
            }
            if options.permissionMode != .ask {
                // -f/--force = "Run Everything"：无头模式下没有权限交互通道，
                // autoEdit/fullAccess 都映射为它（.ask 已在 startRun 前置拒绝）。
                args.append("--force")
            }
            if let model { args.append(contentsOf: ["--model", model]) }

        case .gemini, .qwen:
            args = ["-p", prompt, "-o", "stream-json"]
            let approvalMode: String
            switch options.permissionMode {
            case .autoEdit: approvalMode = "auto_edit"
            case .fullAccess: approvalMode = "yolo"
            case .ask: approvalMode = "default"
            }
            args.append(contentsOf: ["--approval-mode", approvalMode])
            switch options.sessionMode {
            case .continueLast:
                args.append(contentsOf: ["--resume", "latest"])
            case .resume:
                if let resumeID { args.append(contentsOf: ["--resume", resumeID]) }
            case .newSession:
                break
            }
            if let model { args.append(contentsOf: ["-m", model]) }

        case .copilot:
            args = ["-p", prompt, "--output-format", "json", "-s", "--no-ask-user"]
            switch options.sessionMode {
            case .continueLast:
                args.append("--continue")
            case .resume:
                if let resumeID { args.append("--resume=\(resumeID)") }
            case .newSession:
                break
            }
            if options.permissionMode != .ask {
                args.append("--allow-all-tools")
            }
            if let model { args.append(contentsOf: ["--model", model]) }

        case .kimi:
            args = ["-p", prompt, "--output-format", "stream-json"]
            if options.permissionMode == .fullAccess {
                args.append("--yolo")
            }
            switch options.sessionMode {
            case .continueLast:
                args.append("--continue")
            case .resume:
                if let resumeID { args.append(contentsOf: ["-r", resumeID]) }
            case .newSession:
                break
            }
            if let model { args.append(contentsOf: ["-m", model]) }

        case .agy:
            args = ["-p", prompt, "--output-format", "stream-json"]
            switch options.permissionMode {
            case .autoEdit:
                args.append("--mode=accept-edits")
            case .fullAccess:
                args.append("--dangerously-skip-permissions")
            case .ask:
                break
            }
            // resume / continue 在 agy 上未找到官方确认，安全忽略（新会话启动）。
            if let model { args.append(contentsOf: ["--model", model]) }

        case .kiro:
            args = ["chat", "--no-interactive", "--output-format", "stream-json", "--agent-engine", "v3"]
            if options.permissionMode != .ask {
                args.append("--trust-all-tools")
            }
            args.append(contentsOf: ["--effort", options.reasoningEffort.rawValue])
            switch options.sessionMode {
            case .continueLast:
                args.append("--resume")
            case .resume:
                if let resumeID {
                    args.append(contentsOf: ["--resume-id", resumeID])
                } else {
                    args.append("--resume")
                }
            case .newSession:
                break
            }
            if let model { args.append(contentsOf: ["--model", model]) }
            args.append(prompt)
        }
        return args
    }

    /// "default"/空 id 表示让 CLI 使用自己配置的默认模型，不下发 --model。
    private func modelArgument(for modelID: String) -> String? {
        let execution = ChatModelCatalog.executionModelID(for: modelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !execution.isEmpty, execution != "default" else { return nil }
        return execution
    }
}

/// 通用 stream-json/JSONL 无头后端：spawn CLI → stdout 逐行解析为
/// ChatBackendEvent → 进程退出即完成。没有 stdin 控制协议，所以
/// respondToPermission / respondToInteractiveRequest / sendCompact 全部返回 false，
/// 权限在启动参数里一次性降级（--force / --approval-mode / --allow-all-tools /
/// --yolo / --trust-all-tools / --dangerously-skip-permissions）。
final class StreamJSONProcessBackend: ChatProcessBackend {
    let kind: StreamJSONCLIKind

    init(kind: StreamJSONCLIKind) {
        self.kind = kind
    }

    private struct ProcessRunResult {
        let terminationStatus: Int32
        let terminationReason: Process.TerminationReason
        let didReceiveVisibleOutput: Bool
        let didReceiveAssistantContent: Bool
        let didReceiveErrorResult: Bool
        let stderrOutput: String
        let stdoutDiagnostics: String
        let timedOut: Bool

        var diagnosticOutput: String {
            [stderrOutput, stdoutDiagnostics]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private struct StdoutReadResult {
        let didReceiveVisibleOutput: Bool
        let didReceiveAssistantContent: Bool
        let didReceiveErrorResult: Bool
        let diagnostics: String
    }

    private struct StreamState {
        /// 已 emit 的 assistant 文本累计值。各家 CLI 的 assistant 事件有的是增量
        /// （gemini delta:true）、有的是累计快照（cursor partial），统一用
        /// 前缀差分换算成 appendDelta，天然去重 model_call_id 副本。
        var assistantText = ""
        var didReceiveAssistantText = false
        var reasoningText = ""
        var didReceiveReasoningText = false
        var emittedToolCallIDs: Set<String> = []
        var sawTerminalResult = false
        var terminalSucceeded = false
    }

    private static let idleTimeout: TimeInterval = 30 * 60

    private var process: Process?
    private var activityWatchdog: ChatProcessActivityWatchdog?

    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) -> AsyncThrowingStream<ChatBackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let result = await self.runProcess(
                    prompt: prompt,
                    options: options,
                    session: session,
                    attachments: attachments,
                    continuation: continuation
                )
                self.finish(result, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                worker.cancel()
                self?.interrupt()
            }
        }
    }

    private func runProcess(
        prompt: String,
        options: ChatRunOptions,
        session: ChatSessionRecord?,
        attachments: [ChatMessageAttachment],
        continuation: AsyncThrowingStream<ChatBackendEvent, Error>.Continuation
    ) async -> ProcessRunResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: options.executablePath)
        process.arguments = kind.arguments(prompt: effectivePrompt(prompt, attachments: attachments), options: options, session: session)
        process.currentDirectoryURL = URL(fileURLWithPath: options.projectPath, isDirectory: true)
        process.environment = ChatCLIEnvironment.processEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        ChatProcessLauncher.isolateProcessGroup(process)
        self.process = process

        do {
            try process.run()
        } catch {
            self.process = nil
            continuation.yield(.failed(ChatProcessError.launchFailed(error.localizedDescription).localizedDescription))
            return ProcessRunResult(
                terminationStatus: -1,
                terminationReason: .uncaughtSignal,
                didReceiveVisibleOutput: false,
                didReceiveAssistantContent: false,
                didReceiveErrorResult: true,
                stderrOutput: error.localizedDescription,
                stdoutDiagnostics: "",
                timedOut: false
            )
        }

        let watchdog = ChatProcessActivityWatchdog(
            process: process,
            idleTimeout: Self.idleTimeout,
            terminateAfter: .milliseconds(800),
            killAfter: .seconds(2)
        )
        activityWatchdog = watchdog
        watchdog.markActivity()
        watchdog.start()
        continuation.yield(.backendActivity("process-started"))

        let displayName = kind.displayName
        let stdoutTask = Task { () -> StdoutReadResult in
            var didReceiveVisibleOutput = false
            var didReceiveAssistantContent = false
            var didReceiveErrorResult = false
            var streamState = StreamState()
            var eventCoalescer = ChatBackendEventCoalescer()
            var diagnostics: [String] = []
            var didTruncateDiagnostics = false
            var didYieldStdoutActivity = false

            func appendDiagnostic(_ text: String?) {
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                diagnostics.append(text)
                if diagnostics.count > 80 {
                    diagnostics.removeFirst(diagnostics.count - 60)
                    didTruncateDiagnostics = true
                }
            }

            func flushCoalescer() {
                for event in eventCoalescer.flush() {
                    continuation.yield(event)
                }
            }

            do {
                for try await line in JSONLStreamReader.lines(from: stdout) {
                    watchdog.markActivity()
                    if !didYieldStdoutActivity {
                        didYieldStdoutActivity = true
                        continuation.yield(.backendActivity("stdout-first-line"))
                    }
                    appendDiagnostic(Self.diagnosticText(fromLine: line))
                    let events = Self.events(fromLine: line, kind: self.kind, streamState: &streamState)
                    if events.contains(where: Self.isVisibleOutput) {
                        didReceiveVisibleOutput = true
                    }
                    if events.contains(where: Self.isAssistantOutput) {
                        didReceiveAssistantContent = true
                    }
                    if events.contains(where: Self.isErrorOutput) {
                        didReceiveErrorResult = true
                    }
                    for event in eventCoalescer.push(events) {
                        continuation.yield(event)
                    }
                    // 终态事件（result / session.idle / error 等）到达后 CLI 应自行退出；
                    // 主动 yield .finished 并延迟 stop，防止某些 CLI 在输出完结果后挂住不退出。
                    if streamState.sawTerminalResult {
                        flushCoalescer()
                        if streamState.terminalSucceeded {
                            continuation.yield(.finished)
                            continuation.finish()
                        }
                        Self.stopProcessAfterTerminalResult(process)
                        break
                    }
                }
                flushCoalescer()
            } catch {
                flushCoalescer()
                continuation.yield(.failed(error.localizedDescription))
            }

            let output = diagnostics.joined(separator: "\n")
            let diagnosticOutput = didTruncateDiagnostics ? "... stdout diagnostics truncated to last 60 entries ...\n\(output)" : output
            return StdoutReadResult(
                didReceiveVisibleOutput: didReceiveVisibleOutput,
                didReceiveAssistantContent: didReceiveAssistantContent,
                didReceiveErrorResult: didReceiveErrorResult,
                diagnostics: diagnosticOutput
            )
        }

        let stderrTask = Task { () -> String in
            var stderrLines: [String] = []
            var didTruncateStderr = false
            var pendingBuffer: [String] = []
            var lastFlushAt = Date()
            var didYieldStderrActivity = false
            let flushInterval: TimeInterval = 1.0
            let flushBatchSize = 50

            func flushPending() {
                guard !pendingBuffer.isEmpty else { return }
                let combined = pendingBuffer.joined(separator: "\n")
                pendingBuffer.removeAll(keepingCapacity: true)
                continuation.yield(.appendMessage(kind: .commandOutput, title: "stderr", subtitle: displayName, text: combined, status: "stream", requestID: nil))
            }

            do {
                for try await line in JSONLStreamReader.lines(from: stderr) {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    watchdog.markActivity()
                    if !didYieldStderrActivity {
                        didYieldStderrActivity = true
                        continuation.yield(.backendActivity("stderr-first-line"))
                    }
                    stderrLines.append(line)
                    if stderrLines.count > 600 {
                        stderrLines.removeFirst(stderrLines.count - 500)
                        didTruncateStderr = true
                    }
                    pendingBuffer.append(line)
                    let now = Date()
                    if pendingBuffer.count >= flushBatchSize || now.timeIntervalSince(lastFlushAt) >= flushInterval {
                        flushPending()
                        lastFlushAt = now
                    }
                }
                flushPending()
            } catch {
                flushPending()
            }
            let output = stderrLines.joined(separator: "\n")
            return didTruncateStderr ? "... stderr truncated to last 500 lines ...\n\(output)" : output
        }

        process.waitUntilExit()
        let timedOut = watchdog.timedOut
        watchdog.cancel()
        activityWatchdog = nil
        let stdoutResult = await stdoutTask.value
        let stderrOutput = await stderrTask.value
        self.process = nil

        return ProcessRunResult(
            terminationStatus: process.terminationStatus,
            terminationReason: process.terminationReason,
            didReceiveVisibleOutput: stdoutResult.didReceiveVisibleOutput,
            didReceiveAssistantContent: stdoutResult.didReceiveAssistantContent,
            didReceiveErrorResult: stdoutResult.didReceiveErrorResult,
            stderrOutput: stderrOutput,
            stdoutDiagnostics: stdoutResult.diagnostics,
            timedOut: timedOut
        )
    }

    private func finish(
        _ result: ProcessRunResult,
        continuation: AsyncThrowingStream<ChatBackendEvent, Error>.Continuation
    ) {
        let name = kind.displayName
        func messageWithDiagnostics(_ message: String) -> String {
            let diagnostics = result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return diagnostics.isEmpty ? message : "\(message)\n\(diagnostics)"
        }

        if result.didReceiveAssistantContent && !result.didReceiveErrorResult {
            // 中途被截断（超时/信号）但已有真实回复且没报错误 → 按完成处理，保留已收到内容。
            continuation.yield(.finished)
        } else if result.timedOut {
            continuation.yield(.failed(messageWithDiagnostics("\(name) 后端超时无响应，已停止进程。请检查认证、模型或网络配置。")))
        } else if result.didReceiveErrorResult {
            continuation.yield(.failed(messageWithDiagnostics("\(name) 运行失败。")))
        } else if result.terminationStatus == 0 {
            continuation.yield(.failed("\(name) 没有输出任何对话内容。请检查认证配置或模型设置。"))
        } else if result.terminationReason == .uncaughtSignal {
            continuation.yield(.failed(messageWithDiagnostics("\(name) 已停止。")))
        } else {
            continuation.yield(.failed(messageWithDiagnostics("\(name) 退出码：\(result.terminationStatus)")))
        }
    }

    /// 无 stdin 通道，附件只能以路径形式拼进 prompt（与 QueuedChatRequest 的
    /// displayText 区分：displayText 已包含附件占位行，backend prompt 追加真实路径）。
    private func effectivePrompt(_ prompt: String, attachments: [ChatMessageAttachment]) -> String {
        let paths = attachments.map(\.path).compactMap { $0.nonEmptyTrimmed }
        guard !paths.isEmpty else { return prompt }
        return prompt + "\n\n" + paths.joined(separator: "\n")
    }

    func interrupt() {
        activityWatchdog?.cancel()
        activityWatchdog = nil
        guard let process, process.isRunning else { return }
        ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(800), killAfter: .seconds(2))
    }

    func terminateImmediately() {
        activityWatchdog?.cancel()
        activityWatchdog = nil
        guard let process, process.isRunning else { return }
        ChatProcessTerminator.killNow(process)
    }

    /// 这些 CLI 的无头模式没有权限回写协议（权限已折叠进启动 flag），返回 false
    /// 让上层不展示假权限按钮。
    func respondToPermission(requestID: String, decision: ChatPermissionDecision) -> Bool {
        false
    }

    func respondToInteractiveRequest(requestID: String, response: ChatInteractiveResponse) -> Bool {
        false
    }

    func sendCompact() -> Bool {
        false
    }

    // MARK: - 行解析

    /// 终端 result 到达后给进程一点自然退出的时间，随后 SIGINT→SIGTERM→SIGKILL。
    private static func stopProcessAfterTerminalResult(_ process: Process) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) { [weak process] in
            guard let process, process.isRunning else { return }
            ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(150), killAfter: .milliseconds(700))
        }
    }

    private static func isVisibleOutput(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .appendDelta, .permissionRequest, .interactiveRequest, .failed:
            true
        case .appendMessage(let kind, _, _, let text, _, _):
            kind != .system && kind != .rawOutput && !text.isEmpty
        case .finishStreamingMessage, .sessionID, .updateStreamingStatus, .backendActivity, .finished, .tokenUsage:
            false
        }
    }

    private static func isAssistantOutput(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .appendDelta(let kind, _, _, let text, _, _), .appendMessage(let kind, _, _, let text, _, _):
            kind == .assistant && !text.isEmpty
        case .finishStreamingMessage, .sessionID, .updateStreamingStatus, .backendActivity, .permissionRequest, .interactiveRequest, .finished, .failed, .tokenUsage:
            false
        }
    }

    private static func isErrorOutput(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .appendMessage(let kind, _, _, _, _, _):
            kind == .error
        case .failed:
            true
        default:
            false
        }
    }

    /// 归并进 stderr 诊断的错误/异常文本（不直接展示，只在失败时拼进错误消息）。
    private static func diagnosticText(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = (stringValue(object["type"]) ?? stringValue(object["event"]) ?? "").lowercased()
        if let errorText = errorText(from: object, type: type) {
            return errorText
        }
        if type == "result" || type.hasSuffix(".error") {
            let status = (stringValue(object["status"]) ?? stringValue(object["subtype"]) ?? "").lowercased()
            guard status != "success" else { return nil }
            return stringValue(object["message"]) ?? stringValue(object["result"]) ?? compactText(from: object)
        }
        return nil
    }

    // MARK: - 事件映射（各家 stream-json/JSONL 形态的并集解析）

    private static func events(fromLine line: String, kind: StreamJSONCLIKind, streamState: inout StreamState) -> [ChatBackendEvent] {
        let name = kind.displayName
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 非 JSON 行：CLI 忽略了 --output-format 或是杂散 stdout 文本，
            // 以 rawOutput 兜底展示而不是静默丢弃。
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.isInternalToolNoiseLine else { return [] }
            return [.appendMessage(kind: .rawOutput, title: "raw", subtitle: name, text: trimmed, status: "stream", requestID: nil)]
        }

        var events: [ChatBackendEvent] = []

        if let sessionID = sessionID(from: object) {
            events.append(.sessionID(sessionID))
        }
        if let usageEvent = extractTokenUsage(from: object) {
            events.append(usageEvent)
        }

        // Kimi 等 OpenAI 形态：{ "role": "assistant" | "tool" | "meta", ... }
        if let role = stringValue(object["role"]), object["type"] == nil || kind == .kimi {
            events.append(contentsOf: roleEvents(role: role, object: object, name: name, streamState: &streamState))
            return events
        }

        let type = (stringValue(object["type"]) ?? stringValue(object["event"]) ?? "").lowercased()
        let dataObject = object["data"] as? [String: Any] ?? object

        if let errorText = errorText(from: object, type: type) {
            events.append(.appendMessage(kind: .error, title: name, subtitle: type, text: errorText, status: "failed", requestID: nil))
            streamState.sawTerminalResult = true
            return events
        }

        switch type {
        case "init", "system", "ping", "rate_limit", "hooks", "control_request", "control_cancel_request":
            // init/system 只承载会话元信息（session_id/model），已在上面对象级提取。
            break

        case "user", "user.message":
            break

        case "message":
            // gemini/qwen：{ type:"message", role:"assistant", content:"...", delta:true }
            let role = stringValue(object["role"]) ?? ""
            guard role != "user" else { break }
            if role == "assistant" {
                emitAssistantMessage(content: assistantText(from: object, data: dataObject), isDelta: boolValue(object["delta"]) == true, name: name, streamState: &streamState, events: &events)
            }

        case "assistant", "assistant.message":
            // cursor：type=assistant + message.content[]；copilot：type=assistant.message + data.content。
            // cursor 的 model_call_id 副本是同一文本的缓冲重发，差分后自然为空，无需特判。
            if kind == .cursor, stringValue(object["model_call_id"]) != nil { break }
            emitAssistantMessage(content: assistantText(from: object, data: dataObject), isDelta: false, name: name, streamState: &streamState, events: &events)

        case "thinking", "reasoning", "assistant.reasoning", "assistant.thinking":
            emitReasoningMessage(content: assistantText(from: object, data: dataObject), name: name, streamState: &streamState, events: &events)

        case "tool_use", "tool_call", "tool.execution_start", "tool.executionstart":
            events.append(contentsOf: toolCallEvents(from: object, data: dataObject, name: name, streamState: &streamState))

        case "tool_result", "tool.execution_complete", "tool.executioncomplete":
            events.append(contentsOf: toolResultEvents(from: object, data: dataObject, name: name))

        case "result":
            let status = (stringValue(object["status"]) ?? stringValue(object["subtype"]) ?? "success").lowercased()
            let succeeded = status == "success" || status == "ok" || status == "completed" || status == "idle"
            if succeeded, !streamState.didReceiveAssistantText,
               let resultText = stringValue(object["result"]) ?? stringValue(object["response"]) ?? stringValue(dataObject["result"]) {
                emitAssistantMessage(content: resultText, isDelta: false, name: name, streamState: &streamState, events: &events)
            }
            if !succeeded {
                let errorText = stringValue(object["message"])
                    ?? stringValue(object["error"])
                    ?? stringValue((object["error"] as? [String: Any])?["message"])
                    ?? stringValue(object["result"])
                    ?? compactText(from: object)
                events.append(.appendMessage(kind: .error, title: name, subtitle: "result", text: errorText, status: "failed", requestID: nil))
            }
            streamState.sawTerminalResult = true
            streamState.terminalSucceeded = succeeded

        case "session.idle", "session.task_complete", "done", "turn_end", "session.end", "complete", "completed":
            streamState.sawTerminalResult = true
            streamState.terminalSucceeded = true

        default:
            if type.contains("interrupt") {
                streamState.sawTerminalResult = true
                streamState.terminalSucceeded = true
            }
            // 其余未识别 type：静默跳过（compact 文本已进 stdout diagnostics）。
        }
        return events
    }

    /// Kimi/OpenAI 形态事件：role=assistant（content + tool_calls）、role=tool、
    /// role=meta（session.resume_hint 等元信息）。
    private static func roleEvents(role: String, object: [String: Any], name: String, streamState: inout StreamState) -> [ChatBackendEvent] {
        var events: [ChatBackendEvent] = []
        switch role.lowercased() {
        case "assistant":
            emitAssistantMessage(content: assistantText(from: object, data: object), isDelta: false, name: name, streamState: &streamState, events: &events)
            if let toolCalls = object["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    let function = call["function"] as? [String: Any] ?? call
                    let toolName = stringValue(function["name"]) ?? stringValue(call["name"]) ?? "tool"
                    let requestID = stringValue(call["id"]) ?? stringValue(call["tool_call_id"]) ?? "tool-\(streamState.emittedToolCallIDs.count + 1)"
                    guard !streamState.emittedToolCallIDs.contains(requestID) else { continue }
                    streamState.emittedToolCallIDs.insert(requestID)
                    let argumentsText = stringValue(function["arguments"]) ?? compactText(from: function)
                    events.append(.appendMessage(kind: .toolCall, title: toolName, subtitle: name, text: argumentsText, status: "running", requestID: requestID))
                }
            }
        case "tool":
            let requestID = stringValue(object["tool_call_id"]) ?? stringValue(object["id"])
            let text = stringValue(object["content"]) ?? compactText(from: object)
            events.append(.appendMessage(kind: .toolResult, title: "tool", subtitle: name, text: text, status: "done", requestID: requestID))
        case "meta", "user", "system":
            break
        default:
            break
        }
        return events
    }

    /// 前缀差分：把"累计快照 / 增量块 / 重复副本"三种形态统一换算成 appendDelta。
    private static func emitAssistantMessage(content: String?, isDelta: Bool, name: String, streamState: inout StreamState, events: inout [ChatBackendEvent]) {
        guard let content, !content.isEmpty else { return }
        let delta: String
        if isDelta {
            delta = content
            streamState.assistantText += content
        } else if content.hasPrefix(streamState.assistantText) {
            delta = String(content.dropFirst(streamState.assistantText.count))
            streamState.assistantText = content
        } else {
            // 与已累计文本无前缀关系 → 视为新一段（新 turn / 独立消息），整体追加。
            delta = content
            streamState.assistantText += content
        }
        guard !delta.isEmpty else { return }
        streamState.didReceiveAssistantText = true
        events.append(.appendDelta(kind: .assistant, title: "assistant", subtitle: name, text: delta, status: "streaming", requestID: nil))
    }

    private static func emitReasoningMessage(content: String?, name: String, streamState: inout StreamState, events: inout [ChatBackendEvent]) {
        guard let content, !content.isEmpty else { return }
        let delta: String
        if content.hasPrefix(streamState.reasoningText) {
            delta = String(content.dropFirst(streamState.reasoningText.count))
            streamState.reasoningText = content
        } else {
            delta = content
            streamState.reasoningText += content
        }
        guard !delta.isEmpty else { return }
        streamState.didReceiveReasoningText = true
        events.append(.appendDelta(kind: .reasoning, title: "thinking", subtitle: name, text: delta, status: "streaming", requestID: nil))
    }

    /// tool_use（gemini：`tool_name`/`tool_id`/`parameters`）、tool_call（cursor：
    /// `tool_call.{shell|read|edit...}ToolCall` 信封 + subtype started/completed）、
    /// tool.execution_start（copilot：`data.toolCallId`/`data.toolName`/`data.arguments`）、
    /// kimi tool_calls（roleEvents 里单独处理）。
    private static func toolCallEvents(from object: [String: Any], data: [String: Any], name: String, streamState: inout StreamState) -> [ChatBackendEvent] {
        let subtype = (stringValue(object["subtype"]) ?? "").lowercased()
        // cursor tool_call completed → 交给 toolResult 路径
        let isCompleted = subtype == "completed" || subtype == "finished" || subtype == "done"

        // cursor 信封：tool_call 字段里嵌套 xxxToolCall
        if let envelope = object["tool_call"] as? [String: Any] {
            let innerKey = envelope.keys.first { $0.lowercased().hasSuffix("toolcall") } ?? envelope.keys.first ?? "tool"
            let innerName = innerKey.replacingOccurrences(of: "ToolCall", with: "").replacingOccurrences(of: "toolCall", with: "")
            let payload = envelope[innerKey] as? [String: Any] ?? envelope
            let requestID = stringValue(payload["tool_call_id"]) ?? stringValue(payload["call_id"]) ?? stringValue(object["tool_call_id"]) ?? stringValue(object["id"]) ?? UUID().uuidString
            let text = compactText(from: payload)
            if isCompleted {
                return [.appendMessage(kind: .toolResult, title: innerName.isEmpty ? "tool" : innerName, subtitle: name, text: text, status: "done", requestID: requestID)]
            }
            streamState.emittedToolCallIDs.insert(requestID)
            return [.appendMessage(kind: .toolCall, title: innerName.isEmpty ? "tool" : innerName, subtitle: name, text: text, status: "running", requestID: requestID)]
        }

        let toolName = stringValue(data["tool_name"]) ?? stringValue(data["toolName"]) ?? stringValue(data["name"]) ?? stringValue(object["tool_name"]) ?? "tool"
        let requestID = stringValue(data["tool_id"]) ?? stringValue(data["toolCallId"]) ?? stringValue(data["id"]) ?? stringValue(object["tool_id"]) ?? stringValue(object["id"]) ?? UUID().uuidString
        let argumentsText = stringValue(data["parameters"])
            ?? stringValue(data["arguments"])
            ?? stringValue(data["input"])
            ?? compactText(from: data["parameters"] as? [String: Any] ?? data["arguments"] as? [String: Any] ?? data["input"] as? [String: Any] ?? data)
        if isCompleted {
            return [.appendMessage(kind: .toolResult, title: toolName, subtitle: name, text: argumentsText, status: "done", requestID: requestID)]
        }
        streamState.emittedToolCallIDs.insert(requestID)
        return [.appendMessage(kind: .toolCall, title: toolName, subtitle: name, text: argumentsText, status: "running", requestID: requestID)]
    }

    /// tool_result（gemini：`tool_id`/`status`/`output`/`error`）、
    /// tool.execution_complete（copilot：`data.toolCallId`/`data.success`/`data.result`）。
    private static func toolResultEvents(from object: [String: Any], data: [String: Any], name: String) -> [ChatBackendEvent] {
        let requestID = stringValue(data["tool_id"]) ?? stringValue(data["toolCallId"]) ?? stringValue(data["id"]) ?? stringValue(object["tool_id"]) ?? stringValue(object["id"])
        let status = (stringValue(object["status"]) ?? stringValue(data["status"]) ?? "").lowercased()
        let success = boolValue(data["success"]) ?? (status != "error" && status != "failed" && status != "denied")
        let text = stringValue(data["output"])
            ?? stringValue(data["result"])
            ?? stringValue((data["result"] as? [String: Any])?["content"])
            ?? stringValue((data["result"] as? [String: Any])?["output"])
            ?? stringValue((data["error"] as? [String: Any])?["message"])
            ?? stringValue(data["error"])
            ?? stringValue(object["output"])
            ?? stringValue(object["result"])
            ?? compactText(from: data)
        return [.appendMessage(kind: .toolResult, title: "tool", subtitle: name, text: text, status: success ? "done" : "failed", requestID: requestID)]
    }

    /// assistant/reasoning/thinking/message 事件的文本提取：
    /// - content 为 String → 直接用
    /// - content 为 [{type:"text",text:...}] 块数组 → 拼接 text/thinking 块
    /// - message.content / data.content 嵌套同规则
    private static func assistantText(from object: [String: Any], data: [String: Any]) -> String? {
        if let delta = object["delta"] as? [String: Any],
           let text = stringValue(delta["text"]) ?? stringValue(delta["content"]) {
            return text
        }
        for source in [object, data] {
            if let text = contentText(from: source) { return text }
            if let message = source["message"] as? [String: Any], let text = contentText(from: message) { return text }
        }
        return nil
    }

    private static func contentText(from object: [String: Any]) -> String? {
        if let text = stringValue(object["text"]) ?? stringValue(object["content"]) {
            return text
        }
        if let blocks = object["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                let type = (stringValue(block["type"]) ?? "text").lowercased()
                guard type == "text" || type == "thinking" || type == "reasoning" else { return nil }
                return stringValue(block["text"]) ?? stringValue(block["thinking"]) ?? stringValue(block["content"])
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func sessionID(from object: [String: Any]) -> String? {
        let keys = ["session_id", "sessionId", "sessionID", "conversation_id", "conversationId", "chat_id", "chatId"]
        for key in keys {
            if let value = stringValue(object[key]) { return value }
        }
        for nestedKey in ["session", "data", "init", "meta"] {
            if let nested = object[nestedKey] as? [String: Any] {
                for key in keys + ["id"] {
                    if let value = stringValue(nested[key]) { return value }
                    if let idObject = nested[key] as? [String: Any], let value = stringValue(idObject["id"]) { return value }
                }
            }
        }
        return nil
    }

    private static func extractTokenUsage(from object: [String: Any]) -> ChatBackendEvent? {
        for key in ["usage", "stats", "token_usage", "tokenUsage"] {
            if let usage = object[key] as? [String: Any], let event = usageEvent(from: usage) {
                return event
            }
        }
        for parentKey in ["message", "data", "result"] {
            if let parent = object[parentKey] as? [String: Any] {
                for key in ["usage", "stats", "token_usage", "tokenUsage"] {
                    if let usage = parent[key] as? [String: Any], let event = usageEvent(from: usage) {
                        return event
                    }
                }
            }
        }
        return nil
    }

    private static func usageEvent(from usage: [String: Any]) -> ChatBackendEvent? {
        let inputTokens = intValue(usage["input_tokens"]) ?? intValue(usage["prompt_tokens"]) ?? intValue(usage["input"]) ?? 0
        let outputTokens = intValue(usage["output_tokens"]) ?? intValue(usage["completion_tokens"]) ?? intValue(usage["output"]) ?? 0
        let cacheRead = intValue(usage["cache_read_input_tokens"]) ?? intValue(usage["cached_tokens"]) ?? intValue(usage["cached"]) ?? 0
        let cacheCreation = intValue(usage["cache_creation_input_tokens"]) ?? 0
        let used = intValue(usage["total_tokens"]) ?? intValue(usage["totalTokens"]) ?? (inputTokens + outputTokens + cacheRead + cacheCreation)
        let total = intValue(usage["context_window"]) ?? intValue(usage["contextWindow"]) ?? 0
        guard used > 0 || total > 0 else { return nil }
        return .tokenUsage(used: used, total: total, output: outputTokens > 0 ? outputTokens : nil)
    }

    private static func errorText(from object: [String: Any], type: String) -> String? {
        let lowercasedType = type.lowercased()
        guard lowercasedType == "error"
            || lowercasedType.hasSuffix("_error")
            || lowercasedType.hasSuffix(".error")
            || lowercasedType.contains("exception")
            || lowercasedType.contains("failed")
        else {
            return nil
        }
        let data = object["data"] as? [String: Any] ?? object
        if let message = stringValue(data["message"]) ?? stringValue(data["error"]) ?? stringValue(object["message"]) ?? stringValue(object["error"]) {
            return message
        }
        if let error = object["error"] as? [String: Any] ?? data["error"] as? [String: Any] {
            if let message = stringValue(error["message"]) ?? stringValue(error["error"]) {
                let code = stringValue(error["code"]) ?? stringValue(error["type"])
                return [code, message].compactMap { $0?.nonEmptyTrimmed }.joined(separator: ": ")
            }
            return compactText(from: error)
        }
        return compactText(from: object)
    }

    private static func compactText(from object: [String: Any]) -> String {
        if let text = stringValue(object["text"]) ?? stringValue(object["content"]) ?? stringValue(object["message"]),
           object.keys.allSatisfy({ ["text", "content", "message"].contains($0) }) {
            return text
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
