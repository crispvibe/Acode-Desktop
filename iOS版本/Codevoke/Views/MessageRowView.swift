import ChatCore
import ChatUI
import SwiftUI
import UIKit

struct MessageRowView: View {
    let message: ChatMessage
    var streamingText: String? = nil
    var onCopy: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onPermissionDecision: ((String, String) -> Void)? = nil
    var onInteractiveSubmit: ((ChatInteractiveResponse) -> Void)? = nil

    var body: some View {
        // Phase 3: 高级工具卡已进入 ChatUI，iOS 只保留平台级复制和编辑回调。
        ChatUI.MessageRowView(
            message: message,
            streamingText: streamingText,
            onCopy: { text in
                UIPasteboard.general.string = text
                onCopy?()
            },
            onEditUserMessage: message.kind == .user ? { _ in onEdit?() } : nil,
            advancedToolCard: { message in
                if Self.isFileChangeToolMessage(message) {
                    return AnyView(CompactFileChangeToolRow(message: message))
                }
                if Self.shouldUseGenericToolCard(message) {
                    return AnyView(GenericToolCallRow(message: message))
                }
                return AnyView(AdvancedToolCard(
                    message: message,
                    onPermissionDecision: { requestID, decision in
                        onPermissionDecision?(requestID, Self.wireDecision(for: decision))
                    },
                    onInteractiveSubmit: onInteractiveSubmit
                ))
            }
        )
        .equatable()
    }

    private static let fileChangeToolNames: Set<String> = ["edit", "write", "multiedit"]
    private static func wireDecision(for decision: ChatUIPermissionDecision) -> String {
        switch decision {
        case .deny: return "deny"
        case .allow: return "allow"
        case .allowForSession: return "allowForSession"
        }
    }

    static func shouldRenderOperationalCard(for message: ChatMessage) -> Bool {
        guard !ChatMessageFilter.shouldHideMessage(
            kind: message.kind,
            title: message.title,
            subtitle: message.subtitle,
            text: message.text
        ) else {
            return false
        }
        switch message.kind {
        case .permissionRequest, .interactiveRequest:
            return true
        case .diff:
            return true
        case .toolCall, .toolResult, .command, .commandOutput, .result, .rawOutput:
            return true
        case .user, .assistant, .reasoning, .error, .system:
            return true
        }
    }

    private static func isFileChangeToolMessage(_ message: ChatMessage) -> Bool {
        // 排除 TodoWrite 等含 write 子串的非文件类工具。
        if message.isTodoWriteToolMessage || compactHeader(message).contains("todo") {
            return false
        }
        if message.kind == .diff { return true }
        return fileChangeToolNames.contains(toolName(message))
    }

    private static func shouldUseGenericToolCard(_ message: ChatMessage) -> Bool {
        guard toolName(message).isEmpty else { return false }
        let header = compactHeader(message)
        return header.contains("write") || header.contains("edit")
    }

    private static func toolName(_ message: ChatMessage) -> String {
        let candidates = toolNameCandidates(message)
        if candidates.contains("multiedit") || candidates.contains("multi_edit") || (candidates.contains("multi") && candidates.contains("edit")) { return "multiedit" }
        if candidates.contains("todowrite") || candidates.contains("todo_write") { return "todowrite" }
        if candidates.contains("bash") { return "bash" }
        if candidates.contains("write") { return "write" }
        if candidates.contains("edit") { return "edit" }
        if message.kind == .diff { return "diff" }
        return ""
    }

    private static func compactHeader(_ message: ChatMessage) -> String {
        "\(message.title) \(message.subtitle)"
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func toolNameCandidates(_ message: ChatMessage) -> Set<String> {
        let header = "\(message.title) \(message.subtitle)".lowercased()
        let tokens = header
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(tokens + [compactHeader(message)])
    }
}

private extension ChatMessage {
    var isTodoWriteToolMessage: Bool {
        let header = "\(title) \(subtitle)"
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if header.contains("todowrite") { return true }
        return text.lowercased().contains("\"todos\"")
    }
}

typealias ThinkingIndicatorRow = ChatUI.ThinkingIndicatorRow

struct CollapsibleToolGroup: View {
    let id: UUID
    let messages: [ChatMessage]
    let toolCount: Int
    let isExpanded: Bool
    let streamingText: (UUID) -> String?
    let toggle: () -> Void
    var onPermissionDecision: ((String, String) -> Void)? = nil
    var onInteractiveSubmit: ((ChatInteractiveResponse) -> Void)? = nil

