import Darwin
import Foundation

final class ClaudeCodeProcessBackend: ChatProcessBackend {
    private struct ProcessRunResult {
        let terminationStatus: Int32
        let terminationReason: Process.TerminationReason
        let didReceiveVisibleOutput: Bool
        let didReceiveSuccessfulResult: Bool
        let didReceiveAssistantContent: Bool
        let didReceiveErrorResult: Bool
        let stderrOutput: String
        let stdoutDiagnostics: String
        let timedOut: Bool

        var shouldRetryWithoutEffort: Bool {
            guard !timedOut, terminationStatus != 0 else { return false }
            let lowercasedDiagnostics = diagnosticOutput.lowercased()
            return lowercasedDiagnostics.contains("--effort")
                || lowercasedDiagnostics.contains("unknown option 'effort'")
                || lowercasedDiagnostics.contains("unknown option: effort")
                || lowercasedDiagnostics.contains("unexpected argument '--effort'")
        }

        var shouldRetryWithoutPartialMessages: Bool {
            guard !timedOut, terminationStatus != 0 else { return false }
            let lowercasedDiagnostics = diagnosticOutput.lowercased()
            return lowercasedDiagnostics.contains("--include-partial-messages")
                || lowercasedDiagnostics.contains("unknown option 'include-partial-messages'")
                || lowercasedDiagnostics.contains("unknown option: include-partial-messages")
                || lowercasedDiagnostics.contains("unexpected argument '--include-partial-messages'")
        }

        var shouldRetryWithoutBrief: Bool {
            guard !timedOut, terminationStatus != 0 else { return false }
            let lowercasedDiagnostics = diagnosticOutput.lowercased()
            return lowercasedDiagnostics.contains("--brief")
                || lowercasedDiagnostics.contains("unknown option 'brief'")
                || lowercasedDiagnostics.contains("unknown option: brief")
                || lowercasedDiagnostics.contains("unexpected argument '--brief'")
        }

        var shouldRetryWithoutPermissionPromptTool: Bool {
            guard !timedOut, terminationStatus != 0 else { return false }
            let lowercasedDiagnostics = diagnosticOutput.lowercased()
            guard lowercasedDiagnostics.contains("permission-prompt-tool") else { return false }
            return lowercasedDiagnostics.contains("unknown option")
                || lowercasedDiagnostics.contains("unexpected argument")
                || lowercasedDiagnostics.contains("unrecognized")
                || lowercasedDiagnostics.contains("invalid option")
        }

        var diagnosticOutput: String {
            [stderrOutput, stdoutDiagnostics]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private struct StdoutReadResult {
        let didReceiveVisibleOutput: Bool
        let didReceiveSuccessfulResult: Bool
        let didReceiveAssistantContent: Bool
        let didReceiveErrorResult: Bool
        let diagnostics: String
    }

    private struct ClaudeContentBlock {
        let id: String?
        let type: String
        let name: String?
    }

    private struct ClaudeStreamState {
        var didReceiveAssistantTextDelta = false
        var didReceiveStreamEventAssistantTextDelta = false
        var topLevelAssistantText = ""
        var emittedContentItemIDs: Set<String> = []
        var activeBlocks: [Int: ClaudeContentBlock] = [:]
    }

    private static let idleTimeout: TimeInterval = 30 * 60

    private var process: Process?
    private var inputPipe: Pipe?
    private var didCloseInputPipe = false
    private var activeSessionID: String?
    private var activityWatchdog: ChatProcessActivityWatchdog?
    private let compactStateLock = NSLock()
    private var isWaitingForCompactResult = false

    /// One AskUserQuestion question parsed from a `can_use_tool` control_request,
    /// retaining the option-id → label map so a user's selection can be turned back
    /// into the `answers` map the CLI expects in `updatedInput`.
    private struct ParsedAskQuestion {
        let text: String
        let multiSelect: Bool
        let optionLabelsByID: [String: String]
    }

    /// A pending tool-permission / AskUserQuestion request awaiting our
    /// `control_response`. `input`/`toolUseID` are echoed back verbatim so the CLI
    /// runs the tool with the original (or answer-augmented) input.
    private struct PendingControlRequest {
        let requestID: String
        let toolName: String
        let input: [String: Any]
        let toolUseID: String?
        let questions: [ParsedAskQuestion]
    }

    private let controlLock = NSLock()
    private var pendingControlRequests: [String: PendingControlRequest] = [:]
    /// Serializes all writes to the child's stdin so concurrent replies (initial prompt,
    /// permission/selection answers, /compact) from different tasks can't interleave and
    /// corrupt the JSONL stream.
    private let pipeWriteLock = NSLock()

    private func writeJSONToInput(_ object: [String: Any]) -> Bool {
        pipeWriteLock.lock()
        defer { pipeWriteLock.unlock() }
        return ChatPipeWriter.writeJSONObject(object, to: inputPipe)
    }

    private func setPendingControlRequest(_ request: PendingControlRequest) {
        controlLock.lock(); pendingControlRequests[request.requestID] = request; controlLock.unlock()
    }

    private func pendingControlRequest(_ id: String) -> PendingControlRequest? {
        controlLock.lock(); defer { controlLock.unlock() }; return pendingControlRequests[id]
    }

    private func removePendingControlRequest(_ id: String) {
        controlLock.lock(); pendingControlRequests.removeValue(forKey: id); controlLock.unlock()
    }

    private func clearPendingControlRequests() {
        controlLock.lock(); pendingControlRequests.removeAll(); controlLock.unlock()
    }

    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) -> AsyncThrowingStream<ChatBackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                var includeEffort = true
                var includePartialMessages = true
                var includeBrief = true
                var includePermissionPromptTool = true
                let finalRun: ProcessRunResult

                while true {
                    guard let run = await self.runProcess(
                        prompt: prompt,
                        options: options,
                        session: session,
                        attachments: attachments,
                        includeEffort: includeEffort,
                        includePartialMessages: includePartialMessages,
                        includeBrief: includeBrief,
                        includePermissionPromptTool: includePermissionPromptTool,
                        continuation: continuation
                    ) else {
                        continuation.finish()
                        return
                    }

                    if includePermissionPromptTool, run.shouldRetryWithoutPermissionPromptTool {
                        includePermissionPromptTool = false
                        continuation.yield(.appendMessage(
                            kind: .system,
                            title: "Claude Code",
                            subtitle: "fallback",
                            text: "当前 Claude Code 没有接受 --permission-prompt-tool，本次已改用默认权限处理重试。",
                            status: "retry",
                            requestID: nil
                        ))
                        continue
                    }

                    if includeBrief, run.shouldRetryWithoutBrief {
                        includeBrief = false
                        continuation.yield(.appendMessage(
                            kind: .system,
                            title: "Claude Code",
                            subtitle: "fallback",
                            text: "当前 Claude Code 没有接受 --brief，本次已关闭内嵌用户交互工具后重试。",
                            status: "retry",
                            requestID: nil
                        ))
                        continue
                    }

                    if includePartialMessages, run.shouldRetryWithoutPartialMessages {
                        includePartialMessages = false
                        continuation.yield(.appendMessage(
                            kind: .system,
                            title: "Claude Code",
                            subtitle: "fallback",
                            text: "当前 Claude Code 没有接受 --include-partial-messages，本次已自动改用普通 stream-json 重试。",
                            status: "retry",
                            requestID: nil
                        ))
                        continue
                    }

                    if includeEffort, run.shouldRetryWithoutEffort {
                        includeEffort = false
                        continuation.yield(.appendMessage(
                            kind: .system,
                            title: "Claude Code",
                            subtitle: "fallback",
                            text: "当前 Claude Code 没有接受 --effort，本次已自动改用默认思考强度重试。",
                            status: "retry",
                            requestID: nil
                        ))
                        continue
                    }

                    finalRun = run
                    break
                }

