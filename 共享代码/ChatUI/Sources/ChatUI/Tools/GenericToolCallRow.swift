import ChatCore
import Foundation
import SwiftUI

public struct GenericToolCallRow: View {
    public let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(ChatTheme.muted.opacity(0.5))
                .frame(width: 8)

            Image(systemName: iconName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ChatTheme.muted.opacity(0.7))
                .frame(width: 12, height: 12)

            if let summary {
                Text(summary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String? {
        let trimmed: String
        if let jsonSummary = ToolJSONSummary.summary(from: message.text) {
            trimmed = jsonSummary
        } else if ToolJSONSummary.containsJSON(in: message.text) || ToolJSONSummary.looksLikeJSON(in: message.text) {
            return nil
        } else {
            trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }
        if let line = trimmed.split(separator: "\n").first {
            return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private var iconName: String {
        let haystack = "\(message.title) \(message.subtitle) \(message.text)".lowercased()
        if message.kind == .reasoning { return "brain.head.profile" }
        if message.kind == .diff { return "plus.forwardslash.minus" }
        if message.kind == .permissionRequest { return "hand.raised" }
        if message.kind == .interactiveRequest { return "questionmark.bubble" }
        if haystack.contains("mcp") { return "point.3.connected.trianglepath.dotted" }
        if haystack.contains("agent") || haystack.contains("subagent") { return "person.2.wave.2" }
        if message.kind == .command || message.kind == .commandOutput { return "terminal" }
        if haystack.contains("read") { return "doc.text.magnifyingglass" }
        if haystack.contains("grep") || haystack.contains("search") { return "magnifyingglass" }
        if haystack.contains("edit") || haystack.contains("write") { return "square.and.pencil" }
        return "wrench.and.screwdriver"
    }
}

enum ToolJSONSummary {
    static func containsJSON(in text: String) -> Bool {
        firstJSONObject(in: text) != nil
    }

    static func looksLikeJSON(in text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return first == "{" || first == "["
    }

    static func summary(from text: String) -> String? {
        guard let object = firstJSONObject(in: text) else { return nil }
        if let value = firstStringValue(for: [
            "command", "cmd", "file_path", "filePath", "path", "target_file", "targetFile",
            "pattern", "query", "description", "summary", "title", "status", "message"
        ], in: object) {
            return preview(value)
        }
        if let value = firstStringValue(for: ["stdout", "stderr", "output", "result", "text", "content"], in: object) {
            return preview(value)
        }
        return nil
    }

    static func firstJSONObject(in text: String) -> Any? {
        if let object = jsonObject(from: text) { return object }
        for fragment in jsonFragments(in: text) {
            if let object = jsonObject(from: fragment) { return object }
        }
        return nil
    }

    private static func firstStringValue(for keys: [String], in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                if let string = value as? String {
                    let cleaned = cleanString(string)
                    if !cleaned.isEmpty { return cleaned }
                }
                if let number = value as? NSNumber { return number.stringValue }
            }
            for key in nestedKeys {
                guard let value = caseInsensitiveValue(key, in: dictionary),
                      let nested = firstStringValue(for: keys, in: value) else { continue }
                return nested
            }
            for value in dictionary.values {
                if let nested = firstStringValue(for: keys, in: value) { return nested }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = firstStringValue(for: keys, in: value) { return nested }
            }
        }
        if let string = object as? String, let nested = jsonObject(from: string) {
            return firstStringValue(for: keys, in: nested)
        }
        return nil
    }

    private static func cleanString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasSuffix("}") } ?? ""
    }

    private static func preview(_ value: String, limit: Int = 180) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
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
                guard let last = stack.last,
                      (last == "{" && character == "}" || last == "[" && character == "]") else {
                    stack.removeAll()
                    startIndex = nil
                    index = value.index(after: index)
                    continue
                }
                stack.removeLast()
                if stack.isEmpty, let fragmentStartIndex = startIndex {
                    fragments.append(String(value[fragmentStartIndex...index]))
                    startIndex = nil
                }
            }
            index = value.index(after: index)
        }
        return fragments
    }

    private static func caseInsensitiveValue(_ key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    private static var nestedKeys: [String] {
        ["input", "args", "arguments", "params", "data", "item", "message", "content"]
    }
}
