import Darwin
import Foundation

final class CodexAppServerBackend: ChatProcessBackend {
    private static let idleTimeout: TimeInterval = 30 * 60

    private enum PendingRequest {
        case initialize
        case openThread
        case startTurn
        case interrupt
    }

    private struct ApprovalRequest {
        let id: Any
        let method: String
        let requestedPermissions: [String: Any]?
    }

    private struct InteractiveRequest {
        let id: Any
        let method: String
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var nextID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    private var pendingInteractiveRequests: [String: InteractiveRequest] = [:]
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var didFinishTurn = false
    /// 终态 latch：一旦发出过 .failed 或 .finished，就阻止后续重复发出。
    /// 否则 Codex 在 error notification 之后又发出 turn/completed，会让 ChatPanelState
    /// 把已经标 .failed 的状态翻转回 .completed 并自动启动队列（旧 F14 bug）。
    private var didEmitTerminalEvent = false
    private var activityWatchdog: ChatProcessActivityWatchdog?
    /// Guards all shared mutable state above (request/approval/interactive maps, nextID,
    /// thread/turn ids, flags, process/inputPipe). It is concurrently touched by the stdout
    /// reader Task and by respond*/interrupt/sendCompact on the MainActor. Recursive because
    /// some locked sections call helpers that lock again. All stdin writes happen under it, so
    /// JSON-RPC frames can't interleave.
    private let stateLock = NSRecursiveLock()

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Pins the active app-owned Codex relay profile via the highest-priority `-c` overrides so
    /// our provider/base_url/model win over any residual `model_provider` or `[model_providers.*]`
    /// left in the user's `~/.codex/config.toml` by another tool. The API key still flows through
    /// `~/.codex/auth.json`, so it is intentionally not surfaced here.
    private static func activeCodexConfigOverrides() -> [String] {
        let profiles = ProjectStore.loadConfigProfiles()
        guard let id = profiles.activeCodexProfileID,
              let profile = profiles.codexProfiles.first(where: { $0.id == id }) else {
            return []
        }
        let providerID = "codevoke_custom"
        func quoted(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        var overrides: [String] = []
        if let model = profile.model.nonEmptyTrimmed {
            overrides.append("model=\(quoted(model))")
        }
        if let baseURL = profile.baseURL.nonEmptyTrimmed {
            overrides.append("model_provider=\(quoted(providerID))")
            overrides.append("model_providers.\(providerID).name=\(quoted(providerID))")
            overrides.append("model_providers.\(providerID).base_url=\(quoted(baseURL))")
            if let wireApi = profile.wireApi.nonEmptyTrimmed {
                overrides.append("model_providers.\(providerID).wire_api=\(quoted(wireApi))")
            }
            overrides.append("model_providers.\(providerID).requires_openai_auth=true")
        }
        return overrides
    }

    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) -> AsyncThrowingStream<ChatBackendEvent, Error> {
        // TODO(B-P0-1 Codex): Codex `turn/start` JSON-RPC currently only
        // accepts a plain `input` array of `{type:text}` blocks. The Codex
        // app-server protocol has no documented image/file attachment block
        // shape today, so we deliberately drop `attachments` here and only
        // surface them in the UI bubble. If Codex adds an attachment block
        // schema, hydrate it inside `requestTurnStart` below.
        _ = attachments
        return AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                self.locked {
                    self.didFinishTurn = false
                    self.didEmitTerminalEvent = false
                    self.pendingRequests = [:]
                    self.pendingApprovals = [:]
                    self.pendingInteractiveRequests = [:]
                    self.activeThreadID = nil
                    self.activeTurnID = nil
                }

                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                let configOverride = "model_reasoning_effort=\"\(options.reasoningEffort.codexConfigValue)\""
                process.executableURL = URL(fileURLWithPath: options.executablePath)
                var codexArguments = ["app-server", "-c", configOverride]
                for override in Self.activeCodexConfigOverrides() {
                    codexArguments.append("-c")
                    codexArguments.append(override)
                }
                codexArguments.append(contentsOf: ["--listen", "stdio://"])
                process.arguments = codexArguments
                process.currentDirectoryURL = URL(fileURLWithPath: options.projectPath, isDirectory: true)
                process.environment = ChatCLIEnvironment.processEnvironment
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
                    self.bootstrapCodex()
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
                                    fromCodexLine: line,
                                    prompt: prompt,
                                    options: options,
                                    session: session
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
                        // 与 turn/completed / error notification 走同一个终态 latch，
                        // 避免 stdout reader 报错与上游事件重复发出 .failed。
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
                            stderrLines.append(line)
                            if stderrLines.count > 600 {
                                stderrLines.removeFirst(stderrLines.count - 500)
                                didTruncateStderr = true
                            }
                            guard let event = Self.stderrEvent(from: line) else { continue }
                            continuation.yield(event)
                        }
                    } catch {
                        // 同 stdoutTask：stderr reader 报错也走 latch，跟上游保持一致。
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
                let didEmitStderrOutput = !stderrOutput.isEmpty

                self.locked {
                    self.inputPipe = nil
                    self.process = nil
                }

                // 兜底：进程退出但流里没发出过终态事件时，根据退出状态推一个。
                // emitTerminalIfNeeded 内部用 didEmitTerminalEvent latch 二次保险——
                // 如果上游已经发过 .failed/.finished（例如 events(fromError) 那条路径），
                // 这里就不会再覆盖一次。
                if self.locked({ !self.didFinishTurn }) {
                    let fallbackEvent: ChatBackendEvent
                    if timedOut {
                        fallbackEvent = .failed("Codex app-server 超时无响应，已停止进程。请检查认证、模型或网络配置。")
                    } else if process.terminationStatus == 0 {
                        if didReceiveVisibleOutput || didEmitStderrOutput {
                            fallbackEvent = .finished
                        } else {
                            fallbackEvent = .failed("Codex app-server 没有输出任何对话内容。请检查 ~/.codex 权限、中转站 API Key 或模型设置。")
                        }
                    } else if process.terminationReason == .uncaughtSignal {
                        fallbackEvent = .failed("Codex 已停止。")
                    } else {
                        let stderr = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        fallbackEvent = .failed(stderr.isEmpty
                            ? "Codex app-server 退出码：\(process.terminationStatus)"
                            : "Codex app-server 退出码：\(process.terminationStatus)\n\(stderr)")
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
        }
        guard let process = locked({ self.process }), process.isRunning else { return }
        locked {
            if let threadID = activeThreadID, let turnID = activeTurnID {
                let id = sendRequest(method: "turn/interrupt", params: [
                    "threadId": threadID,
                    "turnId": turnID
                ])
                pendingRequests[id] = .interrupt
            }
        }
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
            guard let approval = pendingApprovals.removeValue(forKey: requestID) else { return false }

            let result: [String: Any]
            switch approval.method {
            case "item/commandExecution/requestApproval":
                result = ["decision": codexApprovalDecision(from: decision)]
            case "item/fileChange/requestApproval":
                result = ["decision": codexApprovalDecision(from: decision)]
            case "item/permissions/requestApproval":
                result = [
                    "permissions": decision.isAllowed ? (approval.requestedPermissions ?? [:]) : [:],
                    "scope": decision == .allowForSession ? "session" : "turn"
                ]
            case "applyPatchApproval", "execCommandApproval":
                result = ["decision": decision.isAllowed ? "approved" : "denied"]
            default:
                result = ["decision": codexApprovalDecision(from: decision)]
            }

            let didWrite = sendResponse(id: approval.id, result: result)
            if didWrite {
                activityWatchdog?.resume()
            }
            return didWrite
        }
    }

