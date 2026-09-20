import Foundation

public struct CollapsedToolMessageGroup: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let turnID: UUID?
    public let messages: [ChatMessage]

    public init(id: UUID, turnID: UUID?, messages: [ChatMessage]) {
        self.id = id
        self.turnID = turnID
        self.messages = messages
    }

    public var toolInvocationCount: Int {
        let starts = messages.filter { $0.kind == .toolCall || $0.kind == .command }.count
        return max(starts, 1)
    }
}

public enum CollapsedToolMessageRow: Identifiable, Equatable, Hashable {
    case message(ChatMessage)
    case toolGroup(CollapsedToolMessageGroup)

    public var id: UUID {
        switch self {
        case .message(let message):
            return message.id
        case .toolGroup(let group):
            return group.id
        }
    }
}

public enum ToolMessageGrouping {
    public static func rows(for messages: [ChatMessage]) -> [CollapsedToolMessageRow] {
        var rows: [CollapsedToolMessageRow] = []
        rows.reserveCapacity(messages.count)
        var toolBuffer: [ChatMessage] = []
        var bufferTurnID: UUID?
        var currentTurnID: UUID?

        func flushToolBuffer() {
            guard let first = toolBuffer.first else { return }
            // Bug B: collapse only contiguous tool noise inside the current assistant turn.
            rows.append(.toolGroup(CollapsedToolMessageGroup(id: first.id, turnID: bufferTurnID, messages: toolBuffer)))
            toolBuffer.removeAll(keepingCapacity: true)
            bufferTurnID = nil
        }

        for message in messages {
            if isTurnBoundary(message) {
                flushToolBuffer()
                rows.append(.message(message))
                currentTurnID = message.id
            } else if isCollapsibleToolMessage(message) {
                if toolBuffer.isEmpty {
                    bufferTurnID = currentTurnID
                } else if bufferTurnID != currentTurnID {
                    flushToolBuffer()
                    bufferTurnID = currentTurnID
                }
                toolBuffer.append(message)
            } else {
                flushToolBuffer()
                rows.append(.message(message))
            }
        }

        flushToolBuffer()
        return rows
    }

    private static func isTurnBoundary(_ message: ChatMessage) -> Bool {
        if message.kind == .user { return true }
        if message.kind == .assistant {
            return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func isCollapsibleToolMessage(_ message: ChatMessage) -> Bool {
        switch message.kind {
        case .toolCall, .toolResult, .command, .commandOutput, .diff:
            return true
        case .user, .assistant, .reasoning, .permissionRequest, .interactiveRequest, .error, .system, .result, .rawOutput:
            return false
        }
    }
}
