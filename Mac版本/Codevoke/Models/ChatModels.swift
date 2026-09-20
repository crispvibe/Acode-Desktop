import Foundation
import ChatCore

struct ChatModelOption: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let cli: CLIType
    let contextWindow: Int?

    init(id: String, title: String, cli: CLIType, contextWindow: Int? = nil) {
        self.id = id
        self.title = title
        self.cli = cli
        self.contextWindow = contextWindow
    }
}

enum ChatModelReasoningFamily: Equatable {
    case claude
    case gpt
}

enum ChatModelCatalog {
    static let defaultClaudeModelID = "default"
    static let defaultCodexModelID = "gpt-5.3-codex"

    static func options(for cli: CLIType) -> [ChatModelOption] {
        switch cli.visibleValue {
        case .claude:
            return [
                ChatModelOption(id: defaultClaudeModelID, title: "默认", cli: .claude),
                ChatModelOption(id: "claude-opus-4-8[1m]", title: "Opus 4.8 1M", cli: .claude, contextWindow: 1_000_000),
                ChatModelOption(id: "claude-opus-4-8", title: "Opus 4.8", cli: .claude),
                ChatModelOption(id: "claude-opus-4-7", title: "Opus 4.7 1M", cli: .claude, contextWindow: 1_000_000),
                ChatModelOption(id: "claude-opus-4-6", title: "Opus 4.6", cli: .claude),
                ChatModelOption(id: "claude-sonnet-4-6", title: "Sonnet 4.6", cli: .claude),
                ChatModelOption(id: "claude-haiku-4-5", title: "Haiku 4.5", cli: .claude)
            ]
        case .codex:
            return [
                ChatModelOption(id: "gpt-5.5", title: "GPT-5.5", cli: .codex, contextWindow: 275_000),
                ChatModelOption(id: defaultCodexModelID, title: "GPT-5.3 Codex", cli: .codex),
                ChatModelOption(id: "gpt-5.4", title: "GPT-5.4", cli: .codex),
                ChatModelOption(id: "gpt-5.2-codex", title: "GPT-5.2 Codex", cli: .codex),
                ChatModelOption(id: "gpt-5.2", title: "GPT-5.2", cli: .codex),
                ChatModelOption(id: "gpt-5.1-codex-mini", title: "GPT-5.1 Codex Mini", cli: .codex)
            ]
        case .gemini, .custom:
            return options(for: .claude)
        }
    }

    static func title(for id: String, cli: CLIType) -> String {
        options(for: cli).first { $0.id == id }?.title ?? id
    }

    static func defaultModelID(for cli: CLIType) -> String {
        cli.visibleValue == .codex ? defaultCodexModelID : defaultClaudeModelID
    }

    static func compatibleModelID(_ id: String, cli: CLIType) -> String {
        let normalized = executionModelID(for: id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return defaultModelID(for: cli) }
        switch cli.visibleValue {
        case .claude:
            return isKnownGPTModelID(normalized) ? defaultClaudeModelID : id
        case .codex:
            return normalized == defaultClaudeModelID || isKnownClaudeModelID(normalized) ? defaultCodexModelID : id
        case .gemini, .custom:
            return compatibleModelID(id, cli: .claude)
        }
    }

    static func executionModelID(for id: String) -> String {
        id.replacingOccurrences(of: "[1m]", with: "")
    }

