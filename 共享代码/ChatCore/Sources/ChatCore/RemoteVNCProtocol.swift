// Remote Chat VNC Protocol — authoritative DTO contract.
//
// This file is the single source of truth for wire-level types shared between
// `RemoteChatServer` (Mac) and remote thin clients (iOS / Windows). Spec source
// is `docs/remote-chat-vnc-refactor.md` §4. Do not deviate from field names,
// case spellings, or JSON shape — both ends decode the same blobs.
//
// Encoding strategy (matches the rest of the wire surface):
//   - `JSONEncoder`/`JSONDecoder` with `.dateEncodingStrategy = .iso8601`.
//   - Default key strategy (no `.convertToSnakeCase`).
//
// All types are `Codable` + `Equatable` so test fixtures and SwiftUI bindings
// can compare snapshots cheaply.

import Foundation

// MARK: - Snapshot (server → client)

/// Authoritative description of one panel (== one chat session view) at a
/// specific point in time. Each connection receives snapshots for the session
/// it is currently focused on; switching focus triggers a fresh snapshot push.
public struct PanelStateSnapshot: Codable, Equatable {
    /// Monotonic per-session revision number. Always `>= 1`.
    public let revision: Int

    /// Identifier of the panel this snapshot describes. `nil` means "the
    /// not-yet-persisted draft session for this connection's selected
    /// project".
    public let sessionId: UUID?

    // ---- Catalog (small, push as part of every snapshot) ----
    public let projects: [PanelProjectDTO]
    public let models: [PanelModelDTO]
    public let sessions: [PanelSessionDTO]

    // ---- Current session view ----
    public let currentSessionId: UUID?
    public let messages: [ChatMessage]
    public let queuedRequests: [PanelQueuedRequestDTO]
    public let streamingTexts: [PanelStreamingTextDTO]

    // ---- Runtime / run flags ----
    public let status: String           // `ChatRunStatus.rawValue`
    public let statusText: String
    public let isAwaitingFirstModelOutput: Bool
    public let isLoadingHistory: Bool
    public let tokensUsed: Int
    public let tokensTotal: Int
    public let activeRunStartedAt: Date?
    public let isMirroringRemoteSession: Bool

    // ---- Composer (server-authoritative for non-`text` fields) ----
    public let composer: PanelComposerDTO

    // ---- Capability map (per CLI) ----
    public let capabilities: [PanelCapabilityDTO]

    public init(
        revision: Int,
        sessionId: UUID?,
        projects: [PanelProjectDTO],
        models: [PanelModelDTO],
        sessions: [PanelSessionDTO],
        currentSessionId: UUID?,
        messages: [ChatMessage],
        queuedRequests: [PanelQueuedRequestDTO],
        streamingTexts: [PanelStreamingTextDTO],
        status: String,
        statusText: String,
        isAwaitingFirstModelOutput: Bool,
        isLoadingHistory: Bool,
        tokensUsed: Int,
        tokensTotal: Int,
        activeRunStartedAt: Date?,
        isMirroringRemoteSession: Bool,
        composer: PanelComposerDTO,
        capabilities: [PanelCapabilityDTO]
    ) {
        self.revision = revision
        self.sessionId = sessionId
        self.projects = projects
        self.models = models
        self.sessions = sessions
        self.currentSessionId = currentSessionId
        self.messages = messages
        self.queuedRequests = queuedRequests
        self.streamingTexts = streamingTexts
        self.status = status
        self.statusText = statusText
        self.isAwaitingFirstModelOutput = isAwaitingFirstModelOutput
        self.isLoadingHistory = isLoadingHistory
        self.tokensUsed = tokensUsed
        self.tokensTotal = tokensTotal
        self.activeRunStartedAt = activeRunStartedAt
        self.isMirroringRemoteSession = isMirroringRemoteSession
        self.composer = composer
        self.capabilities = capabilities
    }
}

