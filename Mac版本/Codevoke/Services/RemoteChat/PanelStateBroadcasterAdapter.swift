// PanelStateBroadcasterAdapter.swift
//
// Bridge between the mac-controller side (`ChatPanelController` with its own
// `setComposerText / setCLI / sendFromComposer / stop / …` mutate surface
// and the protocol-server side `PanelStateBroadcasting` protocol declared in
// `PanelStateBroadcaster.swift`.
//
// Three things live here:
//   1. `extension ChatPanelController: PanelStateBroadcasting` — implements the
//      protocol by translating into the existing controller mutate API.
//   2. `RuntimeStorePanelControllerLookup` — replaces `StubPanelControllerLookup`
//      and wraps `ChatRuntimeStore.controller(for:)`.
//   3. A throttled `snapshotPublisher` shared across all controllers
//      (30 ms coalesce so SwiftUI publisher storms produce at most ~33 snapshots
//      per second). This is essential for performance — without throttling, every
//      `@Published` mutation would broadcast a full PanelStateSnapshot.
//
// The adapter uses storage tied to each `ChatPanelController` via
// `objc_setAssociatedObject` to attach a Combine throttler. Lifetime mirrors the
// controller's, so no manual cleanup needed.

import Combine
import Foundation
import ObjectiveC
import os
import ChatCore

// MARK: - Throttled snapshot publisher storage (per-controller)

@MainActor
private final class PanelBroadcastBox {
    let subject = PassthroughSubject<PanelStateSnapshot, Never>()
    var cancellables: Set<AnyCancellable> = []
}

private var panelBroadcastBoxKey: UInt8 = 0

// MARK: - Helper: snapshot construction

@MainActor
private enum PanelStateSnapshotBuilder {
    private static let remoteMessageLimit = 120
    private static let remoteTextBudget = 512 * 1024
    private static let remoteSingleTextLimit = 128 * 1024

    static func build(from controller: ChatPanelController, contextProvider: PanelControllerContextProvider?) -> PanelStateSnapshot {
        let payload = controller.snapshotPayload(for: nil)
        let composer = composerSnapshot(controller: controller, payload: payload, contextProvider: contextProvider)
        let messages = boundedMessages(controller.messages)
        let visibleMessageIDs = Set(messages.map(\.id))
#if DEBUG
        if controller.messages.count > messages.count {
            print("[RemoteSnapshot] capped messages session=\(controller.currentSessionID?.uuidString ?? "draft") raw=\(controller.messages.count) sent=\(messages.count)")
        }
#endif
        let capabilities = controller.capabilities.map { (cli, cap) in
            PanelCapabilityDTO(
                cli: cli.rawValue,
                executableAvailable: cap.isAvailable,
                supportsStreamJSONInput: cap.supportsStreamJSONInput,
                supportsAppServer: cap.supportsAppServer,
                errorMessage: cap.errorMessage
            )
        }
        let streamingTexts = controller.streamingTextStore.entries.compactMap { (messageID, entry) -> PanelStreamingTextDTO? in
            guard visibleMessageIDs.contains(messageID) else { return nil }
            return PanelStreamingTextDTO(
                messageId: messageID,
                text: boundedText(entry.text, limit: remoteSingleTextLimit),
                status: entry.status,
                requestId: entry.requestID
            )
        }
        let queued = controller.queuedRequests.map { req -> PanelQueuedRequestDTO in
            PanelQueuedRequestDTO(
                id: req.id,
                text: req.text,
                displayText: req.displayText,
                cli: req.cli.rawValue,
                modelID: req.modelID,
                permissionMode: req.permissionMode.rawValue,
                reasoningEffort: req.reasoningEffort.rawValue,
                projectId: req.project.id,
                attachments: req.attachments
            )
        }
        let (projects, models, sessions) = contextProvider?.catalogSnapshot() ?? ([], [], [])
        return PanelStateSnapshot(
            revision: 0, // PanelSessionRevisionLog stamps the real revision.
            sessionId: controller.currentSessionID,
            projects: projects,
            models: models,
            sessions: sessions,
            currentSessionId: controller.currentSessionID,
            messages: messages,
            queuedRequests: queued,
            streamingTexts: streamingTexts,
            status: controller.status.rawValue,
            statusText: controller.statusText,
            isAwaitingFirstModelOutput: controller.isAwaitingFirstModelOutput,
            isLoadingHistory: controller.isLoadingHistory,
            tokensUsed: controller.tokensUsed,
            tokensTotal: controller.tokensTotal,
            activeRunStartedAt: payload?.activeRunStartedAt,
            isMirroringRemoteSession: controller.isMirroringRemoteSession,
            composer: composer,
            capabilities: capabilities
        )
    }

