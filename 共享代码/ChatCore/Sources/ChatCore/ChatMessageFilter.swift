import Foundation

public enum ChatMessageFilter {
    public static func shouldHideMessage(kind: ChatMessageKind, title: String, subtitle: String, text: String) -> Bool {
        let cleanedText = cleanedAgentToolInventoryText(text)
        let normalizedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return shouldHideAgentToolInventoryText(text)
            || isProtocolBlob(normalizedText)
            || shouldHideOperationalMessage(kind: kind, title: title, subtitle: subtitle, text: cleanedText)
    }

    public static func shouldHideOperationalMessage(kind: ChatMessageKind, title: String, subtitle: String, text: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noiseSuffixes = ["/updated", "/changed"]
        let noisePrefixes = [
            "mcpserver/",
            "account/ratelimits",
            "thread/status",
            "thread/tokenusage",
            "remotecontrol/",
            "session/configured",
            "session/connected"
        ]

        if kind == .rawOutput || kind == .toolCall || kind == .toolResult || kind == .diff {
            if noisePrefixes.contains(where: { normalizedTitle.hasPrefix($0) }) { return true }
            if noiseSuffixes.contains(where: { normalizedTitle.hasSuffix($0) }) && normalizedTitle.contains("/") { return true }
            let compactTitle = normalizedTitle
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            if compactTitle == "userinput" || compactTitle == "stderr" || compactTitle.contains("usermessage") || compactTitle.contains("reasoning") { return true }
            if normalizedText == "stderr" || normalizedText.contains("\"type\":\"stderr\"") || normalizedText.contains("\"type\": \"stderr\"") { return true }
            let compactText = normalizedText
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            if compactText.contains("\"type\":\"usermessage\"") || compactText.contains("\"type\":\"reasoning\"") { return true }
            if normalizedTitle == "changes.diff", compactText.contains("\"diff\":\"diffgit") { return true }
        }

        if kind == .system,
           normalizedTitle == "model",
           normalizedText.contains("模型与当前 cli 不匹配") {
            return true
        }

        return false
    }

    public static func cleanedAgentToolInventoryText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldHideAgentToolInventoryText(trimmed) else { return text }
        return ""
    }

    public static func shouldHideAgentToolInventoryText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return looksLikeClaudeToolInventory(trimmed)
    }

    public static func extractMacToolNames(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeClaudeToolInventory(trimmed) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for line in trimmed.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("- ") else { continue }
            let item = value.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if item.lowercased().hasSuffix(": connected"), let separator = item.lastIndex(of: ":") {
                name = String(item[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = item
            }
            guard isLikelyToolName(name), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    public static func looksLikeClaudeToolInventory(_ text: String) -> Bool {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let firstContentLine = lines.first(where: { !$0.isEmpty }) else { return false }
        let explicitHeader = isToolInventoryHeader(firstContentLine)
        if explicitHeader {
            return lines.contains { $0.hasPrefix("- ") }
        }
        let hasModel = lines.contains { $0.hasPrefix("model:") }
        let hasPermission = lines.contains { $0.hasPrefix("permission:") }
        let hasToolsHeader = lines.contains { $0 == "tools:" }
        return hasModel && hasPermission && hasToolsHeader
    }

    private static func isToolInventoryHeader(_ line: String) -> Bool {
        if line == "mac tools:" || line == "tool names:" || line == "mcp servers:" || line == "slash commands:" {
            return true
        }
        let countedHeaderPattern = #"^(mac tools|mcp servers|tool names|slash commands):\s+\d+\s+(connected|available|loaded)$"#
        return line.range(of: countedHeaderPattern, options: .regularExpression) != nil
    }

    private static func isLikelyToolName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return false }
        if name.contains(" ") || name.contains("(") || name.contains(")") || name.contains("=") || name.contains("{") || name.contains("}") {
            return false
        }
        let pattern = #"^[A-Za-z0-9_./@:-]+$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isProtocolBlob(_ text: String) -> Bool {
        guard text.hasPrefix("{") && text.hasSuffix("}") else { return false }
        let lowercased = text.lowercased()
        return lowercased.contains("\"session_id\"")
            || lowercased.contains("\"uuid\"")
            || lowercased.contains("\"type\":\"system\"")
            || lowercased.contains("\"type\": \"system\"")
            || lowercased.contains("\"status\":\"requesting\"")
            || lowercased.contains("\"status\": \"requesting\"")
    }
}