public struct PanelProjectDTO: Codable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let defaultCLI: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastOpenedAt: Date?

    public init(
        id: UUID,
        name: String,
        path: String,
        defaultCLI: String,
        createdAt: Date,
        updatedAt: Date,
        lastOpenedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultCLI = defaultCLI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct PanelModelDTO: Codable, Equatable {
    public let id: String
    public let title: String
    public let cli: String
    public let isDefault: Bool

    public init(id: String, title: String, cli: String, isDefault: Bool) {
        self.id = id
        self.title = title
        self.cli = cli
        self.isDefault = isDefault
    }
}

public struct PanelSessionDTO: Codable, Equatable {
    public let id: UUID
    public let cli: String
    public let projectId: UUID?
    public let projectName: String
    public let projectPath: String
    public let title: String
    public let modelID: String
    public let runStatus: String
    public let statusText: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastCompletedAt: Date?
    public let queuedCount: Int

    public init(
        id: UUID,
        cli: String,
        projectId: UUID?,
        projectName: String,
        projectPath: String,
        title: String,
        modelID: String,
        runStatus: String,
        statusText: String,
        createdAt: Date,
        updatedAt: Date,
        lastCompletedAt: Date?,
        queuedCount: Int
    ) {
        self.id = id
        self.cli = cli
        self.projectId = projectId
        self.projectName = projectName
        self.projectPath = projectPath
        self.title = title
        self.modelID = modelID
        self.runStatus = runStatus
        self.statusText = statusText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCompletedAt = lastCompletedAt
        self.queuedCount = queuedCount
    }
}

public enum PanelSessionFilters {
    public static func sessions(_ sessions: [PanelSessionDTO], forSelectedProjectId projectId: UUID?) -> [PanelSessionDTO] {
        guard let projectId else { return sessions }
        return sessions.filter { $0.projectId == projectId }
    }
}

public struct PanelQueuedRequestDTO: Codable, Equatable {
    public let id: UUID
    public let text: String
    public let displayText: String
    public let cli: String
    public let modelID: String
    public let permissionMode: String
    public let reasoningEffort: String
    public let projectId: UUID
    public let attachments: [ChatMessageAttachment]

    public init(
        id: UUID,
        text: String,
        displayText: String,
        cli: String,
        modelID: String,
        permissionMode: String,
        reasoningEffort: String,
        projectId: UUID,
        attachments: [ChatMessageAttachment]
    ) {
        self.id = id
        self.text = text
        self.displayText = displayText
        self.cli = cli
        self.modelID = modelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.projectId = projectId
        self.attachments = attachments
    }
}

public struct PanelStreamingTextDTO: Codable, Equatable {
    /// Message id this streaming text belongs to.
    public let messageId: UUID
    public let text: String
    public let status: String
    public let requestId: String?

    public init(messageId: UUID, text: String, status: String, requestId: String?) {
        self.messageId = messageId
        self.text = text
        self.status = status
        self.requestId = requestId
    }
}

public struct PanelComposerDTO: Codable, Equatable {
    /// Mac UI's current composer text (read-only mirror for cross-end
    /// observability). iOS does **not** send `composerSet` on every keystroke —
    /// iOS composer typing is local. Other composer fields are
    /// server-authoritative.
    public let text: String
    public let cli: String
    public let modelID: String
    public let contextModelID: String?
    public let permissionMode: String
    public let reasoningEffort: String
    public let attachments: [ChatMessageAttachment]
    public let isEnabled: Bool      // `false` when capabilities check failed
    public let placeholder: String  // server-rendered hint

    public init(
        text: String,
        cli: String,
        modelID: String,
        contextModelID: String?,
        permissionMode: String,
        reasoningEffort: String,
        attachments: [ChatMessageAttachment],
        isEnabled: Bool,
        placeholder: String
    ) {
        self.text = text
        self.cli = cli
        self.modelID = modelID
        self.contextModelID = contextModelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.attachments = attachments
        self.isEnabled = isEnabled
        self.placeholder = placeholder
    }
}

public struct PanelCapabilityDTO: Codable, Equatable {
    public let cli: String
    public let executableAvailable: Bool
    public let supportsStreamJSONInput: Bool
    public let supportsAppServer: Bool
    public let errorMessage: String?

    public init(
        cli: String,
        executableAvailable: Bool,
        supportsStreamJSONInput: Bool,
        supportsAppServer: Bool,
        errorMessage: String?
    ) {
        self.cli = cli
        self.executableAvailable = executableAvailable
        self.supportsStreamJSONInput = supportsStreamJSONInput
        self.supportsAppServer = supportsAppServer
        self.errorMessage = errorMessage
    }
}

// MARK: - Patch (server → client)

/// Field-level optional diff. Each non-nil field replaces the corresponding
/// snapshot field wholesale. Messages, queuedRequests, streamingTexts are
/// **whole arrays** when non-nil, never index-based. Clients MUST be able to
/// render from snapshots alone — patches are an optimisation.
public struct PanelStatePatch: Codable, Equatable {
    public let revision: Int
    /// Patch is applicable iff `client.lastRevision == baseRevision`.
    public let baseRevision: Int
    public let sessionId: UUID?

    public let projects: [PanelProjectDTO]?
    public let models: [PanelModelDTO]?
    public let sessions: [PanelSessionDTO]?
    public let currentSessionId: NullableUUIDWrapper?
    public let messages: [ChatMessage]?
    public let queuedRequests: [PanelQueuedRequestDTO]?
    public let streamingTexts: [PanelStreamingTextDTO]?
    public let status: String?
    public let statusText: String?
    public let isAwaitingFirstModelOutput: Bool?
    public let isLoadingHistory: Bool?
    public let tokensUsed: Int?
    public let tokensTotal: Int?
    public let activeRunStartedAt: NullableDateWrapper?
    public let isMirroringRemoteSession: Bool?
    public let composer: PanelComposerDTO?
    public let capabilities: [PanelCapabilityDTO]?

    public init(
        revision: Int,
        baseRevision: Int,
        sessionId: UUID?,
        projects: [PanelProjectDTO]? = nil,
        models: [PanelModelDTO]? = nil,
        sessions: [PanelSessionDTO]? = nil,
        currentSessionId: NullableUUIDWrapper? = nil,
        messages: [ChatMessage]? = nil,
        queuedRequests: [PanelQueuedRequestDTO]? = nil,
        streamingTexts: [PanelStreamingTextDTO]? = nil,
        status: String? = nil,
        statusText: String? = nil,
        isAwaitingFirstModelOutput: Bool? = nil,
        isLoadingHistory: Bool? = nil,
        tokensUsed: Int? = nil,
        tokensTotal: Int? = nil,
        activeRunStartedAt: NullableDateWrapper? = nil,
        isMirroringRemoteSession: Bool? = nil,
        composer: PanelComposerDTO? = nil,
        capabilities: [PanelCapabilityDTO]? = nil
    ) {
        self.revision = revision
        self.baseRevision = baseRevision
        self.sessionId = sessionId
        self.projects = projects
        self.models = models
        self.sessions = sessions
        self.currentSessionId = currentSessionId
        self.messages = messages
        self.queuedRequests = queuedRequests
        self.streamingTexts = streamingTexts
        self.status = status
        self.statusText = statusText
        self.isAwaitingFirstModelOutput = isAwaitingFirstModelOutput
        self.isLoadingHistory = isLoadingHistory
        self.tokensUsed = tokensUsed
        self.tokensTotal = tokensTotal
        self.activeRunStartedAt = activeRunStartedAt
        self.isMirroringRemoteSession = isMirroringRemoteSession
        self.composer = composer
        self.capabilities = capabilities
    }
}

/// Three-state UUID field: omitted (don't touch), present and `nil`
/// (explicit clear), present and non-nil (replace).
public struct NullableUUIDWrapper: Codable, Equatable {
    public let value: UUID?
    public init(_ value: UUID?) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else {
            value = try? c.decode(UUID.self)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value {
            try c.encode(value)
        } else {
            try c.encodeNil()
        }
    }
}

public struct NullableDateWrapper: Codable, Equatable {
    public let value: Date?
    public init(_ value: Date?) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else {
            value = try? c.decode(Date.self)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value {
            try c.encode(value)
        } else {
            try c.encodeNil()
        }
    }
}

// MARK: - Envelope (server → client)

/// Single wire frame that carries either a snapshot or a patch. Wire shape:
///
/// ```json
/// { "type": "panel_state", "kind": "snapshot", "sessionId": "…", "revision": 42, "snapshot": { … } }
/// { "type": "panel_state", "kind": "patch",    "sessionId": "…", "revision": 43, "patch":    { "baseRevision": 42, "messages": [ … ] } }
/// ```
public struct PanelStateEnvelope: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case snapshot
        case patch
    }

    public let type: String           // always "panel_state"
    public let kind: Kind
    public let sessionId: UUID?
    public let revision: Int

    /// Exactly one of these is non-nil based on `kind`.
    public let snapshot: PanelStateSnapshot?
    public let patch: PanelStatePatch?

    public init(snapshot: PanelStateSnapshot) {
        self.type = "panel_state"
        self.kind = .snapshot
        self.sessionId = snapshot.sessionId
        self.revision = snapshot.revision
        self.snapshot = snapshot
        self.patch = nil
    }

    public init(patch: PanelStatePatch) {
        self.type = "panel_state"
        self.kind = .patch
        self.sessionId = patch.sessionId
        self.revision = patch.revision
        self.snapshot = nil
        self.patch = patch
    }
}

