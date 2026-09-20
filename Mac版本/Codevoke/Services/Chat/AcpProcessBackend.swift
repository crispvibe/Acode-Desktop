import Darwin
import Foundation

/// DeepSeek Harness（dsh）的 ACP（Agent Client Protocol v1）后端。
/// `dsh --profile acp` 以 stdio JSON-RPC 服务：协议帧只走 stdout，stderr 仅诊断。
/// 握手序列：initialize → session/new | session/resume →
/// session/set_config_option（model / reasoning_effort，按序下推）→
/// session/prompt（其响应即为 turn 终态）。运行中事件走 session/update 通知，
/// 权限询问走 session/request_permission 服务器请求，取消走 session/cancel。
/// dsh 未直装时 capability.executablePath 指向 npx，由 DshCommandLine 补
/// `-y @deepseek-ai/dsh` 前缀。
final class AcpProcessBackend: ChatProcessBackend {
    private static let idleTimeout: TimeInterval = 30 * 60

    private enum PendingRequest {
        case initialize
        case newSession
        case resumeSession
        /// continueLast / 无 id 的 resume：先 session/list 找该 cwd 最近的会话再 resume。
        case listSessions
        case setConfig
        /// session/prompt 的响应直到整个 turn 结束才返回（stopReason）。
        case prompt
    }

    private struct AcpPermissionRequest {
        /// 原始 JSON-RPC id，应答时原样回传。
        let id: Any
        /// agent 提供的可选项列表（[{optionId, name, kind}]）。
        let options: [[String: Any]]
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var nextID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pendingPermissions: [String: AcpPermissionRequest] = [:]
    private var activeSessionID: String?
    /// session/resume 的响应不回传 sessionId，发出请求时先记下目标 id。
    private var pendingResumeID: String?
    /// 会话就绪后按序下推的 config 写入（model → reasoning_effort），全部应答后
    /// 才发 session/prompt，避免并发请求在 agent 侧重排导致 prompt 跑在旧配置上。
    /// 单项 set_config_option 失败不致命：发告警消息后继续队列。
    private var pendingConfigWrites: [(configId: String, value: String)] = []
    /// initialize 响应里 agentCapabilities.promptCapabilities.image 的实测值；
    /// 为 false 时图片附件降级为 resource_link。
    private var imagePromptEnabled = false
    private var didFinishTurn = false
    /// 终态 latch：一旦发出过 .failed 或 .finished，就阻止后续重复发出（同
    /// CodexAppServerBackend——上游在 error 之后仍可能再发终态响应）。
    private var didEmitTerminalEvent = false
    private var activityWatchdog: ChatProcessActivityWatchdog?
    /// Guards all shared mutable state above. Concurrently touched by the stdout
    /// reader Task and by respond*/interrupt on the MainActor. All stdin writes
    /// happen under it, so JSON-RPC frames can't interleave.
    private let stateLock = NSRecursiveLock()

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) -> AsyncThrowingStream<ChatBackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                self.locked {
                    self.didFinishTurn = false
                    self.didEmitTerminalEvent = false
                    self.pendingRequests = [:]
                    self.pendingPermissions = [:]
                    self.pendingConfigWrites = []
                    self.activeSessionID = nil
                    self.pendingResumeID = nil
                    self.imagePromptEnabled = false
                }

                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                process.executableURL = URL(fileURLWithPath: options.executablePath)
                process.arguments = DshCommandLine.arguments(
                    executablePath: options.executablePath,
                    trailing: ["--profile", "acp"]
                )
                process.currentDirectoryURL = URL(fileURLWithPath: options.projectPath, isDirectory: true)
                var environment = ChatCLIEnvironment.processEnvironment
                // dsh 出厂配置用 DSH_PERMISSION_MODE 同时驱动 sandbox 与审批策略，
                // 未设置时默认 danger-full-access（never 审批），必须每次显式下发。
                environment["DSH_PERMISSION_MODE"] = options.permissionMode.dshPermissionMode
                process.environment = environment
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = stdin
                ChatProcessLauncher.isolateProcessGroup(process)
                self.locked {
                    self.process = process
                    self.inputPipe = stdin
                }
                let watchdog = ChatProcessActivityWatchdog(
                    process: process,
                    idleTimeout: Self.idleTimeout,
                    terminateAfter: .seconds(1),
                    killAfter: .milliseconds(2200)
                )

