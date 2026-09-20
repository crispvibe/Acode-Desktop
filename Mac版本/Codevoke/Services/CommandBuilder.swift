import Foundation

struct CommandBuilder {
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(projectPath: String, cli: CLIType, mode: SessionMode, sessionId: String?) -> String {
        let cdCommand = "cd \(shellQuote(projectPath))"
        let selectedCLI = cli.visibleValue
        let cliCommand: String

        switch (selectedCLI, mode) {
        case (.claude, .newSession):
            cliCommand = "claude"
        case (.claude, .continueLast):
            cliCommand = "claude --continue"
        case (.claude, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "claude --resume \(shellQuote(sessionId))"
            } else {
                cliCommand = "claude --resume"
            }
        case (.codex, .newSession):
            cliCommand = "codex"
        case (.codex, .continueLast):
            cliCommand = "codex resume --last"
        case (.codex, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "codex resume \(shellQuote(sessionId))"
            } else {
                cliCommand = "codex resume"
            }
        case (.cursor, .continueLast):
            cliCommand = "cursor-agent --continue"
        case (.cursor, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "cursor-agent --resume \(shellQuote(sessionId))"
            } else {
                cliCommand = "cursor-agent --resume"
            }
        case (.gemini, .continueLast), (.qwen, .continueLast):
            cliCommand = "\(selectedCLI.executable) --resume latest"
        case (.gemini, .resume), (.qwen, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "\(selectedCLI.executable) --resume \(shellQuote(sessionId))"
            } else {
                cliCommand = "\(selectedCLI.executable) --resume latest"
            }
        case (.copilot, .continueLast):
            cliCommand = "copilot --continue"
        case (.copilot, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "copilot --resume=\(shellQuote(sessionId))"
            } else {
                cliCommand = "copilot --resume"
            }
        case (.kimi, .continueLast):
            cliCommand = "kimi --continue"
        case (.kimi, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "kimi -r \(shellQuote(sessionId))"
            } else {
                cliCommand = "kimi -r"
            }
        case (.kiro, .newSession):
            cliCommand = "kiro-cli chat"
        case (.kiro, .continueLast):
            cliCommand = "kiro-cli chat --resume"
        case (.kiro, .resume):
            if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliCommand = "kiro-cli chat --resume-id \(shellQuote(sessionId))"
            } else {
                cliCommand = "kiro-cli chat --resume"
            }
        case (.dsh, .newSession), (.dsh, .continueLast), (.dsh, .resume):
            // dsh 没有裸 TUI 子命令（不带 --profile 会直接报错退出）；
            // `dsh web` 启动交互 Web 工作台，会话恢复在 Web 界面内完成。
            cliCommand = "dsh web"
        case (_, .newSession), (_, .continueLast), (_, .resume):
            cliCommand = selectedCLI.executable
        }

        return "\(cdCommand) && \(cliCommand)"
    }
}
