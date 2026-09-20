import Darwin
import Foundation

protocol ChatProcessBackend: AnyObject {
    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?, attachments: [ChatMessageAttachment]) -> AsyncThrowingStream<ChatBackendEvent, Error>
    func interrupt()
    /// Synchronously kill the CLI process (and its group/descendants) right now. Used on app
    /// termination / conversation close, where `interrupt()`'s async signal ladder would never
    /// fire before the app exits, leaving backgrounded children (e.g. xcodebuild) orphaned.
    func terminateImmediately()
    func respondToPermission(requestID: String, decision: ChatPermissionDecision) -> Bool
    func respondToInteractiveRequest(requestID: String, response: ChatInteractiveResponse) -> Bool
    func sendCompact() -> Bool
}

struct ChatBackendEventCoalescer {
    private struct DeltaKey: Hashable {
        let kind: ChatMessageKind
        let title: String
        let subtitle: String
        let status: String
        let requestID: String?
    }

    private struct PendingDelta {
        var key: DeltaKey
        var text: String
    }

    private var pendingDeltas: [DeltaKey: PendingDelta] = [:]
    private var deltaOrder: [DeltaKey] = []
    private var pendingDeltaCount = 0
    private var pendingUTF8Bytes = 0
    private var lastFlushAt = Date()

    private let flushInterval: TimeInterval
    private let maxPendingDeltas: Int
    private let maxPendingUTF8Bytes: Int

    init(flushInterval: TimeInterval = 0.09, maxPendingDeltas: Int = 48, maxPendingUTF8Bytes: Int = 8 * 1024) {
        self.flushInterval = flushInterval
        self.maxPendingDeltas = maxPendingDeltas
        self.maxPendingUTF8Bytes = maxPendingUTF8Bytes
    }

    mutating func push(_ events: [ChatBackendEvent]) -> [ChatBackendEvent] {
        var output: [ChatBackendEvent] = []
        for event in events {
            switch event {
            case .appendDelta(let kind, let title, let subtitle, let text, let status, let requestID):
                guard !text.isEmpty else { continue }
                let key = DeltaKey(kind: kind, title: title, subtitle: subtitle, status: status, requestID: requestID)
                if pendingDeltas[key] == nil {
                    deltaOrder.append(key)
                    pendingDeltas[key] = PendingDelta(key: key, text: "")
                }
                pendingDeltas[key]?.text += text
                pendingDeltaCount += 1
                pendingUTF8Bytes += text.utf8.count
                if shouldFlush {
                    output.append(contentsOf: flush())
                }
            default:
                output.append(contentsOf: flush())
                output.append(event)
            }
        }
        return output
    }

    mutating func flush() -> [ChatBackendEvent] {
        guard !deltaOrder.isEmpty else { return [] }
        let orderedDeltas = deltaOrder.compactMap { pendingDeltas[$0] }
        pendingDeltas.removeAll(keepingCapacity: true)
        deltaOrder.removeAll(keepingCapacity: true)
        pendingDeltaCount = 0
        pendingUTF8Bytes = 0
        lastFlushAt = Date()
        return orderedDeltas.map { pending in
            .appendDelta(
                kind: pending.key.kind,
                title: pending.key.title,
                subtitle: pending.key.subtitle,
                text: pending.text,
                status: pending.key.status,
                requestID: pending.key.requestID
            )
        }
    }

    private var shouldFlush: Bool {
        pendingDeltaCount >= maxPendingDeltas
            || pendingUTF8Bytes >= maxPendingUTF8Bytes
            || Date().timeIntervalSince(lastFlushAt) >= flushInterval
    }
}

extension ChatProcessBackend {
    func respondToInteractiveRequest(requestID: String, response: ChatInteractiveResponse) -> Bool { false }

    /// Backward-compat shim: callers that haven't been migrated to the
    /// attachment-aware overload still compile. New code should always pass
    /// `attachments` (even if empty) so the audit P0-1 fix isn't bypassed.
    func start(prompt: String, options: ChatRunOptions, session: ChatSessionRecord?) -> AsyncThrowingStream<ChatBackendEvent, Error> {
        start(prompt: prompt, options: options, session: session, attachments: [])
    }
}

struct ChatProcessOutput: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ChatProcessError: LocalizedError {
    case executableMissing(String)
    case launchFailed(String)
    case unsupported(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let executable): "未找到可执行文件：\(executable)"
        case .launchFailed(let message): "启动 CLI 失败：\(message)"
        case .unsupported(let message): message
        case .processFailed(let message): message
        }
    }
}

