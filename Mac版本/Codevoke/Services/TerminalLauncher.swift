import AppKit
import Foundation

enum TerminalLauncherError: LocalizedError {
    case applicationNotFound(String)
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound(let appName): "未找到\(appName)应用。"
        case .appleScriptFailed(let message): "终端启动失败：\(message)"
        }
    }
}

struct TerminalLauncher {
    private static let terminalBundleIdentifier = "com.apple.Terminal"
    private static let iTermBundleIdentifier = "com.googlecode.iterm2"

    static func launch(command: String, terminal: TerminalType) async throws {
        try await Task.detached(priority: .userInitiated) {
            try launchSynchronously(command: command, terminal: terminal)
        }.value
    }

    private static func launchSynchronously(command: String, terminal: TerminalType) throws {
        switch terminal {
        case .terminal:
            try launchTerminal(command: command)
        case .iTerm2:
            try launchITerm(command: command)
        }
    }

    private static func launchTerminal(command: String) throws {
        try openApplication(bundleIdentifier: terminalBundleIdentifier, appName: "Terminal")
        try runAppleScript("""
        tell application id "\(terminalBundleIdentifier)"
            activate
            do script "\(appleScriptString(command))"
        end tell
        """, appName: "Terminal")
    }

    private static func launchITerm(command: String) throws {
        try openApplication(bundleIdentifier: iTermBundleIdentifier, appName: "iTerm2")
        try runAppleScript("""
        set commandOpened to false
        set lastErrorMessage to "iTerm2 启动后仍未就绪。"
        repeat 60 times
            try
                tell application id "\(iTermBundleIdentifier)"
                    activate
                    create window with default profile
                    tell current session of current window
                        write text "\(appleScriptString(command))"
                    end tell
                end tell
                set commandOpened to true
                exit repeat
            on error errorMessage number errorNumber
                if errorNumber is -1743 then error errorMessage number errorNumber
                set lastErrorMessage to errorMessage
                delay 0.1
            end try
        end repeat

        if commandOpened is false then error "iTerm2 已启动，但无法新建窗口执行命令：" & lastErrorMessage
        """, appName: "iTerm2")
    }

    private static func openApplication(bundleIdentifier: String, appName: String) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw TerminalLauncherError.applicationNotFound(appName)
        }
        guard NSWorkspace.shared.open(appURL) else {
            throw TerminalLauncherError.appleScriptFailed("无法打开\(appName)应用。")
        }

        for _ in 0..<100 {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }), app.isFinishedLaunching {
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TerminalLauncherError.appleScriptFailed("\(appName)启动超时，请手动打开后重试。")
    }

    private static func runAppleScript(_ source: String, appName: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalLauncherError.appleScriptFailed("AppleScript 无法创建。")
        }
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            let number = error[NSAppleScript.errorNumber] as? Int
            throw TerminalLauncherError.appleScriptFailed(friendlyAppleScriptMessage(message, number: number, appName: appName))
        }
    }

    private static func friendlyAppleScriptMessage(_ message: String, number: Int?, appName: String) -> String {
        if number == -1743 || message.localizedCaseInsensitiveContains("not authorized") || message.localizedCaseInsensitiveContains("not permitted") {
            return "请在系统设置 > 隐私与安全性 > 自动化中允许 acode 控制 \(appName)。"
        }
        return message
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