    func respondToInteractiveRequest(requestID: String, response: ChatInteractiveResponse) -> Bool {
        locked {
            guard let request = pendingInteractiveRequests.removeValue(forKey: requestID) else { return false }
            // Send a single, well-formed JSON-RPC result. The previous shotgun of duplicate
            // snake_case keys plus a `method` field (invalid inside a result) risked Codex
            // rejecting the response and wedging the turn.
            var result: [String: Any] = ["selectedOptionIds": response.selectedOptionIDs]
            if let customText = response.customText?.nonEmptyTrimmed {
                result["text"] = customText
            } else if !response.selectedOptionIDs.isEmpty {
                result["answer"] = response.selectedOptionIDs.joined(separator: ", ")
            }
            let didWrite = sendResponse(id: request.id, result: result)
            if didWrite {
                activityWatchdog?.resume()
            }
            return didWrite
        }
    }

    func sendCompact() -> Bool {
        locked {
            _ = sendRequest(method: "compact", params: [:])
            return inputPipe != nil
        }
    }

    /// Audit B-P1-3: error-path teardown must escalate signals to child
    /// processes the same way `interrupt()` does, otherwise crashes leave
    /// orphan `codex app-server` children.
    private func terminateProcessIfNeeded() {
        guard let process, process.isRunning else { return }
        ChatProcessTerminator.stop(process, terminateAfter: .milliseconds(800), killAfter: .seconds(2))
    }

