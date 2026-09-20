import Foundation

public struct ChatMessageAttachment: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var kind: ChatMessageAttachmentKind
    public var filename: String
    public var path: String
    public var thumbnailData: Data?

    public init(
        id: UUID = UUID(),
        kind: ChatMessageAttachmentKind,
        filename: String,
        path: String,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.path = path
        self.thumbnailData = thumbnailData
    }
}

public enum ChatMessageAttachmentKind: String, Codable, Equatable, Hashable {
    case file
    case image
}

public struct ChatMessage: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var sessionID: UUID?
    public var kind: ChatMessageKind
    public var title: String
    public var subtitle: String
    public var text: String
    public var status: String
    public var createdAt: Date
    public var parentUserMessageID: UUID?
    public var requestID: String?
    public var isStreaming: Bool
    public var interactiveRequest: ChatInteractiveRequest?
    public var appendRuleText: String?
    public var outputTokenCount: Int?
    public var attachments: [ChatMessageAttachment]

    public init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        kind: ChatMessageKind,
        title: String = "",
        subtitle: String = "",
        text: String,
        status: String = "",
        createdAt: Date = Date(),
        parentUserMessageID: UUID? = nil,
        requestID: String? = nil,
        isStreaming: Bool = false,
        interactiveRequest: ChatInteractiveRequest? = nil,
        appendRuleText: String? = nil,
        outputTokenCount: Int? = nil,
        attachments: [ChatMessageAttachment] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.parentUserMessageID = parentUserMessageID
        self.requestID = requestID
        self.isStreaming = isStreaming
        self.interactiveRequest = interactiveRequest
        self.appendRuleText = appendRuleText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.outputTokenCount = outputTokenCount
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case kind
        case title
        case subtitle
        case text
        case status
        case createdAt
        case parentUserMessageID
        case requestID
        case isStreaming
        case interactiveRequest
        case appendRuleText
        case outputTokenCount
        case attachments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        kind = try values.decode(ChatMessageKind.self, forKey: .kind)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        parentUserMessageID = try values.decodeIfPresent(UUID.self, forKey: .parentUserMessageID)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        isStreaming = try values.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        interactiveRequest = try values.decodeIfPresent(ChatInteractiveRequest.self, forKey: .interactiveRequest)
        appendRuleText = try values.decodeIfPresent(String.self, forKey: .appendRuleText)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        outputTokenCount = try values.decodeIfPresent(Int.self, forKey: .outputTokenCount)
        attachments = try values.decodeIfPresent([ChatMessageAttachment].self, forKey: .attachments) ?? []
    }

    public var timestampText: String {
        ChatMessageFormatters.timestamp.string(from: createdAt)
    }

    public var diffLines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

private enum ChatMessageFormatters {
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
