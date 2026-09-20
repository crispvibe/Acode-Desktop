import Foundation

struct SubagentTranscript: Equatable {
    var agentID: String
    var agentType: String
    var description: String
    var sourcePath: String
    var updatedAt: Date?
    var messages: [SubagentTranscriptMessage]
}

struct SubagentTranscriptMessage: Identifiable, Equatable {
    var id: String
    var kind: SubagentTranscriptMessageKind
    var title: String
    var subtitle: String
    var text: String
    var status: String
    var timestamp: Date?
}

enum SubagentTranscriptMessageKind: String, Equatable {
    case user
    case assistant
    case reasoning
    case toolCall
    case toolResult
    case raw
}

enum SubagentTranscriptStore {
    static func load(agentID rawAgentID: String, projectPath: String?) -> SubagentTranscript? {
        let agentID = normalizedAgentID(rawAgentID)
        guard let jsonlURL = transcriptURL(agentID: agentID, projectPath: projectPath) else { return nil }
        return load(jsonlURL: jsonlURL, agentID: agentID)
    }

    static func find(agentType: String, description: String, projectPath: String?) -> SubagentTranscript? {
        let targetType = comparable(agentType)
        let targetDescription = comparable(description)
        return candidateMetaURLs(projectPath: projectPath)
            .compactMap { metaURL -> (URL, Date)? in
                let meta = loadMeta(url: metaURL)
                let typeMatches = targetType.isEmpty || comparable(meta.agentType) == targetType
                let descriptionMatches = targetDescription.isEmpty || comparable(meta.description) == targetDescription
                guard typeMatches && descriptionMatches else { return nil }
                let jsonlURL = metaURL.deletingLastPathComponent().appendingPathComponent(metaURL.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
                guard FileManager.default.fileExists(atPath: jsonlURL.path) else { return nil }
                let values = try? jsonlURL.resourceValues(forKeys: [.contentModificationDateKey])
                return (jsonlURL, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .compactMap { url, _ in load(jsonlURL: url, agentID: normalizedAgentID(url.deletingPathExtension().lastPathComponent)) }
            .first
    }

    static func normalizedAgentID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "agent-", with: "")
    }

    private static func load(jsonlURL: URL, agentID: String) -> SubagentTranscript? {
        guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return nil }
        let meta = loadMeta(url: jsonlURL.deletingLastPathComponent().appendingPathComponent("agent-\(agentID).meta.json"))
        let messages = parseMessages(from: content)
        let values = try? jsonlURL.resourceValues(forKeys: [.contentModificationDateKey])
        return SubagentTranscript(
            agentID: agentID,
            agentType: meta.agentType,
            description: meta.description,
            sourcePath: jsonlURL.path,
            updatedAt: values?.contentModificationDate,
            messages: messages
        )
    }