enum ChatPipeWriter {
    /// Hard upper bound on a single stdin write. Anthropic / Codex stdin pipes
    /// are typically 64 KB; a healthy backend drains within milliseconds. If we
    /// block longer than this the backend is wedged (CPU pinned, deadlocked,
    /// or stdin not being read). We bail with `false` so the caller can surface
    /// `.failed` rather than hanging the Swift async task forever (audit P1-4).
    static let writeTimeout: DispatchTimeInterval = .seconds(2)

    @discardableResult
    static func writeJSONObject(_ object: [String: Any], to pipe: Pipe?) -> Bool {
        guard let pipe,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(Data("\n".utf8))
        return writeWithTimeout(data, to: pipe.fileHandleForWriting, timeout: writeTimeout)
    }

    private static func writeWithTimeout(_ data: Data, to handle: FileHandle, timeout: DispatchTimeInterval) -> Bool {
        // `FileHandle.write(contentsOf:)` is a blocking syscall — if the child
        // process is wedged we'd block forever and Swift `Task.cancel()` can't
        // unstick a thread inside `write(2)`. Wrap in a detached dispatch and
        // semaphore so the caller can give up after `timeout` and let the
        // chat-side error path run. The leaked worker thread will eventually
        // either complete (and signal a no-op) or unblock when the FD closes.
        let semaphore = DispatchSemaphore(value: 0)
        // Capture by-value into a class so we can mutate from the worker thread
        // without `inout` parameter capture issues across the closure boundary.
        final class Outcome {
            var success = false
        }
        let outcome = Outcome()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handle.write(contentsOf: data)
                outcome.success = true
            } catch {
                outcome.success = false
            }
            semaphore.signal()
        }
        switch semaphore.wait(timeout: .now() + timeout) {
        case .success:
            return outcome.success
        case .timedOut:
            // Worker thread is still stuck inside write(2). We can't yank it,
            // but at least signal the caller to abort the run.
            return false
        }
    }
}

enum ChatProcessLauncher {
    static func isolateProcessGroup(_ process: Process) {
        let selector = Selector(("setStartsNewProcessGroup:"))
        guard process.responds(to: selector) else { return }
        process.setValue(true, forKey: "startsNewProcessGroup")
    }
}

enum ChatProcessTerminator {
    /// Synchronous best-effort SIGKILL of the process, its group, and all descendants — right
    /// now, no async delay. For app-termination / close where the async `stop` ladder below
    /// would never fire before the app exits.
    static func killNow(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        signal(SIGKILL, process: process, pid: pid, knownDescendants: descendantPIDs(of: pid))
    }

    static func stop(_ process: Process, terminateAfter: DispatchTimeInterval, killAfter: DispatchTimeInterval) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let initialDescendants = descendantPIDs(of: pid)
        signal(SIGINT, process: process, pid: pid, knownDescendants: initialDescendants)
        DispatchQueue.global().asyncAfter(deadline: .now() + terminateAfter) { [weak process] in
            guard let process else { return }
            signal(SIGTERM, process: process, pid: pid, knownDescendants: initialDescendants)
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) { [weak process] in
            guard let process else { return }
            signal(SIGKILL, process: process, pid: pid, knownDescendants: initialDescendants)
        }
    }

    private static func signal(_ signal: Int32, process: Process, pid: pid_t, knownDescendants: [pid_t]) {
        let descendants = Array(Set(knownDescendants + descendantPIDs(of: pid))).sorted()
        for childPID in descendants.reversed() {
            kill(-childPID, signal)
            kill(childPID, signal)
        }
        guard process.isRunning else { return }
        kill(-pid, signal)
        kill(pid, signal)
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }
        let count = length / MemoryLayout<kinfo_proc>.stride
        var processes = Array(repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &processes, &length, nil, 0) == 0 else {
            return []
        }
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for processInfo in processes {
            let pid = processInfo.kp_proc.p_pid
            let parentPID = processInfo.kp_eproc.e_ppid
            guard pid > 0, parentPID > 0 else { continue }
            childrenByParent[parentPID, default: []].append(pid)
        }
        var result: [pid_t] = []
        var stack = childrenByParent[rootPID] ?? []
        while let pid = stack.popLast() {
            result.append(pid)
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }
}

final class ChatProcessActivityWatchdog {
    static let defaultIdleTimeout: TimeInterval = 90
    static let defaultHardTimeout: TimeInterval = 6 * 60 * 60

