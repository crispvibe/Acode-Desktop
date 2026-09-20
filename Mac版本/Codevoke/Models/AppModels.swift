import Foundation

enum CLIType: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case cursor
    case gemini
    case qwen
    case copilot
    case kimi
    case agy
    case kiro
    case dsh
    case custom

    static let visibleCases: [CLIType] = [.claude, .codex, .cursor, .gemini, .qwen, .copilot, .kimi, .agy, .kiro, .dsh]

    var id: String { rawValue }

    var visibleValue: CLIType {
        switch self {
        case .custom: .claude
        default: self
        }
    }

    var displayName: String {
        switch visibleValue {
        case .claude, .custom: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .gemini: "Gemini"
        case .qwen: "Qwen Code"
        case .copilot: "Copilot"
        case .kimi: "Kimi"
        case .agy: "Antigravity"
        case .kiro: "Kiro"
        case .dsh: "DeepSeek Harness"
        }
    }

    var executable: String {
        switch visibleValue {
        case .claude, .custom: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .gemini: "gemini"
        case .qwen: "qwen"
        case .copilot: "copilot"
        case .kimi: "kimi"
        case .agy: "agy"
        case .kiro: "kiro-cli"
        case .dsh: "dsh"
        }
    }

    /// 探测时按顺序尝试的可执行文件名（Kiro 发行版同时存在 kiro-cli / kiro 两种命名）。
    var executableCandidates: [String] {
        switch visibleValue {
        case .kiro: ["kiro-cli", "kiro"]
        default: [executable]
        }
    }
}

enum TerminalType: String, CaseIterable, Codable, Identifiable {
    case terminal
    case iTerm2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: "终端"
        case .iTerm2: "iTerm2"
        }
    }
}

enum SessionMode: String, CaseIterable, Codable, Identifiable {
    case newSession
    case continueLast
    case resume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "新建会话"
        case .continueLast: "继续上次"
        case .resume: "恢复历史"
        }
    }

    var shortTitle: String {
        switch self {
        case .newSession: "新建"
        case .continueLast: "继续"
        case .resume: "恢复"
        }
    }
}

struct ProjectItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var bookmarkData: Data
    var defaultCLI: CLIType
    var defaultTerminal: TerminalType
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var isPendingCreation: Bool = false

    var id: String { url.path }
}

struct ImagePreviewDescriptor: Equatable {
    let url: URL
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let modifiedAt: Date?
    let bookmarkData: Data?
}

enum EditorPreview: Equatable {
    case image(ImagePreviewDescriptor)
    case pdf(Data, isValid: Bool)

    var byteCount: Int {
        switch self {
        case .image(let descriptor): descriptor.byteCount
        case .pdf(let data, _): data.count
        }
    }

    var label: String {
        switch self {
        case .image: "图片预览"
        case .pdf: "PDF 预览"
        }
    }
}

struct EditorTab: Identifiable, Equatable {
    var id: UUID
    var projectId: UUID
    var url: URL
    var title: String
    var text: String
    var savedText: String
    var isDirty: Bool
    var isExternal: Bool
    var openedAt: Date
    var lastActiveAt: Date
    var modifiedAt: Date
    var preview: EditorPreview?
    var isLoadingContent: Bool = false
    var loadErrorMessage: String?

    var isTextEditable: Bool { preview == nil && loadErrorMessage == nil }

    var byteCount: Int { preview?.byteCount ?? text.utf8.count }
}

struct EditorJumpRequest: Identifiable, Equatable {
    let id: UUID
    let tabID: UUID
    let line: Int
    let column: Int

    init(tabID: UUID, line: Int, column: Int = 1) {
        self.id = UUID()
        self.tabID = tabID
        self.line = max(1, line)
        self.column = max(1, column)
    }
}

struct LaunchRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var projectId: UUID
    var projectName: String
    var projectPath: String
    var cliType: CLIType
    var mode: SessionMode
    var sessionId: String?
    var title: String
    var command: String
    var terminal: TerminalType
    var source: String
    var createdAt: Date
    var launchedAt: Date?
}

struct CLIHistorySession: Identifiable, Equatable {
    static let draftSessionId = "__draft__"

    var id: String { "\(cli.rawValue):\(sessionId)" }
    let cli: CLIType
    let sessionId: String
    let title: String
    let projectPath: String?
    let storageKey: String?
    let storagePath: String?
    let createdAt: Date?
    let updatedAt: Date?

    var isDraft: Bool { sessionId == Self.draftSessionId }

    var sourceLabel: String {
        "\(cli.displayName) 历史"
    }

    var relativeUpdatedText: String {
        guard let updatedAt else { return "" }
        let interval = Date().timeIntervalSince(updatedAt)
        if interval < 60 * 60 { return "刚刚" }
        if interval < 60 * 60 * 24 { return "\(max(1, Int(interval / 3600))) 时" }
        if interval < 60 * 60 * 24 * 30 { return "\(max(1, Int(interval / 86400))) 天" }
        return "\(max(1, Int(interval / 2_592_000))) 月"
    }
}

struct AuthorizedFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var bookmarkData: Data
    var createdAt: Date
}