    static func contextWindow(for id: String, cli: CLIType, metadataWindow: Int? = nil) -> Int {
        if let metadataWindow, metadataWindow > 0 {
            return metadataWindow
        }

        let raw = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let executionID = executionModelID(for: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if executionID == "gpt-5.5" || executionID == "gpt5.5" {
            return 275_000
        }
        if executionID == "claude-opus-4-7"
            || raw.contains("[1m]")
            || raw.contains("1m")
            || raw.contains("1000k") {
            return 1_000_000
        }
        return 200_000
    }

    static func reasoningFamily(for id: String, cli: CLIType) -> ChatModelReasoningFamily {
        let normalized = executionModelID(for: id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if isKnownClaudeModelID(normalized) {
            return .claude
        }

        if isKnownGPTModelID(normalized) {
            return .gpt
        }

        return cli.visibleValue == .codex ? .gpt : .claude
    }

    private static func isKnownClaudeModelID(_ normalized: String) -> Bool {
        normalized.hasPrefix("claude-") || normalized.hasPrefix("anthropic/claude-")
    }

    private static func isKnownGPTModelID(_ normalized: String) -> Bool {
        normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("openai/")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.contains("codex")
    }
}

enum ChatPermissionMode: String, CaseIterable, Codable, Identifiable, Equatable {
    case ask
    case autoEdit
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "询问权限"
        case .autoEdit: "自动编辑"
        case .fullAccess: "完全访问权限"
        }
    }

    var shortTitle: String {
        switch self {
        case .ask: "询问"
        case .autoEdit: "自动"
        case .fullAccess: "完全"
        }
    }

    var claudePermissionMode: String {
        switch self {
        case .ask: "default"
        case .autoEdit: "acceptEdits"
        case .fullAccess: "bypassPermissions"
        }
    }

    var codexApprovalPolicy: String {
        switch self {
        case .ask: "on-request"
        case .autoEdit: "on-failure"
        case .fullAccess: "never"
        }
    }

    var codexSandbox: String {
        switch self {
        case .ask, .autoEdit: "workspace-write"
        case .fullAccess: "danger-full-access"
        }
    }
}

enum ChatReasoningEffort: String, CaseIterable, Codable, Identifiable, Equatable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    static func options(for cli: CLIType) -> [ChatReasoningEffort] {
        options(for: cli, modelID: ChatModelCatalog.defaultModelID(for: cli))
    }

    static func options(for cli: CLIType, modelID: String) -> [ChatReasoningEffort] {
        switch ChatModelCatalog.reasoningFamily(for: modelID, cli: cli) {
        case .claude:
            return [.low, .medium, .high, .xhigh, .max]
        case .gpt:
            return [.low, .medium, .high, .xhigh]
        }
    }

    func title(for cli: CLIType) -> String {
        title(for: cli, modelID: ChatModelCatalog.defaultModelID(for: cli))
    }

    func title(for cli: CLIType, modelID: String) -> String {
        switch ChatModelCatalog.reasoningFamily(for: modelID, cli: cli) {
        case .claude:
            return rawValue
        case .gpt:
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            case .xhigh: return "超高"
            case .max: return "最高"
            }
        }
    }

    func menuTitle(for cli: CLIType) -> String {
        menuTitle(for: cli, modelID: ChatModelCatalog.defaultModelID(for: cli))
    }

    func menuTitle(for cli: CLIType, modelID: String) -> String {
        title(for: cli, modelID: modelID)
    }

    var claudeArgument: String {
        rawValue
    }

    var codexConfigValue: String {
        self == .max ? ChatReasoningEffort.xhigh.rawValue : rawValue
    }
}

enum ChatPermissionDecision: String, Codable, Equatable {
    case deny
    case allow
    case allowForSession

    var isAllowed: Bool {
        switch self {
        case .deny: false
        case .allow, .allowForSession: true
        }
    }

    var statusText: String {
        switch self {
        case .deny: "denied"
        case .allow: "allowed"
        case .allowForSession: "session allowed"
        }
    }

    var displayText: String {
        switch self {
        case .deny: "已拒绝"
        case .allow: "已允许"
        case .allowForSession: "本会话已允许"
        }
    }
}

typealias ChatMessageKind = ChatCore.ChatMessageKind
typealias ChatInteractiveMode = ChatCore.ChatInteractiveMode
typealias ChatInteractiveStatus = ChatCore.ChatInteractiveStatus
typealias ChatInteractiveOption = ChatCore.ChatInteractiveOption
typealias ChatInteractiveRequest = ChatCore.ChatInteractiveRequest
typealias ChatInteractiveResponse = ChatCore.ChatInteractiveResponse

