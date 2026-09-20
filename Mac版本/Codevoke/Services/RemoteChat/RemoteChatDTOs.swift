import Foundation

struct RemoteHealthDTO: Codable {
    let ok: Bool
    let name: String
    let version: Int
    let bindLAN: Bool
    let port: UInt16
    let authRequired: Bool
}

struct RemoteProjectDTO: Codable {
    let id: UUID
    let name: String
    let path: String
    let defaultCLI: String
    let createdAt: Date
    let updatedAt: Date
    let lastOpenedAt: Date?

    init(project: ProjectItem) {
        id = project.id
        name = project.name
        path = project.path
        defaultCLI = project.defaultCLI.rawValue
        createdAt = project.createdAt
        updatedAt = project.updatedAt
        lastOpenedAt = project.lastOpenedAt
    }
}

struct RemoteModelDTO: Codable {
    let id: String
    let title: String
    let cli: String
    let isDefault: Bool

    init(option: ChatModelOption, defaultModelID: String) {
        id = option.id
        title = option.title
        cli = option.cli.rawValue
        isDefault = option.id == defaultModelID
    }
}

struct RemoteSessionDTO: Codable {
    let id: UUID
    let cli: String
    let projectName: String
    let projectPath: String
    let title: String
    let modelID: String
    let runStatus: String
    let statusText: String
    let createdAt: Date
    let updatedAt: Date
    let lastCompletedAt: Date?

    init(session: ChatSessionRecord) {
        id = session.id
        cli = session.cli.rawValue
        projectName = session.projectName
        projectPath = session.projectPath
        title = session.title
        modelID = session.modelID
        runStatus = session.runStatus.rawValue
        statusText = session.statusText
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        lastCompletedAt = session.lastCompletedAt
    }
}

struct RemoteProjectFileEntryDTO: Codable {
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

struct RemoteProjectFilesDTO: Codable {
    let projectId: UUID
    let path: String
    let parentPath: String?
    let entries: [RemoteProjectFileEntryDTO]
}

struct RemoteMessageDTO: Codable {
    let id: UUID
    let sessionID: UUID
    let kind: String
    let title: String
    let subtitle: String
    let text: String
    let status: String
    let createdAt: Date
    let parentUserMessageID: UUID?
    let requestID: String?
    let isStreaming: Bool
    let outputTokenCount: Int?
    let interactiveRequest: ChatInteractiveRequest?

    init(message: ChatMessage) {
        id = message.id
        sessionID = message.sessionID ?? UUID()
        kind = message.kind.rawValue
        title = message.title
        subtitle = message.subtitle
        text = message.text
        status = message.status
        createdAt = message.createdAt
        parentUserMessageID = message.parentUserMessageID
        requestID = message.requestID
        isStreaming = message.isStreaming
        outputTokenCount = message.outputTokenCount
        interactiveRequest = message.interactiveRequest
    }
}

struct RemoteMessagePageDTO: Codable {
    let messages: [RemoteMessageDTO]
    let nextBeforeIndex: Int?
    let hasMore: Bool
    let totalCount: Int

    init(page: ChatMessagePage) {
        messages = page.messages.map(RemoteMessageDTO.init(message:))
        nextBeforeIndex = page.nextBeforeIndex
        hasMore = page.hasMore
        totalCount = page.totalCount
    }
}

struct RemoteStreamEventPageDTO: Codable {
    let events: [RemoteChatStreamEvent]
    let nextCursor: Int?
    let hasMore: Bool
}

struct RemoteAttachmentUploadRequestDTO: Codable {
    let filename: String
    let contentBase64: String
}

struct RemoteAttachmentUploadResponseDTO: Codable {
    let filename: String
    let path: String
}

struct RemoteClaudeRelayProfileDTO: Codable, Identifiable {
    var id: UUID
    var name: String
    var baseURL: String
    var authToken: String
    var authTokenSet: Bool
    var model: String
    var haikuModel: String
    var sonnetModel: String
    var opusModel: String
    var httpProxy: String
    var httpsProxy: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case authToken
        case authTokenSet
        case model
        case haikuModel
        case sonnetModel
        case opusModel
        case httpProxy
        case httpsProxy
        case createdAt
        case updatedAt
    }

    init(profile: ClaudeRelayProfile, includeSecrets: Bool = true) {
        id = profile.id
        name = profile.name
        baseURL = profile.baseURL
        authToken = includeSecrets ? profile.authToken : ""
        authTokenSet = !profile.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        model = profile.model
        haikuModel = profile.haikuModel
        sonnetModel = profile.sonnetModel
        opusModel = profile.opusModel
        httpProxy = profile.httpProxy
        httpsProxy = profile.httpsProxy
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        authTokenSet = try container.decodeIfPresent(Bool.self, forKey: .authTokenSet)
            ?? !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        model = try container.decode(String.self, forKey: .model)
        haikuModel = try container.decode(String.self, forKey: .haikuModel)
        sonnetModel = try container.decode(String.self, forKey: .sonnetModel)
        opusModel = try container.decode(String.self, forKey: .opusModel)
        httpProxy = try container.decode(String.self, forKey: .httpProxy)
        httpsProxy = try container.decode(String.self, forKey: .httpsProxy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var profile: ClaudeRelayProfile {
        ClaudeRelayProfile(
            id: id,
            name: name,
            baseURL: baseURL,
            authToken: authToken,
            model: model,
            haikuModel: haikuModel,
            sonnetModel: sonnetModel,
            opusModel: opusModel,
            httpProxy: httpProxy,
            httpsProxy: httpsProxy,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct RemoteConfigProfilesDTO: Codable {
    var activeClaudeRelayProfileID: UUID?
    var claudeRelayProfiles: [RemoteClaudeRelayProfileDTO]

    init(collection: ConfigProfileCollection, includeSecrets: Bool = false) {
        activeClaudeRelayProfileID = collection.activeClaudeRelayProfileID
        claudeRelayProfiles = collection.claudeRelayProfiles.map {
            RemoteClaudeRelayProfileDTO(profile: $0, includeSecrets: includeSecrets)
        }
    }
}

struct RemoteClaudeRelayProfileSaveRequestDTO: Codable {
    var profile: RemoteClaudeRelayProfileDTO
    var activate: Bool
}

struct RemoteClaudeRelayProfileActivateRequestDTO: Codable {
    var id: UUID
}

struct RemoteClaudeModelFetchRequestDTO: Codable {
    var baseURL: String
    var authToken: String
}

struct RemoteClaudeModelFetchResponseDTO: Codable {
    var models: [String]
}

struct RemoteErrorDTO: Codable {
    let error: String
    let message: String
}
