import Foundation
import ChatCore

enum RemoteChatLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "Codevoke.RemoteChatBridge"
}

/// 轻量信封，用来在 send_message 之外识别 flush_queue / interrupt / update_queue_message / delete_queue_message / respond_*。
struct RemoteChatControlEnvelope: Codable {
    let type: String
    let requestId: String?
    let backendRequestId: String?
    let clientConversationId: UUID?
    let sessionId: UUID?
    let content: String?
    let permissionRequestId: String?
    let decision: String?
    let interactiveRequestId: String?
    let interactiveResponse: ChatInteractiveResponse?
    let selectedOptionIds: [String]?
    let selectedOptionIDs: [String]?
    let selected_option_ids: [String]?
    let customText: String?
    let custom_text: String?
    let answer: String?
}

struct RemoteChatSendMessageRequest: Codable {
    let type: String
    let requestId: String?
    let clientConversationId: UUID?
    let projectId: UUID
    let sessionId: UUID?
    let content: String
    let cli: String?
    let modelID: String?
    let permissionMode: String?
    let reasoningEffort: String?
}

/// Phase-B legacy event struct. Still produced by `ChatPanelController.publishRemoteStreamEventIfNeeded`
/// and broadcast to legacy iOS clients via `NotificationCenter`. New VNC clients
/// ignore these — they consume `PanelStateEnvelope` only.
struct RemoteChatStreamEvent: Codable {
    var protocolVersion: Int?
    var eventId: UUID?
    var envelopeKind: String?
    var serverEpoch: String?
    var type: String
    var requestId: String?
    var clientConversationId: UUID?
    var eventScopeId: UUID?
    var eventScopeKind: String?
    var backendRequestId: String?
    var sessionId: UUID?
    var messageId: UUID?
    var seq: Int?
    var cursor: Int?
    var replay: Bool?
    var snapshotCursor: Int?
    var kind: String?
    var title: String?
    var subtitle: String?
    var delta: String?
    var text: String?
    var status: String?
    var externalSessionId: String?
    var message: String?
    var tokenUsed: Int?
    var tokenTotal: Int?
    var outputTokenCount: Int?
    var queueCount: Int?
    var queuePosition: Int?
    var projectId: UUID?
    var projectName: String?
    var projectPath: String?
    var cli: String?
    var modelID: String?
    var permissionMode: String?
    var reasoningEffort: String?
    var interactiveRequest: ChatInteractiveRequest?

    init(
        type: String,
        requestId: String? = nil,
        clientConversationId: UUID? = nil,
        eventScopeId: UUID? = nil,
        eventScopeKind: String? = nil,
        backendRequestId: String? = nil,
        sessionId: UUID? = nil,
        messageId: UUID? = nil,
        seq: Int? = nil,
        cursor: Int? = nil,
        replay: Bool? = nil,
        snapshotCursor: Int? = nil,
        kind: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        delta: String? = nil,
        text: String? = nil,
        status: String? = nil,
        externalSessionId: String? = nil,
        message: String? = nil,
        tokenUsed: Int? = nil,
        tokenTotal: Int? = nil,
        outputTokenCount: Int? = nil,
        queueCount: Int? = nil,
        queuePosition: Int? = nil,
        projectId: UUID? = nil,
        projectName: String? = nil,
        projectPath: String? = nil,
        cli: String? = nil,
        modelID: String? = nil,
        permissionMode: String? = nil,
        reasoningEffort: String? = nil,
        interactiveRequest: ChatInteractiveRequest? = nil,
        protocolVersion: Int? = nil,
        eventId: UUID? = nil,
        envelopeKind: String? = nil,
        serverEpoch: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.eventId = eventId
        self.envelopeKind = envelopeKind
        self.serverEpoch = serverEpoch
        self.type = type
        self.requestId = requestId
        self.clientConversationId = clientConversationId
        self.eventScopeId = eventScopeId
        self.eventScopeKind = eventScopeKind
        self.backendRequestId = backendRequestId
        self.sessionId = sessionId
        self.messageId = messageId
        self.seq = seq
        self.cursor = cursor
        self.replay = replay
        self.snapshotCursor = snapshotCursor
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.delta = delta
        self.text = text
        self.status = status
        self.externalSessionId = externalSessionId
        self.message = message
        self.tokenUsed = tokenUsed
        self.tokenTotal = tokenTotal
        self.outputTokenCount = outputTokenCount
        self.queueCount = queueCount
        self.queuePosition = queuePosition
        self.projectId = projectId
        self.projectName = projectName
        self.projectPath = projectPath
        self.cli = cli
        self.modelID = modelID
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.interactiveRequest = interactiveRequest
    }
}