struct AppSettings: Codable, Equatable {
    var defaultTerminal: TerminalType
    var defaultCLI: CLIType
    var chatCLI: CLIType
    var chatPermissionMode: ChatPermissionMode
    var selectedClaudeModelID: String
    var selectedCodexModelID: String
    var selectedClaudeReasoningEffort: ChatReasoningEffort
    var selectedCodexReasoningEffort: ChatReasoningEffort
    var showCommandPreview: Bool
    var appendRuleEnabled: Bool
    var appendRuleText: String
    var ignoredFolders: [String]
    var apiBaseURL: String
    var apiKey: String
    var authorizedFolders: [AuthorizedFolder]
    var hasSeenFolderPermissionOnboarding: Bool
    var lastSelectedProjectPath: String?
    var lastSelectedCLIHistoryID: String?
    // Remote chat server (previously stored in UserDefaults; migrated on first launch).
    var remoteChatServerEnabled: Bool
    var remoteChatServerPort: Int
    var remoteChatServerBindLAN: Bool
    // Custom model IDs (previously stored in UserDefaults).
    var customClaudeModelIDs: [String]
    var customCodexModelIDs: [String]
    /// 非 Claude/Codex CLI 的模型/思考强度记忆，按 CLIType.rawValue 分桶，
    /// 避免不同第三方 CLI 互相覆盖上次选择。
    var selectedModelIDsByCLI: [String: String]
    var selectedReasoningEffortsByCLI: [String: ChatReasoningEffort]
    // Chat panel width (previously stored via @AppStorage).
    var chatPanelWidth: Double
    var sidebarProjectSectionHeight: Double
    /// Bumped whenever we add new fields whose defaults need to be migrated from
    /// UserDefaults. AppState consults this on launch to run migration once.
    var settingsSchemaVersion: Int

    static let `default` = AppSettings(
        defaultTerminal: .terminal,
        defaultCLI: .claude,
        chatCLI: .claude,
        chatPermissionMode: .autoEdit,
        selectedClaudeModelID: ChatModelCatalog.defaultClaudeModelID,
        selectedCodexModelID: ChatModelCatalog.defaultCodexModelID,
        selectedClaudeReasoningEffort: .high,
        selectedCodexReasoningEffort: .high,
        showCommandPreview: true,
        appendRuleEnabled: false,
        appendRuleText: "",
        ignoredFolders: FileTreeScanner.defaultIgnoredNames.sorted(),
        apiBaseURL: "",
        apiKey: "",
        authorizedFolders: [],
        hasSeenFolderPermissionOnboarding: false,
        lastSelectedProjectPath: nil,
        lastSelectedCLIHistoryID: nil,
        remoteChatServerEnabled: true,
        remoteChatServerPort: 18765,
        remoteChatServerBindLAN: true,
        customClaudeModelIDs: [],
        customCodexModelIDs: [],
        chatPanelWidth: 420,
        sidebarProjectSectionHeight: 252,
        settingsSchemaVersion: 0
    )