// MARK: - Command (client → server)

public struct Command: Codable, Equatable {
    public let type: String           // always "command"
    public let commandId: UUID
    public let op: Op
    public let sessionId: UUID?       // panel scope, when applicable
    public let args: CommandArgs

    public enum Op: String, Codable, Equatable {
        case focusSession                 // args.sessionId
        case focusProject                 // args.projectId
        case newDraftSession              // args.projectId
        case composerSet                  // args.text
        case composerSetCLI               // args.cli
        case composerSetModel             // args.modelID
        case composerSetPermissionMode    // args.permissionMode
        case composerSetReasoningEffort   // args.reasoningEffort
        case composerAttach               // args.attachment
        case composerRemoveAttach         // args.attachmentId
        case composerSend                 // args.sessionMode?, args.resumeSessionID?, args.appendRuleText?
        case stop                         // args.startQueuedAfterStop?
        case flushQueue
        /// Audit B-P1-2: old semantics of `flushQueue` were "interrupt active
        /// turn + start the next queued request". That was renamed when
        /// `flushQueue` was redefined to actually drop all queued requests.
        /// Clients that want the old behavior should send this op instead.
        case interruptAndStartNext
        case cancelQueued                 // args.requestId
        case editQueued                   // args.requestId, args.text
        case respondPermission            // args.permissionRequestId, args.decision
        case respondInteractive           // args.interactiveRequestId, args.interactiveResponse
        case requestSnapshot
        case refreshCapabilities
    }