    private let process: Process
    private let idleTimeout: TimeInterval
    private let hardTimeout: TimeInterval
    private let terminateAfter: DispatchTimeInterval
    private let killAfter: DispatchTimeInterval
    private let checkIntervalNanoseconds: UInt64 = 5_000_000_000
    private let lock = NSLock()
    private let startedAt = Date()
    private var lastActivityAt = Date()
    private var isCancelled = false
    private var isPaused = false
    private var didTimeout = false
    private var task: Task<Void, Never>?

    init(
        process: Process,
        idleTimeout: TimeInterval = ChatProcessActivityWatchdog.defaultIdleTimeout,
        hardTimeout: TimeInterval = ChatProcessActivityWatchdog.defaultHardTimeout,
        terminateAfter: DispatchTimeInterval,
        killAfter: DispatchTimeInterval
    ) {
        self.process = process
        self.idleTimeout = idleTimeout
        self.hardTimeout = hardTimeout
        self.terminateAfter = terminateAfter
        self.killAfter = killAfter
    }

    func start() {
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    func markActivity() {
        lock.lock()
        if !isCancelled, !didTimeout {
            lastActivityAt = Date()
        }
        lock.unlock()
    }

    func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        if !isCancelled, !didTimeout {
            isPaused = false
            lastActivityAt = Date()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        task?.cancel()
        task = nil
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeout
    }

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: checkIntervalNanoseconds)
            if Task.isCancelled { return }
            guard shouldStopProcess() else { continue }
            ChatProcessTerminator.stop(process, terminateAfter: terminateAfter, killAfter: killAfter)
            return
        }
    }

    private func shouldStopProcess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !didTimeout, process.isRunning else { return false }
        let now = Date()
        // The hard cap always applies as a zombie backstop, even while paused.
        if now.timeIntervalSince(startedAt) >= hardTimeout {
            didTimeout = true
            return true
        }
        // The idle cap is suspended while paused (e.g. waiting on a user permission /
        // selection answer), so a slow human can't be mistaken for a dead process.
        if !isPaused, now.timeIntervalSince(lastActivityAt) >= idleTimeout {
            didTimeout = true
            return true
        }
        return false
    }
}