                do {
                    try process.run()
                    self.locked { self.activityWatchdog = watchdog }
                    watchdog.markActivity()
                    watchdog.start()
                    continuation.yield(.backendActivity("process-started"))
                    self.bootstrap()
                } catch {
                    continuation.yield(.failed(ChatProcessError.launchFailed(error.localizedDescription).localizedDescription))
                    continuation.finish()
                    return
                }

                let stdoutTask = Task { () -> Bool in
                    var didReceiveVisibleOutput = false
                    var eventCoalescer = ChatBackendEventCoalescer()
                    var didYieldStdoutActivity = false
                    do {
                        for try await line in JSONLStreamReader.lines(from: stdout) {
                            watchdog.markActivity()
                            if !didYieldStdoutActivity {
                                didYieldStdoutActivity = true
                                continuation.yield(.backendActivity("stdout-first-line"))
                            }
                            let events = self.locked {
                                self.events(
                                    fromLine: line,
                                    prompt: prompt,
                                    options: options,
                                    session: session,
                                    attachments: attachments
                                )
                            }
                            if events.contains(where: Self.isVisibleOutput) {
                                didReceiveVisibleOutput = true
                            }
                            if events.contains(where: Self.shouldPauseActivityWatchdog) {
                                watchdog.pause()
                            }
                            for event in eventCoalescer.push(events) {
                                continuation.yield(event)
                            }
                        }
                        for event in eventCoalescer.flush() {
                            continuation.yield(event)
                        }
                    } catch {
                        for event in eventCoalescer.flush() {
                            continuation.yield(event)
                        }
                        for event in self.emitTerminalIfNeeded(.failed(error.localizedDescription)) {
                            continuation.yield(event)
                        }
                    }
                    return didReceiveVisibleOutput
                }

                let stderrTask = Task { () -> String in
                    var stderrLines: [String] = []
                    var didTruncateStderr = false
                    var didYieldStderrActivity = false
                    do {
                        for try await line in JSONLStreamReader.lines(from: stderr) {
                            watchdog.markActivity()
                            if !didYieldStderrActivity {
                                didYieldStderrActivity = true
                                continuation.yield(.backendActivity("stderr-first-line"))
                            }
                            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            stderrLines.append(text)
                            if stderrLines.count > 600 {
                                stderrLines.removeFirst(stderrLines.count - 500)
                                didTruncateStderr = true
                            }
                        }
                    } catch {
                        for event in self.emitTerminalIfNeeded(.failed(error.localizedDescription)) {
                            continuation.yield(event)
                        }
                    }
                    let output = stderrLines.joined(separator: "\n")
                    return didTruncateStderr ? "... stderr truncated to last 500 lines ...\n\(output)" : output
                }

                process.waitUntilExit()
                let timedOut = watchdog.timedOut
                watchdog.cancel()
                self.locked { self.activityWatchdog = nil }
                let didReceiveVisibleOutput = await stdoutTask.value
                let stderrOutput = await stderrTask.value

                self.locked {
                    self.inputPipe = nil
                    self.process = nil
                }

