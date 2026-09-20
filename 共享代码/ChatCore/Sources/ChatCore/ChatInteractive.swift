import Foundation

public enum ChatInteractiveMode: String, Codable, Equatable, Hashable {
    case singleChoice
    case multipleChoice
    case text
}

public enum ChatInteractiveStatus: String, Codable, Equatable, Hashable {
    case waiting
    case answered
    case cancelled
    case failed
}

public struct ChatInteractiveOption: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public struct ChatInteractiveRequest: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var prompt: String
    public var mode: ChatInteractiveMode
    public var options: [ChatInteractiveOption]
    public var allowCustomInput: Bool
    public var placeholder: String
    public var status: ChatInteractiveStatus

    public init(
        id: String,
        title: String,
        prompt: String,
        mode: ChatInteractiveMode,
        options: [ChatInteractiveOption],
        allowCustomInput: Bool,
        placeholder: String,
        status: ChatInteractiveStatus
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.mode = mode
        self.options = options
        self.allowCustomInput = allowCustomInput
        self.placeholder = placeholder
        self.status = status
    }
}

public struct ChatInteractiveResponse: Codable, Equatable, Hashable {
    public var requestID: String
    public var selectedOptionIDs: [String]
    public var customText: String?

    public init(requestID: String, selectedOptionIDs: [String], customText: String?) {
        self.requestID = requestID
        self.selectedOptionIDs = selectedOptionIDs
        self.customText = customText
    }
}