enum ChatRunStatus: String, Codable, Equatable {
    case idle
    case starting
    case streaming
    case waitingPermission
    case waitingInput
    case stopping
    case completed
    case failed
    case unsupportedVersion

    var isRunning: Bool {
        switch self {
        case .starting, .streaming, .waitingPermission, .waitingInput, .stopping: true
        case .idle, .completed, .failed, .unsupportedVersion: false
        }
    }
}

struct QueuedChatRequest: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let displayText: String
    let appendRuleText: String?
    let attachments: [ChatMessageAttachment]
    let project: ProjectItem
    let cli: CLIType
    let modelID: String
    let contextModelID: String?
    let contextWindow: Int?
    let permissionMode: ChatPermissionMode
    let reasoningEffort: ChatReasoningEffort
    let sessionMode: SessionMode
    let resumeSessionID: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        displayText: String? = nil,
        appendRuleText: String? = nil,
        attachments: [ChatMessageAttachment] = [],
        project: ProjectItem,
        cli: CLIType,
        modelID: String,
        contextModelID: String?,
        contextWindow: Int? = nil,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort,
        sessionMode: SessionMode,
        resumeSessionID: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.displayText = displayText ?? text
        self.appendRuleText = appendRuleText?.nonEmptyTrimmed
        self.attachments = attachments
        self.project = project
        self.cli = cli.visibleValue
        self.modelID = modelID
        self.contextModelID = contextModelID
        self.contextWindow = contextWindow
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.sessionMode = sessionMode
        self.resumeSessionID = resumeSessionID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case displayText
        case appendRuleText
        case attachments
        case project
        case cli
        case modelID
        case contextModelID
        case contextWindow
        case permissionMode
        case reasoningEffort
        case sessionMode
        case resumeSessionID
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try values.decode(String.self, forKey: .text)
        displayText = try values.decodeIfPresent(String.self, forKey: .displayText) ?? text
        appendRuleText = try values.decodeIfPresent(String.self, forKey: .appendRuleText)?.nonEmptyTrimmed
        attachments = try values.decodeIfPresent([ChatMessageAttachment].self, forKey: .attachments) ?? []
        project = try values.decode(ProjectItem.self, forKey: .project)
        cli = (try values.decode(CLIType.self, forKey: .cli)).visibleValue
        modelID = try values.decode(String.self, forKey: .modelID)
        contextModelID = try values.decodeIfPresent(String.self, forKey: .contextModelID)
        contextWindow = try values.decodeIfPresent(Int.self, forKey: .contextWindow)
        permissionMode = try values.decode(ChatPermissionMode.self, forKey: .permissionMode)
        reasoningEffort = try values.decodeIfPresent(ChatReasoningEffort.self, forKey: .reasoningEffort) ?? .high
        sessionMode = try values.decode(SessionMode.self, forKey: .sessionMode)
        resumeSessionID = try values.decodeIfPresent(String.self, forKey: .resumeSessionID)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ChatSessionActivity: Equatable {
    var status: ChatRunStatus
    var statusText: String
    var queuedCount: Int
    var lastCompletedAt: Date?
    var activeRunStartedAt: Date?
}

typealias ChatMessage = ChatCore.ChatMessage

typealias ChatMessageAttachment = ChatCore.ChatMessageAttachment
typealias ChatMessageAttachmentKind = ChatCore.ChatMessageAttachmentKind