    private func codexApprovalDecision(from decision: ChatPermissionDecision) -> String {
        switch decision {
        case .deny: "decline"
        case .allow: "accept"
        case .allowForSession: "acceptForSession"
        }
    }

    private func bootstrapCodex() {
        locked {
            let id = sendRequest(method: "initialize", params: [
                "clientInfo": [
                    "name": "acode",
                    "title": "acode",
                    "version": "1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ])
            pendingRequests[id] = .initialize
        }
    }

    private func requestThread(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?) {
        let resumeID = options.resumeSessionID?.nonEmptyTrimmed ?? session?.externalSessionID?.nonEmptyTrimmed
        var params: [String: Any] = [
            "cwd": options.projectPath,
            "model": options.modelID,
            "approvalPolicy": options.permissionMode.codexApprovalPolicy,
            "sandbox": options.permissionMode.codexSandbox,
            "serviceName": "acode"
        ]

        let method: String
        if options.sessionMode == .resume, let resumeID {
            method = "thread/resume"
            params["threadId"] = resumeID
        } else {
            method = "thread/start"
        }

        let id = sendRequest(method: method, params: params)
        pendingRequests[id] = .openThread
    }

    private func requestTurnStart(threadID: String, prompt: String, options: ChatRunOptions) {
        let params: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": prompt,
                "text_elements": []
            ]],
            "cwd": options.projectPath,
            "approvalPolicy": options.permissionMode.codexApprovalPolicy,
            "model": options.modelID
        ]
        let id = sendRequest(method: "turn/start", params: params)
        pendingRequests[id] = .startTurn
    }

    private func events(
        fromCodexLine line: String,
        prompt: String,
        options: ChatRunOptions,
        session: ChatSessionRecord?
    ) -> [ChatBackendEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let error = object["error"] as? [String: Any] {
            return events(fromError: error, envelope: object)
        }

        if let id = Self.intRequestID(from: object["id"]), let pending = pendingRequests.removeValue(forKey: id) {
            return events(fromResponse: object, pending: pending, prompt: prompt, options: options, session: session)
        }

        guard let method = object["method"] as? String else {
            return []
        }

        if let id = object["id"] {
            if Self.isApprovalRequest(method) {
                return events(fromServerRequest: object, id: id, method: method)
            }
            if Self.isInteractiveRequest(method, object: object) {
                return events(fromInteractiveServerRequest: object, id: id, method: method)
            }
            return events(fromServerRequest: object, id: id, method: method, options: options)
        }

        return events(fromNotification: object, method: method)
    }

    private func events(fromError error: [String: Any], envelope: [String: Any]) -> [ChatBackendEvent] {
        let message = Self.codexErrorText(from: error)
        if Self.boolValue(envelope["willRetry"]) == true {
            return [
                .updateStreamingStatus(Self.stringValue(error["message"]) ?? "reconnecting"),
                .appendMessage(kind: .commandOutput, title: "codex", subtitle: "retrying", text: message, status: "retry", requestID: nil)
            ]
        }
        didFinishTurn = true
        // Audit B-P1-3: route teardown through the SIGINT->SIGTERM->SIGKILL
        // ladder so any forked children of `codex app-server` are escalated
        // and don't become orphans on the error path.
        terminateProcessIfNeeded()
        return emitTerminalIfNeeded(.failed(message))
    }

    private func events(
        fromResponse object: [String: Any],
        pending: PendingRequest,
        prompt: String,
        options: ChatRunOptions,
        session: ChatSessionRecord?
    ) -> [ChatBackendEvent] {
        switch pending {
        case .initialize:
            sendNotification(method: "initialized")
            requestThread(prompt: prompt, options: options, session: session)
            return [.updateStreamingStatus("initialized")]
        case .openThread:
            guard let result = object["result"] as? [String: Any],
                  let threadID = Self.threadID(from: result) else {
                didFinishTurn = true
                terminateProcessIfNeeded()
                return emitTerminalIfNeeded(.failed("Codex thread/start 未返回 thread id。"))
            }
            activeThreadID = threadID
            requestTurnStart(threadID: threadID, prompt: prompt, options: options)
            return [
                .sessionID(threadID),
                .updateStreamingStatus("thread ready")
            ]
        case .startTurn:
            if let result = object["result"] as? [String: Any],
               let turnID = Self.turnID(from: result) {
                activeTurnID = turnID
            }
            return [.updateStreamingStatus("turn started")]
        case .interrupt:
            didFinishTurn = true
            return emitTerminalIfNeeded(.finished)
        }
    }

