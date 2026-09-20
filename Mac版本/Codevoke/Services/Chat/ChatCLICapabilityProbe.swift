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

    /// 该 CLI 是否有运行中权限应答通道：Codex 走 app-server 审批回写，
    /// DeepSeek Harness 走 ACP `session/request_permission`。其余无头 CLI 的
    /// ask 模式会卡死在永远等不到回应的权限提示上，前端用它做前置拒绝。
    var supportsRuntimePermissionApprovals: Bool {
        switch cli.visibleValue {
        case .codex, .dsh: supportsAppServer
        default: false
        }
    }
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
        await withTaskGroup(of: (CLIType, ChatCLICapability).self) { group in
            for cli in CLIType.visibleCases {
                group.addTask {
                    (cli, await probe(cli))
                }
            }
            var result: [CLIType: ChatCLICapability] = [:]
            for await (cli, capability) in group {
                result[cli] = capability
            }
            return result
        }
    }

    static func probe(_ cli: CLIType) async -> ChatCLICapability {
        let visible = cli.visibleValue
        var executable = await locateExecutable(candidates: visible.executableCandidates)
        if executable == nil, visible == .dsh {
            // dsh 未直装时用 `npx -y @deepseek-ai/dsh` 兜底：executablePath 指向 npx，
            // 后端/探测统一经 DshCommandLine 识别 basename 并补包名前缀。
            executable = await locateExecutable(candidates: ["npx"])
        }
        guard let executable else {
            let hint = visible == .dsh
                ? "未找到 dsh，也未找到可用于 `npx -y @deepseek-ai/dsh` 兜底的 npx，请先安装 @deepseek-ai/dsh 或把它加入 PATH。"
                : "未找到 \(visible.executableCandidates.joined(separator: " 或 "))，请先安装或把它加入 PATH。"
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
                errorMessage: hint
            )
        }

        let versionOutput = await ChatProcessRunner.run(executable, arguments: ["--version"], timeout: 5)
        var helpOutput = await ChatProcessRunner.run(executable, arguments: ["--help"], timeout: 5)
        // kiro-cli 的 print/headless 参数在 `chat` 子命令上，顶层 --help 只列出子命令。
        if visible == .kiro {
            let chatHelp = await ChatProcessRunner.run(executable, arguments: ["chat", "--help"], timeout: 5)
            helpOutput = ChatProcessOutput(
                status: helpOutput.status == 0 ? chatHelp.status : helpOutput.status,
                stdout: helpOutput.stdout + "\n" + chatHelp.stdout,
                stderr: helpOutput.stderr + "\n" + chatHelp.stderr
            )
        }
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
        case .cursor, .gemini, .qwen, .copilot, .kimi, .agy, .kiro:
            // 第三方 CLI 都是一次性无头调用（无 stdin 协议、无内嵌权限通道），
            // 能力只探测可执行文件存在性与 help 中声明的 stream-json / resume / continue。
            return ChatCLICapability(
                cli: visible,
                executablePath: executable,
                version: version,
                supportsStreamJSON: launchError == nil && (help.contains("stream-json") || (help.contains("--output-format") && help.contains("json"))),
                supportsStreamJSONInput: false,
                supportsPermissionPromptTool: false,
                supportsResume: launchError == nil && (help.contains("--resume") || help.contains("--session") || help.contains("--resume-id")),
                supportsContinue: launchError == nil && (help.contains("--continue") || help.contains("--resume")),
                supportsAppServer: false,
                errorMessage: launchError
            )
        case .dsh:
            // ACP stdio（dsh --profile acp）是内嵌集成路径：除可执行文件存在性外，
            // 还要确认 acp profile 可用。npx 兜底时 executablePath 指向 npx，
            // 参数统一经 DshCommandLine 补 `-y @deepseek-ai/dsh` 前缀；version
            // 也重测一次拿到 dsh 自身版本而不是 npm 版本（首次触发 npx 下载，
            // 给更长超时）。
            let acpHelp = await ChatProcessRunner.run(
                executable,
                arguments: DshCommandLine.arguments(executablePath: executable, trailing: ["--profile", "acp", "--help"]),
                timeout: 20
            )
            let acpText = acpHelp.stdout + "\n" + acpHelp.stderr
            let acpAvailable = acpHelp.status == 0 && acpText.contains("Agent Client Protocol")
            var probedVersion = version
            if DshCommandLine.isNpxLauncher(executablePath: executable) {
                let dshVersion = await ChatProcessRunner.run(
                    executable,
                    arguments: DshCommandLine.arguments(executablePath: executable, trailing: ["--version"]),
                    timeout: 20
                )
                probedVersion = dshVersion.stdout.nonEmptyTrimmed
                    ?? dshVersion.stderr.nonEmptyTrimmed
                    ?? version
            }
            let acpError = launchError ?? (acpAvailable ? nil : "已找到 \(visible.displayName)：\(executable)，但不支持 ACP 模式（dsh --profile acp），请升级 @deepseek-ai/dsh。")
            return ChatCLICapability(
                cli: visible,
                executablePath: executable,
                version: probedVersion,
                supportsStreamJSON: acpAvailable,
                supportsStreamJSONInput: false,
                supportsPermissionPromptTool: false,
                supportsResume: acpAvailable,
                supportsContinue: acpAvailable,
                supportsAppServer: acpAvailable,
                errorMessage: acpError
            )
        case .custom:
            return await probe(.claude)
        }
    }

    private static func cacheSignature() -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executables = CLIType.visibleCases
            .flatMap(\.executableCandidates)
            .map { executableSignature(named: $0) }
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

    private static func locateExecutable(candidates names: [String]) async -> String? {
        for name in names {
            if let path = await locateExecutable(named: name) {
                return path
            }
        }
        return nil
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