/// VNC refactor — Bridge is now a thin legacy-frame translator. All queue / run
/// scheduling / persistence responsibilities moved into `ChatPanelController`
/// (see spec §1.3, §1.4). The Bridge only accepts the legacy `send_message`
/// / `interrupt` / `flush_queue` / `update_queue_message` / `delete_queue_message`
/// / `respond_permission` / `respond_interactive` / `queue_snapshot` frames from old iOS clients (Phase B back-compat) and
/// translates them into controller mutate API calls via
/// `RemoteVNCWiring.lookup`. New iOS clients send `Command` frames which the
/// server routes directly to `RemoteChatCommandRouter`, bypassing the Bridge.
final class RemoteChatBridge {
    typealias EventHandler = (RemoteChatStreamEvent) -> Void

    private let eventHandler: EventHandler

    init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    /// Decode a legacy WS text frame and translate it to controller calls on
    /// the main actor. The Bridge no longer keeps any local queue or backend.
    func handle(text: String) async {
        var decodedRequestId: String?
        do {
            guard let data = text.data(using: .utf8) else { throw RemoteChatBridgeError.invalidPayload }
            // Distinguish control envelopes from full send_message payloads.
            if let envelope = try? JSONDecoder().decode(RemoteChatControlEnvelope.self, from: data),
               envelope.type != "send_message" {
                decodedRequestId = envelope.requestId
                switch envelope.type {
                case "flush_queue":
                    await translateFlushQueue(envelope)
                    return
                case "interrupt":
                    await translateInterrupt(envelope)
                    return
                case "update_queue_message":
                    try await translateUpdateQueueMessage(envelope)
                    return
                case "delete_queue_message":
                    try await translateDeleteQueueMessage(envelope)
                    return
                case "respond_permission", "permission_response", "respondPermission":
                    try await translateRespondPermission(envelope)
                    return
                case "respond_interactive", "interactive_response", "respondInteractive":
                    try await translateRespondInteractive(envelope)
                    return
                case "queue_snapshot":
                    // No-op: snapshots are now pushed by the VNC pipeline.
                    // Legacy clients still rely on `queue_status` events that
                    // the controller emits on its own as queuedRequests change.
                    return
                default:
                    throw RemoteChatBridgeError.unsupportedMessageType
                }
            }
            let request = try JSONDecoder().decode(RemoteChatSendMessageRequest.self, from: data)
            decodedRequestId = request.requestId
            guard request.type == "send_message" else { throw RemoteChatBridgeError.unsupportedMessageType }
            await translateSendMessage(request)
        } catch {
            eventHandler(RemoteChatStreamEvent(
                type: "assistant_error",
                requestId: decodedRequestId,
                status: "failed",
                message: error.localizedDescription
            ))
        }
    }

    /// Tear-down hook called when the server stops. Nothing to clean now that
    /// the Bridge holds no transient state of its own.
    func stop() {}

    // MARK: - Legacy frame translation (delegates to ChatPanelController)

    private func translateSendMessage(_ request: RemoteChatSendMessageRequest) async {
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            eventHandler(RemoteChatStreamEvent(
                type: "assistant_error",
                requestId: request.requestId,
                clientConversationId: request.clientConversationId,
                sessionId: request.sessionId,
                status: "failed",
                message: RemoteChatBridgeError.emptyContent.errorDescription ?? ""
            ))
            return
        }
        guard let project = ProjectStore.loadProjects().first(where: { $0.id == request.projectId }) else {
            eventHandler(RemoteChatStreamEvent(
                type: "assistant_error",
                requestId: request.requestId,
                clientConversationId: request.clientConversationId,
                sessionId: request.sessionId,
                status: "failed",
                message: RemoteChatBridgeError.projectNotFound.errorDescription ?? ""
            ))
            return
        }
        let cli = CLIType(rawValue: request.cli ?? "")?.visibleValue ?? project.defaultCLI.visibleValue
        let modelID = request.modelID?.nonEmptyTrimmed ?? ChatModelCatalog.defaultModelID(for: cli)
        let permissionMode = ChatPermissionMode(rawValue: request.permissionMode ?? "") ?? .autoEdit
        let reasoningEffort = ChatReasoningEffort(rawValue: request.reasoningEffort ?? "") ?? .high
        let sessionId = request.sessionId

