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
        case (_, .newSession), (_, .continueLast), (_, .resume):
            cliCommand = selectedCLI.executable
        }

        return "\(cdCommand) && \(cliCommand)"
    }
}