    /// 把终态事件（.failed / .finished）通过 latch 发出，已经发过的就丢弃。
    /// Codex 在 error notification 之后还可能再发出 turn/completed，没有 latch 的话
    /// ChatPanelState 会先 .failed 再 .finished，导致 反复覆盖状态。
    private func emitTerminalIfNeeded(_ event: ChatBackendEvent) -> [ChatBackendEvent] {
        locked {
            guard !didEmitTerminalEvent else { return [] }
            didEmitTerminalEvent = true
            return [event]
        }
    }

    private func events(fromServerRequest object: [String: Any], id: Any, method: String) -> [ChatBackendEvent] {
        let requestID = Self.requestKey(from: id)
        let params = object["params"] as? [String: Any] ?? [:]
        pendingApprovals[requestID] = ApprovalRequest(
            id: id,
            method: method,
            requestedPermissions: params["permissions"] as? [String: Any]
        )
        return [.permissionRequest(
            id: requestID,
            title: Self.title(forApprovalMethod: method),
            text: Self.approvalText(method: method, params: params)
        )]
    }

    private func events(fromInteractiveServerRequest object: [String: Any], id: Any, method: String) -> [ChatBackendEvent] {
        let requestID = Self.requestKey(from: id)
        pendingInteractiveRequests[requestID] = InteractiveRequest(id: id, method: method)
        let params = object["params"] as? [String: Any] ?? [:]
        return [.interactiveRequest(Self.interactiveRequest(id: requestID, method: method, params: params))]
    }

    private func events(fromServerRequest object: [String: Any], id: Any, method: String, options: ChatRunOptions) -> [ChatBackendEvent] {
        if Self.isReadFileRequest(method) {
            return events(fromReadFileRequest: object, id: id, method: method, projectPath: options.projectPath)
        }
        return events(fromUnsupportedServerRequest: object, id: id, method: method)
    }

    private func events(fromReadFileRequest object: [String: Any], id: Any, method: String, projectPath: String) -> [ChatBackendEvent] {
        let params = object["params"] as? [String: Any] ?? [:]
        guard let rawPath = Self.pathValue(from: params) else {
            let message = "Codex readFile request missing path"
            let didWrite = sendErrorResponse(id: id, code: -32602, message: message)
            return [.appendMessage(kind: .toolResult, title: method, subtitle: didWrite ? "invalid request" : "response failed", text: message, status: "failed", requestID: Self.requestKey(from: id))]
        }
        do {
            let fileURL = try Self.projectFileURL(rawPath: rawPath, projectPath: projectPath)
            let text = try Self.readProjectTextFile(fileURL)
            let didWrite = sendResponse(id: id, result: [
                "content": text,
                "text": text,
                "path": fileURL.path
            ])
            return [.appendMessage(kind: .toolResult, title: method, subtitle: didWrite ? fileURL.lastPathComponent : "response failed", text: "read \(fileURL.path)", status: didWrite ? "done" : "failed", requestID: Self.requestKey(from: id))]
        } catch {
            let message = error.localizedDescription
            let didWrite = sendErrorResponse(id: id, code: -32000, message: message)
            return [.appendMessage(kind: .toolResult, title: method, subtitle: didWrite ? "read failed" : "response failed", text: message, status: "failed", requestID: Self.requestKey(from: id))]
        }
    }