        await MainActor.run {
            guard let controller = Self.resolveController(sessionId: sessionId) else { return }
            // Mirror the composer state from the legacy frame, then send.
            controller.setComposerText(content)
            controller.setCLI(cli)
            controller.setModel(modelID)
            controller.setPermissionMode(permissionMode)
            controller.setReasoningEffort(reasoningEffort)
            let sessionMode: SessionMode = sessionId == nil ? .newSession : .resume
            _ = controller.sendFromComposer(
                text: content,
                project: project,
                cli: cli,
                modelID: modelID,
                permissionMode: permissionMode,
                reasoningEffort: reasoningEffort,
                sessionMode: sessionMode,
                resumeSessionID: nil
            )
        }
    }

    private func translateInterrupt(_ envelope: RemoteChatControlEnvelope) async {
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            Self.resolveController(sessionId: sessionId)?.stop()
        }
    }

    private func translateFlushQueue(_ envelope: RemoteChatControlEnvelope) async {
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            // Audit B-P1-2: flushQueue now drops the entire queue.
            Self.resolveController(sessionId: sessionId)?.discardQueuedRequestsForNewChat()
        }
    }

    private func translateUpdateQueueMessage(_ envelope: RemoteChatControlEnvelope) async throws {
        guard let rawRequestId = envelope.requestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRequestId.isEmpty,
              let requestUUID = UUID(uuidString: rawRequestId) else {
            throw RemoteChatBridgeError.invalidPayload
        }
        let content = envelope.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw RemoteChatBridgeError.emptyContent }
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            Self.resolveController(sessionId: sessionId)?.editQueuedRequest(requestUUID, text: content)
        }
    }

    private func translateDeleteQueueMessage(_ envelope: RemoteChatControlEnvelope) async throws {
        guard let rawRequestId = envelope.requestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRequestId.isEmpty,
              let requestUUID = UUID(uuidString: rawRequestId) else {
            throw RemoteChatBridgeError.invalidPayload
        }
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            Self.resolveController(sessionId: sessionId)?.cancelQueuedRequest(requestUUID)
        }
    }

    private func translateRespondPermission(_ envelope: RemoteChatControlEnvelope) async throws {
        guard let requestID = Self.backendRequestID(from: envelope.permissionRequestId ?? envelope.backendRequestId ?? envelope.requestId),
              let rawDecision = envelope.decision?.nonEmptyTrimmed,
              let decision = ChatPermissionDecision(rawValue: rawDecision) else {
            throw RemoteChatBridgeError.invalidPayload
        }
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            Self.resolveController(sessionId: sessionId)?.respondToPermission(requestID: requestID, decision: decision)
        }
    }

    private func translateRespondInteractive(_ envelope: RemoteChatControlEnvelope) async throws {
        guard let response = Self.interactiveResponse(from: envelope) else {
            throw RemoteChatBridgeError.invalidPayload
        }
        let sessionId = envelope.sessionId ?? envelope.clientConversationId
        await MainActor.run {
            Self.resolveController(sessionId: sessionId)?.respondToInteractiveRequest(response)
        }
    }

    private static func interactiveResponse(from envelope: RemoteChatControlEnvelope) -> ChatInteractiveResponse? {
        if let response = envelope.interactiveResponse {
            return response
        }
        guard let requestID = backendRequestID(from: envelope.interactiveRequestId ?? envelope.backendRequestId ?? envelope.requestId) else {
            return nil
        }
        let selectedOptionIDs = envelope.selectedOptionIDs ?? envelope.selectedOptionIds ?? envelope.selected_option_ids ?? []
        let customText = (envelope.customText ?? envelope.custom_text ?? envelope.answer ?? envelope.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = customText?.isEmpty == false ? customText : nil
        guard !selectedOptionIDs.isEmpty || trimmedText != nil else { return nil }
        return ChatInteractiveResponse(
            requestID: requestID,
            selectedOptionIDs: selectedOptionIDs,
            customText: trimmedText
        )
    }

    private static func backendRequestID(from value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyTrimmed
    }

    @MainActor
    private static func resolveController(sessionId: UUID?) -> ChatPanelController? {
        // Bridge routes through the same lookup the VNC pipeline uses so old
        // and new clients drive the same controller instance.
        if let lookup = RemoteVNCWiring.lookup,
           let resolved = lookup.controller(for: sessionId) as? ChatPanelController {
            return resolved
        }
        return nil
    }
}

enum RemoteChatBridgeError: LocalizedError {
    case invalidPayload
    case unsupportedMessageType
    case emptyContent
    case projectNotFound
    case projectAccessDenied
    case cliUnavailable(String)
    case backendFailed(String)
    case queueRequestNotFound

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "消息格式无效。"
        case .unsupportedMessageType: "不支持的 WebSocket 消息类型。"
        case .emptyContent: "消息内容不能为空。"
        case .projectNotFound: "项目不存在。"
        case .projectAccessDenied: "项目目录授权失效。"
        case .cliUnavailable(let message): message
        case .backendFailed(let message): message
        case .queueRequestNotFound: "队列消息不存在或已经开始执行。"
        }
    }
}