                if self.locked({ !self.didFinishTurn }) {
                    let fallbackEvent: ChatBackendEvent
                    if timedOut {
                        fallbackEvent = .failed("DeepSeek Harness 超时无响应，已停止进程。请检查模型与网络配置。")
                    } else if process.terminationStatus == 0 {
                        if didReceiveVisibleOutput || !stderrOutput.isEmpty {
                            fallbackEvent = .finished
                        } else {
                            fallbackEvent = .failed("DeepSeek Harness 没有输出任何对话内容。请检查 ~/.dsh 配置与模型设置。")
                        }
                    } else if process.terminationReason == .uncaughtSignal {
                        fallbackEvent = .failed("DeepSeek Harness 已停止。")
                    } else {
                        let stderrText = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        fallbackEvent = .failed(stderrText.isEmpty
                            ? "DeepSeek Harness 退出码：\(process.terminationStatus)"
                            : "DeepSeek Harness 退出码：\(process.terminationStatus)\n\(stderrText)")
                    }
                    for event in self.emitTerminalIfNeeded(fallbackEvent) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                worker.cancel()
                self?.interrupt()
            }
        }
    }

    func interrupt() {
        locked {
            activityWatchdog?.cancel()
            activityWatchdog = nil
            if let sessionID = activeSessionID {
                // ACP 的取消语义是通知不是请求：agent 收到后结束当前 turn，
                // 随后 session/prompt 以 stopReason=cancelled 返回。
                sendNotification(method: "session/cancel", params: ["sessionId": sessionID])
            }
        }
        guard let process = locked({ self.process }), process.isRunning else { return }
        ChatProcessTerminator.stop(process, terminateAfter: .seconds(1), killAfter: .milliseconds(2200))
    }

    func terminateImmediately() {
        locked {
            activityWatchdog?.cancel()
            activityWatchdog = nil
        }
        guard let process = locked({ self.process }), process.isRunning else { return }
        ChatProcessTerminator.killNow(process)
    }

    func respondToPermission(requestID: String, decision: ChatPermissionDecision) -> Bool {
        locked {
            guard let request = pendingPermissions.removeValue(forKey: requestID) else { return false }
            let result: [String: Any]
            if let optionID = Self.preferredOptionID(from: request.options, decision: decision) {
                result = ["outcome": ["outcome": "selected", "optionId": optionID]]
            } else {
                // agent 没有提供匹配 kind 的选项时按 ACP 语义回 cancelled，而不是
                // 瞎编一个 optionId——后者会被 schema 校验拒绝并把 turn 卡死。
                result = ["outcome": ["outcome": "cancelled"]]
            }
            let didWrite = sendResponse(id: request.id, result: result)
            if didWrite {
                activityWatchdog?.resume()
            }
            return didWrite
        }
    }

    func sendCompact() -> Bool {
        // ACP v1 没有 compact 方法；返回 false 让 UI 按"不支持"处理。
        false
    }

    /// 终态 latch：重复终态事件直接丢弃。
    private func emitTerminalIfNeeded(_ event: ChatBackendEvent) -> [ChatBackendEvent] {
        locked {
            guard !didEmitTerminalEvent else { return [] }
            didEmitTerminalEvent = true
            return [event]
        }
    }

    private func terminateProcessIfNeeded() {
        guard let process, process.isRunning else { return }
        ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(800), killAfter: .seconds(2))
    }

    // MARK: - 握手与请求链

    private func bootstrap() {
        locked {
            let id = sendRequest(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ],
                "clientInfo": ["name": "acode", "title": "acode", "version": "1.0"]
            ])
            pendingRequests[id] = .initialize
        }
    }

    /// initialize 完成后按 sessionMode 决定 new / resume / list→resume。
    /// ACP 要求 cwd 必须是绝对路径（validateWorkspaceParams 校验）。
    private func requestSession(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) {
        let cwd = Self.absoluteProjectPath(options.projectPath)
        let resumeID = options.resumeSessionID?.nonEmptyTrimmed ?? session?.externalSessionID?.nonEmptyTrimmed

        if options.sessionMode == .resume, let resumeID {
            sendResumeSession(sessionID: resumeID, cwd: cwd)
            return
        }
        if options.sessionMode == .newSession {
            sendNewSession(cwd: cwd)
            return
        }
        // .continueLast 与无 id 的 .resume：先 session/list 取该 cwd 下最近会话。
        let id = sendRequest(method: "session/list", params: ["cwd": cwd])
        pendingRequests[id] = .listSessions
    }

    private func sendNewSession(cwd: String) {
        let id = sendRequest(method: "session/new", params: [
            "cwd": cwd,
            "mcpServers": []
        ])
        pendingRequests[id] = .newSession
    }

    private func sendResumeSession(sessionID: String, cwd: String) {
        pendingResumeID = sessionID
        let id = sendRequest(method: "session/resume", params: [
            "sessionId": sessionID,
            "cwd": cwd,
            "mcpServers": []
        ])
        pendingRequests[id] = .resumeSession
    }

    /// 会话就绪后先把 model / reasoning_effort 通过 session/set_config_option
    /// 按序下推，队列排空后再发 session/prompt。
    private func queueConfigWrites(options: ChatRunOptions, prompt: String, attachments: [ChatMessageAttachment]) {
        var writes: [(configId: String, value: String)] = []
        let modelID = ChatModelCatalog.executionModelID(for: options.modelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelID.isEmpty, modelID != "default" {
            // ACP 的 model select 值是 ["<provider>","<model>"] 的 JSON 元组；
            // 目录内建模型都在官方 deepseek-official provider 下。用户自定义的
            // 自建 provider 模型同样按官方 provider 组装——agent 校验不过会回
            // invalidParams，走告警路径继续跑 profile 默认模型。
            if let data = try? JSONSerialization.data(withJSONObject: ["deepseek-official", modelID]),
               let value = String(data: data, encoding: .utf8) {
                writes.append(("model", value))
            }
        }
        writes.append(("reasoning_effort", options.reasoningEffort.dshConfigValue))
        pendingConfigWrites = writes
        drainConfigQueue(prompt: prompt, options: options, attachments: attachments)
    }

    private func drainConfigQueue(prompt: String, options: ChatRunOptions, attachments: [ChatMessageAttachment]) {
        if let next = pendingConfigWrites.first, let sessionID = activeSessionID {
            pendingConfigWrites.removeFirst()
            let id = sendRequest(method: "session/set_config_option", params: [
                "sessionId": sessionID,
                "configId": next.configId,
                "value": next.value
            ])
            pendingRequests[id] = .setConfig
            return
        }
        sendPrompt(prompt: prompt, options: options, attachments: attachments)
    }

    private func sendPrompt(prompt: String, options: ChatRunOptions, attachments: [ChatMessageAttachment]) {
        guard let sessionID = activeSessionID else {
            didFinishTurn = true
            terminateProcessIfNeeded()
            _ = emitTerminalIfNeeded(.failed("DeepSeek Harness 会话未建立。"))
            return
        }
        var blocks: [[String: Any]] = []
        if let text = prompt.nonEmptyTrimmed {
            blocks.append(["type": "text", "text": text])
        }
        for attachment in attachments {
            blocks.append(Self.contentBlock(for: attachment, projectPath: options.projectPath, imageEnabled: imagePromptEnabled))
        }
        let id = sendRequest(method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": blocks
        ])
        pendingRequests[id] = .prompt
    }

    // MARK: - 帧分发

    private func events(
        fromLine line: String,
        prompt: String,
        options: ChatRunOptions,
        session: ChatSessionRecord?,
        attachments: [ChatMessageAttachment]
    ) -> [ChatBackendEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // JSON-RPC 语义：带 method 的一定是 request/notification，不是 response。
        // 必须先判 method——否则 agent 请求的 id 与我们 pending 的 id 数字撞上时
        // 会被误当成响应路由走（Codex 同款分发顺序在这里修掉）。
        if let method = object["method"] as? String {
            if let id = object["id"] {
                // agent → client 的 JSON-RPC 请求（权限询问、fs/terminal 等）。
                if method == "session/request_permission" {
                    return events(fromPermissionRequest: object, id: id)
                }
                let message = "acode embedded ACP client does not support server request method: \(method)"
                let didWrite = sendErrorResponse(id: id, code: -32601, message: message)
                return [.appendMessage(
                    kind: .rawOutput,
                    title: method,
                    subtitle: didWrite ? "unsupported request" : "response failed",
                    text: Self.compactText(from: object),
                    status: didWrite ? "unsupported" : "failed",
                    requestID: Self.requestKey(from: id)
                )]
            }
            guard method == "session/update" else { return [] }
            let params = object["params"] as? [String: Any] ?? [:]
            return events(fromUpdate: params["update"] as? [String: Any] ?? [:])
        }

        if let error = object["error"] as? [String: Any] {
            return events(fromError: error, envelope: object, prompt: prompt, options: options, attachments: attachments)
        }

        if let id = Self.intRequestID(from: object["id"]), let pending = pendingRequests.removeValue(forKey: id) {
            return events(fromResponse: object, pending: pending, prompt: prompt, options: options, session: session, attachments: attachments)
        }

        return []
    }

    private func events(
        fromError error: [String: Any],
        envelope: [String: Any],
        prompt: String,
        options: ChatRunOptions,
        attachments: [ChatMessageAttachment]
    ) -> [ChatBackendEvent] {
        let message = Self.errorText(from: error)

        // set_config_option 失败不致命：回显告警后继续 config 队列 / prompt。
        if let id = Self.intRequestID(from: envelope["id"]),
           pendingRequests[id] == .setConfig {
            pendingRequests.removeValue(forKey: id)
            var events: [ChatBackendEvent] = [.appendMessage(
                kind: .error,
                title: "session/set_config_option",
                subtitle: "DeepSeek",
                text: "配置项写入失败，已跳过：\(message)",
                status: "failed",
                requestID: nil
            )]
            events.append(contentsOf: drainConfigQueueEvents(prompt: prompt, options: options, attachments: attachments))
            return events
        }
        // resume/list 失败回退新建会话——继续跑比直接报错更符合用户意图，
        // 但要在消息里显式说明上下文没有续上。
        if let id = Self.intRequestID(from: envelope["id"]),
           pendingRequests[id] == .resumeSession || pendingRequests[id] == .listSessions {
            pendingRequests.removeValue(forKey: id)
            pendingResumeID = nil
            sendNewSession(cwd: Self.absoluteProjectPath(options.projectPath))
            return [.appendMessage(
                kind: .system,
                title: "session/resume",
                subtitle: "DeepSeek",
                text: "会话恢复失败，已改为新建会话：\(message)",
                status: "failed",
                requestID: nil
            )]
        }

        didFinishTurn = true
        terminateProcessIfNeeded()
        return emitTerminalIfNeeded(.failed(message))
    }

    private func events(
        fromResponse object: [String: Any],
        pending: PendingRequest,
        prompt: String,
        options: ChatRunOptions,
        session: ChatSessionRecord?,
        attachments: [ChatMessageAttachment]
    ) -> [ChatBackendEvent] {
        let result = object["result"] as? [String: Any] ?? [:]
        switch pending {
        case .initialize:
            if let capabilities = result["agentCapabilities"] as? [String: Any],
               let promptCapabilities = capabilities["promptCapabilities"] as? [String: Any] {
                imagePromptEnabled = Self.boolValue(promptCapabilities["image"]) == true
            }
            requestSession(prompt: prompt, options: options, session: session, attachments: attachments)
            return [.updateStreamingStatus("initialized")]
        case .listSessions:
            let sessions = result["sessions"] as? [[String: Any]] ?? []
            let cwd = Self.absoluteProjectPath(options.projectPath)
            if let sessionID = sessions.compactMap({ Self.stringValue($0["sessionId"]) }).first {
                sendResumeSession(sessionID: sessionID, cwd: cwd)
            } else {
                sendNewSession(cwd: cwd)
            }
            return [.updateStreamingStatus("session lookup")]
        case .newSession:
            guard let sessionID = Self.stringValue(result["sessionId"]) else {
                didFinishTurn = true
                terminateProcessIfNeeded()
                return emitTerminalIfNeeded(.failed("DeepSeek Harness session/new 未返回 sessionId。"))
            }
            activeSessionID = sessionID
            queueConfigWrites(options: options, prompt: prompt, attachments: attachments)
            return [
                .sessionID(sessionID),
                .updateStreamingStatus("session ready")
            ]
        case .resumeSession:
            guard let sessionID = pendingResumeID else {
                didFinishTurn = true
                terminateProcessIfNeeded()
                return emitTerminalIfNeeded(.failed("DeepSeek Harness session/resume 内部状态缺失。"))
            }
            pendingResumeID = nil
            activeSessionID = sessionID
            queueConfigWrites(options: options, prompt: prompt, attachments: attachments)
            return [
                .sessionID(sessionID),
                .updateStreamingStatus("session resumed")
            ]
        case .setConfig:
            return drainConfigQueueEvents(prompt: prompt, options: options, attachments: attachments)
        case .prompt:
            didFinishTurn = true
            terminateProcessIfNeeded()
            let stopReason = Self.stringValue(result["stopReason"]) ?? "end_turn"
            return [.updateStreamingStatus("stop: \(stopReason)")] + emitTerminalIfNeeded(.finished)
        }
    }

    private func drainConfigQueueEvents(prompt: String, options: ChatRunOptions, attachments: [ChatMessageAttachment]) -> [ChatBackendEvent] {
        drainConfigQueue(prompt: prompt, options: options, attachments: attachments)
        return [.updateStreamingStatus("configured")]
    }

    // MARK: - agent → client 请求 / 通知

    private func events(fromPermissionRequest object: [String: Any], id: Any) -> [ChatBackendEvent] {
        let requestID = Self.requestKey(from: id)
        let params = object["params"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        pendingPermissions[requestID] = AcpPermissionRequest(id: id, options: options)

        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let title = Self.stringValue(toolCall["title"])?.nonEmptyTrimmed ?? "权限请求"
        var lines: [String] = []
        if let callID = Self.stringValue(toolCall["toolCallId"])?.nonEmptyTrimmed {
            lines.append("工具调用：\(callID)")
        }
        if let rawInput = toolCall["rawInput"],
           JSONSerialization.isValidJSONObject(rawInput),
           let data = try? JSONSerialization.data(withJSONObject: rawInput, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8)?.nonEmptyTrimmed {
            lines.append(text)
        }
        let optionNames = options.compactMap { Self.stringValue($0["name"])?.nonEmptyTrimmed }
        if !optionNames.isEmpty {
            lines.append("可选：\(optionNames.joined(separator: " / "))")
        }
        return [.permissionRequest(
            id: requestID,
            title: title,
            text: lines.joined(separator: "\n")
        )]
    }

    private func events(fromUpdate update: [String: Any]) -> [ChatBackendEvent] {
        guard let sessionUpdate = Self.stringValue(update["sessionUpdate"]) else { return [] }
        switch sessionUpdate {
        case "agent_message_chunk":
            let text = Self.contentText(from: update["content"])
            guard !text.isEmpty else { return [] }
            return [.appendDelta(
                kind: .assistant,
                title: "assistant",
                subtitle: "DeepSeek",
                text: text,
                status: "streaming",
                requestID: Self.stringValue(update["messageId"])
            )]
        case "agent_thought_chunk":
            let text = Self.contentText(from: update["content"])
            guard !text.isEmpty else { return [] }
            return [.appendDelta(
                kind: .reasoning,
                title: "reasoning",
                subtitle: "DeepSeek",
                text: text,
                status: "streaming",
                requestID: Self.stringValue(update["messageId"]).map { "thought-\($0)" }
            )]
        case "tool_call":
            let toolCallID = Self.stringValue(update["toolCallId"])
            var lines: [String] = []
            if let rawInput = update["rawInput"],
               JSONSerialization.isValidJSONObject(rawInput),
               let data = try? JSONSerialization.data(withJSONObject: rawInput, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8)?.nonEmptyTrimmed {
                lines.append(text)
            }
            return [.appendMessage(
                kind: .toolCall,
                title: Self.stringValue(update["title"])?.nonEmptyTrimmed ?? "tool call",
                subtitle: "DeepSeek",
                text: lines.joined(separator: "\n"),
                status: "streaming",
                requestID: toolCallID
            )]
        case "tool_call_update":
            let toolCallID = Self.stringValue(update["toolCallId"])
            let status = Self.stringValue(update["status"]) ?? ""
            let resultText = Self.toolResultText(from: update["content"])
            var events: [ChatBackendEvent] = []
            if let text = resultText.nonEmptyTrimmed {
                events.append(.appendDelta(
                    kind: .toolCall,
                    title: "tool result",
                    subtitle: "DeepSeek",
                    text: "\n\(text)",
                    status: "streaming",
                    requestID: toolCallID
                ))
            }
            if status == "completed" || status == "failed" || status == "cancelled" {
                events.append(.finishStreamingMessage(
                    kind: .toolCall,
                    requestID: toolCallID,
                    status: status == "completed" ? "done" : "failed"
                ))
            }
            return events
        case "usage_update":
            let used = Self.intValue(update["used"]) ?? 0
            let total = Self.intValue(update["size"]) ?? 0
            guard used > 0 || total > 0 else { return [] }
            return [.tokenUsage(used: used, total: total, output: nil)]
        default:
            // config_option_update / available_commands_update / plan 等暂无 UI 映射。
            return []
        }
    }

    // MARK: - JSON-RPC 写通道（全部在 stateLock 内调用）

    @discardableResult
    private func sendRequest(method: String, params: Any) -> Int {
        let id = nextID
        nextID += 1
        writeJSONObject(["id": id, "method": method, "params": params])
        return id
    }

    private func sendNotification(method: String, params: Any? = nil) {
        var object: [String: Any] = ["method": method]
        if let params {
            object["params"] = params
        }
        writeJSONObject(object)
    }

    @discardableResult
    private func sendResponse(id: Any, result: [String: Any]) -> Bool {
        writeJSONObject(["id": id, "result": result])
    }

    @discardableResult
    private func sendErrorResponse(id: Any, code: Int, message: String) -> Bool {
        writeJSONObject([
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    @discardableResult
    private func writeJSONObject(_ object: [String: Any]) -> Bool {
        let didWrite = ChatPipeWriter.writeJSONObject(object, to: inputPipe)
        if didWrite {
            activityWatchdog?.markActivity()
        }
        return didWrite
    }

    // MARK: - 纯函数映射

    /// ACP 权限选项按 kind 选择：allow_once/allow_always/reject_once/reject_always。
    /// .allowForSession 优先 allow_always，没有时退 allow_once（DSH 目前只发
    /// allow-once / reject-once 两个选项）。
    private static func preferredOptionID(from options: [[String: Any]], decision: ChatPermissionDecision) -> String? {
        let preferredKinds: [String]
        switch decision {
        case .deny: preferredKinds = ["reject_always", "reject_once"]
        case .allow: preferredKinds = ["allow_once", "allow_always"]
        case .allowForSession: preferredKinds = ["allow_always", "allow_once"]
        }
        for kind in preferredKinds {
            if let optionID = options.first(where: { stringValue($0["kind"]) == kind })?["optionId"].flatMap({ stringValue($0) }) {
                return optionID
            }
        }
        return nil
    }

    private static func contentText(from content: Any?) -> String {
        guard let block = content as? [String: Any] else { return "" }
        if let text = stringValue(block["text"]) { return text }
        return ""
    }

    private static func toolResultText(from content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            if let nested = item["content"] as? [String: Any] {
                return stringValue(nested["text"])
            }
            return stringValue(item["text"])
        }.joined(separator: "\n")
    }

    /// 附件 → ACP content block。文本以外一律 resource_link（DSH 渲染成
    /// `[resource_link name= uri=]` 文本标记，模型可用工具按 file:// 路径读
    /// 原文件）；图片在 agent 声明 image 能力时发 base64 image 块，超出
    /// 支持类型/大小上限同样降级为 resource_link。
    private static func contentBlock(for attachment: ChatMessageAttachment, projectPath: String, imageEnabled: Bool) -> [String: Any] {
        let resolvedPath = attachment.path.hasPrefix("/")
            ? attachment.path
            : (projectPath as NSString).appendingPathComponent(attachment.path)
        let displayName = attachment.filename.isEmpty ? (resolvedPath as NSString).lastPathComponent : attachment.filename
        let fileURL = URL(fileURLWithPath: resolvedPath)

        if attachment.kind == .image, imageEnabled {
            let acpImageTypes: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif"]
            let mediaType = mimeType(forPath: resolvedPath)
            let maxImageBytes = 8 * 1024 * 1024
            if acpImageTypes.contains(mediaType),
               let data = try? Data(contentsOf: fileURL), data.count <= maxImageBytes {
                return [
                    "type": "image",
                    "data": data.base64EncodedString(),
                    "mimeType": mediaType
                ]
            }
        }
        return [
            "type": "resource_link",
            "uri": fileURL.absoluteString,
            "name": displayName
        ]
    }

    private static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    private static func absoluteProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
            kind != .system && !text.isEmpty
        case .finishStreamingMessage, .sessionID, .updateStreamingStatus, .backendActivity, .finished, .tokenUsage:
            false
        }
    }

    private static func errorText(from error: [String: Any]) -> String {
        if let message = stringValue(error["message"])?.nonEmptyTrimmed {
            return message
        }
        return compactText(from: error)
    }

    private static func compactText(from object: [String: Any]) -> String {
        if let text = stringValue(object["text"]) ?? stringValue(object["message"]) {
            return text
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private static func intRequestID(from value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func requestKey(from value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
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

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