enum ChatCLIEnvironment {
    static var realHomeDirectory: String {
        if let passwd = getpwuid(getuid()),
           let directory = passwd.pointee.pw_dir {
            return String(cString: directory)
        }
        return ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    static var defaultPath: String {
        defaultPathComponents.joined(separator: ":")
    }

    static var defaultPathComponents: [String] {
        let home = realHomeDirectory
        return [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    static func executableCandidatePaths(named name: String) -> [String] {
        defaultPathComponents
            .map { "\($0)/\(name)" }
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
    }

    static var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        sanitizeInheritedAgentEnvironment(&environment)
        mergePersistedClaudeEnvironment(into: &environment)
        // App-owned relay config is the source of truth: overlay it LAST so it wins over both the
        // inherited shell env and a ~/.claude/settings.json that a third-party switcher may have
        // overwritten. Anthropic precedence puts process env above the settings.json env block,
        // so this makes our configured base URL / key / model authoritative and un-preemptable.
        mergeActiveClaudeProfileEnvironment(into: &environment)
        normalizeProxyValues(&environment)
        mirrorProxyValues(&environment)
        environment["HOME"] = realHomeDirectory
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        environment["PATH"] = mergePath(existingPath)
        return environment
    }

    private static func mergeActiveClaudeProfileEnvironment(into environment: inout [String: String]) {
        let profiles = ProjectStore.loadConfigProfiles()
        guard let id = profiles.activeClaudeRelayProfileID,
              let profile = profiles.claudeRelayProfiles.first(where: { $0.id == id }) else {
            return
        }
        let mapped: [(String, String)] = [
            ("ANTHROPIC_BASE_URL", profile.baseURL),
            ("ANTHROPIC_API_KEY", profile.authToken),
            ("ANTHROPIC_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", profile.haikuModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", profile.sonnetModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", profile.opusModel),
            ("HTTP_PROXY", profile.httpProxy),
            ("HTTPS_PROXY", profile.httpsProxy),
        ]
        for (key, value) in mapped {
            guard let trimmed = value.nonEmptyTrimmed else { continue }
            environment[key] = trimmed
        }
        // The relay key is delivered via ANTHROPIC_API_KEY; clear the legacy token so a stale
        // ANTHROPIC_AUTH_TOKEN from the shell/settings.json can't shadow the active profile.
        if environment["ANTHROPIC_API_KEY"]?.nonEmptyTrimmed != nil {
            environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        }
    }

    private static func sanitizeInheritedAgentEnvironment(_ environment: inout [String: String]) {
        let runtimeKeys = [
            "CODEX_CI",
            "CODEX_SANDBOX",
            "CODEX_THREAD_ID",
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
            "CODEX_SHELL",
            "__CFBundleIdentifier"
        ]
        runtimeKeys.forEach { environment.removeValue(forKey: $0) }
        normalizeProxyValues(&environment)
    }

    private static let proxyURLKeys = [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy"
    ]

    private static let proxyBypassKeys = [
        "NO_PROXY",
        "no_proxy"
    ]

    private static var proxyKeys: [String] {
        proxyURLKeys + proxyBypassKeys
    }

    private static func mergePersistedClaudeEnvironment(into environment: inout [String: String]) {
        for (key, value) in persistedClaudeEnvironment() {
            environment[key] = value
        }
    }

    private static func persistedClaudeEnvironment() -> [String: String] {
        let settingsURL = URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else {
            return [:]
        }

        return resolvedPersistedClaudeEnvironment(from: env)
    }

    static func resolvedPersistedClaudeEnvironment(from env: [String: Any]) -> [String: String] {
        var values = env.reduce(into: [String: String]()) { result, item in
            guard isSupportedPersistedEnvironmentKey(item.key),
                  let value = item.value as? String,
                  let trimmed = value.nonEmptyTrimmed else { return }
            result[item.key] = trimmed
        }
        if values["ANTHROPIC_API_KEY"]?.nonEmptyTrimmed == nil,
           let legacyToken = values["ANTHROPIC_AUTH_TOKEN"]?.nonEmptyTrimmed {
            values["ANTHROPIC_API_KEY"] = legacyToken
        }
        values.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        return values
    }

    private static func isSupportedPersistedEnvironmentKey(_ key: String) -> Bool {
        proxyKeys.contains(key)
            || key.hasPrefix("ANTHROPIC_")
            || key.hasPrefix("CLAUDE_CODE_")
    }

    private static func normalizeProxyValues(_ environment: inout [String: String]) {
        for key in proxyURLKeys {
            guard let rawValue = environment[key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || proxyURLHasMissingHost(value) {
                environment.removeValue(forKey: key)
                continue
            }
            environment[key] = value.replacingOccurrences(of: "127.0.01", with: "127.0.0.1")
        }

        for key in proxyBypassKeys {
            guard let rawValue = environment[key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                environment.removeValue(forKey: key)
            } else {
                environment[key] = value
            }
        }
    }

    private static func mirrorProxyValues(_ environment: inout [String: String]) {
        mirrorProxyValue(upper: "HTTP_PROXY", lower: "http_proxy", environment: &environment)
        mirrorProxyValue(upper: "HTTPS_PROXY", lower: "https_proxy", environment: &environment)
        mirrorProxyValue(upper: "ALL_PROXY", lower: "all_proxy", environment: &environment)
        mirrorProxyValue(upper: "NO_PROXY", lower: "no_proxy", environment: &environment)
    }

    private static func mirrorProxyValue(upper: String, lower: String, environment: inout [String: String]) {
        if let upperValue = environment[upper], environment[lower] == nil {
            environment[lower] = upperValue
        } else if let lowerValue = environment[lower], environment[upper] == nil {
            environment[upper] = lowerValue
        }
    }

    private static func proxyURLHasMissingHost(_ value: String) -> Bool {
        guard value.contains("://") else { return false }
        guard let components = URLComponents(string: value) else { return true }
        return components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    static func mergePath(_ path: String) -> String {
        let current = path.split(separator: ":").map(String.init)
        let defaults = defaultPath.split(separator: ":").map(String.init)
        return (defaults + current).reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }.joined(separator: ":")
    }
}

enum ChatProcessRunner {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 8) async -> ChatProcessOutput {
        await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ChatCLIEnvironment.processEnvironment
            process.standardOutput = stdout
            process.standardError = stderr
            ChatProcessLauncher.isolateProcessGroup(process)

            do {
                try process.run()
            } catch {
                return ChatProcessOutput(status: 127, stdout: "", stderr: error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 150_000_000)
                if process.isRunning { process.interrupt() }
            }

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            return ChatProcessOutput(
                status: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