    public init(
        type: String = "command",
        commandId: UUID = UUID(),
        op: Op,
        sessionId: UUID? = nil,
        args: CommandArgs = CommandArgs()
    ) {
        self.type = type
        self.commandId = commandId
        self.op = op
        self.sessionId = sessionId
        self.args = args
    }
}

/// Flat arguments bag. Each op uses a subset; unrecognised keys must be
/// ignored on both ends to allow forward compatibility.
public struct CommandArgs: Codable, Equatable {
    public var text: String?
    public var cli: String?
    public var modelID: String?
    public var contextModelID: String?
    public var permissionMode: String?
    public var reasoningEffort: String?
    public var projectId: UUID?
    public var sessionId: UUID?
    public var requestId: String?            // for cancelQueued / editQueued (UUID encoded as string for parity with legacy wire format)
    public var permissionRequestId: String?
    public var decision: String?
    public var interactiveRequestId: String?
    public var interactiveResponse: ChatInteractiveResponse?
    public var attachment: ChatMessageAttachment?
    public var attachmentId: UUID?
    public var sessionMode: String?
    public var resumeSessionID: String?
    public var appendRuleText: String?
    public var startQueuedAfterStop: Bool?
    public var expectedProjectId: UUID?
    public var expectedSessionId: UUID?