    private static func boundedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var totalTextBytes = 0
        for var message in messages.reversed() {
            message.text = boundedText(message.text, limit: remoteSingleTextLimit)
            message.attachments = message.attachments.map { attachment in
                var copy = attachment
                copy.thumbnailData = nil
                return copy
            }
            let textBytes = message.text.utf8.count + message.title.utf8.count + message.subtitle.utf8.count + (message.appendRuleText?.utf8.count ?? 0)
            if !result.isEmpty, result.count >= remoteMessageLimit || totalTextBytes + textBytes > remoteTextBudget {
                break
            }
            result.append(message)
            totalTextBytes += textBytes
        }
        return Array(result.reversed())
    }

    private static func boundedText(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let headLimit = limit / 2
        let tailLimit = limit - headLimit
        let head = String(decoding: text.utf8.prefix(headLimit), as: UTF8.self)
        let tail = String(decoding: text.utf8.suffix(tailLimit), as: UTF8.self)
        return head + "\n…（远程视图已截断，完整内容请在 Mac 查看）\n" + tail
    }

    private static func composerSnapshot(
        controller: ChatPanelController,
        payload: PanelStatePayload?,
        contextProvider: PanelControllerContextProvider?
    ) -> PanelComposerDTO {
        // capability-based enabled flag, mirroring the Mac composer "send"
        // button's enablement.
        let capability = controller.capabilities[controller.composerCLI.visibleValue]
        let isEnabled = capability?.isAvailable ?? false
        let placeholder = contextProvider?.composerPlaceholder(for: controller) ?? ""
        return PanelComposerDTO(
            text: controller.composerText,
            cli: controller.composerCLI.rawValue,
            modelID: controller.composerModelID,
            contextModelID: controller.composerContextModelID,
            permissionMode: controller.composerPermissionMode.rawValue,
            reasoningEffort: controller.composerReasoningEffort.rawValue,
            attachments: controller.composerAttachments,
            isEnabled: isEnabled,
            placeholder: placeholder
        )
    }
}

// MARK: - Catalog provider (projects/models/sessions)

/// Vended by the lookup so we can stamp every snapshot with the cross-controller
/// catalog (projects, models, sessions). Decoupled from `ChatPanelController` so
/// the controller doesn't need to know about `AppState` / `ChatModelService`.
@MainActor
protocol PanelControllerContextProvider: AnyObject {
    var appStateForRemoteFocus: AppState? { get }
    /// Returns `(projects, models, sessions)`.
    func catalogSnapshot() -> ([PanelProjectDTO], [PanelModelDTO], [PanelSessionDTO])
    /// Composer placeholder hint for the current focused project/cli.
    func composerPlaceholder(for controller: ChatPanelController) -> String
    /// Default project to use for sends originating from a remote command when
    /// the controller has no current session yet (draft mode).
    func defaultProject(for controller: ChatPanelController) -> ProjectItem?
    /// Bug A: remote project focus must mutate Mac AppState before iOS sends.
    func selectProject(id: UUID) -> ProjectItem?
}

// MARK: - ChatPanelController + PanelStateBroadcasting

extension ChatPanelController: PanelStateBroadcasting {

    // The `sessionId` property already exists conceptually as
    // `currentSessionID`; satisfy the protocol with a tiny wrapper.
    var sessionId: UUID? { currentSessionID }

    func currentSnapshot() -> PanelStateSnapshot {
        let provider = panelControllerContextProvider
        return PanelStateSnapshotBuilder.build(from: self, contextProvider: provider)
    }

    var snapshotPublisher: AnyPublisher<PanelStateSnapshot, Never> {
        let box = ensurePanelBroadcastBox()
        return box.subject.eraseToAnyPublisher()
    }

    var patchPublisher: AnyPublisher<PanelStatePatch, Never>? {
        // Mac controller doesn't compute incremental patches — server diffs
        // snapshots itself (cheap because most fields are reference-equal).
        nil
    }

    // MARK: - Command surface — translate to existing mutate API