                self.finish(finalRun, continuation: continuation)
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
        includeEffort: Bool,
        includePartialMessages: Bool,
        includeBrief: Bool,
        includePermissionPromptTool: Bool,
        continuation: AsyncThrowingStream<ChatBackendEvent, Error>.Continuation
    ) async -> ProcessRunResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        clearPendingControlRequests()
        process.executableURL = URL(fileURLWithPath: options.executablePath)
        process.arguments = arguments(prompt: prompt, options: options, session: session, includeEffort: includeEffort, includePartialMessages: includePartialMessages, includeBrief: includeBrief, includePermissionPromptTool: includePermissionPromptTool)
        process.currentDirectoryURL = URL(fileURLWithPath: options.projectPath, isDirectory: true)
        process.environment = ChatCLIEnvironment.processEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        ChatProcessLauncher.isolateProcessGroup(process)
        if options.supportsStreamJSONInput {
            process.standardInput = stdin
            inputPipe = stdin
            didCloseInputPipe = false
            activeSessionID = session?.externalSessionID?.nonEmptyTrimmed
        } else {
            inputPipe = nil
            didCloseInputPipe = false
            activeSessionID = nil
        }
        self.process = process

        do {
            try process.run()
        } catch {
            inputPipe = nil
            activeSessionID = nil
            continuation.yield(.failed(ChatProcessError.launchFailed(error.localizedDescription).localizedDescription))
            return nil
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
        if options.supportsStreamJSONInput {
            guard self.writeStreamUserMessage(text: prompt, attachments: attachments, sessionID: activeSessionID, parentToolUseID: nil, toolUseResult: nil, projectPath: options.projectPath) else {
                watchdog.cancel()
                activityWatchdog = nil
                inputPipe = nil
                activeSessionID = nil
                ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(200), killAfter: .milliseconds(800))
                continuation.yield(.failed("Claude Code stream-json 输入写入失败。"))
                return nil
            }
            continuation.yield(.backendActivity("stdin-written"))
        }
        watchdog.markActivity()

        let stdoutTask = Task { () -> StdoutReadResult in
            var didReceiveVisibleOutput = false
            var didReceiveSuccessfulResult = false
            var didReceiveAssistantContent = false
            var didReceiveErrorResult = false
            // Count of background tasks (Bash run_in_background) the model launched that haven't
            // reported completion. While >0, a turn-ending `result` is NOT terminal: claude
            // stays alive, the task notification will arrive, and the model auto-continues.
            var pendingBackgroundTasks = 0
            var streamState = ClaudeStreamState()
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

            func makeReadResult() -> StdoutReadResult {
                let output = diagnostics.joined(separator: "\n")
                let diagnosticOutput = didTruncateDiagnostics ? "... stdout diagnostics truncated to last 60 entries ...\n\(output)" : output
                return StdoutReadResult(didReceiveVisibleOutput: didReceiveVisibleOutput, didReceiveSuccessfulResult: didReceiveSuccessfulResult, didReceiveAssistantContent: didReceiveAssistantContent, didReceiveErrorResult: didReceiveErrorResult, diagnostics: diagnosticOutput)
            }

            do {
                for try await line in JSONLStreamReader.lines(from: stdout) {
                    watchdog.markActivity()
                    if !didYieldStdoutActivity {
                        didYieldStdoutActivity = true
                        continuation.yield(.backendActivity("stdout-first-line"))
                    }
                    if let controlEvents = self.handleControlRequestLine(line) {
                        didReceiveVisibleOutput = true
                        // We are now blocked on the user; freeze the idle watchdog so a slow
                        // human answer can't be mistaken for a dead process.
                        watchdog.pause()
                        for event in eventCoalescer.push(controlEvents) {
                            continuation.yield(event)
                        }
                        continue
                    }
                    appendDiagnostic(Self.diagnosticText(fromClaudeLine: line))
                    switch Self.backgroundTaskTransition(forLine: line) {
                    case .started:
                        pendingBackgroundTasks += 1
                    case .completed:
                        pendingBackgroundTasks = max(0, pendingBackgroundTasks - 1)
                        watchdog.resume()
                    case .none:
                        break
                    }
                    let events = Self.events(fromClaudeLine: line, streamState: &streamState)
                    if events.contains(where: Self.isVisibleOutput) {
                        didReceiveVisibleOutput = true
                    }
                    if events.contains(where: Self.isAssistantOutput) {
                        didReceiveAssistantContent = true
                    }
                    if events.contains(where: Self.isErrorOutput) {
                        didReceiveErrorResult = true
                    }
                    if events.contains(where: Self.shouldPauseActivityWatchdog) {
                        watchdog.pause()
                    }
                    for event in eventCoalescer.push(events) {
                        if case .sessionID(let sessionID) = event {
                            self.activeSessionID = sessionID
                        }
                        continuation.yield(event)
                    }
                    // claude.exe 在 --input-format stream-json 模式下是 long-lived 的:
                    // 输出完一轮 turn (result success) 之后并不会自己退出,而是继续等
                    // stdin 上的下一条 user message。Codevoke 每次 send 都是新的 Process,
                    // 不复用同一个 claude 进程做多轮,所以 turn 结束后要主动关闭 stdin
                    // 通知 claude EOF。自动压缩是例外: result 行会先短暂等 UI 根据
                    // tokenUsage 调用 sendCompact(), 成功写入 /compact 时就等压缩结果后再 EOF。
                    if Self.shouldCloseStdinAfterLine(line) {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if self.consumeCompactResultWait() {
                            watchdog.markActivity()
                        } else if pendingBackgroundTasks > 0 {
                            // The model ended its turn but a background task it launched is still
                            // running. claude stays alive and auto-continues when the task's
                            // notification arrives, so DON'T close stdin / finish / stop the
                            // process here (that would abort the background build). Pause the idle
                            // watchdog while we wait for the silent task to complete.
                            watchdog.pause()
                            for event in eventCoalescer.flush() {
                                if case .sessionID(let sessionID) = event {
                                    self.activeSessionID = sessionID
                                }
                                continuation.yield(event)
                            }
                            continuation.yield(.updateStreamingStatus("后台任务进行中…"))
                        } else {
                            didReceiveSuccessfulResult = Self.isSuccessfulTerminalResultLine(line)
                            for event in eventCoalescer.flush() {
                                if case .sessionID(let sessionID) = event {
                                    self.activeSessionID = sessionID
                                }
                                continuation.yield(event)
                            }
                            if didReceiveSuccessfulResult {
                                continuation.yield(.finished)
                                continuation.finish()
                            }
                            self.closeInputPipeIfNeeded()
                            if didReceiveSuccessfulResult {
                                Self.stopProcessAfterTerminalResult(process)
                                return makeReadResult()
                            }
                        }
                    }
                }
                for event in eventCoalescer.flush() {
                    if case .sessionID(let sessionID) = event {
                        self.activeSessionID = sessionID
                    }
                    continuation.yield(event)
                }
            } catch {
                for event in eventCoalescer.flush() {
                    continuation.yield(event)
                }
                continuation.yield(.failed(error.localizedDescription))
            }
            return makeReadResult()
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
                continuation.yield(.appendMessage(kind: .commandOutput, title: "stderr", subtitle: "Claude Code", text: combined, status: "stream", requestID: nil))
            }