struct ChatSessionRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var cli: CLIType
    var projectName: String
    var projectPath: String
    var title: String
    var modelID: String
    var permissionMode: ChatPermissionMode
    var reasoningEffort: ChatReasoningEffort
    var externalSessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var runStatus: ChatRunStatus
    var statusText: String
    var queuedRequests: [QueuedChatRequest]
    var lastCompletedAt: Date?
    var activeRunStartedAt: Date?
    var activeRunRequest: QueuedChatRequest?

    init(
        id: UUID = UUID(),
        cli: CLIType,
        projectName: String,
        projectPath: String,
        title: String,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort = .high,
        externalSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        runStatus: ChatRunStatus = .idle,
        statusText: String = "就绪",
        queuedRequests: [QueuedChatRequest] = [],
        lastCompletedAt: Date? = nil,
        activeRunStartedAt: Date? = nil,
        activeRunRequest: QueuedChatRequest? = nil
    ) {
        self.id = id
        self.cli = cli.visibleValue
        self.projectName = projectName
        self.projectPath = projectPath
        self.title = title
        self.modelID = modelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.externalSessionID = externalSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runStatus = runStatus
        self.statusText = statusText
        self.queuedRequests = queuedRequests
        self.lastCompletedAt = lastCompletedAt
        self.activeRunStartedAt = activeRunStartedAt
        self.activeRunRequest = activeRunRequest
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cli
        case projectName
        case projectPath
        case title
        case modelID
        case permissionMode
        case reasoningEffort
        case externalSessionID
        case createdAt
        case updatedAt
        case runStatus
        case statusText
        case queuedRequests
        case lastCompletedAt
        case activeRunStartedAt
        case activeRunRequest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cli = try container.decode(CLIType.self, forKey: .cli).visibleValue
        projectName = try container.decode(String.self, forKey: .projectName)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        title = try container.decode(String.self, forKey: .title)
        modelID = try container.decode(String.self, forKey: .modelID)
        permissionMode = try container.decode(ChatPermissionMode.self, forKey: .permissionMode)
        reasoningEffort = try container.decodeIfPresent(ChatReasoningEffort.self, forKey: .reasoningEffort) ?? .high
        externalSessionID = try container.decodeIfPresent(String.self, forKey: .externalSessionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        runStatus = try container.decodeIfPresent(ChatRunStatus.self, forKey: .runStatus) ?? .idle
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? "就绪"
        queuedRequests = try container.decodeIfPresent([QueuedChatRequest].self, forKey: .queuedRequests) ?? []
        lastCompletedAt = try container.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        activeRunStartedAt = try container.decodeIfPresent(Date.self, forKey: .activeRunStartedAt)
        activeRunRequest = try container.decodeIfPresent(QueuedChatRequest.self, forKey: .activeRunRequest)
        if runStatus.isRunning || activeRunRequest != nil {
            runStatus = .failed
            statusText = "上次运行已中断"
            activeRunStartedAt = nil
            activeRunRequest = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cli, forKey: .cli)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(title, forKey: .title)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(externalSessionID, forKey: .externalSessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(runStatus, forKey: .runStatus)
        try container.encode(statusText, forKey: .statusText)
        try container.encode(queuedRequests, forKey: .queuedRequests)
        try container.encodeIfPresent(lastCompletedAt, forKey: .lastCompletedAt)
        try container.encodeIfPresent(activeRunStartedAt, forKey: .activeRunStartedAt)
        try container.encodeIfPresent(activeRunRequest, forKey: .activeRunRequest)
    }
}

struct ChatRunOptions: Equatable {
    var cli: CLIType
    var executablePath: String
    var projectPath: String
    var modelID: String
    var permissionMode: ChatPermissionMode
    var reasoningEffort: ChatReasoningEffort
    var sessionMode: SessionMode
    var resumeSessionID: String?
    var supportsStreamJSONInput: Bool
}

enum ChatBackendEvent: Equatable {
    case appendMessage(kind: ChatMessageKind, title: String, subtitle: String, text: String, status: String, requestID: String?)
    case appendDelta(kind: ChatMessageKind, title: String, subtitle: String, text: String, status: String, requestID: String?)
    case finishStreamingMessage(kind: ChatMessageKind, requestID: String?, status: String)
    case updateStreamingStatus(String)
    case backendActivity(String)
    case sessionID(String)
    case permissionRequest(id: String, title: String, text: String)
    case interactiveRequest(ChatInteractiveRequest)
    case tokenUsage(used: Int, total: Int, output: Int?)
    case finished
    case failed(String)
}