    func remoteFocusSession(_ id: UUID) {
        loadPersistedSession(id)
    }

    func remoteNewDraftSession(projectId: UUID) -> UUID {
        let id = newDraftSession(projectId: projectId)
        remoteFocusedProjectID = projectId
        return id
    }

    func remoteComposerSet(text: String) {
        setComposerText(text)
    }

    func remoteComposerSetCLI(_ cli: CLIType) {
        setCLI(cli.visibleValue)
    }

    func remoteComposerSetModel(_ modelID: String) {
        setModel(modelID)
    }

    func remoteComposerSetPermissionMode(_ mode: ChatPermissionMode) {
        setPermissionMode(mode)
    }

    func remoteComposerSetReasoningEffort(_ effort: ChatReasoningEffort) {
        setReasoningEffort(effort)
    }

    func remoteComposerAttach(_ attachment: ChatMessageAttachment) {
        uploadAttachment(attachment)
    }

    func remoteComposerRemoveAttach(id: UUID) {
        removeAttachment(id: id)
    }

    func remoteResolvedProjectForSend() -> ProjectItem? {
        panelControllerContextProvider?.defaultProject(for: self)
    }

    func remoteComposerSend(sessionMode: SessionMode?, resumeSessionID: String?, appendRuleText: String?) -> Bool {
        // Bug A: remote composer sends resolve cwd from the focused/draft project, not the Mac sidebar fallback.
        guard let project = remoteResolvedProjectForSend() else {
            return false
        }
        let resolvedSessionMode = sessionMode ?? (currentSessionID == nil ? .newSession : .resume)
        let dispatch: (String, [ChatMessageAttachment]) -> Bool = { [weak self] text, atts in
            guard let self else { return false }
            let ok = self.sendFromComposer(
                text: text,
                appendRuleText: appendRuleText,
                attachments: atts,
                project: project,
                cli: self.composerCLI,
                modelID: self.composerModelID,
                contextModelID: self.composerContextModelID,
                permissionMode: self.composerPermissionMode,
                reasoningEffort: self.composerReasoningEffort,
                sessionMode: resolvedSessionMode,
                resumeSessionID: resumeSessionID
            )
            if ok {
                self.setComposerText("")
                for attachment in atts { self.removeAttachment(id: attachment.id) }
            }
            return ok
        }
        // Race-tolerant fast path: if the composer already has text the
        // client's `composerSet → composerSend` ordering held; send now.
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || !composerAttachments.isEmpty {
            return dispatch(composerText, composerAttachments)
        }
        // Audit B-P1-1 / A-P0-2: composer is empty -> the client almost
        // certainly posted `composerSend` before `composerSet` landed. We
        // schedule one short retry. The synchronous ack used to return
        // `false`, which iOS surfaced as a red "send rejected" banner even
        // when the deferred retry succeeded. Return optimistic `true` now so
        // the UI doesn't flash an error; if the deferred retry still finds
        // an empty composer 500 ms later we surface the failure via
        // `appendError`, which flows through the normal panel_state patch
        // and the iOS message list (instead of an out-of-band reject ack).
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let later = self.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !later.isEmpty || !self.composerAttachments.isEmpty else {
                self.appendErrorFromRemoteBridge("发送失败：输入框为空，可能 composerSet 未送达。")
                return
            }
            _ = dispatch(self.composerText, self.composerAttachments)
        }
        return true
    }

    func remoteStop(startQueuedAfterStop: Bool) {
        stop(startQueuedAfterStop: startQueuedAfterStop)
    }

    func remoteFlushQueue() {
        // Audit B-P1-2: real "clear the queue" semantics now match the UX
        // text. The old "interrupt + start next" path lives under
        // `remoteInterruptAndStartNext`.
        discardQueuedRequestsForNewChat()
    }

    func remoteInterruptAndStartNext() {
        interrupt(startQueuedAfterStop: true)
    }

    func remoteCancelQueued(requestId: UUID) {
        cancelQueuedRequest(requestId)
    }

    func remoteEditQueued(requestId: UUID, text: String) {
        editQueuedRequest(requestId, text: text)
    }

    func remoteRespondPermission(requestId: String, decision: ChatPermissionDecision) {
        respondToPermission(requestID: requestId, decision: decision)
    }

    func remoteRespondInteractive(response: ChatInteractiveResponse) {
        respondToInteractiveRequest(response)
    }

    func remoteRequestSnapshot() {
        // The command router/server sends the focused snapshot directly. Keeping
        // this as a no-op avoids a second immediate publisher emission that can
        // race with the direct reply and double the payload during focus churn.
    }

    func remoteRefreshCapabilities() {
        refreshCapabilities(force: true)
    }

    // MARK: - Throttled broadcasting

    /// Lazily attaches a throttled subject to this controller. Fires at most
    /// once every 100 ms when `objectWillChange` storms (typing, delta floods,
    /// queue churn) and once on every `sessionChangePublisher` emission. Also
    /// subscribes to `streamingTextStore.revisionPublisher` and
    /// `statusStore.objectWillChange` — those side stores are `let`
    /// references on the controller, so their internal `@Published` churn
    /// does NOT propagate to `controller.objectWillChange`. Without these
    /// subscriptions, every assistant streaming delta is invisible to the
    /// VNC pipeline (no `panel_state` patch is broadcast) and iOS sees the
    /// stream as frozen.
    fileprivate func ensurePanelBroadcastBox() -> PanelBroadcastBox {
        if let existing = objc_getAssociatedObject(self, &panelBroadcastBoxKey) as? PanelBroadcastBox {
            return existing
        }
        let box = PanelBroadcastBox()
        let coreChange = objectWillChange
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .map { _ in () }
            .eraseToAnyPublisher()
        let session = sessionChangePublisher
            .map { _ in () }
            .eraseToAnyPublisher()
        let streaming = streamingTextStore.revisionPublisher
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .map { _ in () }
            .eraseToAnyPublisher()
        let status = statusStore.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .map { _ in () }
            .eraseToAnyPublisher()
        Publishers.MergeMany([coreChange, session, streaming, status])
            // Final coalesce after merge. Without this the four upstream
            // throttles fire independently and the merged stream can hit
            // hundreds of events per second (streaming + status churn),
            // overwhelming the WS encoder and producing patch sequences the
            // client can't keep up with — every dropped patch triggers a
            // `requestSnapshot` and the client UI never settles.
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let snapshot = PanelStateSnapshotBuilder.build(from: self, contextProvider: self.panelControllerContextProvider)
                box.subject.send(snapshot)
            }
            .store(in: &box.cancellables)
        objc_setAssociatedObject(self, &panelBroadcastBoxKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return box
    }

    /// Force-fire a snapshot, bypassing the throttle. Used by `remoteRequestSnapshot`
    /// and `remoteFocusSession`.
    fileprivate func triggerImmediateSnapshot() {
        let box = ensurePanelBroadcastBox()
        let snapshot = PanelStateSnapshotBuilder.build(from: self, contextProvider: panelControllerContextProvider)
        box.subject.send(snapshot)
    }
}

