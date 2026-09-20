import Foundation

struct ChatCLICapability: Codable, Equatable, Sendable {
    let cli: CLIType
    let executablePath: String?
    let version: String?
    let supportsStreamJSON: Bool
    let supportsStreamJSONInput: Bool
    let supportsPermissionPromptTool: Bool
    let supportsResume: Bool
    let supportsContinue: Bool
    let supportsAppServer: Bool
    let errorMessage: String?

    var isAvailable: Bool { executablePath != nil && errorMessage == nil }
}

private actor ChatCLICapabilityCache {
    static let shared = ChatCLICapabilityCache()

    private var cachedSignature: String?
    private var cachedCapabilities: [CLIType: ChatCLICapability]?
    private var inFlightID: UUID?
    private var inFlightSignature: String?
    private var inFlight: Task<[CLIType: ChatCLICapability], Never>?

    func capabilities(
        force: Bool,
        signature: String,
        loader: @escaping @Sendable () async -> [CLIType: ChatCLICapability]
    ) async -> [CLIType: ChatCLICapability] {
        if !force, cachedSignature == signature, let cachedCapabilities {
            return cachedCapabilities
        }
        if !force, inFlightSignature == signature, let inFlight {
            return await inFlight.value
        }

        let taskID = UUID()
        let task = Task { await loader() }
        inFlightID = taskID
        inFlightSignature = signature
        inFlight = task
        let result = await task.value
        if inFlightID == taskID {
            cachedSignature = signature
            cachedCapabilities = result
            inFlightID = nil
            inFlightSignature = nil
            inFlight = nil
        }
        return result
    }
}

enum ChatCLICapabilityProbe {
    static func probeAll(force: Bool = false) async -> [CLIType: ChatCLICapability] {
        let signature = cacheSignature()
        return await ChatCLICapabilityCache.shared.capabilities(force: force, signature: signature) {
            await performProbeAll()
        }
    }

    private static func performProbeAll() async -> [CLIType: ChatCLICapability] {
        async let claude = probe(.claude)
        async let codex = probe(.codex)
        return await [
            .claude: claude,
            .codex: codex
        ]
    }

    static func probe(_ cli: CLIType) async -> ChatCLICapability {
        let visible = cli.visibleValue
        guard let executable = await locateExecutable(named: visible.executable) else {
            return ChatCLICapability(
                cli: visible,
                executablePath: nil,
                version: nil,
                supportsStreamJSON: false,
                supportsStreamJSONInput: false,
                supportsPermissionPromptTool: false,
                supportsResume: false,
                supportsContinue: false,
                supportsAppServer: false,
                errorMessage: "未找到 \(visible.executable)，请先安装或把它加入 PATH。"
            )
        }

        let versionOutput = await ChatProcessRunner.run(executable, arguments: ["--version"], timeout: 5)
        let helpOutput = await ChatProcessRunner.run(executable, arguments: ["--help"], timeout: 5)
        let help = helpOutput.stdout + "\n" + helpOutput.stderr
        let version = (versionOutput.stdout.nonEmptyTrimmed ?? versionOutput.stderr.nonEmptyTrimmed)
        let launchError = launchErrorMessage(
            cli: visible,
            executable: executable,
            versionOutput: versionOutput,
            helpOutput: helpOutput
        )

        switch visible {
        case .claude:
            return ChatCLICapability(
                cli: visible,
                executablePath: executable,
                version: version,
                supportsStreamJSON: launchError == nil && help.contains("stream-json"),
                supportsStreamJSONInput: launchError == nil && help.contains("--input-format") && help.contains("stream-json"),
                supportsPermissionPromptTool: help.contains("permission-prompt-tool"),
                supportsResume: launchError == nil && help.contains("--resume"),
                supportsContinue: launchError == nil && help.contains("--continue"),
                supportsAppServer: false,
                errorMessage: launchError
            )
        case .codex:
            let appServerHelp = await ChatProcessRunner.run(executable, arguments: ["app-server", "--help"], timeout: 5)
            let appServerText = appServerHelp.stdout + "\n" + appServerHelp.stderr
            return ChatCLICapability(
                cli: visible,
                executablePath: executable,
                version: version,
                supportsStreamJSON: launchError == nil,
                supportsStreamJSONInput: false,
                supportsPermissionPromptTool: false,
                supportsResume: launchError == nil && help.contains("resume"),
                supportsContinue: launchError == nil && help.contains("resume"),
                supportsAppServer: launchError == nil && (appServerHelp.status == 0 || appServerText.contains("listen") || appServerText.contains("app-server")),
                errorMessage: launchError
            )
        case .gemini, .custom:
            return await probe(.claude)
        }
    }

    private static func cacheSignature() -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executables = CLIType.visibleCases
            .map { executableSignature(named: $0.executable) }
            .joined(separator: "|")
        return [ChatCLIEnvironment.defaultPath, path, executables].joined(separator: "\n")
    }

    private static func executableSignature(named name: String) -> String {
        let fileManager = FileManager.default
        return ChatCLIEnvironment.executableCandidatePaths(named: name)
            .map { candidate in
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                guard fileManager.fileExists(atPath: resolved) else { return "\(candidate)=missing" }
                let attributes = try? fileManager.attributesOfItem(atPath: resolved)
                let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = attributes?[.size] ?? 0
                return "\(candidate)=\(resolved):\(modifiedAt):\(size)"
            }
            .joined(separator: ";")
    }

    private static func locateExecutable(named name: String) async -> String? {
        for candidate in ChatCLIEnvironment.executableCandidatePaths(named: name) where FileManager.default.fileExists(atPath: candidate) {
            if let path = await usableExecutablePath(candidate) {
                return path
            }
        }

        let shellOutput = await ChatProcessRunner.run(
            "/bin/zsh",
            arguments: ["-lc", "PATH=\(ChatCLIEnvironment.defaultPath):$PATH; command -v -a \(name)"],
            timeout: 4
        )
        if shellOutput.status == 0, let output = shellOutput.stdout.nonEmptyTrimmed {
            for rawPath in output.components(separatedBy: .newlines) {
                if let path = rawPath.nonEmptyTrimmed,
                   let usablePath = await usableExecutablePath(path) {
                    return usablePath
                }
            }
        }

        let output = await ChatProcessRunner.run("/usr/bin/env", arguments: ["which", "-a", name], timeout: 4)
        guard output.status == 0, let path = output.stdout.nonEmptyTrimmed else { return nil }
        for rawPath in path.components(separatedBy: .newlines) {
            if let path = rawPath.nonEmptyTrimmed,
               let usablePath = await usableExecutablePath(path) {
                return usablePath
            }
        }
        return nil
    }

    private static func usableExecutablePath(_ path: String) async -> String? {
        let resolved = canonicalExecutablePath(path)
        guard FileManager.default.isExecutableFile(atPath: resolved) else { return nil }

        let output = await ChatProcessRunner.run(resolved, arguments: ["--version"], timeout: 4)
        return output.status == 0 ? resolved : nil
    }

    private static func canonicalExecutablePath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : path
    }

    private static func launchErrorMessage(
        cli: CLIType,
        executable: String,
        versionOutput: ChatProcessOutput,
        helpOutput: ChatProcessOutput
    ) -> String? {
        guard versionOutput.status == 127 || helpOutput.status == 127 else { return nil }
        let message = versionOutput.stderr.nonEmptyTrimmed
            ?? helpOutput.stderr.nonEmptyTrimmed
            ?? "未知启动错误"
        return "已找到 \(cli.displayName)：\(executable)，但无法启动：\(message)"
    }
}