    public init(
        text: String? = nil,
        cli: String? = nil,
        modelID: String? = nil,
        contextModelID: String? = nil,
        permissionMode: String? = nil,
        reasoningEffort: String? = nil,
        projectId: UUID? = nil,
        sessionId: UUID? = nil,
        requestId: String? = nil,
        permissionRequestId: String? = nil,
        decision: String? = nil,
        interactiveRequestId: String? = nil,
        interactiveResponse: ChatInteractiveResponse? = nil,
        attachment: ChatMessageAttachment? = nil,
        attachmentId: UUID? = nil,
        sessionMode: String? = nil,
        resumeSessionID: String? = nil,
        appendRuleText: String? = nil,
        startQueuedAfterStop: Bool? = nil,
        expectedProjectId: UUID? = nil,
        expectedSessionId: UUID? = nil
    ) {
        self.text = text
        self.cli = cli
        self.modelID = modelID
        self.contextModelID = contextModelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.projectId = projectId
        self.sessionId = sessionId
        self.requestId = requestId
        self.permissionRequestId = permissionRequestId
        self.decision = decision
        self.interactiveRequestId = interactiveRequestId
        self.interactiveResponse = interactiveResponse
        self.attachment = attachment
        self.attachmentId = attachmentId
        self.sessionMode = sessionMode
        self.resumeSessionID = resumeSessionID
        self.appendRuleText = appendRuleText
        self.startQueuedAfterStop = startQueuedAfterStop
        self.expectedProjectId = expectedProjectId
        self.expectedSessionId = expectedSessionId
    }
}

// MARK: - Ack (server → client)

public struct CommandAck: Codable, Equatable {
    public let type: String          // always "command_ack"
    public let commandId: UUID
    public let status: Status
    public let message: String?
    /// Populated for `newDraftSession` and any op that resolves to a session.
    public let sessionId: UUID?

    public enum Status: String, Codable, Equatable {
        case ok
        case rejected     // command valid but server refuses (e.g. CLI unsupported)
        case error        // command malformed or threw
    }

    public init(
        type: String = "command_ack",
        commandId: UUID,
        status: Status,
        message: String? = nil,
        sessionId: UUID? = nil
    ) {
        self.type = type
        self.commandId = commandId
        self.status = status
        self.message = message
        self.sessionId = sessionId
    }
}

// MARK: - Resume (client → server, on connect)

public struct ResumeRequest: Codable, Equatable {
    public let type: String           // always "resume"
    public let sessionId: UUID?       // panel scope; nil = "currently focused"
    /// `nil` ⇒ client has no state; server should send a full snapshot.
    public let lastRevision: Int?

    public init(type: String = "resume", sessionId: UUID?, lastRevision: Int?) {
        self.type = type
        self.sessionId = sessionId
        self.lastRevision = lastRevision
    }
}

// MARK: - Wire-frame type constants

public enum RemoteVNCFrameType {
    public static let command = "command"
    public static let commandAck = "command_ack"
    public static let panelState = "panel_state"
    public static let resume = "resume"
    public static let recoveryRequest = "recovery_request"
    public static let recoveryResponse = "recovery_response"
}

public enum RemoteRecoveryLimits {
    public static let maximumAttachmentBytes = 10 * 1024 * 1024
    public static let maximumAttachmentContentBase64Length = ((maximumAttachmentBytes + 2) / 3) * 4
    public static let maximumTextFrameUTF8Bytes = maximumAttachmentContentBase64Length + (64 * 1024)
}

// MARK: - Recovery RPC (client <-> server)

/// Request/response frames for state that must be recoverable independently of
/// the currently focused live panel. This keeps history and file browsing from
/// depending on `panel_state` timing during project/session switches.
public struct RemoteRecoveryRequest: Codable, Equatable {
    public let type: String
    public let requestId: UUID
    public let op: Op
    public let projectId: UUID?
    public let cli: String?
    public let sessionId: UUID?
    public let limit: Int?
    public let before: Int?
    public let page: Bool?
    public let path: String?
    public let filename: String?
    public let contentBase64: String?

    public enum Op: String, Codable, Equatable {
        case catalog
        case sessions
        case messages
        case projectFiles
        case uploadAttachment
    }