    init(
        defaultTerminal: TerminalType,
        defaultCLI: CLIType,
        chatCLI: CLIType,
        chatPermissionMode: ChatPermissionMode,
        selectedClaudeModelID: String,
        selectedCodexModelID: String,
        selectedClaudeReasoningEffort: ChatReasoningEffort = .high,
        selectedCodexReasoningEffort: ChatReasoningEffort = .high,
        showCommandPreview: Bool,
        appendRuleEnabled: Bool,
        appendRuleText: String,
        ignoredFolders: [String],
        apiBaseURL: String,
        apiKey: String,
        authorizedFolders: [AuthorizedFolder] = [],
        hasSeenFolderPermissionOnboarding: Bool = false,
        lastSelectedProjectPath: String?,
        lastSelectedCLIHistoryID: String?,
        remoteChatServerEnabled: Bool = true,
        remoteChatServerPort: Int = 18765,
        remoteChatServerBindLAN: Bool = true,
        customClaudeModelIDs: [String] = [],
        customCodexModelIDs: [String] = [],
        selectedModelIDsByCLI: [String: String] = [:],
        selectedReasoningEffortsByCLI: [String: ChatReasoningEffort] = [:],
        chatPanelWidth: Double = 420,
        sidebarProjectSectionHeight: Double = 252,
        settingsSchemaVersion: Int = 0
    ) {
        self.defaultTerminal = defaultTerminal
        self.defaultCLI = defaultCLI
        self.chatCLI = chatCLI.visibleValue
        self.chatPermissionMode = chatPermissionMode
        self.selectedClaudeModelID = selectedClaudeModelID
        self.selectedCodexModelID = selectedCodexModelID
        self.selectedClaudeReasoningEffort = selectedClaudeReasoningEffort
        self.selectedCodexReasoningEffort = selectedCodexReasoningEffort
        self.showCommandPreview = showCommandPreview
        self.appendRuleEnabled = appendRuleEnabled
        self.appendRuleText = appendRuleText
        self.ignoredFolders = ignoredFolders
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.authorizedFolders = authorizedFolders
        self.hasSeenFolderPermissionOnboarding = hasSeenFolderPermissionOnboarding
        self.lastSelectedProjectPath = lastSelectedProjectPath
        self.lastSelectedCLIHistoryID = lastSelectedCLIHistoryID
        self.remoteChatServerEnabled = remoteChatServerEnabled
        self.remoteChatServerPort = remoteChatServerPort
        self.remoteChatServerBindLAN = remoteChatServerBindLAN
        self.customClaudeModelIDs = customClaudeModelIDs
        self.customCodexModelIDs = customCodexModelIDs
        self.selectedModelIDsByCLI = selectedModelIDsByCLI
        self.selectedReasoningEffortsByCLI = selectedReasoningEffortsByCLI
        self.chatPanelWidth = chatPanelWidth
        self.sidebarProjectSectionHeight = sidebarProjectSectionHeight
        self.settingsSchemaVersion = settingsSchemaVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultTerminal = try values.decodeIfPresent(TerminalType.self, forKey: .defaultTerminal) ?? .terminal
        defaultCLI = try values.decodeIfPresent(CLIType.self, forKey: .defaultCLI) ?? .claude
        chatCLI = (try values.decodeIfPresent(CLIType.self, forKey: .chatCLI) ?? defaultCLI).visibleValue
        chatPermissionMode = try values.decodeIfPresent(ChatPermissionMode.self, forKey: .chatPermissionMode) ?? .autoEdit
        selectedClaudeModelID = try values.decodeIfPresent(String.self, forKey: .selectedClaudeModelID) ?? ChatModelCatalog.defaultClaudeModelID
        selectedCodexModelID = try values.decodeIfPresent(String.self, forKey: .selectedCodexModelID) ?? ChatModelCatalog.defaultCodexModelID
        selectedClaudeReasoningEffort = try values.decodeIfPresent(ChatReasoningEffort.self, forKey: .selectedClaudeReasoningEffort) ?? .high
        selectedCodexReasoningEffort = try values.decodeIfPresent(ChatReasoningEffort.self, forKey: .selectedCodexReasoningEffort) ?? .high
        showCommandPreview = try values.decodeIfPresent(Bool.self, forKey: .showCommandPreview) ?? true
        appendRuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .appendRuleEnabled) ?? false
        appendRuleText = try values.decodeIfPresent(String.self, forKey: .appendRuleText) ?? ""
        ignoredFolders = try values.decodeIfPresent([String].self, forKey: .ignoredFolders) ?? FileTreeScanner.defaultIgnoredNames.sorted()
        apiBaseURL = try values.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? ""
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        authorizedFolders = try values.decodeIfPresent([AuthorizedFolder].self, forKey: .authorizedFolders) ?? []
        hasSeenFolderPermissionOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasSeenFolderPermissionOnboarding) ?? false
        lastSelectedProjectPath = try values.decodeIfPresent(String.self, forKey: .lastSelectedProjectPath)
        lastSelectedCLIHistoryID = try values.decodeIfPresent(String.self, forKey: .lastSelectedCLIHistoryID)
        remoteChatServerEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteChatServerEnabled) ?? true
        remoteChatServerPort = try values.decodeIfPresent(Int.self, forKey: .remoteChatServerPort) ?? 18765
        remoteChatServerBindLAN = try values.decodeIfPresent(Bool.self, forKey: .remoteChatServerBindLAN) ?? true
        customClaudeModelIDs = try values.decodeIfPresent([String].self, forKey: .customClaudeModelIDs) ?? []
        customCodexModelIDs = try values.decodeIfPresent([String].self, forKey: .customCodexModelIDs) ?? []
        selectedModelIDsByCLI = try values.decodeIfPresent([String: String].self, forKey: .selectedModelIDsByCLI) ?? [:]
        selectedReasoningEffortsByCLI = try values.decodeIfPresent([String: ChatReasoningEffort].self, forKey: .selectedReasoningEffortsByCLI) ?? [:]
        chatPanelWidth = try values.decodeIfPresent(Double.self, forKey: .chatPanelWidth) ?? 420
        sidebarProjectSectionHeight = try values.decodeIfPresent(Double.self, forKey: .sidebarProjectSectionHeight) ?? 252
        settingsSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .settingsSchemaVersion) ?? 0
    }
}

struct ClaudeRelayProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var authToken: String
    var model: String
    var haikuModel: String
    var sonnetModel: String
    var opusModel: String
    var httpProxy: String
    var httpsProxy: String
    var createdAt: Date
    var updatedAt: Date
}

struct CodexConfigProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var authMode: String
    var model: String
    var baseURL: String
    var apiKey: String
    var wireApi: String
    var createdAt: Date
    var updatedAt: Date
}

struct ConfigProfileCollection: Codable, Equatable, Sendable {
    var activeClaudeRelayProfileID: UUID?
    var activeCodexProfileID: UUID?
    var claudeRelayProfiles: [ClaudeRelayProfile]
    var codexProfiles: [CodexConfigProfile]

    static let empty = ConfigProfileCollection(
        activeClaudeRelayProfileID: nil,
        activeCodexProfileID: nil,
        claudeRelayProfiles: [],
        codexProfiles: []
    )
}