    var body: some View {
        let visibleMessages = messages.filter { MessageRowView.shouldRenderOperationalCard(for: $0) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleMessages) { message in
                MessageRowView(
                    message: message,
                    streamingText: streamingText(message.id),
                    onPermissionDecision: onPermissionDecision,
                    onInteractiveSubmit: onInteractiveSubmit
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactFileChangeToolRow: View {
    let message: ChatMessage

    private var summary: FileChangeSummary {
        FileChangeSummary(message: message)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.codevokeMuted.opacity(0.5))
                .frame(width: 8)

            Image(systemName: "pencil.line")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.codevokeMuted.opacity(0.72))
                .frame(width: 12, height: 12)

            Text(summary.displayPath)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.codevokeMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            Text("已更新")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.codevokeMuted.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FileChangeSummary {
    let displayPath: String
    let added: Int
    let removed: Int

    init(message: ChatMessage) {
        let object = Self.firstJSONObject(in: message.text)
        let path = object.flatMap(Self.filePath(in:)) ?? Self.firstPath(in: message.text)
        self.displayPath = Self.compactPath(path ?? "文件已更新")
        let counts = Self.changeCounts(object: object, text: message.text, isWrite: Self.toolName(message) == "write")
        self.added = counts.added
        self.removed = counts.removed
    }

    private static func toolName(_ message: ChatMessage) -> String {
        let compactHeader = "\(message.title) \(message.subtitle)"
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if compactHeader.contains("write") { return "write" }
        if compactHeader.contains("multiedit") { return "multiedit" }
        if compactHeader.contains("edit") { return "edit" }
        if message.kind == .diff { return "diff" }
        return ""
    }

    private static func compactPath(_ path: String) -> String {
        path
    }

    private static func changeCounts(object: Any?, text: String, isWrite: Bool) -> (added: Int, removed: Int) {
        if let object {
            let counts = generatedChangeCounts(object: object, isWrite: isWrite)
            if counts.added > 0 || counts.removed > 0 { return counts }
        }

        var added = 0
        var removed = 0
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    private static func generatedChangeCounts(object: Any, isWrite: Bool) -> (added: Int, removed: Int) {
        if let dictionary = object as? [String: Any] {
            if let edits = caseInsensitiveValue("edits", in: dictionary) as? [Any] {
                return edits.map { generatedChangeCounts(object: $0, isWrite: false) }.reduce((0, 0)) {
                    ($0.added + $1.added, $0.removed + $1.removed)
                }
            }

            var added = 0
            var removed = 0
            if let old = stringValue(for: ["old_string", "oldString", "old", "before"], in: dictionary) {
                removed += lineCount(old)
            }
            if let new = stringValue(for: ["new_string", "newString", "replacement", "after"], in: dictionary) {
                added += lineCount(new)
            }
            if added == 0, removed == 0, isWrite, let content = stringValue(for: ["content", "text"], in: dictionary) {
                added += lineCount(content)
            }
            if added > 0 || removed > 0 { return (added, removed) }

            for key in ["input", "args", "arguments", "params", "data", "message", "content"] {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                let counts = generatedChangeCounts(object: value, isWrite: isWrite)
                if counts.added > 0 || counts.removed > 0 { return counts }
            }
        }

        if let array = object as? [Any] {
            return array.map { generatedChangeCounts(object: $0, isWrite: isWrite) }.reduce((0, 0)) {
                ($0.added + $1.added, $0.removed + $1.removed)
            }
        }

        if let string = object as? String, let nested = jsonObject(from: string) {
            return generatedChangeCounts(object: nested, isWrite: isWrite)
        }
        return (0, 0)
    }

    private static func lineCount(_ value: String) -> Int {
        max(1, value.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private static func filePath(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let path = stringValue(for: ["file_path", "filePath", "path", "target_file", "targetFile"], in: dictionary) {
                return path
            }
            for value in dictionary.values {
                if let path = filePath(in: value) { return path }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let path = filePath(in: value) { return path }
            }
        }
        if let string = object as? String, let nested = jsonObject(from: string) {
            return filePath(in: nested)
        }
        return nil
    }

    private static func firstPath(in value: String) -> String? {
        let pattern = #"(?<!\w)(?:/[^\s`\"'<>|]+|[A-Za-z0-9_.-]+(?:[/\\][A-Za-z0-9_.-]+)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: range) {
            guard let matchRange = Range(match.range, in: value) else { continue }
            let path = String(value[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)。），"))
            if path.contains(".") { return path }
        }
        return nil
    }

    private static func firstJSONObject(in text: String) -> Any? {
        if let object = jsonObject(from: text) { return object }
        for fragment in jsonFragments(in: text) {
            if let object = jsonObject(from: fragment) { return object }
        }
        return nil
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func jsonFragments(in value: String) -> [String] {
        var fragments: [String] = []
        var startIndex: String.Index?
        var stack: [Character] = []
        var isInsideString = false
        var isEscaped = false
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" || character == "[" {
                if stack.isEmpty { startIndex = index }
                stack.append(character)
            } else if character == "}" || character == "]" {
                if let last = stack.last, (last == "{" && character == "}" || last == "[" && character == "]") {
                    stack.removeLast()
                    if stack.isEmpty, let startIndex {
                        fragments.append(String(value[startIndex...index]))
                    }
                } else {
                    stack.removeAll()
                }
            }
            index = value.index(after: index)
        }
        return fragments
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func caseInsensitiveValue(_ key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { $0.key.lowercased() == key.lowercased() }?.value
    }
}