    public init(
        type: String = RemoteVNCFrameType.recoveryRequest,
        requestId: UUID = UUID(),
        op: Op,
        projectId: UUID? = nil,
        cli: String? = nil,
        sessionId: UUID? = nil,
        limit: Int? = nil,
        before: Int? = nil,
        page: Bool? = nil,
        path: String? = nil,
        filename: String? = nil,
        contentBase64: String? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.op = op
        self.projectId = projectId
        self.cli = cli
        self.sessionId = sessionId
        self.limit = limit
        self.before = before
        self.page = page
        self.path = path
        self.filename = filename
        self.contentBase64 = contentBase64
    }
}

public struct RemoteRecoveryResponse: Codable, Equatable {
    public let type: String
    public let requestId: UUID
    public let status: Status
    public let message: String?
    public let projects: [PanelProjectDTO]?
    public let models: [PanelModelDTO]?
    public let sessions: [PanelSessionDTO]?
    public let messages: [ChatMessage]?
    public let messagePage: RemoteRecoveryMessagePageDTO?
    public let files: RemoteRecoveryProjectFilesDTO?
    public let attachmentUpload: RemoteRecoveryAttachmentUploadDTO?

    public enum Status: String, Codable, Equatable {
        case ok
        case error
    }

    public init(
        type: String = RemoteVNCFrameType.recoveryResponse,
        requestId: UUID,
        status: Status,
        message: String? = nil,
        projects: [PanelProjectDTO]? = nil,
        models: [PanelModelDTO]? = nil,
        sessions: [PanelSessionDTO]? = nil,
        messages: [ChatMessage]? = nil,
        messagePage: RemoteRecoveryMessagePageDTO? = nil,
        files: RemoteRecoveryProjectFilesDTO? = nil,
        attachmentUpload: RemoteRecoveryAttachmentUploadDTO? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.status = status
        self.message = message
        self.projects = projects
        self.models = models
        self.sessions = sessions
        self.messages = messages
        self.messagePage = messagePage
        self.files = files
        self.attachmentUpload = attachmentUpload
    }

    public static func ok(
        requestId: UUID,
        projects: [PanelProjectDTO]? = nil,
        models: [PanelModelDTO]? = nil,
        sessions: [PanelSessionDTO]? = nil,
        messages: [ChatMessage]? = nil,
        messagePage: RemoteRecoveryMessagePageDTO? = nil,
        files: RemoteRecoveryProjectFilesDTO? = nil,
        attachmentUpload: RemoteRecoveryAttachmentUploadDTO? = nil
    ) -> RemoteRecoveryResponse {
        RemoteRecoveryResponse(
            requestId: requestId,
            status: .ok,
            projects: projects,
            models: models,
            sessions: sessions,
            messages: messages,
            messagePage: messagePage,
            files: files,
            attachmentUpload: attachmentUpload
        )
    }

    public static func error(requestId: UUID, message: String) -> RemoteRecoveryResponse {
        RemoteRecoveryResponse(requestId: requestId, status: .error, message: message)
    }
}

public struct RemoteRecoveryMessagePageDTO: Codable, Equatable {
    public let messages: [ChatMessage]
    public let nextBeforeIndex: Int?
    public let hasMore: Bool
    public let totalCount: Int

    public init(messages: [ChatMessage], nextBeforeIndex: Int?, hasMore: Bool, totalCount: Int) {
        self.messages = messages
        self.nextBeforeIndex = nextBeforeIndex
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

public struct RemoteRecoveryProjectFileEntryDTO: Codable, Equatable, Hashable {
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool

    public init(name: String, relativePath: String, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

public struct RemoteRecoveryProjectFilesDTO: Codable, Equatable, Hashable {
    public let projectId: UUID
    public let path: String
    public let parentPath: String?
    public let entries: [RemoteRecoveryProjectFileEntryDTO]

    public init(projectId: UUID, path: String, parentPath: String?, entries: [RemoteRecoveryProjectFileEntryDTO]) {
        self.projectId = projectId
        self.path = path
        self.parentPath = parentPath
        self.entries = entries
    }
}

public struct RemoteRecoveryAttachmentUploadDTO: Codable, Equatable, Hashable {
    public let filename: String
    public let path: String

    public init(filename: String, path: String) {
        self.filename = filename
        self.path = path
    }
}
