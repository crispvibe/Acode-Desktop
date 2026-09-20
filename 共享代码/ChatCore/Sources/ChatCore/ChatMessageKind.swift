import Foundation

public enum ChatMessageKind: String, Codable, Equatable, Hashable {
    case user
    case assistant
    case reasoning
    case toolCall
    case toolResult
    case command
    case commandOutput
    case permissionRequest
    case interactiveRequest
    case diff
    case error
    case system
    case result
    case rawOutput

    public var isConversationBubble: Bool {
        self == .user || self == .assistant || self == .error || self == .system
    }

    public var isOperationalOutput: Bool {
        switch self {
        case .reasoning, .toolCall, .toolResult, .command, .commandOutput, .permissionRequest, .interactiveRequest, .diff, .result, .rawOutput:
            true
        case .user, .assistant, .error, .system:
            false
        }
    }
}