            do {
                for try await line in JSONLStreamReader.lines(from: stderr) {
                    guard !Self.shouldSuppressStderrLine(line) else { continue }
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
                continuation.yield(.failed(error.localizedDescription))
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
        closeInputPipeIfNeeded()
        inputPipe = nil
        activeSessionID = nil
        self.process = nil

        return ProcessRunResult(
            terminationStatus: process.terminationStatus,
            terminationReason: process.terminationReason,
            didReceiveVisibleOutput: stdoutResult.didReceiveVisibleOutput,
            didReceiveSuccessfulResult: stdoutResult.didReceiveSuccessfulResult,
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
        func messageWithDiagnostics(_ message: String) -> String {
            let diagnostics = result.diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return diagnostics.isEmpty ? message : "\(message)\n\(diagnostics)"
        }

        if result.didReceiveSuccessfulResult {
            continuation.yield(.finished)
        } else if result.didReceiveAssistantContent && !result.didReceiveErrorResult {
            // The turn was cut short (idle/hard timeout, signal, or aborted stream) but it had
            // already streamed real assistant content and reported no error — finish gracefully
            // and keep what arrived. We intentionally do NOT treat error results / error
            // messages as a clean finish, so auth/quota/error_* failures still surface.
            continuation.yield(.finished)
        } else if result.timedOut {
            continuation.yield(.failed(messageWithDiagnostics("Claude Code 后端超时无响应，已停止进程。请检查认证、模型或网络配置。")))
        } else if result.terminationStatus == 0 {
            continuation.yield(.failed("Claude Code 没有输出任何对话内容。请检查认证配置或模型设置。"))
        } else if result.terminationReason == .uncaughtSignal {
            continuation.yield(.failed(messageWithDiagnostics("Claude Code 已停止。")))
        } else {
            continuation.yield(.failed(messageWithDiagnostics("Claude Code 退出码：\(result.terminationStatus)")))
        }
    }

    func interrupt() {
        activityWatchdog?.cancel()
        activityWatchdog = nil
        guard let process, process.isRunning else { return }
        // 用户主动停止时也先 EOF stdin,给 claude.exe 一个干净退出的机会,
        // 再走信号链路(SIGINT/SIGTERM/SIGKILL)兜底。
        closeInputPipeIfNeeded()
        ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(800), killAfter: .seconds(2))
    }

    func terminateImmediately() {
        activityWatchdog?.cancel()
        activityWatchdog = nil
        closeInputPipeIfNeeded()
        guard let process, process.isRunning else { return }
        ChatProcessTerminator.killNow(process)
    }

    func respondToPermission(requestID: String, decision: ChatPermissionDecision) -> Bool {
        let pending = pendingControlRequest(requestID)
        var inner: [String: Any] = [:]
        if decision.isAllowed {
            inner["behavior"] = "allow"
            inner["updatedInput"] = pending?.input ?? [:]
            if decision == .allowForSession, let toolName = pending?.toolName {
                inner["updatedPermissions"] = [[
                    "type": "addRules",
                    "rules": [["toolName": toolName]],
                    "behavior": "allow",
                    "destination": "session"
                ]]
            }
        } else {
            inner["behavior"] = "deny"
            inner["message"] = "用户拒绝了该操作。"
        }
        if let toolUseID = pending?.toolUseID { inner["toolUseID"] = toolUseID }
        let didWrite = writeControlResponse(requestID: requestID, inner: inner)
        if didWrite {
            removePendingControlRequest(requestID)
            activityWatchdog?.resume()
        }
        return didWrite
    }

    func respondToInteractiveRequest(requestID: String, response: ChatInteractiveResponse) -> Bool {
        guard let pending = pendingControlRequest(requestID), !pending.questions.isEmpty else {
            // No control gate recorded (legacy/custom interactive tool): best-effort send as a
            // plain user message so the turn isn't left hanging.
            let answer = response.customText?.nonEmptyTrimmed ?? response.selectedOptionIDs.joined(separator: ", ").nonEmptyTrimmed
            guard let answer else { return false }
            let didWrite = writeStreamUserMessage(text: answer, attachments: [], sessionID: activeSessionID?.nonEmptyTrimmed, parentToolUseID: requestID, toolUseResult: nil, projectPath: nil)
            if didWrite { activityWatchdog?.resume() }
            return didWrite
        }

        // Map selected option IDs (formatted "q{qi}o{oi}") back to per-question answer labels.
        var labelsByQuestion: [Int: [String]] = [:]
        for optionID in response.selectedOptionIDs {
            for (index, question) in pending.questions.enumerated() {
                if let label = question.optionLabelsByID[optionID] {
                    labelsByQuestion[index, default: []].append(label)
                    break
                }
            }
        }
        var answers: [String: String] = [:]
        for (index, question) in pending.questions.enumerated() {
            if let labels = labelsByQuestion[index], !labels.isEmpty {
                answers[question.text] = labels.joined(separator: ", ")
            }
        }
        // Free-text reply (typed in the composer or the card's custom field): use it as the
        // answer to the first question not already answered via options — works whether or not
        // that question has preset options, so custom input is always accepted.
        if let custom = response.customText?.nonEmptyTrimmed {
            if let firstUnanswered = pending.questions.firstIndex(where: { answers[$0.text] == nil }) {
                answers[pending.questions[firstUnanswered].text] = custom
            } else if let first = pending.questions.first, answers.isEmpty {
                answers[first.text] = custom
            }
        }
        guard !answers.isEmpty else { return false }

        var updatedInput = pending.input
        updatedInput["answers"] = answers
        var inner: [String: Any] = ["behavior": "allow", "updatedInput": updatedInput]
        if let toolUseID = pending.toolUseID { inner["toolUseID"] = toolUseID }
        let didWrite = writeControlResponse(requestID: requestID, inner: inner)
        if didWrite {
            removePendingControlRequest(requestID)
            activityWatchdog?.resume()
        }
        return didWrite
    }

    /// Serialize the authoritative control_response envelope. `request_id` is nested inside
    /// `response` (not top-level), and the innermost `response` is the PermissionResult.
    private func writeControlResponse(requestID: String, inner: [String: Any]) -> Bool {
        let object: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": inner
            ]
        ]
        return writeJSONToInput(object)
    }

    /// Parse a `can_use_tool` control_request line, record its context for the eventual
    /// control_response, and return the UI event (permission card or interactive picker).
    /// Returns nil for non-control lines so the caller falls through to normal parsing.
    private func handleControlRequestLine(_ line: String) -> [ChatBackendEvent]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "control_request",
              let request = object["request"] as? [String: Any],
              (request["subtype"] as? String) == "can_use_tool" else { return nil }

        let requestID = Self.stringValue(object["request_id"]) ?? Self.stringValue(object["id"]) ?? UUID().uuidString
        let toolName = Self.stringValue(request["tool_name"]) ?? "tool"
        let displayName = Self.stringValue(request["display_name"]) ?? toolName
        let input = (request["input"] as? [String: Any]) ?? [:]
        let toolUseID = Self.stringValue(request["tool_use_id"])

        if Self.isAskUserQuestionName(toolName) {
            let (interactive, questions) = Self.buildInteractiveRequest(requestID: requestID, input: input)
            setPendingControlRequest(PendingControlRequest(requestID: requestID, toolName: toolName, input: input, toolUseID: toolUseID, questions: questions))
            return [.interactiveRequest(interactive)]
        }

        setPendingControlRequest(PendingControlRequest(requestID: requestID, toolName: toolName, input: input, toolUseID: toolUseID, questions: []))
        return [.permissionRequest(id: requestID, title: displayName, text: Self.permissionPromptText(toolName: displayName, input: input))]
    }

    private static func isAskUserQuestionName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .contains("askuserquestion")
    }

    private static func permissionPromptText(toolName: String, input: [String: Any]) -> String {
        if let command = stringValue(input["command"]), !command.isEmpty {
            return command
        }
        if let path = stringValue(input["file_path"]) ?? stringValue(input["path"]), !path.isEmpty {
            return path
        }
        let summary = compactText(from: input)
        return summary.isEmpty ? "请求使用 \(toolName)" : summary
    }

    /// Build the interactive picker plus the option-id → label map used to translate the
    /// user's selection back into the AskUserQuestion `answers` object.
    private static func buildInteractiveRequest(requestID: String, input: [String: Any]) -> (ChatInteractiveRequest, [ParsedAskQuestion]) {
        let rawQuestions = (input["questions"] as? [[String: Any]]) ?? []
        let multiQuestion = rawQuestions.count > 1
        var parsed: [ParsedAskQuestion] = []
        var options: [ChatInteractiveOption] = []
        var prompts: [String] = []
        var anyMultiSelect = false

        for (questionIndex, question) in rawQuestions.enumerated() {
            let questionText = stringValue(question["question"]) ?? stringValue(question["prompt"]) ?? stringValue(question["message"]) ?? "问题 \(questionIndex + 1)"
            let header = stringValue(question["header"])
            let multiSelect = boolValue(question["multiSelect"]) ?? boolValue(question["multi_select"]) ?? false
            if multiSelect { anyMultiSelect = true }
            prompts.append(questionText)

            var labelsByID: [String: String] = [:]
            let rawOptions = (question["options"] as? [Any]) ?? (question["choices"] as? [Any]) ?? []
            for (optionIndex, rawOption) in rawOptions.enumerated() {
                let optionID = "q\(questionIndex)o\(optionIndex)"
                let label: String
                let detail: String
                if let text = stringValue(rawOption) {
                    label = text
                    detail = ""
                } else if let dict = rawOption as? [String: Any] {
                    label = stringValue(dict["label"]) ?? stringValue(dict["title"]) ?? stringValue(dict["value"]) ?? "选项 \(optionIndex + 1)"
                    detail = stringValue(dict["description"]) ?? stringValue(dict["detail"]) ?? ""
                } else {
                    label = "选项 \(optionIndex + 1)"
                    detail = ""
                }
                labelsByID[optionID] = label
                let displayLabel = multiQuestion ? "\(header ?? "问题 \(questionIndex + 1)")：\(label)" : label
                options.append(ChatInteractiveOption(id: optionID, label: displayLabel, detail: detail))
            }
            parsed.append(ParsedAskQuestion(text: questionText, multiSelect: multiSelect, optionLabelsByID: labelsByID))
        }

        let mode: ChatInteractiveMode = options.isEmpty ? .text : ((anyMultiSelect || multiQuestion) ? .multipleChoice : .singleChoice)
        let title = (rawQuestions.count == 1 ? stringValue(rawQuestions[0]["header"]) : nil) ?? "需要选择"
        let request = ChatInteractiveRequest(
            id: requestID,
            title: title,
            prompt: prompts.joined(separator: "\n\n"),
            mode: mode,
            options: options,
            allowCustomInput: options.isEmpty,
            placeholder: "输入自定义回复",
            status: .waiting
        )
        return (request, parsed)
    }

    /// Audit B-P0-1: write the user message to Claude stdin with optional
    /// attachments. When `attachments` is non-empty we follow Anthropic's
    /// stream-json schema and switch `message.content` from a plain string
    /// to an array of content blocks. Image attachments become base64
    /// `image` blocks so the model can actually see them; other file types
    /// are encoded as a `text` block describing the path so Claude can read
    /// the file via tools. The legacy plain-string content path is kept for
    /// backward compatibility when there are no attachments to minimise risk.
    private func writeStreamUserMessage(
        text: String,
        attachments: [ChatMessageAttachment],
        sessionID: String?,
        parentToolUseID: String?,
        toolUseResult: [String: Any]?,
        projectPath: String?
    ) -> Bool {
        guard text.nonEmptyTrimmed != nil || !attachments.isEmpty else { return false }
        guard !didCloseInputPipe else { return false }

        let messageContent: Any
        if attachments.isEmpty {
            messageContent = text
        } else {
            var blocks: [[String: Any]] = []
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            for attachment in attachments {
                if let block = Self.contentBlock(for: attachment, projectPath: projectPath) {
                    blocks.append(block)
                }
            }
            if blocks.isEmpty {
                messageContent = text
            } else {
                messageContent = blocks
            }
        }

        var object: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": messageContent
            ],
            "shouldQuery": true
        ]
        if let sessionID = sessionID?.nonEmptyTrimmed {
            object["session_id"] = sessionID
        }
        if let parentToolUseID = parentToolUseID?.nonEmptyTrimmed {
            object["parent_tool_use_id"] = parentToolUseID
        }
        if let toolUseResult {
            object["tool_use_result"] = toolUseResult
        }
        return writeJSONToInput(object)
    }

    /// Build a single Anthropic content block for an attachment. Images get
    /// base64-encoded `image` blocks (the only way Claude can "see" them via
    /// stream-json), other files degrade to a `text` block describing the
    /// path. We cap base64 payload at ~8 MB raw to avoid blowing past
    /// Anthropic's per-message limits and our own stdin write timeout; over
    /// the cap we fall back to a text reference so the model at least knows
    /// the file exists at <path>.
    private static func contentBlock(for attachment: ChatMessageAttachment, projectPath: String?) -> [String: Any]? {
        let displayName = attachment.filename.isEmpty ? (attachment.path as NSString).lastPathComponent : attachment.filename
        let resolvedPath = resolvedAttachmentPath(attachment.path, projectPath: projectPath)
        let fileURL = URL(fileURLWithPath: resolvedPath)
        let maxImageBytes = 8 * 1024 * 1024

        if attachment.kind == .image {
            if let data = try? Data(contentsOf: fileURL), data.count <= maxImageBytes {
                let mediaType = mimeType(forPath: resolvedPath, defaultValue: "image/png")
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": data.base64EncodedString()
                    ]
                ]
            }
            return [
                "type": "text",
                "text": "[image attachment: \(displayName) at \(resolvedPath)]"
            ]
        }

        return [
            "type": "text",
            "text": "[attachment: \(displayName) at \(resolvedPath)]"
        ]
    }

    private static func resolvedAttachmentPath(_ path: String, projectPath: String?) -> String {
        if path.hasPrefix("/") { return path }
        guard let projectPath, !projectPath.isEmpty else { return path }
        return (projectPath as NSString).appendingPathComponent(path)
    }

    private static func mimeType(forPath path: String, defaultValue: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return defaultValue
        }
    }

    private static func shouldCloseStdinAfterLine(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return isTerminalResult(compact)
    }

    private enum BackgroundTaskTransition { case started, completed, none }

    /// Detect a `system` event that starts or completes a background task (Bash
    /// run_in_background). `task_started` means a task is now running; `task_notification`/
    /// `task_completed` means one finished (and the model will auto-continue).
    private static func backgroundTaskTransition(forLine line: String) -> BackgroundTaskTransition {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.contains("\"type\":\"system\"") else { return .none }
        if compact.contains("\"subtype\":\"task_started\"") { return .started }
        if compact.contains("\"subtype\":\"task_notification\"") || compact.contains("\"subtype\":\"task_completed\"") {
            return .completed
        }
        return .none
    }

    private static func isSuccessfulTerminalResultLine(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return isTerminalResult(compact) && compact.contains("\"subtype\":\"success\"")
    }

    private static func isTerminalResult(_ compactLine: String) -> Bool {
        compactLine.contains("\"type\":\"result\"")
            && !compactLine.contains("\"stop_reason\":\"tool_use\"")
            && !compactLine.contains("\"terminal_reason\":\"tool_use\"")
    }

    private static func stopProcessAfterTerminalResult(_ process: Process) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(120)) { [weak process] in
            guard let process, process.isRunning else { return }
            ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(150), killAfter: .milliseconds(700))
        }
    }

    private static func shouldSuppressStderrLine(_ line: String) -> Bool {
        line.lowercased().contains("failed to generate conversation summary")
    }

    private func closeInputPipeIfNeeded() {
        guard let pipe = inputPipe, !didCloseInputPipe else { return }
        didCloseInputPipe = true
        // 关 fileHandleForWriting 即给 claude.exe 发 EOF;close 失败也吞掉,
        // 重复 close 在 try? 下不会再抛出。
        try? pipe.fileHandleForWriting.close()
    }

    func sendCompact() -> Bool {
        // Don't issue a second /compact while one is still in flight (a transient low
        // token-usage reading could otherwise re-trigger auto-compaction and spam the CLI).
        compactStateLock.lock()
        let alreadyWaiting = isWaitingForCompactResult
        compactStateLock.unlock()
        if alreadyWaiting { return false }
        let didWrite = writeStreamUserMessage(
            text: "/compact",
            attachments: [],
            sessionID: activeSessionID?.nonEmptyTrimmed,
            parentToolUseID: nil,
            toolUseResult: nil,
            projectPath: nil
        )
        if didWrite {
            markCompactResultWait()
            activityWatchdog?.resume()
        }
        return didWrite
    }

    private func markCompactResultWait() {
        compactStateLock.lock()
        isWaitingForCompactResult = true
        compactStateLock.unlock()
    }

    private func consumeCompactResultWait() -> Bool {
        compactStateLock.lock()
        defer { compactStateLock.unlock() }
        guard isWaitingForCompactResult else { return false }
        isWaitingForCompactResult = false
        return true
    }

    private func displayCommand(executablePath: String, arguments: [String]) -> String {
        var displayArguments = arguments
        if let promptFlagIndex = displayArguments.firstIndex(of: "-p"), displayArguments.indices.contains(promptFlagIndex + 1) {
            displayArguments[promptFlagIndex + 1] = "<prompt>"
        }
        return ([executablePath] + displayArguments).joined(separator: " ")
    }

    private func arguments(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, includeEffort: Bool, includePartialMessages: Bool, includeBrief: Bool, includePermissionPromptTool: Bool) -> [String] {
        var args: [String] = []
        if options.sessionMode == .continueLast {
            args.append("--continue")
        } else if options.sessionMode == .resume, let resumeID = options.resumeSessionID?.nonEmptyTrimmed ?? session?.externalSessionID?.nonEmptyTrimmed {
            args.append(contentsOf: ["--resume", resumeID])
        }
        if options.supportsStreamJSONInput {
            args.append("-p")
        } else {
            args.append(contentsOf: ["-p", prompt])
        }
        args.append(contentsOf: ["--output-format", "stream-json"])
        if options.supportsStreamJSONInput {
            args.append(contentsOf: ["--input-format", "stream-json", "--replay-user-messages"])
        }
        args.append("--verbose")
        if includeBrief {
            args.append("--brief")
        }
        if includePartialMessages {
            args.append("--include-partial-messages")
        }
        args.append(contentsOf: ["--permission-mode", options.permissionMode.claudePermissionMode])
        if options.supportsStreamJSONInput, includePermissionPromptTool {
            // Route tool-permission and AskUserQuestion gating to our stdin/stdout control
            // channel so we can answer with a proper control_response. Without this the CLI
            // either resolves silently or waits for a TTY that doesn't exist and aborts.
            args.append(contentsOf: ["--permission-prompt-tool", "stdio"])
        }
        if includeEffort {
            args.append(contentsOf: ["--effort", options.reasoningEffort.claudeArgument])
        }
        let executionModelID = ChatModelCatalog.executionModelID(for: options.modelID)
        if isClaudeModelArgument(executionModelID) {
            args.append(contentsOf: ["--model", executionModelID])
        }
        return args
    }

    private func isClaudeModelArgument(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        return normalized != ChatModelCatalog.defaultClaudeModelID
            && normalized.hasPrefix("claude-")
    }

    private static func events(fromClaudeLine line: String, streamState: inout ClaudeStreamState) -> [ChatBackendEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard !isClaudeProtocolRawLine(line) else { return [] }
            return [.appendMessage(kind: .rawOutput, title: "raw", subtitle: "Claude Code", text: line, status: "stream", requestID: nil)]
        }

        var events: [ChatBackendEvent] = []
        if let sessionID = object["session_id"] as? String ?? object["sessionId"] as? String {
            events.append(.sessionID(sessionID))
        }

        if let usageEvent = extractTokenUsage(from: object) {
            events.append(usageEvent)
        }

        let type = object["type"] as? String ?? object["event"] as? String ?? "raw"
        guard type != "user" else { return events }
        // control_request (tool permission / AskUserQuestion gating) is handled by the
        // instance loop via handleControlRequestLine, which can store the request context
        // needed to build a correct control_response. Don't emit a generic card here.
        guard type != "control_request", type != "control_cancel_request" else { return events }
        if let errorText = errorText(from: object, type: type) {
            events.append(.appendMessage(kind: .error, title: "Claude Code", subtitle: type, text: errorText, status: "failed", requestID: stringValue(object["request_id"]) ?? stringValue(object["id"])))
            return events
        }
        if type == "system" {
            if let statusText = systemStatusText(from: object) {
                events.append(.updateStreamingStatus(statusText))
            }
            if let compactError = compactErrorText(from: object) {
                events.append(.appendMessage(kind: .error, title: "Claude Code", subtitle: "compact", text: compactError, status: "failed", requestID: stringValue(object["request_id"]) ?? stringValue(object["id"])))
            }
            if let subtype = object["subtype"] as? String, subtype == "init" {
                let summary = initSummary(from: object)
                if !summary.isEmpty {
                    events.append(.appendMessage(kind: .system, title: "Mac tools", subtitle: "agent", text: summary, status: "done", requestID: nil))
                }
            } else if let subtype = object["subtype"] as? String {
                events.append(.appendMessage(kind: .system, title: "system", subtitle: subtype, text: compactText(from: object), status: "done", requestID: nil))
            }
            return events
        }

        if type == "stream_event" {
            events.append(contentsOf: streamEvents(from: object, streamState: &streamState))
            return events
        }

        if type == "assistant" {
            let assistantEvents = assistantEvents(from: object, streamState: &streamState)
            if assistantEvents.contains(where: isAssistantOutput) {
                streamState.didReceiveAssistantTextDelta = true
            }
            events.append(contentsOf: assistantEvents)
            return events
        }

        if type == "result" {
            let subtype = object["subtype"] as? String ?? ""
            let resultText = stringValue(object["result"]) ?? stringValue(object["message"])
            if !streamState.didReceiveAssistantTextDelta, let resultText, !resultText.isEmpty {
                streamState.didReceiveAssistantTextDelta = true
                events.append(.appendDelta(kind: .assistant, title: "assistant", subtitle: "Claude Code", text: resultText, status: "streaming", requestID: nil))
            }
            guard subtype != "success" else { return events }
            events.append(.appendMessage(kind: .error, title: "result", subtitle: subtype, text: resultText ?? compactText(from: object), status: "done", requestID: nil))
            return events
        }

        if let request = interactiveRequest(from: object, fallbackID: stringValue(object["request_id"]) ?? stringValue(object["id"]), fallbackTitle: type) {
            events.append(.interactiveRequest(request))
            return events
        }

        if Self.isPermissionRequestType(type) {
            let requestID = object["request_id"] as? String ?? object["id"] as? String ?? UUID().uuidString
            events.append(.permissionRequest(id: requestID, title: type, text: compactText(from: object)))
            return events
        }

        if type.contains("tool") {
            let kind: ChatMessageKind = type.contains("result") ? .toolResult : .toolCall
            events.append(.appendMessage(kind: kind, title: type, subtitle: stringValue(object["name"]) ?? "", text: compactText(from: object), status: "done", requestID: stringValue(object["id"])))
            return events
        }

        return events
    }

    private static func diagnosticText(fromClaudeLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return isClaudeProtocolRawLine(line) ? nil : line
        }
        let type = object["type"] as? String ?? object["event"] as? String ?? "raw"
        if let errorText = errorText(from: object, type: type) {
            return errorText
        }
        if type == "result" {
            let subtype = object["subtype"] as? String ?? ""
            guard subtype != "success" else { return nil }
            return stringValue(object["result"]) ?? stringValue(object["message"]) ?? compactText(from: object)
        }
        if type.lowercased().contains("error") || type.lowercased().contains("fail") {
            return compactText(from: object)
        }
        return nil
    }

    private static func systemStatusText(from object: [String: Any]) -> String? {
        if let compactResult = stringValue(object["compact_result"])?.lowercased(), compactResult == "failed" {
            return "上下文压缩失败"
        }
        guard let status = stringValue(object["status"])?.lowercased() else { return nil }
        switch status {
        case "compacting":
            return "正在压缩上下文"
        case "requesting":
            return "正在请求 Claude Code"
        case "queued":
            return "Claude Code 请求排队中"
        default:
            return nil
        }
    }

    private static func compactErrorText(from object: [String: Any]) -> String? {
        guard let compactResult = stringValue(object["compact_result"])?.lowercased(), compactResult == "failed" else { return nil }
        return stringValue(object["compact_error"]) ?? "Claude Code 上下文压缩失败。"
    }

    private static func errorText(from object: [String: Any], type: String) -> String? {
        let lowercasedType = type.lowercased()
        guard lowercasedType == "error"
            || lowercasedType.hasSuffix("_error")
            || lowercasedType.contains("exception")
            || lowercasedType.contains("failed")
        else {
            return nil
        }
        if let message = stringValue(object["message"]) ?? stringValue(object["error"]) {
            return message
        }
        if let error = object["error"] as? [String: Any] {
            if let message = stringValue(error["message"]) ?? stringValue(error["error"]) {
                let code = stringValue(error["code"]) ?? stringValue(error["type"])
                return [code, message].compactMap { $0?.nonEmptyTrimmed }.joined(separator: ": ")
            }
            return compactText(from: error)
        }
        return compactText(from: object)
    }

    private static func streamEvents(from object: [String: Any], streamState: inout ClaudeStreamState) -> [ChatBackendEvent] {
        guard let event = object["event"] as? [String: Any] else { return [] }
        let type = stringValue(event["type"]) ?? "stream_event"
        let blockIndex = intValue(event["index"])
        let activeBlock = blockIndex.flatMap { streamState.activeBlocks[$0] }

        if let usageEvent = extractTokenUsage(from: event) {
            return [usageEvent]
        }

        if type == "content_block_start", let contentBlock = event["content_block"] as? [String: Any] {
            let blockType = stringValue(contentBlock["type"]) ?? "content_block"
            let block = ClaudeContentBlock(
                id: stringValue(contentBlock["id"]),
                type: blockType,
                name: stringValue(contentBlock["name"])
            )
            if let blockIndex {
                streamState.activeBlocks[blockIndex] = block
            }
            guard blockType != "text" && blockType != "thinking" else { return [] }
            // AskUserQuestion is surfaced (and answered) via its can_use_tool control_request,
            // so suppress the streaming tool_use card to avoid showing it twice.
            if Self.isAskUserQuestionName(block.name) { return [] }
            let kind = kindForClaudeBlockType(blockType)
            guard kind != .rawOutput else { return [] }
            return [.appendMessage(
                kind: kind,
                title: blockType,
                subtitle: block.name ?? "",
                text: compactText(from: contentBlock),
                status: "streaming",
                requestID: block.id
            )]
        }

        if type == "content_block_delta", let delta = event["delta"] as? [String: Any] {
            let deltaType = stringValue(delta["type"]) ?? ""
            if deltaType == "text_delta", let text = stringValue(delta["text"]), !text.isEmpty {
                let kind = kindForClaudeDelta(block: activeBlock, defaultKind: .assistant)
                if kind == .assistant {
                    streamState.didReceiveAssistantTextDelta = true
                    streamState.didReceiveStreamEventAssistantTextDelta = true
                }
                return [.appendDelta(kind: kind, title: activeBlock?.type ?? "", subtitle: activeBlock?.name ?? "Claude Code", text: text, status: "streaming", requestID: activeBlock?.id)]
            }
            if deltaType == "thinking_delta", let text = stringValue(delta["thinking"]) ?? stringValue(delta["text"]), !text.isEmpty {
                return [.appendDelta(kind: .reasoning, title: "thinking", subtitle: "Claude Code", text: text, status: "streaming", requestID: activeBlock?.id)]
            }
            if deltaType == "input_json_delta", let activeBlock, let text = stringValue(delta["partial_json"]), !text.isEmpty {
                if Self.isAskUserQuestionName(activeBlock.name) { return [] }
                return [.appendDelta(kind: .toolCall, title: activeBlock.type, subtitle: activeBlock.name ?? "", text: text, status: "streaming", requestID: activeBlock.id)]
            }
            return []
        }

        if type == "content_block_stop" {
            if let blockIndex {
                streamState.activeBlocks.removeValue(forKey: blockIndex)
            }
            guard let activeBlock, activeBlock.type != "text", activeBlock.type != "thinking" else { return [] }
            if Self.isAskUserQuestionName(activeBlock.name) { return [] }
            return [.finishStreamingMessage(kind: kindForClaudeBlockType(activeBlock.type), requestID: activeBlock.id, status: "done")]
        }

        return []
    }

    private static func isClaudeProtocolRawLine(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace }
        guard compact.hasPrefix("{") else { return false }
        return [
            "\"type\":\"stream_event\"",
            "\"type\":\"message_start\"",
            "\"type\":\"message_delta\"",
            "\"type\":\"message_stop\"",
            "\"type\":\"content_block_start\"",
            "\"type\":\"content_block_delta\"",
            "\"type\":\"content_block_stop\"",
            "\"type\":\"input_json_delta\"",
            "\"type\":\"signature_delta\"",
            "\"type\":\"ping\""
        ].contains { compact.contains($0) }
    }

    private static func isInternalClaudeStreamEvent(_ type: String) -> Bool {
        switch type {
        case "message_start", "message_delta", "message_stop", "content_block_stop", "signature_delta":
            true
        default:
            false
        }
    }

    /// Claude Code 真正可识别的权限/审批请求 type 白名单。
    /// 旧实现用 `type.contains("permission") || type.contains("approval")` 匹配，
    /// 任意带这两个子串的事件（例如 `permission_test_event`、`approval_completed`）
    /// 都会被误识别成"待响应权限请求"，UI 上挂出永等不到回复的死按钮。
    /// 这里只列出已知确实需要用户响应的 type；后续若发现 Claude 引入了新的权限类型，
    /// 应该把具体 type 加入这个集合，而不是用模糊匹配。
    private static let knownPermissionRequestTypes: Set<String> = [
        "control_request"
    ]

    private static func isPermissionRequestType(_ type: String) -> Bool {
        knownPermissionRequestTypes.contains(type)
    }

    private static func shouldPauseActivityWatchdog(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .permissionRequest, .interactiveRequest:
            true
        default:
            false
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

    /// True for events that signal a real failure (error messages or a non-success terminal
    /// result). Used so a turn that only emitted an error isn't reported as a clean finish.
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

    private static func assistantEvents(from object: [String: Any], streamState: inout ClaudeStreamState) -> [ChatBackendEvent] {
        var events: [ChatBackendEvent] = []
        if !streamState.didReceiveStreamEventAssistantTextDelta,
           let text = assistantText(from: object), !text.isEmpty {
            let delta = topLevelAssistantDelta(text, previous: streamState.topLevelAssistantText)
            streamState.topLevelAssistantText = text
            if !delta.isEmpty {
                events.append(.appendDelta(kind: .assistant, title: "assistant", subtitle: "Claude Code", text: delta, status: "streaming", requestID: nil))
            }
        }
        if let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            for item in content {
                let type = stringValue(item["type"]) ?? "content"
                guard type != "text", type != "thinking" else { continue }
                let id = stringValue(item["id"]) ?? stringValue(item["tool_use_id"]) ?? compactText(from: item)
                guard !streamState.emittedContentItemIDs.contains(id) else { continue }
                streamState.emittedContentItemIDs.insert(id)
                // AskUserQuestion is rendered/answered via its can_use_tool control_request;
                // drop the assistant-side copy (matched by name OR the questions shape) so the
                // picker isn't shown twice and a duplicate, ungated card can't be answered.
                if isAskUserQuestionName(stringValue(item["name"])) || item["questions"] != nil { continue }
                events.append(contentsOf: contentItemEvents(from: item))
            }
        }
        return events
    }

    private static func topLevelAssistantDelta(_ text: String, previous: String) -> String {
        guard !previous.isEmpty else { return text }
        if text.hasPrefix(previous) {
            return String(text.dropFirst(previous.count))
        }
        return text == previous ? "" : text
    }

    private static func contentItemEvents(from item: [String: Any]) -> [ChatBackendEvent] {
        let type = stringValue(item["type"]) ?? "content"
        let id = stringValue(item["id"])
        if let request = interactiveRequest(from: item, fallbackID: id, fallbackTitle: stringValue(item["name"]) ?? type) {
            return [.interactiveRequest(request)]
        }
        switch type {
        case "text":
            guard let text = stringValue(item["text"]), !text.isEmpty else { return [] }
            return [.appendDelta(kind: .assistant, title: "assistant", subtitle: "Claude Code", text: text, status: "streaming", requestID: nil)]
        case "thinking":
            guard let text = stringValue(item["thinking"]) ?? stringValue(item["text"]), !text.isEmpty else { return [] }
            return [.appendDelta(kind: .reasoning, title: "thinking", subtitle: "Claude Code", text: text, status: "streaming", requestID: id)]
        case "tool_result":
            let requestID = stringValue(item["tool_use_id"]) ?? id
            return [.appendMessage(kind: .toolResult, title: type, subtitle: stringValue(item["name"]) ?? "", text: compactText(from: item), status: "done", requestID: requestID)]
        case "tool_use":
            return [.appendMessage(kind: .toolCall, title: type, subtitle: stringValue(item["name"]) ?? "", text: compactText(from: item), status: "done", requestID: id)]
        default:
            return []
        }
    }

    private static func kindForClaudeBlockType(_ blockType: String) -> ChatMessageKind {
        let lowercased = blockType.lowercased()
        if lowercased.contains("result") { return .toolResult }
        if lowercased.contains("diff") || lowercased.contains("edit") || lowercased.contains("patch") { return .diff }
        if lowercased.contains("command") || lowercased.contains("bash") { return .command }
        if lowercased.contains("tool") || lowercased.contains("mcp") || lowercased.contains("server") { return .toolCall }
        return .rawOutput
    }

    private static func kindForClaudeDelta(block: ClaudeContentBlock?, defaultKind: ChatMessageKind) -> ChatMessageKind {
        guard let block else { return defaultKind }
        let lowercased = block.type.lowercased()
        if lowercased == "text" { return .assistant }
        if lowercased.contains("result") { return .toolResult }
        if lowercased.contains("diff") || lowercased.contains("edit") || lowercased.contains("patch") { return .diff }
        if lowercased.contains("command") || lowercased.contains("bash") { return .commandOutput }
        if lowercased.contains("tool") || lowercased.contains("mcp") || lowercased.contains("server") { return .toolCall }
        return .rawOutput
    }

    private static func assistantText(from object: [String: Any]) -> String? {
        if let delta = object["delta"] as? [String: Any] {
            return stringValue(delta["text"]) ?? stringValue(delta["content"])
        }
        if let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content.compactMap { item in
                if item["type"] as? String == "text" { return item["text"] as? String }
                return nil
            }.joined()
        }
        return stringValue(object["text"]) ?? stringValue(object["content"])
    }

    private static func interactiveRequest(from object: [String: Any], fallbackID: String?, fallbackTitle: String) -> ChatInteractiveRequest? {
        let input = dictionaryValue(object["input"])
        let source = input ?? object
        let name = [
            stringValue(object["name"]),
            stringValue(object["tool_name"]),
            stringValue(object["type"]),
            fallbackTitle
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        let normalizedName = name
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let isAskUserQuestion = normalizedName.contains("askuserquestion")
        let isSendUserMessage = normalizedName.contains("sendusermessage")
            || normalizedName.contains("requestuserinput")
            || normalizedName.contains("requestinput")
        let questions = (source["questions"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let hasChoiceShape = source["options"] != nil || source["choices"] != nil || !questions.isEmpty
        guard hasChoiceShape
            || isAskUserQuestion
            || isSendUserMessage
            || normalizedName.contains("question")
            || normalizedName.contains("choice")
            || normalizedName.contains("input") else {
            return nil
        }
        guard !name.contains("permission"), !name.contains("approval") else { return nil }
        let id = fallbackID ?? stringValue(source["id"]) ?? stringValue(source["request_id"]) ?? UUID().uuidString
        let questionSource = questions.first ?? source
        let prompt = promptText(from: source, questions: questions)
        let options = questions.isEmpty ? interactiveOptions(from: source) : interactiveOptions(fromQuestions: questions)
        let mode: ChatInteractiveMode
        if options.isEmpty {
            mode = .text
        } else if questions.count > 1 || questions.contains(where: isMultipleChoiceQuestion) || isMultipleChoiceQuestion(source) {
            mode = .multipleChoice
        } else {
            mode = .singleChoice
        }
        return ChatInteractiveRequest(
            id: id,
            title: stringValue(questionSource["header"]) ?? stringValue(source["title"]) ?? stringValue(object["name"]) ?? "需要选择",
            prompt: prompt,
            mode: mode,
            options: options,
            allowCustomInput: boolValue(questionSource["allowCustomInput"]) ?? boolValue(source["allowCustomInput"]) ?? boolValue(source["allow_custom_input"]) ?? (isAskUserQuestion || isSendUserMessage),
            placeholder: stringValue(questionSource["placeholder"]) ?? stringValue(source["placeholder"]) ?? "输入自定义回复",
            status: .waiting
        )
    }

    private static func interactiveOptions(from object: [String: Any]) -> [ChatInteractiveOption] {
        let rawOptions = object["options"] ?? object["choices"]
        guard let array = rawOptions as? [Any] else { return [] }
        return array.enumerated().map { option(from: $0.element, index: $0.offset, labelPrefix: nil, idPrefix: nil) }
    }

    private static func interactiveOptions(fromQuestions questions: [[String: Any]]) -> [ChatInteractiveOption] {
        questions.enumerated().flatMap { questionIndex, question in
            let labelPrefix = questions.count > 1 ? (stringValue(question["header"]) ?? "问题 \(questionIndex + 1)") : nil
            let idPrefix = questions.count > 1 ? "q\(questionIndex + 1)" : nil
            let rawOptions = question["options"] ?? question["choices"]
            guard let options = rawOptions as? [Any] else { return [ChatInteractiveOption]() }
            return options.enumerated().map { option(from: $0.element, index: $0.offset, labelPrefix: labelPrefix, idPrefix: idPrefix) }
        }
    }

    private static func option(from item: Any, index: Int, labelPrefix: String?, idPrefix: String?) -> ChatInteractiveOption {
        if let text = stringValue(item) {
            return ChatInteractiveOption(id: prefixedID(text, prefix: idPrefix), label: prefixed(text, prefix: labelPrefix), detail: "")
        }
        if let option = item as? [String: Any] {
            let rawID = stringValue(option["id"]) ?? stringValue(option["value"]) ?? stringValue(option["label"]) ?? "option-\(index + 1)"
            let label = stringValue(option["label"]) ?? stringValue(option["title"]) ?? stringValue(option["text"]) ?? rawID
            let detail = stringValue(option["detail"]) ?? stringValue(option["description"]) ?? ""
            return ChatInteractiveOption(id: prefixedID(rawID, prefix: idPrefix), label: prefixed(label, prefix: labelPrefix), detail: detail)
        }
        let label = "选项 \(index + 1)"
        return ChatInteractiveOption(id: prefixedID("option-\(index + 1)", prefix: idPrefix), label: prefixed(label, prefix: labelPrefix), detail: "")
    }

    private static func prefixed(_ value: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return value }
        return "\(prefix)：\(value)"
    }

    private static func prefixedID(_ value: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return value }
        return "\(prefix):\(value)"
    }

    private static func promptText(from source: [String: Any], questions: [[String: Any]]) -> String {
        if !questions.isEmpty {
            return questions.enumerated().map { index, question in
                stringValue(question["question"])
                    ?? stringValue(question["prompt"])
                    ?? stringValue(question["message"])
                    ?? stringValue(question["text"])
                    ?? "问题 \(index + 1)"
            }.joined(separator: "\n\n")
        }
        return stringValue(source["prompt"])
            ?? stringValue(source["question"])
            ?? stringValue(source["message"])
            ?? stringValue(source["text"])
            ?? "请选择后继续。"
    }

    private static func isMultipleChoiceQuestion(_ question: [String: Any]) -> Bool {
        boolValue(question["multiple"]) == true || boolValue(question["multiSelect"]) == true || boolValue(question["multi_select"]) == true
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

    #if DEBUG
    static func debugShouldCloseStdinAfterLine(_ line: String) -> Bool {
        shouldCloseStdinAfterLine(line)
    }

    static func debugInteractiveRequest(from object: [String: Any]) -> ChatInteractiveRequest? {
        interactiveRequest(
            from: object,
            fallbackID: stringValue(object["id"]) ?? stringValue(object["request_id"]),
            fallbackTitle: stringValue(object["name"]) ?? stringValue(object["type"]) ?? "debug"
        )
    }

    static func debugEvents(fromClaudeLine line: String) -> [ChatBackendEvent] {
        var state = ClaudeStreamState()
        return events(fromClaudeLine: line, streamState: &state)
    }
    #endif

    private static func initSummary(from object: [String: Any]) -> String {
        guard let servers = object["mcp_servers"] as? [[String: Any]] else { return "" }
        let connectedServers = servers.compactMap { server -> String? in
            guard (stringValue(server["status"]) ?? "").lowercased() == "connected" else { return nil }
            return stringValue(server["name"])
        }
        guard !connectedServers.isEmpty else { return "" }
        return (["Mac tools: \(connectedServers.count) connected"] + connectedServers.map { "- \($0)" }).joined(separator: "\n")
    }

    private static func extractTokenUsage(from object: [String: Any]) -> ChatBackendEvent? {
        // Try top-level "usage" field
        if let usage = object["usage"] as? [String: Any], let event = usageEvent(from: usage) {
            return event
        }
        // Try nested "message.usage"
        if let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any],
           let event = usageEvent(from: usage) {
            return event
        }
        return nil
    }

    private static func usageEvent(from usage: [String: Any]) -> ChatBackendEvent? {
        // Anthropic usage 字段语义：input/cache_creation/cache_read 三者互不相交，
        // 真实占用上下文窗口的 prompt token = input + cache_creation + cache_read。
        // 旧实现用 ?? 链只取其一，会在 cache 命中且同时扩展 cache 时漏算。
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let used = inputTokens + outputTokens + cacheRead + cacheCreation
        // total 只信任 context_window；max_tokens 是单次回复的输出上限（4K/8K），
        // 用它当 fallback 会让 UI 误以为整个 200K context 已经撑满。
        let total = usage["context_window"] as? Int ?? 0
        guard used > 0 || total > 0 else { return nil }
        return .tokenUsage(used: used, total: total, output: outputTokens > 0 ? outputTokens : nil)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