    private static func transcriptURL(agentID: String, projectPath: String?) -> URL? {
        let fileName = "agent-\(agentID).jsonl"
        if let projectPath {
            let direct = claudeProjectsRoot()
                .appendingPathComponent(storageKey(for: projectPath), isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: claudeProjectsRoot(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }

    private static func candidateMetaURLs(projectPath: String?) -> [URL] {
        let root: URL
        if let projectPath {
            root = claudeProjectsRoot().appendingPathComponent(storageKey(for: projectPath), isDirectory: true)
        } else {
            root = claudeProjectsRoot()
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL,
                  url.lastPathComponent.hasPrefix("agent-"),
                  url.lastPathComponent.hasSuffix(".meta.json") else { return nil }
            return url
        }
    }

    private static func comparable(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadMeta(url: URL) -> (agentType: String, description: String) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Agent", "子代理")
        }
        return (
            readableString(object["agentType"]) ?? "Agent",
            readableString(object["description"]) ?? "子代理"
        )
    }

    private static func parseMessages(from content: String) -> [SubagentTranscriptMessage] {
        content.split(separator: "\n", omittingEmptySubsequences: true).enumerated().flatMap { index, line -> [SubagentTranscriptMessage] in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return messages(from: object, lineIndex: index)
        }
    }

    private static func messages(from object: [String: Any], lineIndex: Int) -> [SubagentTranscriptMessage] {
        let timestamp = date(from: object["timestamp"])
        let topType = readableString(object["type"]) ?? "event"
        guard let message = object["message"] as? [String: Any] else {
            return rawMessage(object, lineIndex: lineIndex, timestamp: timestamp, title: topType)
        }
        let role = readableString(message["role"]) ?? topType
        return contentMessages(
            content: message["content"],
            role: role,
            lineIndex: lineIndex,
            timestamp: timestamp,
            fallbackTitle: topType
        )
    }

    private static func contentMessages(content: Any?, role: String, lineIndex: Int, timestamp: Date?, fallbackTitle: String) -> [SubagentTranscriptMessage] {
        if let text = readableString(content), !text.isEmpty {
            return [SubagentTranscriptMessage(
                id: "\(lineIndex):0",
                kind: role == "assistant" ? .assistant : .user,
                title: role,
                subtitle: "",
                text: text,
                status: "done",
                timestamp: timestamp
            )]
        }
        guard let blocks = content as? [Any] else {
            let text = transcriptText(from: content) ?? compactText(from: content)
            guard !text.isEmpty else { return [] }
            return [SubagentTranscriptMessage(
                id: "\(lineIndex):0",
                kind: .raw,
                title: fallbackTitle,
                subtitle: role,
                text: text,
                status: "done",
                timestamp: timestamp
            )]
        }
        return blocks.enumerated().compactMap { blockIndex, block in
            guard let block = block as? [String: Any] else { return nil }
            return message(from: block, role: role, lineIndex: lineIndex, blockIndex: blockIndex, timestamp: timestamp)
        }
    }

    private static func message(from block: [String: Any], role: String, lineIndex: Int, blockIndex: Int, timestamp: Date?) -> SubagentTranscriptMessage? {
        let type = readableString(block["type"]) ?? role
        let id = "\(lineIndex):\(blockIndex)"
        switch type {
        case "text":
            guard let text = readableString(block["text"]), !text.isEmpty else { return nil }
            return SubagentTranscriptMessage(id: id, kind: .assistant, title: "assistant", subtitle: "", text: text, status: "done", timestamp: timestamp)
        case "thinking":
            guard let text = readableString(block["thinking"]) ?? readableString(block["text"]), !text.isEmpty else { return nil }
            return SubagentTranscriptMessage(id: id, kind: .reasoning, title: "thinking", subtitle: "", text: text, status: "done", timestamp: timestamp)
        case "tool_use":
            let name = readableString(block["name"]) ?? "tool"
            return SubagentTranscriptMessage(id: id, kind: .toolCall, title: name, subtitle: readableString(block["id"]) ?? "", text: compactText(from: block["input"]), status: "done", timestamp: timestamp)
        case "tool_result":
            let isError = (block["is_error"] as? Bool) == true
            let text = (transcriptText(from: block["content"]) ?? compactText(from: block["content"])).nonEmptyTrimmed ?? "empty result"
            return SubagentTranscriptMessage(id: id, kind: .toolResult, title: "tool_result", subtitle: readableString(block["tool_use_id"]) ?? "", text: text, status: isError ? "failed" : "done", timestamp: timestamp)
        default:
            if role == "user", let text = transcriptText(from: block["content"]) ?? transcriptText(from: block["text"]), !text.isEmpty {
                return SubagentTranscriptMessage(id: id, kind: .user, title: "user", subtitle: type, text: text, status: "done", timestamp: timestamp)
            }
            let text = transcriptText(from: block) ?? compactText(from: block)
            guard !text.isEmpty else { return nil }
            return SubagentTranscriptMessage(id: id, kind: .raw, title: type, subtitle: role, text: text, status: "done", timestamp: timestamp)
        }
    }

    private static func rawMessage(_ object: [String: Any], lineIndex: Int, timestamp: Date?, title: String) -> [SubagentTranscriptMessage] {
        let text = transcriptText(from: object) ?? compactText(from: object)
        guard !text.isEmpty else { return [] }
        return [SubagentTranscriptMessage(id: "\(lineIndex):0", kind: .raw, title: title, subtitle: "", text: text, status: "done", timestamp: timestamp)]
    }

    private static func claudeProjectsRoot() -> URL {
        URL(fileURLWithPath: ChatCLIEnvironment.realHomeDirectory, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private static func storageKey(for projectPath: String) -> String {
        "-" + (projectPath as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "-")
    }

    private static func readableString(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func transcriptText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.nonEmptyTrimmed
        case let blocks as [Any]:
            let text = blocks.compactMap { transcriptText(from: $0) }.joined(separator: "\n\n")
            return text.nonEmptyTrimmed
        case let object as [String: Any]:
            let type = readableString(object["type"])
            if type == "thinking", readableString(object["thinking"])?.nonEmptyTrimmed == nil, readableString(object["text"])?.nonEmptyTrimmed == nil {
                return nil
            }
            for key in ["text", "thinking", "content", "result", "summary", "answer", "output"] {
                if let text = transcriptText(from: object[key])?.nonEmptyTrimmed {
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func compactText(from value: Any?) -> String {
        guard let value = sanitizedJSONValue(value) else { return "" }
        if let text = readableString(value) { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func sanitizedJSONValue(_ value: Any?) -> Any? {
        switch value {
        case let object as [String: Any]:
            let filtered = object.compactMapValues { value -> Any? in
                sanitizedJSONValue(value)
            }.filter { key, _ in
                !["signature", "usage", "cache_creation", "server_tool_use"].contains(key)
            }
            return filtered.isEmpty ? nil : filtered
        case let array as [Any]:
            let filtered = array.compactMap { sanitizedJSONValue($0) }
            return filtered.isEmpty ? nil : filtered
        case let text as String:
            return text.nonEmptyTrimmed
        case let value?:
            return value
        case nil:
            return nil
        }
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return iso8601Formatter.date(from: text)
    }
}
