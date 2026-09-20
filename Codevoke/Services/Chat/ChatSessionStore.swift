import Foundation

struct ChatMessagePage {
    let messages: [ChatMessage]
    let nextBeforeIndex: Int?
    let hasMore: Bool
    let totalCount: Int
}

enum ChatSessionStore {
    private static let indexFileName = "chat-sessions.json"
    private static let draftsFileName = "chat-drafts.json"
    private static let messagesDirectoryName = "chat-messages"
    private static let persistenceQueue = DispatchQueue(label: "com.codevoke.chat-session-store", qos: .utility)
    static let storageKey = "claudemac"

    static func loadSessions() -> [ChatSessionRecord] {
        persistenceQueue.sync { loadSessionsUnlocked() }
    }

    static func loadSession(id: UUID) -> ChatSessionRecord? {
        persistenceQueue.sync { loadSessionUnlocked(id: id) }
    }

    private static func loadSessionsUnlocked() -> [ChatSessionRecord] {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder.chat.decode([ChatSessionRecord].self, from: data)
        } catch {
            // Index exists but won't decode — preserve it instead of returning empty and
            // letting the next saveSession overwrite every other session.
            ProjectStore.backupCorruptedFile(at: url)
            return []
        }
    }

    private static func loadSessionUnlocked(id: UUID) -> ChatSessionRecord? {
        guard let data = try? Data(contentsOf: indexURL()),
              let idData = "\"id\":\"\(id.uuidString)\"".data(using: .utf8) else { return nil }
        var searchStart = data.startIndex
        while searchStart < data.endIndex {
            let searchRange = searchStart..<data.endIndex
            guard let idRange = data.range(of: idData, options: [], in: searchRange) else { return nil }
            if let objectRange = topLevelObjectRange(containing: idRange, in: data),
               let session = try? JSONDecoder.chat.decode(ChatSessionRecord.self, from: Data(data[objectRange])),
               session.id == id {
                return session
            }
            searchStart = idRange.upperBound
        }
        return nil
    }

    static func saveSession(_ session: ChatSessionRecord) throws {
        try persistenceQueue.sync { () throws in
            try ensureDirectories()
            var sessions = loadSessionsUnlocked()
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.insert(session, at: 0)
            }
            sessions.sort { $0.updatedAt > $1.updatedAt }
            let data = try JSONEncoder.chat.encode(sessions)
            try data.write(to: indexURL(), options: .atomic)
        }
    }

    static func loadMessages(sessionID: UUID) -> [ChatMessage] {
        persistenceQueue.sync { loadMessagesUnlocked(sessionID: sessionID) }
    }

    static func loadMessagePage(sessionID: UUID, beforeIndex: Int?, limit: Int) -> ChatMessagePage {
        persistenceQueue.sync { loadMessagePageUnlocked(sessionID: sessionID, beforeIndex: beforeIndex, limit: limit) }
    }

    private static func loadMessagesUnlocked(sessionID: UUID) -> [ChatMessage] {
        let url = messagesURL(for: sessionID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? JSONDecoder.chat.decode(ChatMessage.self, from: Data(line))
        }
    }

    private static func loadMessagePageUnlocked(sessionID: UUID, beforeIndex: Int?, limit: Int) -> ChatMessagePage {
        let url = messagesURL(for: sessionID)
        guard let data = try? Data(contentsOf: url) else {
            return ChatMessagePage(messages: [], nextBeforeIndex: nil, hasMore: false, totalCount: 0)
        }
        let pageLimit = min(max(limit, 1), 500)
        if beforeIndex == nil {
            let total = approximateLineCount(in: data)
            let lines = tailJSONLines(from: data, limit: pageLimit)
            let messages = lines.compactMap { try? JSONDecoder.chat.decode(ChatMessage.self, from: Data($0)) }
            let startIndex = max(0, total - lines.count)
            return ChatMessagePage(
                messages: messages,
                nextBeforeIndex: startIndex > 0 ? startIndex : nil,
                hasMore: startIndex > 0,
                totalCount: total
            )
        }
        let lines = data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        let total = lines.count
        let endIndex = min(max(beforeIndex ?? total, 0), total)
        let startIndex = max(0, endIndex - pageLimit)
        let messages = lines[startIndex..<endIndex].compactMap { line in
            try? JSONDecoder.chat.decode(ChatMessage.self, from: Data(line))
        }
        return ChatMessagePage(
            messages: messages,
            nextBeforeIndex: startIndex > 0 ? startIndex : nil,
            hasMore: startIndex > 0,
            totalCount: total
        )
    }

    private static func approximateLineCount(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newline = UInt8(ascii: "\n")
        let newlineCount = data.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        return data.last == newline ? newlineCount : newlineCount + 1
    }

    private static func tailJSONLines(from data: Data, limit: Int) -> [Data.SubSequence] {
        guard !data.isEmpty, limit > 0 else { return [] }
        let newline = UInt8(ascii: "\n")
        var ranges: [Range<Data.Index>] = []
        var end = data.endIndex
        while end > data.startIndex, data[data.index(before: end)] == newline {
            end = data.index(before: end)
        }
        var index = end
        while index > data.startIndex, ranges.count < limit {
            let previous = data.index(before: index)
            if data[previous] == newline {
                let start = data.index(after: previous)
                if start < end {
                    ranges.append(start..<end)
                }
                end = previous
            }
            index = previous
        }
        if ranges.count < limit, data.startIndex < end {
            ranges.append(data.startIndex..<end)
        }
        return ranges.reversed().map { data[$0] }
    }

    static func saveMessages(_ messages: [ChatMessage], sessionID: UUID) throws {
        try persistenceQueue.sync { () throws in
            try ensureDirectories()
            let encoder = JSONEncoder.chat
            let lines = try messages.map { message -> String in
                let data = try encoder.encode(message)
                return String(data: data, encoding: .utf8) ?? ""
            }
            try lines.joined(separator: "\n").write(to: messagesURL(for: sessionID), atomically: true, encoding: .utf8)
        }
    }

    static func session(id: String) -> ChatSessionRecord? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return loadSession(id: uuid)
    }

    static func deleteSession(id: String) throws {
        guard let uuid = UUID(uuidString: id) else { return }
        try persistenceQueue.sync { () throws in
            // 先删 messages 文件（即便失败也只是孤儿一个文件，不会让索引出现"指向已删条目的悬空引用"）。
            // 旧实现先写索引再删文件，若 removeItem 抛异常会留下"索引已无、文件常驻"的孤儿。
            let url = messagesURL(for: uuid)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            var sessions = loadSessionsUnlocked()
            let deletedSession = sessions.first { $0.id == uuid }
            sessions.removeAll { $0.id == uuid }
            try JSONEncoder.chat.encode(sessions).write(to: indexURL(), options: .atomic)
            if let deletedSession {
                try? writeDraftUnlocked("", for: "history:\(deletedSession.cli.rawValue):\(uuid.uuidString)")
            }
        }
    }

    static func draft(for key: String) -> String {
        persistenceQueue.sync { loadDraftsUnlocked()[key] ?? "" }
    }

    static func saveDraft(_ text: String, for key: String) throws {
        DraftPersistenceQueue.shared.enqueue(text, for: key)
    }

    static func saveDraftImmediately(_ text: String, for key: String) throws {
        try writeDraft(text, for: key)
    }

    static func flushPendingDrafts() {
        DraftPersistenceQueue.shared.flushImmediately()
    }

    static func deleteDraft(for key: String) throws {
        try saveDraft("", for: key)
    }

    fileprivate static func writeDraft(_ text: String, for key: String) throws {
        try persistenceQueue.sync { () throws in
            try writeDraftUnlocked(text, for: key)
        }
    }

    private static func writeDraftUnlocked(_ text: String, for key: String) throws {
        try ensureDirectories()
        var drafts = loadDraftsUnlocked()
        if text.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = text
        }
        try JSONEncoder.chat.encode(drafts).write(to: draftsURL(), options: .atomic)
    }

    static func historySessions() -> [CLIHistorySession] {
        historySessions(from: loadSessions())
    }

    static func historySessions(from sessions: [ChatSessionRecord]) -> [CLIHistorySession] {
        sessions.map { session in
            CLIHistorySession(
                cli: session.cli,
                sessionId: session.id.uuidString,
                title: session.title,
                projectPath: session.projectPath,
                storageKey: storageKey,
                storagePath: messagesURL(for: session.id).path,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        }
    }

    private static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportURL(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messagesDirectoryURL(), withIntermediateDirectories: true)
    }

    private static func appSupportURL() -> URL {
        (try? ProjectStore.appSupportDirectory)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Codevoke", isDirectory: true)
    }

    private static func loadDrafts() -> [String: String] {
        persistenceQueue.sync { loadDraftsUnlocked() }
    }

    private static func loadDraftsUnlocked() -> [String: String] {
        guard let data = try? Data(contentsOf: draftsURL()) else { return [:] }
        return (try? JSONDecoder.chat.decode([String: String].self, from: data)) ?? [:]
    }

    private static func topLevelObjectRange(containing targetRange: Range<Data.Index>, in data: Data) -> Range<Data.Index>? {
        var isInString = false
        var isEscaped = false
        var objectDepth = 0
        var objectStart: Data.Index?
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                isInString = true
            } else if byte == UInt8(ascii: "{") {
                objectDepth += 1
                if objectDepth == 1 {
                    objectStart = index
                }
            } else if byte == UInt8(ascii: "}") {
                if objectDepth == 1, let start = objectStart {
                    let objectEnd = data.index(after: index)
                    let objectRange = start..<objectEnd
                    if objectRange.contains(targetRange.lowerBound) {
                        return objectRange
                    }
                    objectStart = nil
                }
                objectDepth = max(0, objectDepth - 1)
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func indexURL() -> URL {
        appSupportURL().appendingPathComponent(indexFileName)
    }

    private static func draftsURL() -> URL {
        appSupportURL().appendingPathComponent(draftsFileName)
    }

    private static func messagesDirectoryURL() -> URL {
        appSupportURL().appendingPathComponent(messagesDirectoryName, isDirectory: true)
    }

    private static func messagesURL(for sessionID: UUID) -> URL {
        messagesDirectoryURL().appendingPathComponent("\(sessionID.uuidString).jsonl")
    }
}

private final class DraftPersistenceQueue {
    static let shared = DraftPersistenceQueue()

    private let queue = DispatchQueue(label: "com.codevoke.draft-persist", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: String] = [:]
    private var flushScheduled = false
    private let debounceInterval: TimeInterval = 0.5

    private init() {}

    func enqueue(_ text: String, for key: String) {
        lock.lock()
        pending[key] = text
        let alreadyScheduled = flushScheduled
        flushScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        queue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            self?.flushIfNeeded()
        }
    }

    func flushImmediately() {
        queue.sync { [weak self] in
            self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        lock.lock()
        let snapshot = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        for (key, text) in snapshot {
            try? ChatSessionStore.writeDraft(text, for: key)
        }
    }
}

private extension JSONEncoder {
    static let chat: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let chat: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