    private func events(fromUnsupportedServerRequest object: [String: Any], id: Any, method: String) -> [ChatBackendEvent] {
        let message = "Codevoke embedded Codex client does not support server request method: \(method)"
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

    private func events(fromNotification object: [String: Any], method: String) -> [ChatBackendEvent] {
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "thread/started":
            if let threadID = Self.threadID(from: params) {
                activeThreadID = threadID
                return [.sessionID(threadID)]
            }
        case "turn/started":
            if let turnID = Self.turnID(from: params) {
                activeTurnID = turnID
            }
            return [.updateStreamingStatus("streaming")]
        case "item/agentMessage/delta":
            return [.appendDelta(kind: .assistant, title: "assistant", subtitle: "Codex", text: Self.deltaText(from: params), status: "streaming", requestID: Self.itemID(from: params))]
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            let text = Self.deltaText(from: params)
            guard !text.isEmpty else { return [] }
            return [.appendDelta(kind: .reasoning, title: "reasoning", subtitle: "Codex", text: text, status: "streaming", requestID: outputRequestID(method: method, params: params))]
        case "item/plan/delta":
            let text = Self.deltaText(from: params)
            guard !text.isEmpty else { return [] }
            return [.appendDelta(kind: .toolCall, title: "plan", subtitle: "Codex", text: text, status: "streaming", requestID: outputRequestID(method: method, params: params))]
        case "command/exec/outputDelta", "item/commandExecution/outputDelta":
            let text = Self.deltaText(from: params)
            guard !text.isEmpty else { return [] }
            return [.appendDelta(kind: .commandOutput, title: Self.itemTitle(from: params, fallback: "command output"), subtitle: "Codex", text: text, status: "streaming", requestID: outputRequestID(method: method, params: params))]
        case "item/fileChange/outputDelta":
            let text = Self.deltaText(from: params)
            guard !text.isEmpty else { return [] }
            return [.appendDelta(kind: .diff, title: Self.itemTitle(from: params, fallback: "file change"), subtitle: "Codex", text: text, status: "streaming", requestID: outputRequestID(method: method, params: params))]
        case "turn/diff/updated":
            guard let text = Self.diffText(from: params)?.nonEmptyTrimmed else { return [] }
            return [.appendDelta(kind: .diff, title: "diff", subtitle: "Codex", text: text, status: "streaming", requestID: outputRequestID(method: method, params: params))]
        case "item/started", "item/completed":
            let itemType = Self.itemType(from: params).lowercased()
            if Self.shouldSuppressCodexItemType(itemType) {
                return []
            }
            let completed = method == "item/completed"
            let kind = Self.kindForCodexItem(params, completed: completed)
            if kind == .diff {
                guard completed, let diffText = Self.diffText(from: params)?.nonEmptyTrimmed else { return [] }
                return [.appendMessage(
                    kind: .diff,
                    title: Self.itemTitle(from: params, fallback: "file change"),
                    subtitle: "Codex",
                    text: diffText,
                    status: "done",
                    requestID: Self.itemID(from: params)
                )]
            }
            return [.appendMessage(
                kind: kind,
                title: Self.itemTitle(from: params, fallback: completed ? "item completed" : "item started"),
                subtitle: "Codex",
                text: Self.compactText(from: params),
                status: completed ? "done" : "streaming",
                requestID: Self.itemID(from: params)
            )]
        case "thread/tokenUsage/updated":
            let usage = params["usage"] as? [String: Any]
            let used = Self.intValue(params["used"]) ?? Self.intValue(usage?["used"]) ?? 0
            let total = Self.intValue(params["total"]) ?? Self.intValue(usage?["total"]) ?? 0
            let output = Self.intValue(params["output"]) ?? Self.intValue(usage?["output"])
            return [.tokenUsage(used: used, total: total, output: output)]
        case "mcpServer/startupStatus/updated",
             "thread/status/changed",
             "remoteControl/status/changed",
             "account/rateLimits/updated",
             "session/configured",
             "session/connected":
            return []
        case "turn/completed":
            didFinishTurn = true
            terminateProcessIfNeeded()
            if let turn = params["turn"] as? [String: Any],
               let error = turn["error"], !(error is NSNull) {
                return emitTerminalIfNeeded(.failed(Self.codexErrorText(from: error)))
            }
            return emitTerminalIfNeeded(.finished)
        case "error":
            return events(fromError: params, envelope: object)
        default:
            return []
        }
        return []
    }

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