// MARK: - Context provider association

private var panelControllerContextProviderKey: UInt8 = 0
private var remoteFocusedProjectIDKey: UInt8 = 0

extension ChatPanelController {
    /// Optional context provider used to fill catalog fields. Set by the
    /// owning `RuntimeStorePanelControllerLookup` whenever it vends a
    /// controller for the server's snapshot construction.
    var panelControllerContextProvider: PanelControllerContextProvider? {
        get {
            objc_getAssociatedObject(self, &panelControllerContextProviderKey) as? PanelControllerContextProvider
        }
        set {
            objc_setAssociatedObject(self, &panelControllerContextProviderKey, newValue, .OBJC_ASSOCIATION_ASSIGN)
        }
    }

    var remoteFocusedProjectID: UUID? {
        get {
            objc_getAssociatedObject(self, &remoteFocusedProjectIDKey) as? UUID
        }
        set {
            objc_setAssociatedObject(self, &remoteFocusedProjectIDKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

// MARK: - Real lookup wrapping ChatRuntimeStore

@MainActor
final class RuntimeStorePanelControllerLookup: PanelControllerLookup, PanelControllerContextProvider, RemoteFocusResolving {
    fileprivate static let log = Logger(subsystem: RemoteChatLog.subsystem, category: "RuntimeStorePanelControllerLookup")
    private weak var runtimeStore: ChatRuntimeStore?
    private weak var appState: AppState?
    private weak var modelService: ChatModelService?

    init(runtimeStore: ChatRuntimeStore, appState: AppState?, modelService: ChatModelService?) {
        self.runtimeStore = runtimeStore
        self.appState = appState
        self.modelService = modelService
    }

    func controller(for sessionId: UUID?) -> PanelStateBroadcasting? {
        guard let runtimeStore else { return nil }
        let controller: ChatPanelController?
        if let sessionId {
            controller = runtimeStore.controller(for: sessionId) ?? createOrAdopt(sessionID: sessionId)
        } else if let current = runtimeStore.controller(for: nil) {
            controller = current
        } else if let appState {
            controller = runtimeStore.state(
                for: appState,
                modelID: modelID(for: appState.selectedCLI.visibleValue),
                permissionMode: appState.settings.chatPermissionMode,
                reasoningEffort: .high
            )
        } else {
            controller = nil
        }
        controller?.panelControllerContextProvider = self
        return controller
    }

    func allControllers() -> [PanelStateBroadcasting] {
        guard let runtimeStore else { return [] }
        let controllers = runtimeStore.allLiveControllers()
        controllers.forEach { $0.panelControllerContextProvider = self }
        return controllers
    }

    func focusSession(_ sessionId: UUID) -> PanelStateBroadcasting? {
        if let controller = focusSessionMutatingWorkspace(sessionId) {
            return controller
        }
        guard let controller = controller(for: sessionId) else { return nil }
        if let chatController = controller as? ChatPanelController,
           let history = historyForUUID(sessionId),
           let projectPath = AppState.normalizedProjectPath(history.projectPath),
           let project = appState?.projects.first(where: { AppState.normalizedProjectPath($0.path) == projectPath }) {
            chatController.remoteFocusedProjectID = project.id
        }
        controller.remoteFocusSession(sessionId)
        return controller
    }

    func focusProject(_ projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        focusProjectMutatingWorkspace(projectId)
    }

    func createDraft(projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        createDraftMutatingWorkspace(projectId)
    }

    private func focusProjectMutatingWorkspace(_ projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        guard let appState else {
            Self.log.warning("focusProject failed reason=missingAppState projectId=\(projectId.uuidString, privacy: .public)")
            return nil
        }
        guard let runtimeStore else {
            Self.log.warning("focusProject failed reason=missingRuntimeStore projectId=\(projectId.uuidString, privacy: .public)")
            return nil
        }
        guard let project = selectProject(id: projectId) else {
            let known = appState.projects.map { $0.id.uuidString }.joined(separator: ",")
            Self.log.warning("focusProject failed reason=selectProjectRejected projectId=\(projectId.uuidString, privacy: .public) knownProjectIds=\(known, privacy: .public)")
            return nil
        }
        if let latest = latestHistory(for: project),
           let sessionID = sessionUUID(from: latest) {
            appState.selectCLIHistory(latest)
            guard appState.selectedCLIHistoryID == latest.id else {
                Self.log.warning("focusProject failed reason=selectCLIHistoryRejected projectId=\(projectId.uuidString, privacy: .public) historyId=\(latest.id, privacy: .public)")
                return nil
            }
            let controller = runtimeStore.state(
                for: appState,
                modelID: modelID(for: latest.cli.visibleValue),
                permissionMode: appState.settings.chatPermissionMode,
                reasoningEffort: .high
            )
            controller.panelControllerContextProvider = self
            controller.remoteFocusedProjectID = projectId
            controller.remoteFocusSession(sessionID)
            return (controller, sessionID)
        }
        appState.startNewChat(for: project)
        let controller = runtimeStore.state(
            for: appState,
            modelID: modelID(for: appState.selectedCLI.visibleValue),
            permissionMode: appState.settings.chatPermissionMode,
            reasoningEffort: .high
        )
        controller.panelControllerContextProvider = self
        controller.remoteFocusedProjectID = projectId
        controller.remoteRequestSnapshot()
        return (controller, nil)
    }

    private func createDraftMutatingWorkspace(_ projectId: UUID) -> (controller: PanelStateBroadcasting, sessionId: UUID?)? {
        guard let appState else {
            Self.log.warning("createDraft failed reason=missingAppState projectId=\(projectId.uuidString, privacy: .public)")
            return nil
        }
        guard let runtimeStore else {
            Self.log.warning("createDraft failed reason=missingRuntimeStore projectId=\(projectId.uuidString, privacy: .public)")
            return nil
        }
        guard let project = selectProject(id: projectId) else {
            let known = appState.projects.map { $0.id.uuidString }.joined(separator: ",")
            Self.log.warning("createDraft failed reason=selectProjectRejected projectId=\(projectId.uuidString, privacy: .public) knownProjectIds=\(known, privacy: .public)")
            return nil
        }
        appState.startNewChat(for: project)
        let controller = runtimeStore.state(
            for: appState,
            modelID: modelID(for: appState.selectedCLI.visibleValue),
            permissionMode: appState.settings.chatPermissionMode,
            reasoningEffort: .high
        )
        controller.panelControllerContextProvider = self
        controller.remoteFocusedProjectID = projectId
        controller.remoteRequestSnapshot()
        return (controller, nil)
    }

    private func focusSessionMutatingWorkspace(_ sessionId: UUID) -> PanelStateBroadcasting? {
        guard let appState, let runtimeStore, let history = historyForUUID(sessionId) else { return nil }
        appState.selectCLIHistory(history)
        guard appState.selectedCLIHistoryID == history.id else {
            Self.log.warning("focusSession failed reason=selectCLIHistoryRejected sessionId=\(sessionId.uuidString, privacy: .public) historyId=\(history.id, privacy: .public)")
            return nil
        }
        let controller = runtimeStore.state(
            for: appState,
            modelID: modelID(for: history.cli.visibleValue),
            permissionMode: appState.settings.chatPermissionMode,
            reasoningEffort: .high
        )
        controller.panelControllerContextProvider = self
        if let project = project(for: history) {
            controller.remoteFocusedProjectID = project.id
        }
        controller.remoteFocusSession(sessionId)
        return controller
    }

    // MARK: PanelControllerContextProvider

    var appStateForRemoteFocus: AppState? { appState }

    func catalogSnapshot() -> ([PanelProjectDTO], [PanelModelDTO], [PanelSessionDTO]) {
        let projects: [PanelProjectDTO] = (appState?.projects ?? []).map { p in
            PanelProjectDTO(
                id: p.id,
                name: p.name,
                path: p.path,
                defaultCLI: p.defaultCLI.rawValue,
                createdAt: p.createdAt,
                updatedAt: p.updatedAt,
                lastOpenedAt: p.lastOpenedAt
            )
        }
        var models: [PanelModelDTO] = []
        if let modelService {
            let cliTypes: [CLIType] = [.claude, .codex]
            for cli in cliTypes {
                let defaultID = modelService.defaultModelID(for: cli)
                for option in modelService.options(for: cli) {
                    models.append(PanelModelDTO(
                        id: option.id,
                        title: option.title,
                        cli: cli.rawValue,
                        isDefault: option.id == defaultID
                    ))
                }
            }
        }
        // R5: compare only canonical project paths so symlinks/trailing slashes don't leave sessions with nil projectId.
        let projectByPath = Dictionary(grouping: appState?.projects.compactMap { project -> (String, ProjectItem)? in
            guard let path = AppState.normalizedProjectPath(project.path) else { return nil }
            return (path, project)
        } ?? [], by: { $0.0 })
        let sessions: [PanelSessionDTO] = (appState?.cliHistory ?? []).compactMap { h in
            // CLIHistorySession.sessionId is a String — try to parse as UUID; skip
            // entries that don't map cleanly (rare external CLI-format sessions).
            guard let sessionUUID = UUID(uuidString: h.sessionId) else { return nil }
            let project = AppState.normalizedProjectPath(h.projectPath).flatMap { projectByPath[$0]?.first?.1 }
            return PanelSessionDTO(
                id: sessionUUID,
                cli: h.cli.rawValue,
                projectId: project?.id,
                projectName: project?.name ?? "",
                projectPath: h.projectPath ?? "",
                title: h.title,
                modelID: "",
                runStatus: ChatRunStatus.idle.rawValue,
                statusText: "",
                createdAt: h.createdAt ?? Date.distantPast,
                updatedAt: h.updatedAt ?? Date.distantPast,
                lastCompletedAt: nil,
                queuedCount: 0
            )
        }
        return (projects, models, sessions)
    }

    func composerPlaceholder(for controller: ChatPanelController) -> String {
        // Default Mac placeholder; iOS doesn't strictly need this — it's a UX
        // hint. Kept short to avoid bloating every snapshot.
        switch controller.composerCLI.visibleValue {
        case .claude: return "向 Claude Code 提问…"
        case .codex: return "向 Codex 提问…"
        case .gemini, .custom: return "输入消息…"
        }
    }

    func defaultProject(for controller: ChatPanelController) -> ProjectItem? {
        guard let appState else { return nil }
        let projects = appState.projects
        if let id = controller.remoteFocusedProjectID,
           let project = projects.first(where: { $0.id == id }) {
            return project
        }
        let currentSessionPath = AppState.normalizedProjectPath(controller.currentSessionSnapshot?.projectPath)
        if let currentSessionPath,
           let project = projects.first(where: { AppState.normalizedProjectPath($0.path) == currentSessionPath }) {
            return project
        }
        return nil
    }

    func selectProject(id: UUID) -> ProjectItem? {
        guard let appState,
              let project = appState.projects.first(where: { $0.id == id }),
              appState.selectProject(project) else { return nil }
        return project
    }

    private func createOrAdopt(sessionID: UUID) -> ChatPanelController? {
        guard let runtimeStore, let appState,
              let history = historyForUUID(sessionID) else { return nil }
        let project = project(for: history)
        let controller = runtimeStore.remoteSessionState(
            for: history,
            appState: appState,
            projectID: project?.id,
            modelID: modelID(for: history.cli.visibleValue),
            permissionMode: appState.settings.chatPermissionMode,
            reasoningEffort: .high
        )
        controller?.panelControllerContextProvider = self
        if let project {
            controller?.remoteFocusedProjectID = project.id
        }
        return controller
    }

    private func historyForUUID(_ sessionID: UUID) -> CLIHistorySession? {
        appState?.cliHistory.first { sessionUUID(from: $0) == sessionID }
    }

    private func latestHistory(for project: ProjectItem) -> CLIHistorySession? {
        guard let projectPath = AppState.normalizedProjectPath(project.path) else { return nil }
        return appState?.cliHistory.first { AppState.normalizedProjectPath($0.projectPath) == projectPath }
    }

    private func project(for history: CLIHistorySession) -> ProjectItem? {
        guard let projectPath = AppState.normalizedProjectPath(history.projectPath) else { return nil }
        return appState?.projects.first { AppState.normalizedProjectPath($0.path) == projectPath }
    }

    private func sessionUUID(from history: CLIHistorySession) -> UUID? {
        UUID(uuidString: history.sessionId) ?? sessionUUIDComponent(in: history.id)
    }

    private func sessionUUIDComponent(in historyID: String) -> UUID? {
        let parts = historyID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return UUID(uuidString: parts[1])
    }

    private func modelID(for cli: CLIType) -> String {
        guard let appState else { return modelService?.defaultModelID(for: cli) ?? ChatModelCatalog.defaultModelID(for: cli) }
        switch cli.visibleValue {
        case .claude, .gemini, .custom:
            return appState.settings.selectedClaudeModelID.nonEmptyTrimmed
                ?? modelService?.defaultModelID(for: cli)
                ?? ChatModelCatalog.defaultModelID(for: cli)
        case .codex:
            return appState.settings.selectedCodexModelID.nonEmptyTrimmed
                ?? modelService?.defaultModelID(for: cli)
                ?? ChatModelCatalog.defaultModelID(for: cli)
        }
    }
}

// MARK: - Wiring entry-point for the server

/// Singleton holder so `RemoteChatServer.VNCPipeline` can pick up the lookup
/// once the App constructs the ChatRuntimeStore. The app sets this from
/// `CodevokeApp` after `@StateObject` initialization; the server reads it on
/// first connection. If unset, the server falls back to the stub lookup.
@MainActor
enum RemoteVNCWiring {
    /// Active production lookup. The server prefers this over the stub.
    static weak var lookup: RuntimeStorePanelControllerLookup?

    /// Install / refresh wiring. Safe to call multiple times.
    static func install(runtimeStore: ChatRuntimeStore, appState: AppState, modelService: ChatModelService?) {
        let nextLookup = RuntimeStorePanelControllerLookup(
            runtimeStore: runtimeStore,
            appState: appState,
            modelService: modelService
        )
        lookup = nextLookup
        // Detain via a singleton retainer; weak references die otherwise once
        // `install` returns and the local `nextLookup` falls out of scope.
        retainedLookup = nextLookup
    }

    private static var retainedLookup: RuntimeStorePanelControllerLookup?
}