    private static func shouldPauseActivityWatchdog(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .permissionRequest, .interactiveRequest:
            true
        default:
            false
        }
    }

    private static func isApprovalRequest(_ method: String) -> Bool {
        method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
            || method == "item/permissions/requestApproval"
            || method == "applyPatchApproval"
            || method == "execCommandApproval"
    }

    private static func isReadFileRequest(_ method: String) -> Bool {
        let normalized = method.lowercased().replacingOccurrences(of: "_", with: "")
        return normalized.contains("readfile") || normalized == "fs/read" || normalized.hasSuffix("/read")
    }

    private static func isInteractiveRequest(_ method: String, object: [String: Any]) -> Bool {
        let params = object["params"] as? [String: Any] ?? [:]
        let normalized = method.lowercased().replacingOccurrences(of: "_", with: "")
        guard !normalized.contains("approval"), !normalized.contains("permission") else { return false }
        return normalized.contains("ask")
            || normalized.contains("question")
            || normalized.contains("choice")
            || normalized.contains("input")
            || params["options"] != nil
            || params["choices"] != nil
            || params["questions"] != nil
    }

    private func outputRequestID(method: String, params: [String: Any]) -> String {
        if let value = Self.outputID(from: params) {
            return value
        }
        let turnPrefix = activeTurnID ?? activeThreadID ?? "turn"
        return "\(turnPrefix)-\(method)"
    }

    private static func outputID(from object: [String: Any]) -> String? {
        let keys = ["itemId", "item_id", "callId", "call_id", "commandId", "command_id", "outputId", "output_id", "id"]
        for key in keys {
            if let value = stringValue(object[key]) {
                return value
            }
        }
        if let item = object["item"] as? [String: Any] {
            return outputID(from: item)
        }
        return nil
    }

    private static func interactiveRequest(id: String, method: String, params: [String: Any]) -> ChatInteractiveRequest {
        let options = interactiveOptions(from: params)
        let mode: ChatInteractiveMode
        if options.isEmpty {
            mode = .text
        } else if boolValue(params["multiple"]) == true || boolValue(params["multiSelect"]) == true || boolValue(params["multi_select"]) == true {
            mode = .multipleChoice
        } else {
            mode = .singleChoice
        }
        return ChatInteractiveRequest(
            id: id,
            title: stringValue(params["title"]) ?? "需要选择",
            prompt: stringValue(params["prompt"])
                ?? stringValue(params["question"])
                ?? stringValue(params["message"])
                ?? stringValue(params["text"])
                ?? "请选择后继续。",
            mode: mode,
            options: options,
            allowCustomInput: boolValue(params["allowCustomInput"]) ?? boolValue(params["allow_custom_input"]) ?? false,
            placeholder: stringValue(params["placeholder"]) ?? "输入回复",
            status: .waiting
        )
    }

    private static func interactiveOptions(from params: [String: Any]) -> [ChatInteractiveOption] {
        let rawOptions = params["options"] ?? params["choices"] ?? params["questions"]
        guard let array = rawOptions as? [Any] else { return [] }
        return array.enumerated().map { index, item in
            if let text = stringValue(item) {
                return ChatInteractiveOption(id: text, label: text, detail: "")
            }
            if let option = item as? [String: Any] {
                let id = stringValue(option["id"]) ?? stringValue(option["value"]) ?? stringValue(option["label"]) ?? "option-\(index + 1)"
                let label = stringValue(option["label"]) ?? stringValue(option["title"]) ?? stringValue(option["text"]) ?? id
                let detail = stringValue(option["detail"]) ?? stringValue(option["description"]) ?? ""
                return ChatInteractiveOption(id: id, label: label, detail: detail)
            }
            return ChatInteractiveOption(id: "option-\(index + 1)", label: "选项 \(index + 1)", detail: "")
        }
    }

    private static func pathValue(from params: [String: Any]) -> String? {
        if let value = stringValue(params["path"]) ?? stringValue(params["filePath"]) ?? stringValue(params["filepath"]) ?? stringValue(params["uri"]) {
            return value.hasPrefix("file://") ? URL(string: value)?.path : value
        }
        if let file = params["file"] as? [String: Any] {
            return pathValue(from: file)
        }
        return nil
    }

    private static let maxReadableFileBytes = 5 * 1024 * 1024

    private static func projectFileURL(rawPath: String, projectPath: String) throws -> URL {
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let requestedURL: URL
        if rawPath.hasPrefix("/") {
            requestedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        } else {
            requestedURL = projectURL.appendingPathComponent(rawPath).standardizedFileURL
        }
        let fileURL = requestedURL.resolvingSymlinksInPath()
        guard Self.isInsideProject(fileURL, projectURL: projectURL) else {
            throw ChatProcessError.unsupported("Codex readFile 越过项目目录：\(fileURL.path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ChatProcessError.unsupported("Codex readFile 找不到文本文件：\(fileURL.path)")
        }
        return fileURL
    }

    private static func readProjectTextFile(_ fileURL: URL) throws -> String {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if (values.fileSize ?? 0) > maxReadableFileBytes {
            throw ChatProcessError.unsupported("Codex readFile 文件过大，暂不支持读取超过 5 MB 的文件：\(fileURL.path)")
        }
        let data = try Data(contentsOf: fileURL)
        if data.count > maxReadableFileBytes {
            throw ChatProcessError.unsupported("Codex readFile 文件过大，暂不支持读取超过 5 MB 的文件：\(fileURL.path)")
        }
        if data.prefix(4096).contains(0) {
            throw ChatProcessError.unsupported("Codex readFile 检测到二进制文件，已拒绝读取：\(fileURL.path)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChatProcessError.unsupported("Codex readFile 仅支持 UTF-8 文本文件：\(fileURL.path)")
        }
        return text
    }

    private static func isInsideProject(_ fileURL: URL, projectURL: URL) -> Bool {
        fileURL.path == projectURL.path || fileURL.path.hasPrefix(projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/")
    }

    private static func title(forApprovalMethod method: String) -> String {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval": "命令执行权限"
        case "item/fileChange/requestApproval", "applyPatchApproval": "文件修改权限"
        case "item/permissions/requestApproval": "额外权限请求"
        default: method
        }
    }

    private static func stderrEvent(from line: String) -> ChatBackendEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("could not update PATH") || text.contains("WARNING: proceeding") {
            return nil
        }
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fields = object["fields"] as? [String: Any] {
            let level = stringValue(object["level"]) ?? ""
            let message = stringValue(fields["message"]) ?? compactText(from: fields)
            guard level == "ERROR" else { return nil }
            let lowercased = message.lowercased()
            guard lowercased.contains("permission")
                || lowercased.contains("operation not permitted")
                || lowercased.contains("failed to create session")
                || lowercased.contains("readonly database")
            else {
                return nil
            }
            return .appendMessage(kind: .error, title: "Codex error", subtitle: "Codex", text: message, status: "failed", requestID: nil)
        }
        return nil
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

    private static func approvalText(method: String, params: [String: Any]) -> String {
        if method == "item/commandExecution/requestApproval" {
            let command = stringValue(params["command"]) ?? "未知命令"
            let cwd = stringValue(params["cwd"]) ?? ""
            let reason = stringValue(params["reason"]) ?? ""
            return [command, cwd.isEmpty ? nil : "cwd: \(cwd)", reason.isEmpty ? nil : reason]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        if method == "item/fileChange/requestApproval" {
            let root = stringValue(params["grantRoot"]) ?? ""
            let reason = stringValue(params["reason"]) ?? ""
            return [root.isEmpty ? "文件修改" : "root: \(root)", reason.isEmpty ? nil : reason]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        return compactText(from: params)
    }

    private static func threadID(from object: [String: Any]) -> String? {
        if let value = stringValue(object["threadId"]) ?? stringValue(object["thread_id"]) {
            return value
        }
        if let thread = object["thread"] as? [String: Any] {
            return stringValue(thread["id"]) ?? stringValue(thread["threadId"])
        }
        return nil
    }

    private static func turnID(from object: [String: Any]) -> String? {
        if let value = stringValue(object["turnId"]) ?? stringValue(object["turn_id"]) {
            return value
        }
        if let turn = object["turn"] as? [String: Any] {
            return stringValue(turn["id"]) ?? stringValue(turn["turnId"])
        }
        return nil
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

    private static func itemID(from object: [String: Any]) -> String? {
        if let value = stringValue(object["itemId"]) ?? stringValue(object["item_id"]) ?? stringValue(object["id"]) {
            return value
        }
        if let item = object["item"] as? [String: Any] {
            return stringValue(item["id"]) ?? stringValue(item["itemId"])
        }
        return nil
    }

    private static func itemTitle(from object: [String: Any], fallback: String) -> String {
        if let value = stringValue(object["title"]) ?? stringValue(object["name"]) ?? stringValue(object["type"]) {
            return value
        }
        if let item = object["item"] as? [String: Any] {
            return stringValue(item["title"]) ?? stringValue(item["name"]) ?? stringValue(item["type"]) ?? fallback
        }
        return fallback
    }

    private static func itemType(from object: [String: Any]) -> String {
        if let value = stringValue(object["type"]) ?? stringValue(object["itemType"]) ?? stringValue(object["item_type"]) {
            return value
        }
        if let item = object["item"] as? [String: Any] {
            return stringValue(item["type"]) ?? stringValue(item["itemType"]) ?? stringValue(item["item_type"]) ?? ""
        }
        return ""
    }

    private static func shouldSuppressCodexItemType(_ itemType: String) -> Bool {
        let normalized = itemType
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return normalized.contains("usermessage")
            || normalized == "userinput"
            || normalized == "stderr"
            || normalized.contains("reasoning")
            || normalized.contains("plan")
    }

    private static func kindForCodexItem(_ object: [String: Any], completed: Bool) -> ChatMessageKind {
        let haystack = [
            stringValue(object["type"]),
            stringValue(object["name"]),
            stringValue((object["item"] as? [String: Any])?["type"]),
            stringValue((object["item"] as? [String: Any])?["name"])
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        let normalizedHaystack = haystack.replacingOccurrences(of: "_", with: "")
        if normalizedHaystack.contains("agentmessage") || normalizedHaystack.contains("assistantmessage") {
            return .assistant
        }
        if haystack.contains("diff") || haystack.contains("patch") || haystack.contains("filechange") || haystack.contains("file_change") {
            return .diff
        }
        if haystack.contains("command") || haystack.contains("exec") || haystack.contains("shell") {
            return completed ? .commandOutput : .command
        }
        return completed ? .toolResult : .toolCall
    }

    private static func deltaText(from object: [String: Any]) -> String {
        stringValue(object["delta"])
            ?? stringValue(object["text"])
            ?? stringValue(object["content"])
            ?? compactText(from: object)
    }

    private static func diffText(from object: [String: Any]) -> String? {
        if let value = stringValue(object["diff"]) ?? stringValue(object["patch"]) {
            return decodedDiffText(from: value) ?? value
        }
        if let item = object["item"] as? [String: Any] {
            return diffText(from: item)
        }
        if let value = stringValue(object["delta"])
            ?? stringValue(object["text"])
            ?? stringValue(object["content"]) {
            return decodedDiffText(from: value) ?? value
        }
        return nil
    }

    private static func decodedDiffText(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let diff = stringValue(object["diff"]) ?? stringValue(object["patch"]) {
            return diff
        }
        if let item = object["item"] as? [String: Any] {
            return diffText(from: item)
        }
        return nil
    }

    private static func compactText(from object: [String: Any]) -> String {
        if let text = stringValue(object["text"]) ?? stringValue(object["message"]) ?? stringValue(object["delta"]) {
            return text
        }
        if let item = object["item"] as? [String: Any],
           let text = stringValue(item["text"]) ?? stringValue(item["message"]) ?? stringValue(item["delta"]) ?? stringValue(item["content"]) {
            return text
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private static func codexErrorText(from error: Any) -> String {
        if let text = stringValue(error)?.nonEmptyTrimmed {
            return friendlyCodexErrorText(raw: text, info: nil)
        }
        guard let object = error as? [String: Any] else { return "Codex 运行失败。" }

        let message = stringValue(object["message"])
        let additionalDetails = stringValue(object["additionalDetails"])
        let errorInfo = stringValue(object["codexErrorInfo"])

        if let friendly = friendlyCodexErrorText(raw: [message, additionalDetails].compactMap { $0 }.joined(separator: "\n"), info: errorInfo).nonEmptyTrimmed {
            return friendly
        }

        let parts = [
            message,
            additionalDetails
        ]
        .compactMap { $0?.nonEmptyTrimmed }

        if !parts.isEmpty {
            return parts.reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }.joined(separator: "\n")
        }
        return compactText(from: object)
    }

    private static func friendlyCodexErrorText(raw: String, info: String?) -> String {
        let lowercased = ([raw, info].compactMap { $0 }.joined(separator: "\n")).lowercased()

        if lowercased.contains("unauthorized")
            || lowercased.contains("access token could not be refreshed")
            || lowercased.contains("please sign in again") {
            return """
            Codex 中转站认证失败。

            Codex 无法通过当前 ~/.codex/auth.json 里的 OPENAI_API_KEY 访问配置的模型服务。

            处理方式：
            1. 到设置页检查 Codex 的 base_url、OPENAI_API_KEY、model 和 wire_api。
            2. 保存配置后新开一个 Codex 会话再试。
            """
        }

        if lowercased.contains("nodename nor servname provided")
            || lowercased.contains("failed to lookup address information")
            || lowercased.contains("timeout waiting for child process") {
            return """
            Codex 网络连接失败。

            这通常是代理没有生效、代理不可达，或当前中转站地址无法解析。请确认设置页的 HTTP_PROXY / HTTPS_PROXY 和 Codex base_url 已保存，并新开 Codex 会话重试。
            """
        }

        return raw
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
