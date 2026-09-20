import AppKit
import ChatCore
import Combine
import Foundation

struct StreamingTextEntry: Equatable {
    var text: String
    var status: String
    var requestID: String?
}

@MainActor
final class StreamingTextStore: ObservableObject {
    @Published private(set) var entries: [UUID: StreamingTextEntry] = [:]
    private let revisionSubject = PassthroughSubject<Int, Never>()
    private(set) var revision = 0
    private(set) var totalTextLength = 0
    var revisionPublisher: AnyPublisher<Int, Never> { revisionSubject.eraseToAnyPublisher() }

    func text(for id: UUID) -> String? {
        entries[id]?.text
    }

    func entry(for id: UUID) -> StreamingTextEntry? {
        entries[id]
    }

    func setText(_ text: String, status: String, requestID: String?, for id: UUID) {
        let previousLength = entries[id]?.text.count ?? 0
        entries[id] = StreamingTextEntry(text: text, status: status, requestID: requestID)
        publishChange(lengthDelta: text.count - previousLength)
    }

    func append(_ delta: String, status: String?, requestID: String?, to id: UUID) {
        var entry = entries[id] ?? StreamingTextEntry(text: "", status: "streaming", requestID: nil)
        entry.text += delta
        if let status {
            entry.status = status
        }
        if let requestID {
            entry.requestID = requestID
        }
        entries[id] = entry
        publishChange(lengthDelta: delta.count)
    }

    func remove(_ id: UUID) {
        guard let removed = entries.removeValue(forKey: id) else { return }
        publishChange(lengthDelta: -removed.text.count)
    }

    func removeAll() {
        guard !entries.isEmpty || revision != 0 || totalTextLength != 0 else { return }
        entries.removeAll()
        totalTextLength = 0
        revision &+= 1
        revisionSubject.send(revision)
    }

    private func publishChange(lengthDelta: Int) {
        totalTextLength = max(0, totalTextLength + lengthDelta)
        revision &+= 1
        revisionSubject.send(revision)
    }
}

@MainActor
final class ChatStatusStore: ObservableObject {
    @Published private(set) var statusText = "就绪"
    @Published private(set) var tokensUsed = 0
    @Published private(set) var tokensTotal = 200_000

    func updateStatusText(_ value: String) {
        guard statusText != value else { return }
        statusText = value
    }

    func updateTokens(used: Int, total: Int) {
        if tokensUsed != used {
            tokensUsed = used
        }
        if tokensTotal != total {
            tokensTotal = total
        }
    }
}

/// Backward-compatible alias. The canonical name after the VNC refactor is
/// `ChatPanelController`. Mac SwiftUI views and existing services may continue
/// using the `ChatPanelState` symbol; new code (`RemoteChat` server, `iOS`
/// thin-client adapter) should refer to `ChatPanelController` directly.
typealias ChatPanelState = ChatPanelController

@MainActor
final class ChatPanelController: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var queuedRequests: [QueuedChatRequest] = []
    @Published var status: ChatRunStatus = .idle
    @Published var capabilities: [CLIType: ChatCLICapability] = [:]
    @Published var isAwaitingFirstModelOutput = false
    @Published var isLoadingHistory = false
    @Published private(set) var isLoadingEarlierHistory = false
    @Published private(set) var historyTotalMessageCount = 0
    @Published var structureRevision = 0

    // MARK: - Composer mirror (for VNC remote-control surface)
    // Mac SwiftUI views still own their own composer @State; these properties
    // give the remote-protocol agent something to snapshot/patch when iOS
    // drives the composer. Updates from Mac UI flow through `setComposerText`
    // / `setCLI` etc. so both sides stay in sync.
    @Published private(set) var composerText: String = ""
    @Published private(set) var composerCLI: CLIType = .claude
    @Published private(set) var composerModelID: String = ""
    @Published private(set) var composerContextModelID: String? = nil
    @Published private(set) var composerPermissionMode: ChatPermissionMode = .autoEdit
    @Published private(set) var composerReasoningEffort: ChatReasoningEffort = .high
    @Published private(set) var composerAttachments: [ChatMessageAttachment] = []

    /// Fires the session id whenever any observable state on this controller
    /// changes. The remote protocol agent subscribes here to coalesce SwiftUI
    /// publisher storms into a single snapshot/patch envelope per main-actor
    /// turn (see spec §4.8 / §4.9).
    private let sessionChangeSubject = PassthroughSubject<UUID?, Never>()
    var sessionChangePublisher: AnyPublisher<UUID?, Never> {
        sessionChangeSubject.eraseToAnyPublisher()
    }
    let streamingTextStore = StreamingTextStore()
    let statusStore = ChatStatusStore()
    var statusText = "就绪" {
        didSet { statusStore.updateStatusText(statusText) }
    }
    var tokensUsed: Int = 0 {
        didSet { statusStore.updateTokens(used: tokensUsed, total: tokensTotal) }
    }
    var tokensTotal: Int = 200_000 {
        didSet { statusStore.updateTokens(used: tokensUsed, total: tokensTotal) }
    }

    private static let compactThreshold: Double = 0.90
    private static let compactRearmThreshold: Double = 0.70
    /// Claude Code has native auto-compaction, so the app only steps in late (e.g. 1M-window
    /// models where the CLI's own threshold never fires before the relay rejects the request).
    private static let claudeCompactFallbackThreshold: Double = 0.95
    private static let firstVisibleOutputTimeoutNanoseconds: UInt64 = 45_000_000_000
    // After the process is alive (emitted backend activity) we switch to this longer backstop:
    // if it never produces any VISIBLE output (only protocol noise), fail instead of spinning
    // the loading indicator forever.
    private static let silentOutputBackstopNanoseconds: UInt64 = 180_000_000_000
    nonisolated static let historyInitialMessageLimit = 240
    private var didAutoCompact = false
    private var didReceiveBackendActivityAfterStart = false
    /// Caches the immutable paged-out history prefix used when persisting a paged session, so
    /// every persist no longer synchronously re-decodes the entire on-disk transcript on the
    /// main actor (a periodic hitch on large sessions). Keyed by (sessionID, prefixCount).
    private var cachedPersistencePrefix: (sessionID: UUID, count: Int, messages: [ChatMessage])?

    static func defaultContextWindow(
        for modelID: String,
        cli: CLIType = .claude,
        metadataWindow: Int? = nil
    ) -> Int {
        ChatModelCatalog.contextWindow(for: modelID, cli: cli, metadataWindow: metadataWindow)
    }

    static func isMillionContextModel(_ modelID: String) -> Bool {
        defaultContextWindow(for: modelID) >= 1_000_000
    }

    private var currentSession: ChatSessionRecord? {
        didSet {
            // currentSession 的 sessionID 变化时，刷新对 RemoteSessionMirrorBus 的订阅，
            // 让 Mac 端 UI 实时镜像 iOS 触发的远程对话（详见 RemoteSessionMirrorBus）。
            if currentSession?.id != oldValue?.id {
                refreshRemoteMirrorSubscription()
            }
        }
    }
    private var currentTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    private var historyLoadID: UUID?
    private var earlierHistoryLoadID: UUID?
    private var historyNextBeforeIndex: Int?
    private var pendingPersistTask: Task<Void, Never>?
    private var pendingPersistShouldSaveMessages: Bool?
    private var activeBackend: ChatProcessBackend?
    private var activeRunRequest: QueuedChatRequest?
    private var activeRunStartedAt: Date?
    private var firstVisibleOutputAt: Date?
    private var isRuntimeVisible = false
    var onActivityChanged: ((ChatSessionActivity?) -> Void)?
    var onSessionPersisted: (() -> Void)?
    var onRemoteSessionBegan: ((ChatSessionRecord) -> Void)?

    // MARK: 远程镜像
    /// 标记当前 session 正在被 RemoteChatBridge 远程驱动（iOS 触发的对话）。
    /// 镜像模式下：actuallyPersist 跳过（Bridge 负责写盘）、send() 拒绝（防止干扰远程任务）。
    @Published private(set) var isMirroringRemoteSession: Bool = false
    private var remoteMirrorSessionID: UUID?
    private var remoteMirrorToken: UUID?
    private var remoteMirrorBeginToken: UUID?

    var currentSessionID: UUID? { currentSession?.id }
    var currentSessionSnapshot: ChatSessionRecord? { currentSession }
    var unloadedEarlierMessageCount: Int {
        max(0, historyTotalMessageCount - messages.count)
    }
    var canLoadEarlierHistory: Bool {
        currentSessionID != nil
            && historyNextBeforeIndex != nil
            && unloadedEarlierMessageCount > 0
            && !isLoadingHistory
            && !isLoadingEarlierHistory
    }

    var activity: ChatSessionActivity? {
        if let currentSession {
            return ChatSessionActivity(
                status: status,
                statusText: statusText,
                queuedCount: queuedRequests.count,
                lastCompletedAt: currentSession.lastCompletedAt,
                activeRunStartedAt: activeRunStartedAt
            )
        }
        return nil
    }

    var hasLiveRun: Bool {
        status.isRunning || currentTask != nil || activeBackend != nil
    }

    var shouldRetainRuntime: Bool {
        hasLiveRun
            || status == .waitingPermission
            || status == .waitingInput
            || !queuedRequests.isEmpty
            || isLoadingHistory
            || isMirroringRemoteSession
    }

    var hasPendingPlanConfirmation: Bool {
        latestExitPlanModeMessageID != nil
    }

    func setRuntimeVisible(_ visible: Bool) {
        isRuntimeVisible = visible
        if visible {
            subscribeRemoteMirrorBeginsIfNeeded()
        } else {
            unsubscribeRemoteMirrorBegins()
        }
    }
    private struct StreamingMessageKey: Hashable {
        let kind: ChatMessageKind
        let requestID: String?

        init(kind: ChatMessageKind, requestID: String?) {
            self.kind = kind
            self.requestID = requestID?.nonEmptyTrimmed
        }
    }

    private var isUserStopping = false
    private var shouldStartQueuedRequestAfterBackendEnds = false
    private var activeAssistantMessageID: UUID?
    private var activeStreamingMessageIDs: [StreamingMessageKey: UUID] = [:]
    private var activeParentUserMessageID: UUID?
    private var pendingDeltaBuffers: [UUID: String] = [:]
    private var pendingDeltaStatuses: [UUID: String] = [:]
    private var pendingDeltaRequestIDs: [UUID: String] = [:]
    private var pendingOutputTokenCounts: [UUID: Int] = [:]
    private var deltaFlushTask: Task<Void, Never>?
    private var runSnapshotTask: Task<Void, Never>?
    private var stopFallbackTask: Task<Void, Never>?
    private var queuedStartTask: Task<Void, Never>?
    private var firstVisibleOutputTimeoutTask: Task<Void, Never>?

    init() {
        refreshCapabilities()
    }


    func refreshCapabilities(force: Bool = false) {
        Task { [weak self] in
            let result = await ChatCLICapabilityProbe.probeAll(force: force)
            self?.capabilities = result
        }
    }

    deinit {
        MainActor.assumeIsolated {
            prepareForApplicationTermination()
            unsubscribeRemoteMirror()
            unsubscribeRemoteMirrorBegins()
        }
        historyLoadTask?.cancel()
#if DEBUG
        print("[ChatPanelController] deinit")
#endif
    }

    func prepareForApplicationTermination() {
        persistActiveRunSnapshotBeforeCleanup()
        // The app is exiting now: synchronously kill the CLI process group so backgrounded
        // children (e.g. a running xcodebuild) aren't orphaned. interrupt()'s async signal
        // ladder would never fire before the process exits.
        activeBackend?.terminateImmediately()
        cleanupActiveRun()
    }

    func syncContextWindow(modelID: String, cli: CLIType = .claude, contextWindow: Int? = nil) {
        let nextTokensTotal = Self.defaultContextWindow(for: modelID, cli: cli, metadataWindow: contextWindow)
        guard tokensTotal != nextTokensTotal || didAutoCompact else { return }
        tokensTotal = nextTokensTotal
        didAutoCompact = false
    }

    func resetToNewSession() {
        flushPendingPersistImmediately()
        clearCurrentSessionState()
    }

    private func resetToNewSessionIfIdle() {
        guard !hasLiveRun else {
            publishActivity()
            return
        }
        resetToNewSession()
    }

    func discardCurrentSessionWithoutPersisting() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistShouldSaveMessages = nil
        clearCurrentSessionState()
    }

    private func clearCurrentSessionState() {
        cleanupActiveRun()
        historyLoadTask?.cancel()
        historyLoadTask = nil
        historyLoadID = nil
        isLoadingHistory = false
        resetHistoryPagingState()
        currentSession = nil
        messages = []
        queuedRequests = []
        status = .idle
        statusText = "新会话"
        bumpStructureRevision()
        publishActivity()
    }

    private func resetHistoryPagingState(totalCount: Int = 0, nextBeforeIndex: Int? = nil) {
        earlierHistoryLoadID = nil
        isLoadingEarlierHistory = false
        historyTotalMessageCount = totalCount
        historyNextBeforeIndex = nextBeforeIndex
    }

    private func materializeFullHistoryIfNeededForMutation() {
        guard let sessionID = currentSession?.id, historyNextBeforeIndex != nil else { return }
        messages = ChatSessionStore.loadMessages(sessionID: sessionID)
        resetHistoryPagingState(totalCount: messages.count)
        bumpStructureRevision()
    }

    private func persistActiveRunSnapshotBeforeCleanup() {
        guard currentSession != nil else {
            flushPendingPersistImmediately()
            return
        }
        let hadStreamingState = !pendingDeltaBuffers.isEmpty
            || !activeStreamingMessageIDs.isEmpty
            || messages.contains(where: \.isStreaming)
        let hadActiveRun = hasLiveRun || hadStreamingState || isAwaitingFirstModelOutput
        if hadStreamingState {
            flushPendingDeltas()
            finishStreamingMessages(status: "stopped")
        }
        guard hadActiveRun else {
            flushPendingPersistImmediately()
            return
        }
        setAwaitingFirstModelOutput(false)
        currentSession?.updatedAt = Date()
        currentSession?.lastCompletedAt = Date()
        activeRunRequest = nil
        activeRunStartedAt = nil
        status = .completed
        statusText = "已停止"
        isUserStopping = false
        shouldStartQueuedRequestAfterBackendEnds = false
        actuallyPersist()
    }

    func loadDraftDefaults(
        cli: CLIType,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort
    ) {
        guard !hasLiveRun else { return }
        composerCLI = cli.visibleValue
        composerModelID = modelID
        composerContextModelID = modelID
        composerPermissionMode = permissionMode
        composerReasoningEffort = reasoningEffort
        syncContextWindow(modelID: modelID, cli: cli)
        publishActivity()
    }

    private func cleanupActiveRun() {
        flushPendingDeltas()
        activeBackend?.interrupt()
        currentTask?.cancel()
        currentTask = nil
        activeBackend = nil
        resetTransientRunState()
    }

    private func resetTransientRunState() {
        activeAssistantMessageID = nil
        activeStreamingMessageIDs.removeAll()
        activeParentUserMessageID = nil
        streamingTextStore.removeAll()
        pendingDeltaBuffers.removeAll()
        pendingDeltaStatuses.removeAll()
        pendingDeltaRequestIDs.removeAll()
        pendingOutputTokenCounts.removeAll()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        runSnapshotTask?.cancel()
        runSnapshotTask = nil
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        queuedStartTask?.cancel()
        queuedStartTask = nil
        firstVisibleOutputTimeoutTask?.cancel()
        firstVisibleOutputTimeoutTask = nil
        isUserStopping = false
        shouldStartQueuedRequestAfterBackendEnds = false
        activeRunRequest = nil
        activeRunStartedAt = nil
        firstVisibleOutputAt = nil
        didReceiveBackendActivityAfterStart = false
        isAwaitingFirstModelOutput = false
    }

    func loadFromAppState(
        _ appState: AppState,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort
    ) {
        guard let historyID = appState.selectedCLIHistoryID else {
            if currentSession != nil, !messages.isEmpty {
                publishActivity()
                return
            }
            resetToNewSessionIfIdle()
            return
        }

        guard let history = appState.cliHistory.first(where: { $0.id == historyID }) else {
            resetToNewSessionIfIdle()
            return
        }

        guard history.storageKey == ChatSessionStore.storageKey,
              let uuid = UUID(uuidString: history.sessionId) else {
            resetToNewSessionIfIdle()
            return
        }

        flushPendingPersistImmediately()
        historyLoadTask?.cancel()
        historyLoadTask = nil
        earlierHistoryLoadID = nil
        isLoadingEarlierHistory = false
        if currentSession?.id == uuid {
            historyLoadID = nil
            if isLoadingHistory {
                isLoadingHistory = false
                bumpStructureRevision()
            }
            publishActivity()
            return
        }

        let loadID = UUID()
        historyLoadID = loadID
        isLoadingHistory = true
        historyLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                let session = ChatSessionStore.loadSession(id: uuid)
                let page = ChatSessionStore.loadMessagePage(sessionID: uuid, beforeIndex: nil, limit: Self.historyInitialMessageLimit)
                return (session, page)
            }.value
            guard let self, self.historyLoadID == loadID, !Task.isCancelled else { return }
            self.resetTransientRunState()
            self.currentSession = loaded.0
            self.messages = loaded.1.messages
            self.queuedRequests = loaded.0?.queuedRequests ?? []
            self.status = loaded.0?.runStatus ?? .idle
            self.statusText = loaded.0?.statusText ?? "已加载本地会话"
            self.resetHistoryPagingState(totalCount: loaded.1.totalCount, nextBeforeIndex: loaded.1.nextBeforeIndex)
            self.reconcileLoadedRunStateIfStale()
            self.isLoadingHistory = false
            self.historyLoadID = nil
            self.historyLoadTask = nil
            self.bumpStructureRevision()
            self.publishActivity()
        }
    }

    func loadPersistedSession(_ sessionID: UUID) {
        guard !hasLiveRun || currentSessionID == sessionID else {
            publishActivity()
            return
        }
        flushPendingPersistImmediately()
        historyLoadTask?.cancel()
        historyLoadTask = nil
        earlierHistoryLoadID = nil
        isLoadingEarlierHistory = false
        if currentSession?.id == sessionID {
            historyLoadID = nil
            if isLoadingHistory {
                isLoadingHistory = false
                bumpStructureRevision()
            }
            publishActivity()
            return
        }

        let loadID = UUID()
        historyLoadID = loadID
        isLoadingHistory = true
        historyLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                let session = ChatSessionStore.loadSession(id: sessionID)
                let page = ChatSessionStore.loadMessagePage(sessionID: sessionID, beforeIndex: nil, limit: Self.historyInitialMessageLimit)
                return (session, page)
            }.value
            guard let self, self.historyLoadID == loadID, !Task.isCancelled else { return }
            self.resetTransientRunState()
            self.currentSession = loaded.0
            self.messages = loaded.1.messages
            self.queuedRequests = loaded.0?.queuedRequests ?? []
            self.status = loaded.0?.runStatus ?? .idle
            self.statusText = loaded.0?.statusText ?? "已加载本地会话"
            self.resetHistoryPagingState(totalCount: loaded.1.totalCount, nextBeforeIndex: loaded.1.nextBeforeIndex)
            self.reconcileLoadedRunStateIfStale()
            if let session = loaded.0 {
                self.composerCLI = session.cli.visibleValue
                self.composerModelID = session.modelID
                self.composerContextModelID = session.modelID
                self.composerPermissionMode = session.permissionMode
                self.composerReasoningEffort = session.reasoningEffort
                self.tokensTotal = Self.defaultContextWindow(for: session.modelID, cli: session.cli)
            }
            self.isLoadingHistory = false
            self.historyLoadID = nil
            self.historyLoadTask = nil
            self.bumpStructureRevision()
            self.publishActivity()
        }
    }

    func loadEarlierHistoryMessages(limit: Int = 240) {
        guard let sessionID = currentSession?.id,
              let beforeIndex = historyNextBeforeIndex,
              !isLoadingHistory,
              !isLoadingEarlierHistory else { return }
        let loadID = UUID()
        earlierHistoryLoadID = loadID
        isLoadingEarlierHistory = true
        Task { [weak self] in
            let page = await Task.detached(priority: .utility) {
                ChatSessionStore.loadMessagePage(sessionID: sessionID, beforeIndex: beforeIndex, limit: limit)
            }.value
            guard let self,
                  self.earlierHistoryLoadID == loadID,
                  self.currentSessionID == sessionID,
                  !Task.isCancelled else { return }
            let existingIDs = Set(self.messages.map(\.id))
            let olderMessages = page.messages.filter { !existingIDs.contains($0.id) }
            if !olderMessages.isEmpty {
                self.messages = olderMessages + self.messages
            }
            self.historyTotalMessageCount = max(page.totalCount, self.messages.count)
            self.historyNextBeforeIndex = page.nextBeforeIndex
            self.isLoadingEarlierHistory = false
            self.earlierHistoryLoadID = nil
            self.bumpStructureRevision()
            self.publishActivity()
        }
    }

    @discardableResult
    func send(
        text rawText: String,
        backendText rawBackendText: String? = nil,
        appendRuleText rawAppendRuleText: String? = nil,
        attachments: [ChatMessageAttachment] = [],
        project: ProjectItem?,
        cli: CLIType,
        modelID: String,
        contextModelID: String? = nil,
        contextWindow: Int? = nil,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort,
        sessionMode: SessionMode,
        resumeSessionID: String?,
        prioritizeBeforeQueuedRequests: Bool = false
    ) -> Bool {
        let displayText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendText = (rawBackendText ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        let appendRuleText = rawAppendRuleText?.nonEmptyTrimmed
        guard !displayText.isEmpty, !backendText.isEmpty else { return false }
        guard !isLoadingHistory else {
            appendError("历史会话仍在加载，请稍后再发送。")
            return false
        }
        guard let project else {
            appendError("请先选择项目。")
            return false
        }

        let request = QueuedChatRequest(
            text: backendText,
            displayText: displayText,
            appendRuleText: appendRuleText,
            attachments: attachments,
            project: project,
            cli: cli,
            modelID: modelID,
            contextModelID: contextModelID,
            contextWindow: contextWindow,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            sessionMode: sessionMode,
            resumeSessionID: resumeSessionID
        )
        // VNC-refactor §1.3 / §7.1: this is the *single* queue surface in the
        // system. `RemoteChatBridge.pendingRequests` is being removed in the
        // protocol-server agent's worktree; once that lands, every send — Mac
        // UI or remote command — funnels into this same queue.
        if shouldQueueNewRequest(prioritizeBeforeQueuedRequests: prioritizeBeforeQueuedRequests) {
            queuedRequests.append(request)
            statusText = "已加入队列"
            bumpStructureRevision()
            persistCurrentSession(saveMessages: false)
            publishActivity()
            return true
        }
        return startRun(request)
    }

    private func shouldQueueNewRequest(prioritizeBeforeQueuedRequests: Bool) -> Bool {
        status.isRunning || currentTask != nil || activeBackend != nil || isMirroringRemoteSession || (!prioritizeBeforeQueuedRequests && !queuedRequests.isEmpty)
    }

    func cancelQueuedRequest(_ id: UUID) {
        queuedRequests.removeAll { $0.id == id }
        bumpStructureRevision()
        persistCurrentSession(saveMessages: false)
        publishActivity()
    }

    func discardQueuedRequestsForNewChat() {
        guard !queuedRequests.isEmpty else { return }
        queuedRequests = []
        bumpStructureRevision()
        persistCurrentSession(saveMessages: false)
        publishActivity()
    }

    @discardableResult
    private func startRun(_ request: QueuedChatRequest) -> Bool {
        let visibleCLI = request.cli.visibleValue
        guard let capability = capabilities[visibleCLI] else {
            appendError("正在检测 \(visibleCLI.displayName)，请稍后重试。")
            refreshCapabilities()
            return false
        }
        guard let executable = capability.executablePath, capability.errorMessage == nil else {
            status = .unsupportedVersion
            appendError(capability.errorMessage ?? "\(visibleCLI.displayName) 不可用。")
            return false
        }
        if visibleCLI == .codex, !capability.supportsAppServer {
            status = .unsupportedVersion
            appendError("当前 Codex 版本不支持 app-server，无法在内嵌对话中启动。")
            return false
        }
        if request.permissionMode == .ask, !capability.supportsRuntimePermissionApprovals {
            // 除 Codex（app-server 审批回写）和 DeepSeek Harness（ACP
            // session/request_permission）外，其余 CLI 的无头进程都没有运行中
            // 权限应答通道，ask 模式会卡死在永远不会到达的权限提示上。
            status = .unsupportedVersion
            let reason: String
            if visibleCLI == .claude {
                reason = capability.supportsStreamJSONInput
                    ? "当前 Claude Code CLI 未公开 stdin 权限 allow/deny 回写协议。"
                    : "当前 Claude Code 版本不支持 stream-json stdin 输入。"
            } else if visibleCLI == .dsh {
                reason = "当前 DeepSeek Harness 的 ACP 通道不可用（dsh --profile acp 探测失败）。"
            } else {
                reason = "当前 \(visibleCLI.displayName) 无头模式不支持运行中权限审批。"
            }
            appendError("\(reason)请改用自动编辑/完全访问权限后重试，避免工具调用时出现无法响应的假权限按钮。")
            return false
        }

        let effectiveRunModelID = ChatModelCatalog.compatibleModelID(request.modelID, cli: visibleCLI)
        let requestedContextModelID = request.contextModelID?.nonEmptyTrimmed ?? request.modelID
        let effectiveContextModelID = ChatModelCatalog.compatibleModelID(requestedContextModelID, cli: visibleCLI)
        var session = ensureSession(
            project: request.project,
            cli: visibleCLI,
            modelID: effectiveContextModelID,
            permissionMode: request.permissionMode,
            reasoningEffort: request.reasoningEffort,
            firstPrompt: request.displayText
        )
        session.cli = visibleCLI
        session.modelID = effectiveContextModelID
        session.permissionMode = request.permissionMode
        session.reasoningEffort = request.reasoningEffort
        session.updatedAt = Date()
        if currentSession?.id == session.id {
            materializeFullHistoryIfNeededForMutation()
        }
        let isStartingNewSession = currentSession?.id != session.id
        let isStartingQueuedRequest = queuedRequests.contains(where: { $0.id == request.id })
        if isStartingNewSession {
            messages.removeAll(keepingCapacity: false)
            resetHistoryPagingState()
            if !isStartingQueuedRequest {
                queuedRequests.removeAll(keepingCapacity: false)
            }
            resetTransientRunState()
        }
        currentSession = session

        tokensTotal = Self.defaultContextWindow(
            for: effectiveContextModelID,
            cli: visibleCLI,
            metadataWindow: request.contextWindow
        )
        didAutoCompact = false

        let userMessage = ChatMessage(
            sessionID: session.id,
            kind: .user,
            text: request.displayText,
            status: "user",
            appendRuleText: request.appendRuleText,
            attachments: request.attachments
        )
        activeParentUserMessageID = userMessage.id
        activeAssistantMessageID = nil
        activeStreamingMessageIDs.removeAll()
        messages.append(userMessage)
        publishRemoteUserMessageIfNeeded(userMessage, session: session)
        setAwaitingFirstModelOutput(true)
        bumpStructureRevision()

        let options = ChatRunOptions(
            cli: visibleCLI,
            executablePath: executable,
            projectPath: request.project.path,
            modelID: effectiveRunModelID,
            permissionMode: request.permissionMode,
            reasoningEffort: request.reasoningEffort,
            sessionMode: request.sessionMode,
            resumeSessionID: effectiveResumeSessionID(request.resumeSessionID, for: session, cli: visibleCLI, projectPath: request.project.path),
            supportsStreamJSONInput: capability.supportsStreamJSONInput
        )
        let backend = ChatBackendFactory.makeBackend(for: visibleCLI)
        activeBackend = backend
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        isUserStopping = false
        shouldStartQueuedRequestAfterBackendEnds = false
        activeRunRequest = request
        activeRunStartedAt = Date()
        firstVisibleOutputAt = nil
        didReceiveBackendActivityAfterStart = false
        status = .starting
        statusText = "启动 \(visibleCLI.displayName)"
        if isStartingNewSession {
            actuallyPersist()
        } else {
            persistCurrentSession()
        }
        publishActivity()

        queuedStartTask?.cancel()
        queuedStartTask = nil

        currentTask = Task { [weak self] in
            guard let self else { return }
            let scopedURL: URL
            let didStartAccessing: Bool
            do {
                scopedURL = try ProjectStore.resolveURL(for: request.project)
                didStartAccessing = scopedURL.startAccessingSecurityScopedResource()
            } catch {
                await MainActor.run {
                    self.appendError(error.localizedDescription)
                    self.status = .failed
                    self.statusText = "项目权限失效"
                    self.currentTask = nil
                    self.activeBackend = nil
                    self.activeRunRequest = nil
                    self.activeRunStartedAt = nil
                    self.setAwaitingFirstModelOutput(false)
                    self.actuallyPersist()
                }
                return
            }
            guard didStartAccessing else {
                await MainActor.run {
                    self.appendError("项目目录授权失效，请重新添加或重新授权项目。")
                    self.status = .failed
                    self.statusText = "项目权限失效"
                    self.currentTask = nil
                    self.activeBackend = nil
                    self.activeRunRequest = nil
                    self.activeRunStartedAt = nil
                    self.setAwaitingFirstModelOutput(false)
                    self.actuallyPersist()
                }
                return
            }
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Running \(visibleCLI.displayName) chat task"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                scopedURL.stopAccessingSecurityScopedResource()
            }

            do {
                for try await event in backend.start(
                    prompt: request.text,
                    options: options,
                    session: session,
                    attachments: request.attachments
                ) {
                    await MainActor.run {
                        self.apply(event)
                    }
                }
                await MainActor.run {
                    self.backendStreamDidEnd()
                }
            } catch {
                await MainActor.run {
                    self.currentTask = nil
                    self.activeBackend = nil
                    if Task.isCancelled || self.isUserStopping {
                        self.completeInterruptedRunIfNeeded()
                        return
                    }
                    self.appendError(error.localizedDescription)
                    self.status = .failed
                    self.statusText = "失败"
                    self.activeRunRequest = nil
                    self.activeRunStartedAt = nil
                    self.flushPendingDeltas()
                    self.finishStreamingMessages(status: "failed")
                    self.setAwaitingFirstModelOutput(false)
                    self.shouldStartQueuedRequestAfterBackendEnds = false
                    self.stopRunSnapshotLoop()
                    self.actuallyPersist()
                }
            }
        }
        startRunSnapshotLoop()
        return true
    }

    func removeMessageThread(_ id: UUID) {
        materializeFullHistoryIfNeededForMutation()
        // 先把整条 thread 涉及的所有消息 ID 收集出来：thread root（id 本身）+ 子消息
        // （assistant / tool result / reasoning 等，它们的 parentUserMessageID == id）。
        let removedIDs = Set(
            messages
                .filter { $0.id == id || $0.parentUserMessageID == id }
                .map(\.id)
        )
        messages.removeAll { removedIDs.contains($0.id) }
        // 旧实现只按 value=id 过滤，但子消息的 ID 不等于 thread root id，所以
        // streaming 子消息的 entry 会留在 activeStreamingMessageIDs / streamingTextStore
        // 等结构里，造成幽灵 streaming 状态。
        activeStreamingMessageIDs = activeStreamingMessageIDs.filter { !removedIDs.contains($0.value) }
        for removedID in removedIDs {
            streamingTextStore.remove(removedID)
            pendingDeltaBuffers.removeValue(forKey: removedID)
            pendingDeltaStatuses.removeValue(forKey: removedID)
            pendingDeltaRequestIDs.removeValue(forKey: removedID)
            pendingOutputTokenCounts.removeValue(forKey: removedID)
        }
        if let activeID = activeAssistantMessageID, removedIDs.contains(activeID) {
            activeAssistantMessageID = nil
        }
        if activeParentUserMessageID == id {
            activeParentUserMessageID = nil
            activeAssistantMessageID = nil
            activeStreamingMessageIDs.removeAll()
        }
        bumpStructureRevision()
        persistCurrentSession()
    }

    func interrupt(startQueuedAfterStop: Bool = false) {
        // 镜像模式下 status.isRunning 是被远程事件设置的；本地按"停止"会把状态机
        // 拨到 .stopping、设置 isUserStopping、finishStreamingMessages，但 Bridge
        // 后续推过来的事件还会继续 apply，结果是本地状态混乱、Bridge 远程任务并未真正停止。
        guard !isMirroringRemoteSession else { return }
        guard status.isRunning else {
            if startQueuedAfterStop {
                scheduleNextQueuedRequestIfNeeded()
            }
            return
        }
        flushPendingDeltas()
        isUserStopping = true
        shouldStartQueuedRequestAfterBackendEnds = startQueuedAfterStop
        status = .stopping
        statusText = startQueuedAfterStop ? "正在停止当前任务并发送" : "正在停止"
        activeBackend?.interrupt()
        currentTask?.cancel()
        currentTask = nil
        activeBackend = nil
        flushPendingDeltas()
        finishStreamingMessages(status: "stopped")
        setAwaitingFirstModelOutput(false)
        // Audit B-P0-2: `finishStreamingMessages` only touches rows with
        // `isStreaming==true`. Permission / interactive request rows are
        // created with `isStreaming=false` and `status="waiting"`, so without
        // this sweep the UI keeps the Allow/Deny / answer buttons live even
        // though the backend has been killed. Tapping them later runs into
        // `activeBackend == nil` and degrades to `.failed`. Mark them as
        // cancelled here so the UI collapses cleanly.
        cancelWaitingInteractiveRequestsOnInterrupt()
        stopRunSnapshotLoop()
        actuallyPersist()
        scheduleStopFallback()
    }

    /// Cancels every permission / interactive request row still marked `waiting`. Only valid
    /// when no live backend could ever answer them (interrupt, backend stream end, or a stale
    /// persisted session) — otherwise the transcript keeps showing Allow/Deny / option buttons
    /// whose taps either hit `activeBackend == nil` and degrade to `.failed`, or (worse) write a
    /// bogus control_response into a NEW run's backend.
    @discardableResult
    private func cancelWaitingInteractiveRequestsOnInterrupt() -> Bool {
        guard !isMirroringRemoteSession else { return false }
        var didMutate = false
        for index in messages.indices {
            let kind = messages[index].kind
            guard kind == .permissionRequest || kind == .interactiveRequest else { continue }
            if messages[index].status == "waiting" {
                messages[index].status = "cancelled"
                didMutate = true
            }
            if messages[index].interactiveRequest?.status == .waiting {
                messages[index].interactiveRequest?.status = .cancelled
                didMutate = true
            }
        }
        if didMutate {
            bumpStructureRevision()
        }
        return didMutate
    }

    func respondToPermission(requestID: String, allowed: Bool) {
        respondToPermission(requestID: requestID, decision: allowed ? .allow : .deny)
    }

    func respondToPermission(requestID: String, decision: ChatPermissionDecision) {
        guard !isMirroringRemoteSession else {
            // 镜像模式下没有本地 backend，调 activeBackend?.respondToPermission 必然返回
            // false，原代码会走错误路径把 status 翻成 .failed 并 appendError，污染镜像状态。
            // 远程权限请求应该在 iOS 端响应。
            appendError("该会话正在 iOS 端远程运行，请在 iOS 端响应权限请求。")
            return
        }
        let previousStatus = status
        guard activeBackend?.respondToPermission(requestID: requestID, decision: decision) == true else {
            if let index = messages.firstIndex(where: { $0.requestID == requestID }) {
                messages[index].status = "failed"
            }
            appendError("权限响应写回失败。当前 CLI 模式不支持内嵌权限交互，请改用自动编辑/完全访问权限后重试。")
            status = .failed
            statusText = "权限写回失败"
            bumpStructureRevision()
            actuallyPersist()
            return
        }
        if let index = messages.firstIndex(where: { $0.requestID == requestID }) {
            messages[index].status = decision.statusText
        }
        status = .streaming
        statusText = decision.displayText
        bumpStructureRevision()
        persistCurrentSession()
        if status != previousStatus {
            publishActivity()
        }
    }

    func respondToInteractiveRequest(_ response: ChatInteractiveResponse) {
        guard !isMirroringRemoteSession else {
            // 同 respondToPermission：镜像模式下无本地 backend，错误路径会破坏状态。
            appendError("该会话正在 iOS 端远程运行，请在 iOS 端响应交互请求。")
            return
        }
        let previousStatus = status
        guard activeBackend?.respondToInteractiveRequest(requestID: response.requestID, response: response) == true else {
            updateInteractiveRequestStatus(response.requestID, status: .failed)
            appendError("交互响应写回失败。当前 CLI 模式不支持此类选择题/输入回写。")
            status = .failed
            statusText = "交互写回失败"
            actuallyPersist()
            return
        }
        updateInteractiveRequestStatus(response.requestID, status: .answered)
        status = .streaming
        statusText = "已回复选择"
        persistCurrentSession()
        if status != previousStatus {
            publishActivity()
        }
    }

    /// The AskUserQuestion (选择题) currently awaiting an answer in the active turn, if any.
    /// Lets the composer route a typed answer into the interactive response instead of starting
    /// a new turn (which would leave the CLI blocked on its control_response).
    var firstWaitingInteractiveRequest: ChatInteractiveRequest? {
        for message in messages.reversed() {
            if message.kind == .interactiveRequest,
               let request = message.interactiveRequest,
               request.status == .waiting {
                return request
            }
            if message.kind == .user { break }
        }
        return nil
    }

    /// True while the active turn is blocked on a user decision (选择题 or permission). Used to
    /// keep the "no visible output" backstop from killing a run that is just waiting for input.
    var hasPendingUserDecision: Bool {
        for message in messages.reversed() {
            if message.kind == .interactiveRequest, (message.interactiveRequest?.status ?? .waiting) == .waiting {
                return true
            }
            if message.kind == .permissionRequest, message.status == "waiting" {
                return true
            }
            if message.kind == .user { break }
        }
        return false
    }

    /// Answer a pending AskUserQuestion with free text typed in the composer.
    @discardableResult
    func answerPendingInteractiveWithCustomText(_ text: String) -> Bool {
        guard let request = firstWaitingInteractiveRequest else { return false }
        respondToInteractiveRequest(ChatInteractiveResponse(requestID: request.id, selectedOptionIDs: [], customText: text))
        return true
    }

    private func interruptIfNeededForLoad() {
        if status.isRunning { interrupt() }
    }

    private func effectiveResumeSessionID(_ resumeSessionID: String?, for session: ChatSessionRecord, cli: CLIType, projectPath: String) -> String? {
        guard let resumeSessionID = resumeSessionID?.nonEmptyTrimmed else { return nil }
        if resumeSessionID.caseInsensitiveCompare(session.id.uuidString) == .orderedSame { return nil }
        return resumeSessionID
    }

    private func ensureSession(
        project: ProjectItem,
        cli: CLIType,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort,
        firstPrompt: String
    ) -> ChatSessionRecord {
        if var currentSession, currentSession.projectPath == project.path, currentSession.cli == cli.visibleValue {
            currentSession.updatedAt = Date()
            return currentSession
        }
        return ChatSessionRecord(
            cli: cli,
            projectName: project.name,
            projectPath: project.path,
            title: title(from: firstPrompt),
            modelID: modelID,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
    }

    private func apply(_ event: ChatBackendEvent) {
        let previousStatus = status
        markBackendActivityForFirstOutputTimeout(event)
        publishRemoteStreamEventIfNeeded(event)
        switch event {
        case .appendMessage(let kind, let title, let subtitle, let text, let itemStatus, let requestID):
            guard let sessionID = currentSession?.id else { return }
            let isStreamingItem = isStreamingItemStatus(itemStatus)
            if !isStreamingItem,
               finishActiveStreamingMessageIfPossible(kind: kind, requestID: requestID, text: text, status: itemStatus) {
                if shouldClearAwaitingFirstModelOutput(kind: kind, title: title, subtitle: subtitle, text: text, isStreaming: false) {
                    setAwaitingFirstModelOutput(false)
                    if isVisibleModelOutput(kind) { status = .streaming }
                }
                recordFirstVisibleOutputIfNeeded(kind: kind)
                if shouldReplaceStatusText(for: kind) {
                    statusText = itemStatus
                }
                break
            }
            let message = ChatMessage(
                sessionID: sessionID,
                kind: kind,
                title: title,
                subtitle: subtitle,
                text: text,
                status: itemStatus,
                parentUserMessageID: activeParentUserMessageID,
                requestID: requestID,
                isStreaming: isStreamingItem
            )
            messages.append(message)
            if isStreamingItem {
                activeStreamingMessageIDs[StreamingMessageKey(kind: kind, requestID: requestID)] = message.id
                if kind == .assistant {
                    activeAssistantMessageID = message.id
                }
            }
            if shouldClearAwaitingFirstModelOutput(kind: kind, title: title, subtitle: subtitle, text: text, isStreaming: isStreamingItem) {
                setAwaitingFirstModelOutput(false)
                if isVisibleModelOutput(kind) { status = .streaming }
            }
            recordFirstVisibleOutputIfNeeded(kind: kind)
            if shouldReplaceStatusText(for: kind) {
                statusText = itemStatus
            }
            bumpStructureRevision()
        case .appendDelta(let kind, let title, let subtitle, let text, let itemStatus, let requestID):
            let revealedFirstOutput = appendDelta(kind: kind, title: title, subtitle: subtitle, text: text, status: itemStatus, requestID: requestID)
            if revealedFirstOutput, isVisibleModelOutput(kind), status != .streaming {
                status = .streaming
            }
            recordFirstVisibleOutputIfNeeded(kind: kind)
            statusText = itemStatus.nonEmptyTrimmed ?? "streaming"
        case .finishStreamingMessage(let kind, let requestID, let itemStatus):
            finishStreamingMessage(kind: kind, requestID: requestID, status: itemStatus)
            statusText = itemStatus.nonEmptyTrimmed ?? statusText
        case .updateStreamingStatus(let value):
            statusText = value
        case .backendActivity:
            break
        case .sessionID(let externalID):
            currentSession?.externalSessionID = externalID
        case .permissionRequest(let id, let title, let text):
            guard let sessionID = currentSession?.id else { return }
            messages.append(ChatMessage(
                sessionID: sessionID,
                kind: .permissionRequest,
                title: title,
                text: text,
                status: "waiting",
                parentUserMessageID: activeParentUserMessageID,
                requestID: id
            ))
            setAwaitingFirstModelOutput(false)
            status = .waitingPermission
            statusText = "等待权限"
            bumpStructureRevision()
        case .interactiveRequest(let request):
            guard let sessionID = currentSession?.id else { return }
            messages.append(ChatMessage(
                sessionID: sessionID,
                kind: .interactiveRequest,
                title: request.title,
                text: request.prompt,
                status: request.status.rawValue,
                parentUserMessageID: activeParentUserMessageID,
                requestID: request.id,
                interactiveRequest: request
            ))
            setAwaitingFirstModelOutput(false)
            status = .waitingInput
            statusText = "等待输入"
            bumpStructureRevision()
        case .tokenUsage(let used, let total, let output):
            tokensUsed = used
            if let output, output > 0 {
                applyOutputTokenCount(output)
            }
            if total > 0 {
                let modelID = currentSession?.modelID ?? activeRunRequest?.contextModelID ?? activeRunRequest?.modelID ?? ""
                let cli = currentSession?.cli ?? activeRunRequest?.cli ?? .claude
                let expectedTotal = Self.defaultContextWindow(
                    for: modelID,
                    cli: cli,
                    metadataWindow: activeRunRequest?.contextWindow
                )
                tokensTotal = max(total, expectedTotal)
            }
            checkAutoCompact()
        case .finished:
            // 镜像模式下本地没有 queued requests 也没有本地 backend，
            // 不应该设置 shouldStartQueuedRequestAfterBackendEnds=true——否则这个
            // flag 会残留到下次本地操作时被误读为"上一个 turn 结束后要启动队列"。
            if !isMirroringRemoteSession {
                shouldStartQueuedRequestAfterBackendEnds = !isUserStopping
            }
            flushPendingDeltas()
            finishStreamingMessages(status: isUserStopping ? "stopped" : "done")
            setAwaitingFirstModelOutput(false)
            currentSession?.updatedAt = Date()
            currentSession?.lastCompletedAt = Date()
            activeRunRequest = nil
            logRunTiming(label: "finished")
            activeRunStartedAt = nil
            status = .completed
            statusText = isUserStopping ? "已停止" : "完成"
            playCompletionSoundIfNeeded(stopped: isUserStopping)
            isUserStopping = false
            actuallyPersist()
        case .failed(let message):
            if isUserStopping {
                let shouldStartQueuedRequest = shouldStartQueuedRequestAfterBackendEnds
                shouldStartQueuedRequestAfterBackendEnds = false
                flushPendingDeltas()
                finishStreamingMessages(status: "stopped")
                setAwaitingFirstModelOutput(false)
                currentSession?.updatedAt = Date()
                currentSession?.lastCompletedAt = Date()
                activeRunRequest = nil
                logRunTiming(label: "stopped")
                activeRunStartedAt = nil
                status = .completed
                statusText = "已停止"
                isUserStopping = false
                actuallyPersist()
                if shouldStartQueuedRequest {
                    scheduleNextQueuedRequestIfNeeded()
                }
                return
            }
            flushPendingDeltas()
            finishStreamingMessages(status: "failed")
            appendError(message)
            setAwaitingFirstModelOutput(false)
            currentSession?.updatedAt = Date()
            activeRunRequest = nil
            logRunTiming(label: "failed")
            activeRunStartedAt = nil
            status = .failed
            statusText = "失败"
            shouldStartQueuedRequestAfterBackendEnds = false
            actuallyPersist()
        }
        if status != previousStatus {
            publishActivity()
        }
    }

    private func publishRemoteStreamEventIfNeeded(_ event: ChatBackendEvent) {
        guard !isMirroringRemoteSession, let sessionID = currentSession?.id else { return }
        guard !Self.isMCPRemoteEvent(event) else { return }
        let streamEvent: RemoteChatStreamEvent?
        switch event {
        case .appendMessage(let kind, let title, let subtitle, let text, let status, let requestID):
            streamEvent = RemoteChatStreamEvent(
                type: "assistant_message",
                backendRequestId: requestID,
                sessionId: sessionID,
                kind: kind.rawValue,
                title: title,
                subtitle: subtitle,
                text: text,
                status: status
            )
        case .appendDelta(let kind, let title, let subtitle, let text, let status, let requestID):
            streamEvent = RemoteChatStreamEvent(
                type: "assistant_delta",
                backendRequestId: requestID,
                sessionId: sessionID,
                kind: kind.rawValue,
                title: title,
                subtitle: subtitle,
                delta: text,
                status: status
            )
        case .finishStreamingMessage(let kind, let requestID, let status):
            streamEvent = RemoteChatStreamEvent(
                type: "output_finished",
                backendRequestId: requestID,
                sessionId: sessionID,
                kind: kind.rawValue,
                status: status
            )
        case .updateStreamingStatus(let value):
            streamEvent = RemoteChatStreamEvent(
                type: "stream_status",
                sessionId: sessionID,
                status: value,
                message: value
            )
        case .backendActivity:
            streamEvent = nil
        case .sessionID(let externalID):
            streamEvent = RemoteChatStreamEvent(
                type: "session_id",
                sessionId: sessionID,
                externalSessionId: externalID
            )
        case .permissionRequest(let id, let title, let text):
            streamEvent = RemoteChatStreamEvent(
                type: "permission_request",
                backendRequestId: id,
                sessionId: sessionID,
                kind: ChatMessageKind.permissionRequest.rawValue,
                title: title,
                text: text,
                status: "waiting"
            )
        case .interactiveRequest(let request):
            streamEvent = RemoteChatStreamEvent(
                type: "interactive_request",
                backendRequestId: request.id,
                sessionId: sessionID,
                kind: ChatMessageKind.interactiveRequest.rawValue,
                title: request.title,
                text: request.prompt,
                status: request.status.rawValue,
                interactiveRequest: request
            )
        case .tokenUsage(let used, let total, let output):
            streamEvent = RemoteChatStreamEvent(
                type: "token_usage",
                sessionId: sessionID,
                kind: ChatMessageKind.result.rawValue,
                title: "tokens",
                subtitle: "\(used)/\(total)",
                text: output.map { "输出 token：\($0)" },
                status: "done",
                tokenUsed: used,
                tokenTotal: total,
                outputTokenCount: output
            )
        case .finished:
            streamEvent = RemoteChatStreamEvent(
                type: "assistant_done",
                sessionId: sessionID,
                kind: ChatMessageKind.assistant.rawValue,
                status: "done"
            )
        case .failed(let message):
            streamEvent = RemoteChatStreamEvent(
                type: "assistant_error",
                sessionId: sessionID,
                status: "failed",
                message: message
            )
        }
        if let streamEvent {
            NotificationCenter.default.post(name: .remoteChatStreamEvent, object: nil, userInfo: ["event": streamEvent])
        }
    }

    private func publishRemoteUserMessageIfNeeded(_ message: ChatMessage, session: ChatSessionRecord) {
        guard !isMirroringRemoteSession else { return }
        let streamEvent = RemoteChatStreamEvent(
            type: "user_message_saved",
            requestId: message.requestID,
            sessionId: session.id,
            messageId: message.id,
            kind: message.kind.rawValue,
            text: message.text,
            status: message.status,
            externalSessionId: session.externalSessionID
        )
        NotificationCenter.default.post(name: .remoteChatStreamEvent, object: nil, userInfo: ["event": streamEvent])
    }

    private static func isMCPRemoteEvent(_ event: ChatBackendEvent) -> Bool {
        switch event {
        case .appendMessage(let kind, let title, let subtitle, let text, _, _),
             .appendDelta(let kind, let title, let subtitle, let text, _, _):
            return isMCPPayload(kind: kind, title: title, subtitle: subtitle, text: text)
        case .finishStreamingMessage, .updateStreamingStatus, .backendActivity, .sessionID, .permissionRequest, .interactiveRequest, .finished, .failed, .tokenUsage:
            return false
        }
    }

    private static func isMCPPayload(kind: ChatMessageKind, title: String, subtitle: String, text: String) -> Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mac tools" { return true }
        if ChatMessageFilter.looksLikeClaudeToolInventory(text) { return true }
        let haystack = "\(title) \(subtitle)".lowercased()
        return (kind == .toolCall || kind == .toolResult || kind == .rawOutput)
            && (haystack.contains("mcp") || haystack.contains("mcpserver"))
    }

    private static let completionSound = NSSound(named: NSSound.Name("Glass"))

    private func playCompletionSoundIfNeeded(stopped: Bool) {
        guard !stopped, isRuntimeVisible else { return }
        if Self.completionSound?.play() != true {
            NSSound.beep()
        }
    }

    private func backendStreamDidEnd() {
        currentTask = nil
        activeBackend = nil
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        // A permission / interactive request can only be answered while its backend is alive.
        // If the stream ends with one still `waiting` (CLI crash/EOF mid-prompt, `.failed`
        // while waiting — note `status.isRunning` is already false in that path), its buttons
        // become dead taps. Collapse them now so the card shows as cancelled instead.
        cancelWaitingInteractiveRequestsOnInterrupt()
        let shouldStartQueuedRequest = shouldStartQueuedRequestAfterBackendEnds
        shouldStartQueuedRequestAfterBackendEnds = false
        if status.isRunning {
            flushPendingDeltas()
            finishStreamingMessages(status: isUserStopping ? "stopped" : "done")
            setAwaitingFirstModelOutput(false)
            currentSession?.updatedAt = Date()
            currentSession?.lastCompletedAt = Date()
            activeRunRequest = nil
            logRunTiming(label: "stream-ended")
            activeRunStartedAt = nil
            status = .completed
            statusText = isUserStopping ? "已停止" : "完成"
            playCompletionSoundIfNeeded(stopped: isUserStopping)
            isUserStopping = false
            stopRunSnapshotLoop()
            actuallyPersist()
        }
        if shouldStartQueuedRequest {
            scheduleNextQueuedRequestIfNeeded()
        }
    }

    @discardableResult
    private func appendDelta(kind: ChatMessageKind, title: String, subtitle: String, text: String, status itemStatus: String, requestID: String?) -> Bool {
        guard !text.isEmpty, let sessionID = currentSession?.id else { return false }
        let key = StreamingMessageKey(kind: kind, requestID: requestID)
        let status = itemStatus.nonEmptyTrimmed ?? "streaming"
        let normalizedRequestID = requestID?.nonEmptyTrimmed
        if let activeMessageID = activeStreamingMessageIDs[key],
           messages.contains(where: { $0.id == activeMessageID }),
           shouldAppendDeltaToExistingMessage(kind: kind, requestID: requestID, activeMessageID: activeMessageID) {
            let revealsFirstOutput = isAwaitingFirstModelOutput && shouldClearAwaitingFirstModelOutput(kind: kind, text: text)
            if revealsFirstOutput {
                appendDeltaImmediately(text, status: status, requestID: normalizedRequestID, to: activeMessageID)
                setAwaitingFirstModelOutput(false)
                return true
            }
            // Flush the FIRST tool-input chunk immediately rather than batching it, so the tool
            // card fills with content in the same beat its header appears — removing the visible
            // "tool name first, body a moment later" two-stage stutter.
            if kind == .toolCall,
               pendingDeltaBuffers[activeMessageID] == nil,
               (streamingTextStore.entry(for: activeMessageID)?.text.isEmpty ?? true) {
                appendDeltaImmediately(text, status: status, requestID: normalizedRequestID, to: activeMessageID)
                return false
            }
            pendingDeltaBuffers[activeMessageID, default: ""] += text
            pendingDeltaStatuses[activeMessageID] = status
            if let normalizedRequestID {
                pendingDeltaRequestIDs[activeMessageID] = normalizedRequestID
            }
            scheduleDeltaFlush()
            return false
        }

        let message = ChatMessage(
            sessionID: sessionID,
            kind: kind,
            title: title,
            subtitle: subtitle,
            text: "",
            status: status,
            parentUserMessageID: activeParentUserMessageID,
            requestID: normalizedRequestID,
            isStreaming: true
        )
        streamingTextStore.setText(text, status: status, requestID: normalizedRequestID, for: message.id)
        activeStreamingMessageIDs[key] = message.id
        if kind == .assistant {
            activeAssistantMessageID = message.id
        }
        messages.append(message)
        let revealsFirstOutput = shouldClearAwaitingFirstModelOutput(kind: kind, text: text)
        if revealsFirstOutput { setAwaitingFirstModelOutput(false) }
        bumpStructureRevision()
        return revealsFirstOutput
    }

    private func appendDeltaImmediately(_ delta: String, status: String, requestID: String?, to messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        streamingTextStore.append(delta, status: status, requestID: requestID, to: messageID)
        messages[index].status = status
        if shouldMirrorStreamingTextIntoMessage(messages[index].kind), let entry = streamingTextStore.entry(for: messageID) {
            messages[index].text = entry.text
            messages[index].requestID = messages[index].requestID ?? entry.requestID
        }
    }

    private func appendError(_ text: String) {
        let sessionID = currentSession?.id ?? UUID()
        messages.append(ChatMessage(
            sessionID: sessionID,
            kind: .error,
            title: "error",
            text: text,
            status: "failed",
            parentUserMessageID: activeParentUserMessageID
        ))
        setAwaitingFirstModelOutput(false)
        bumpStructureRevision()
    }

    /// Internal accessor for the remote bridge to surface deferred-send /
    /// race-tolerant failures into the live panel state (audit B-P1-1).
    /// Keeps the existing `appendError` private so callers can't bypass
    /// the controller's structure-revision invariants.
    func appendErrorFromRemoteBridge(_ text: String) {
        appendError(text)
    }

#if DEBUG
    func debugSetAwaitingFirstModelOutput(_ value: Bool) {
        setAwaitingFirstModelOutput(value)
    }

    var debugHasFirstVisibleOutputTimeoutTask: Bool {
        firstVisibleOutputTimeoutTask != nil
    }

    var debugDidReceiveBackendActivityAfterStart: Bool {
        didReceiveBackendActivityAfterStart
    }

    func debugApplyBackendEvent(_ event: ChatBackendEvent) {
        apply(event)
    }

    func debugFireFirstVisibleOutputTimeout() {
        failRunForFirstVisibleOutputTimeoutIfNeeded()
    }
#endif

    private func applyOutputTokenCount(_ count: Int) {
        if let activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == activeAssistantMessageID }) {
            if messages[index].isStreaming {
                pendingOutputTokenCounts[activeAssistantMessageID] = count
            } else {
                messages[index].outputTokenCount = count
            }
            return
        }
        if let index = messages.lastIndex(where: { $0.kind == .assistant }) {
            if messages[index].isStreaming {
                pendingOutputTokenCounts[messages[index].id] = count
            } else {
                messages[index].outputTokenCount = count
            }
        }
    }

    private func finishStreamingMessage(kind: ChatMessageKind, requestID: String?, status itemStatus: String = "done") {
        flushPendingDeltas()
        let key = StreamingMessageKey(kind: kind, requestID: requestID)
        guard let messageID = activeStreamingMessageIDs[key],
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let entry = streamingTextStore.entry(for: messageID) {
            messages[index].text = entry.text
            messages[index].requestID = messages[index].requestID ?? entry.requestID
        }
        messages[index].isStreaming = false
        messages[index].status = itemStatus
        streamingTextStore.remove(messageID)
        pendingOutputTokenCounts.removeValue(forKey: messageID)
        activeStreamingMessageIDs.removeValue(forKey: key)
        if activeAssistantMessageID == messageID {
            activeAssistantMessageID = nil
        }
        bumpStructureRevision()
    }

    private func finishStreamingMessages(status itemStatus: String = "done") {
        flushPendingDeltas()
        for index in messages.indices where messages[index].isStreaming {
            let messageID = messages[index].id
            if let entry = streamingTextStore.entry(for: messageID) {
                messages[index].text = entry.text
                messages[index].requestID = messages[index].requestID ?? entry.requestID
            }
            if let outputTokenCount = pendingOutputTokenCounts[messageID] {
                messages[index].outputTokenCount = outputTokenCount
            }
            messages[index].isStreaming = false
            messages[index].status = itemStatus
            streamingTextStore.remove(messageID)
            pendingOutputTokenCounts.removeValue(forKey: messageID)
        }
        activeAssistantMessageID = nil
        activeStreamingMessageIDs.removeAll()
        bumpStructureRevision()
    }

    private func finishActiveStreamingMessageIfPossible(kind: ChatMessageKind, requestID: String?, text: String, status itemStatus: String) -> Bool {
        flushPendingDeltas()
        let normalizedRequestID = requestID?.nonEmptyTrimmed
        let exactKey = StreamingMessageKey(kind: kind, requestID: normalizedRequestID)
        let fallbackKey = activeStreamingMessageIDs.keys.first { key in
            key.requestID == normalizedRequestID && Self.areCompatibleStreamingKinds(key.kind, kind)
        }
        guard let key = activeStreamingMessageIDs[exactKey] != nil ? exactKey : fallbackKey,
              let messageID = activeStreamingMessageIDs[key],
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        if let entry = streamingTextStore.entry(for: messageID) {
            messages[index].text = entry.text
            messages[index].requestID = messages[index].requestID ?? entry.requestID
        }
        let previousKind = messages[index].kind
        let completedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !completedText.isEmpty,
           (messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || previousKind != kind || kind == .diff) {
            messages[index].text = text
        }
        messages[index].kind = kind
        messages[index].isStreaming = false
        messages[index].status = itemStatus
        streamingTextStore.remove(messageID)
        pendingOutputTokenCounts.removeValue(forKey: messageID)
        activeStreamingMessageIDs.removeValue(forKey: key)
        if activeAssistantMessageID == messageID {
            activeAssistantMessageID = nil
        }
        bumpStructureRevision()
        return true
    }

    private static func areCompatibleStreamingKinds(_ streamingKind: ChatMessageKind, _ completedKind: ChatMessageKind) -> Bool {
        if streamingKind == completedKind { return true }
        switch (streamingKind, completedKind) {
        case (.commandOutput, .command), (.command, .commandOutput),
             (.toolResult, .toolCall), (.toolCall, .toolResult):
            return true
        default:
            return false
        }
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        let delay: UInt64 = isRuntimeVisible ? 90_000_000 : 300_000_000
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                self?.flushPendingDeltas()
            }
        }
    }

    private func flushPendingDeltas() {
        guard !pendingDeltaBuffers.isEmpty else {
            deltaFlushTask?.cancel()
            deltaFlushTask = nil
            return
        }
        let buffers = pendingDeltaBuffers
        let statuses = pendingDeltaStatuses
        let requestIDs = pendingDeltaRequestIDs
        pendingDeltaBuffers.removeAll()
        pendingDeltaStatuses.removeAll()
        pendingDeltaRequestIDs.removeAll()
        deltaFlushTask?.cancel()
        deltaFlushTask = nil

        var didMirrorToolOutput = false
        for (messageID, delta) in buffers {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
            streamingTextStore.append(delta, status: statuses[messageID], requestID: requestIDs[messageID], to: messageID)
            guard shouldMirrorStreamingTextIntoMessage(messages[index].kind),
                  let entry = streamingTextStore.entry(for: messageID) else { continue }
            messages[index].text = entry.text
            messages[index].requestID = messages[index].requestID ?? entry.requestID
            messages[index].status = statuses[messageID] ?? messages[index].status
            didMirrorToolOutput = true
        }
        if didMirrorToolOutput {
            bumpStructureRevision()
        }
    }

    private func scheduleStopFallback() {
        stopFallbackTask?.cancel()
        stopFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                self?.completeInterruptedRunIfNeeded()
            }
        }
    }

	    private func completeInterruptedRunIfNeeded() {
        guard status == .stopping else { return }
        let shouldStartQueuedRequest = shouldStartQueuedRequestAfterBackendEnds
        shouldStartQueuedRequestAfterBackendEnds = false
        flushPendingDeltas()
        finishStreamingMessages(status: "stopped")
        setAwaitingFirstModelOutput(false)
        currentSession?.updatedAt = Date()
        currentSession?.lastCompletedAt = Date()
        activeRunRequest = nil
        logRunTiming(label: "interrupted")
        activeRunStartedAt = nil
        currentTask = nil
        activeBackend = nil
        status = .completed
        statusText = "已停止"
        isUserStopping = false
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        actuallyPersist()
        if shouldStartQueuedRequest {
            scheduleNextQueuedRequestIfNeeded()
        }
    }

    private func reconcileLoadedRunStateIfStale() {
        // 进入这里时刚加载完一个本地持久化会话,没有任何 live backend / Task。若它的
        // runStatus 仍落在"运行中"区间,说明上次是异常退出(强制退出 / 强杀 / 崩溃)时
        // 被周期快照写下的中间态——纠正为已停止,并给残留的流式消息收尾,避免 UI 卡在
        // "运行中 / 打字中"且 Allow/Deny、停止等按钮点击后必然失败。镜像会话(iOS 端
        // 正在跑、Mac 端只镜像显示)的运行态是合法的,不在此列。
        guard !isMirroringRemoteSession, currentTask == nil, activeBackend == nil else { return }
        // A persisted snapshot can also leave `waiting` permission/交互 rows behind even when
        // runStatus was already saved as non-running — with no live backend those rows render
        // dead Allow/Deny / option buttons, so always cancel them here.
        let cancelledStaleRequests = cancelWaitingInteractiveRequestsOnInterrupt()
        guard status.isRunning else {
            if cancelledStaleRequests { actuallyPersist() }
            return
        }
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            if messages[index].status == "streaming" || messages[index].status.isEmpty {
                messages[index].status = "stopped"
            }
        }
        status = .completed
        statusText = "已停止(上次异常退出已恢复)"
        currentSession?.runStatus = .completed
        currentSession?.statusText = statusText
        currentSession?.lastCompletedAt = Date()
        bumpStructureRevision()
        actuallyPersist()
    }

    private func scheduleNextQueuedRequestIfNeeded() {
        guard !queuedRequests.isEmpty else { return }
        guard !hasPendingPlanConfirmation else {
            pauseQueuedRequestsForPlanConfirmation()
            return
        }
        queuedStartTask?.cancel()
        queuedStartTask = Task { [weak self] in
            await MainActor.run {
                self?.startNextQueuedRequestIfNeeded()
            }
        }
    }

    private func startNextQueuedRequestIfNeeded() {
        queuedStartTask?.cancel()
        queuedStartTask = nil
        guard !hasPendingPlanConfirmation else {
            pauseQueuedRequestsForPlanConfirmation()
            return
        }
        guard canStartQueuedRequest, let request = queuedRequests.first else { return }
        queuedRequests.removeFirst()
        guard startRun(request) else {
            queuedRequests.insert(request, at: 0)
            bumpStructureRevision()
            persistCurrentSession(saveMessages: false)
            return
        }
        bumpStructureRevision()
        persistCurrentSession(saveMessages: false)
    }

    private var canStartQueuedRequest: Bool {
        !status.isRunning
            && currentTask == nil
            && activeBackend == nil
            && pendingDeltaBuffers.isEmpty
            && deltaFlushTask == nil
            && activeStreamingMessageIDs.isEmpty
            && !messages.contains(where: \.isStreaming)
    }

    private func pauseQueuedRequestsForPlanConfirmation() {
        queuedStartTask?.cancel()
        queuedStartTask = nil
        statusText = "等待用户确认方案，队列已暂停"
        bumpStructureRevision()
        persistCurrentSession(saveMessages: false)
        publishActivity()
    }

    private var latestExitPlanModeMessageID: UUID? {
        for message in messages.reversed() {
            if message.isExitPlanModeCall {
                return message.id
            }
            if message.kind == .user {
                return nil
            }
        }
        return nil
    }

    private func shouldAppendDeltaToExistingMessage(kind: ChatMessageKind, requestID: String?, activeMessageID: UUID) -> Bool {
        switch kind {
        case .assistant:
            // Top-level assistant text often streams with a nil requestID, so we only keep
            // appending to the active bubble while it's the last visible row — otherwise a
            // reply that resumes after a tool call would merge into the pre-tool bubble.
            guard lastVisibleMessageID == activeMessageID else { return false }
            return true
        case .reasoning:
            // Reasoning blocks carry a stable block id (requestID), so keep streaming into the
            // same thinking bubble even once a tool/text row follows it. Without this, mid-turn
            // thinking interleaved with tool calls fragments or stops rendering live.
            return true
        default:
            return true
        }
    }

    private var lastVisibleMessageID: UUID? {
        messages.last(where: { isVisibleModelOutput($0.kind) || $0.kind == .user })?.id
    }

    private func setAwaitingFirstModelOutput(_ value: Bool) {
        if value {
            scheduleFirstVisibleOutputTimeoutIfNeeded()
        } else {
            cancelFirstVisibleOutputTimeout()
        }
        guard isAwaitingFirstModelOutput != value else { return }
        isAwaitingFirstModelOutput = value
        bumpStructureRevision()
    }

    private func scheduleFirstVisibleOutputTimeoutIfNeeded() {
        guard firstVisibleOutputTimeoutTask == nil else { return }
        scheduleFirstVisibleOutputTimeout(after: Self.firstVisibleOutputTimeoutNanoseconds)
    }

    private func scheduleFirstVisibleOutputTimeout(after nanoseconds: UInt64) {
        firstVisibleOutputTimeoutTask?.cancel()
        firstVisibleOutputTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.failRunForFirstVisibleOutputTimeoutIfNeeded()
            }
        }
    }

    private func cancelFirstVisibleOutputTimeout() {
        firstVisibleOutputTimeoutTask?.cancel()
        firstVisibleOutputTimeoutTask = nil
    }

    private func failRunForFirstVisibleOutputTimeoutIfNeeded() {
        firstVisibleOutputTimeoutTask = nil
        guard isAwaitingFirstModelOutput,
              status.isRunning,
              !isUserStopping,
              !isMirroringRemoteSession,
              // Never kill a run that's just waiting for the user to answer a 选择题 / permission
              // prompt — the model HAS produced output (the question), it's the user's turn.
              !hasPendingUserDecision else { return }
        let backend = activeBackend
        activeBackend = nil
        currentTask?.cancel()
        currentTask = nil
        backend?.interrupt()
        flushPendingDeltas()
        finishStreamingMessages(status: "failed")
        appendError("Claude Code 启动后长时间没有产生任何可见输出，已停止当前任务。请检查认证、模型或网络配置。")
        currentSession?.updatedAt = Date()
        activeRunRequest = nil
        logRunTiming(label: "first-output-timeout")
        activeRunStartedAt = nil
        status = .failed
        statusText = "响应超时"
        shouldStartQueuedRequestAfterBackendEnds = false
        isUserStopping = false
        actuallyPersist()
        scheduleNextQueuedRequestIfNeeded()
    }

    private func markBackendActivityForFirstOutputTimeout(_ event: ChatBackendEvent) {
        guard isAwaitingFirstModelOutput else { return }
        guard case .backendActivity = event else { return }
        didReceiveBackendActivityAfterStart = true
        // The process is alive but hasn't produced visible output yet. Replace the short
        // "won't start" timeout with a longer backstop so a CLI that only emits protocol
        // noise (no visible reply) can't leave the loading indicator spinning forever.
        scheduleFirstVisibleOutputTimeout(after: Self.silentOutputBackstopNanoseconds)
    }

    private func shouldReplaceStatusText(for kind: ChatMessageKind) -> Bool {
        switch kind {
        case .system, .rawOutput, .result:
            false
        default:
            true
        }
    }

    private func recordFirstVisibleOutputIfNeeded(kind: ChatMessageKind) {
        guard firstVisibleOutputAt == nil, isVisibleModelOutput(kind) else { return }
        firstVisibleOutputAt = Date()
#if DEBUG
        if let activeRunStartedAt {
            let latency = firstVisibleOutputAt?.timeIntervalSince(activeRunStartedAt) ?? 0
            print("[ChatPerf] first_visible_output latency=\(String(format: "%.3f", latency))s")
        }
#endif
    }

    private func logRunTiming(label: String) {
#if DEBUG
        guard let activeRunStartedAt else { return }
        let total = Date().timeIntervalSince(activeRunStartedAt)
        let first = firstVisibleOutputAt.map { String(format: "%.3f", $0.timeIntervalSince(activeRunStartedAt)) } ?? "n/a"
        print("[ChatPerf] run_\(label) total=\(String(format: "%.3f", total))s first_visible=\(first)s messages=\(messages.count)")
#endif
        firstVisibleOutputAt = nil
    }

    private func bumpStructureRevision() {
        structureRevision &+= 1
    }

    private func isVisibleModelOutput(_ kind: ChatMessageKind) -> Bool {
        switch kind {
        case .assistant, .reasoning, .toolCall, .toolResult, .command, .commandOutput, .permissionRequest, .interactiveRequest, .diff, .error:
            true
        case .user, .system, .result, .rawOutput:
            false
        }
    }

    private func shouldClearAwaitingFirstModelOutput(kind: ChatMessageKind, title: String, subtitle: String, text: String, isStreaming: Bool) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .assistant, .reasoning:
            return hasText
        case .result, .rawOutput:
            return hasText
        default:
            guard isVisibleModelOutput(kind) else { return false }
            return isStreaming
                || hasText
                || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func shouldClearAwaitingFirstModelOutput(kind: ChatMessageKind, text: String) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText else { return false }
        return isVisibleModelOutput(kind) || kind == .result || kind == .rawOutput
    }

    private func isStreamingItemStatus(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "stream"
            || normalized == "streaming"
            || normalized == "running"
            || normalized.contains("streaming")
            || normalized.contains("running")
    }

    private func shouldMirrorStreamingTextIntoMessage(_ kind: ChatMessageKind) -> Bool {
        switch kind {
        case .assistant, .reasoning:
            false
        case .user, .toolCall, .toolResult, .command, .commandOutput, .permissionRequest, .interactiveRequest, .diff, .error, .system, .result, .rawOutput:
            true
        }
    }

    private func updateInteractiveRequestStatus(_ requestID: String, status: ChatInteractiveStatus) {
        guard let index = messages.firstIndex(where: { $0.requestID == requestID }) else { return }
        messages[index].status = status.rawValue
        messages[index].interactiveRequest?.status = status
        bumpStructureRevision()
    }

    // 流式期间的崩溃保护:每隔几秒把正在进行的对话(含尚未完成的流式消息)落盘一次。
    // 否则一整段 AI 回复只会在 run 正常结束(backendStreamDidEnd)或优雅退出钩子
    // (willTerminateNotification)时才写盘——强制退出 / 强杀进程 / 崩溃 / 断电时这两者
    // 都不触发,整段进行中的回复会全部丢失。
    private func startRunSnapshotLoop() {
        runSnapshotTask?.cancel()
        runSnapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                let keepRunning = await MainActor.run { () -> Bool in
                    guard let self, self.status.isRunning else { return false }
                    self.snapshotActiveRunToDisk()
                    return true
                }
                if !keepRunning { return }
            }
        }
    }

    private func stopRunSnapshotLoop() {
        runSnapshotTask?.cancel()
        runSnapshotTask = nil
    }

    private func snapshotActiveRunToDisk() {
        guard currentSession != nil, !isMirroringRemoteSession else { return }
        flushPendingDeltas()
        actuallyPersist()
    }

    private func persistCurrentSession(saveMessages shouldSaveMessages: Bool = true) {
        guard currentSession != nil else { return }
        let saveMessages = shouldSaveMessages || (pendingPersistShouldSaveMessages == true)
        pendingPersistShouldSaveMessages = saveMessages
        pendingPersistTask?.cancel()
        let delay: UInt64 = isRuntimeVisible ? 200_000_000 : 1_200_000_000
        pendingPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.runPendingPersist()
            }
        }
    }

    private func flushPendingPersistImmediately() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        guard let options = pendingPersistShouldSaveMessages else { return }
        pendingPersistShouldSaveMessages = nil
        actuallyPersist(saveMessages: options)
    }

    private func runPendingPersist() {
        pendingPersistTask = nil
        guard let options = pendingPersistShouldSaveMessages else { return }
        pendingPersistShouldSaveMessages = nil
        actuallyPersist(saveMessages: options)
    }

    private func messagesForPersistence(sessionID: UUID) -> [ChatMessage] {
        guard let prefixCount = historyNextBeforeIndex, prefixCount > 0 else { return messages }
        if let cached = cachedPersistencePrefix, cached.sessionID == sessionID, cached.count == prefixCount {
            return cached.messages + messages
        }
        let existingMessages = ChatSessionStore.loadMessages(sessionID: sessionID)
        let prefix = Array(existingMessages.prefix(min(prefixCount, existingMessages.count)))
        cachedPersistencePrefix = (sessionID, prefixCount, prefix)
        return prefix + messages
    }

    private func actuallyPersist(saveMessages shouldSaveMessages: Bool = true) {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        pendingPersistShouldSaveMessages = nil
        // 镜像模式：会话由 RemoteChatBridge 在 iOS 触发流程里写盘，本地 ChatPanelState
        // 只做 UI 显示，不能再重复写盘——否则两端的内存副本会互相覆盖（旧 F19/F20 bug）。
        guard !isMirroringRemoteSession else {
            publishActivity()
            return
        }
        guard var session = currentSession else { return }
        session.runStatus = status
        session.statusText = statusText
        session.queuedRequests = queuedRequests
        session.activeRunRequest = activeRunRequest
        session.activeRunStartedAt = activeRunStartedAt
        currentSession = session
        do {
            // Write the messages file FIRST, then the index. The index is the "commit
            // pointer"; if we crash between the two writes, the index never references
            // messages that weren't durably written.
            if shouldSaveMessages {
                try ChatSessionStore.saveMessages(messagesForPersistence(sessionID: session.id), sessionID: session.id)
            }
            try ChatSessionStore.saveSession(session)
            onSessionPersisted?()
            NotificationCenter.default.post(
                name: .remoteChatSessionsDidChange,
                object: nil,
                userInfo: ["session": session]
            )
        } catch {
            statusText = "保存失败"
        }
        publishActivity()
    }

    private func publishActivity() {
        onActivityChanged?(activity)
    }

    // MARK: - 远程镜像（iOS 端通过 RemoteChatBridge 触发对话，Mac 端 UI 同步显示）

    /// currentSession 变化时调用：取消旧订阅、订阅新 sessionID 的事件流。
    private func refreshRemoteMirrorSubscription() {
        unsubscribeRemoteMirror()
        guard let sessionID = currentSession?.id else { return }
        remoteMirrorSessionID = sessionID
        remoteMirrorToken = RemoteSessionMirrorBus.shared.subscribe(sessionID: sessionID) { [weak self] event in
            self?.handleRemoteMirrorEvent(event)
        }
    }

    private func unsubscribeRemoteMirror() {
        if let token = remoteMirrorToken, let sessionID = remoteMirrorSessionID {
            RemoteSessionMirrorBus.shared.unsubscribe(sessionID: sessionID, token: token)
        }
        remoteMirrorToken = nil
        remoteMirrorSessionID = nil
        if isMirroringRemoteSession {
            isMirroringRemoteSession = false
        }
    }

    private func subscribeRemoteMirrorBeginsIfNeeded() {
        guard remoteMirrorBeginToken == nil else { return }
        remoteMirrorBeginToken = RemoteSessionMirrorBus.shared.subscribeToBegins { [weak self] event in
            self?.handleRemoteMirrorBeginEvent(event)
        }
    }

    private func unsubscribeRemoteMirrorBegins() {
        if let token = remoteMirrorBeginToken {
            RemoteSessionMirrorBus.shared.unsubscribeFromBegins(token: token)
        }
        remoteMirrorBeginToken = nil
    }

    private func handleRemoteMirrorBeginEvent(_ event: RemoteSessionMirrorBus.Event) {
        guard isRuntimeVisible else { return }
        switch event {
        case .queue(let queueEvent):
            guard currentSession?.id == queueEvent.sessionId || queueEvent.sessionId == nil || queueEvent.clientConversationId != nil else { return }
            applyRemoteQueueEvent(queueEvent)
        case .beginRun(let session, _):
            guard currentSession?.id != session.id else { return }
            guard activeBackend == nil, currentTask == nil else { return }
            handleRemoteMirrorEvent(event)
        case .backend, .endRun:
            break
        }
    }

    private func handleRemoteMirrorEvent(_ event: RemoteSessionMirrorBus.Event) {
        switch event {
        case .queue(let queueEvent):
            applyRemoteQueueEvent(queueEvent)
        case .beginRun(let session, let userMessage):
            // 本地已经在跑 backend 时，不能让远程事件污染本地状态。直接丢弃 beginRun，
            // 也就不进入镜像模式；后续 .backend / .endRun 也会被对应 guard 拦截。
            guard activeBackend == nil, currentTask == nil else { return }
            isMirroringRemoteSession = true
            // 不管 session.id 是否与当前匹配，都更新 currentSession。订阅是按 sessionID
            // 索引的，理论上 currentSession.id 就是 session.id；这里赋值同时把 Bridge
            // 写盘后的最新字段（runStatus / externalSessionID 等）同步过来。
            currentSession = session
            if let requestID = userMessage.requestID,
               let index = messages.firstIndex(where: { $0.requestID == requestID && $0.kind == .user }) {
                messages[index] = userMessage
            } else if !messages.contains(where: { $0.id == userMessage.id }) {
                messages.append(userMessage)
            }
            activeParentUserMessageID = userMessage.id
            activeAssistantMessageID = nil
            activeStreamingMessageIDs.removeAll()
            activeRunStartedAt = session.updatedAt
            setAwaitingFirstModelOutput(true)
            status = .streaming
            statusText = "远程运行中"
            bumpStructureRevision()
            publishActivity()
            onRemoteSessionBegan?(session)
        case .backend(let backendEvent):
            // 本地正在跑时，远程 backend 事件不能被 apply（会让状态机错乱）。
            // apply 内 actuallyPersist 因 isMirroringRemoteSession guard 被跳过，
            // 持久化由 Bridge 负责。
            guard activeBackend == nil, currentTask == nil else { return }
            apply(backendEvent)
        case .endRun(let session):
            // endRun 必须**无条件**处理 isMirroringRemoteSession 重置，否则只要镜像中途
            // 本地起了 backend（极小 race window），后面的 .endRun 就会被 guard 吃掉，
            // 镜像 flag 永远卡在 true，导致本地永久无法 send。
            if currentSession?.id == session.id {
                currentSession = session
                status = session.runStatus
                statusText = session.statusText
            }
            activeRunStartedAt = nil
            setAwaitingFirstModelOutput(false)
            isMirroringRemoteSession = false
            publishActivity()
            startNextQueuedRequestIfNeeded()
        }
    }

    private func applyRemoteQueueEvent(_ event: RemoteChatStreamEvent) {
        guard event.type == "queue_accepted" || event.type == "queue_status" else { return }
        guard let requestID = event.requestId,
              let requestUUID = UUID(uuidString: requestID),
              let text = event.text?.nonEmptyTrimmed else { return }
        if event.status == "idle" || event.status == "deleted" {
            queuedRequests.removeAll { $0.id == requestUUID }
            updateRemoteQueueTranscriptMessage(requestID: requestID, sessionID: event.sessionId, text: text, status: event.status == "idle" ? "user" : "deleted")
            statusText = event.message ?? "Mac 队列已更新"
            bumpStructureRevision()
            publishActivity()
            return
        }
        if event.status == "running" {
            queuedRequests.removeAll { $0.id == requestUUID }
            updateRemoteQueueTranscriptMessage(requestID: requestID, sessionID: event.sessionId, text: text, status: "user")
            statusText = "远程运行中"
            bumpStructureRevision()
            publishActivity()
            return
        }
        let projects = ProjectStore.loadProjects()
        let session = currentSession
        let projectPath = event.projectPath ?? session?.projectPath
        let project = event.projectId.flatMap { id in
            projects.first(where: { $0.id == id })
        } ?? projectPath.flatMap { path in
            projects.first(where: {
                ($0.path as NSString).standardizingPath == (path as NSString).standardizingPath
            })
        }
        guard let project else {
            statusText = event.message ?? "Mac 已接收远程消息"
            publishActivity()
            return
        }
        let cli = CLIType(rawValue: event.cli ?? "")?.visibleValue ?? session?.cli ?? project.defaultCLI.visibleValue
        let modelID = event.modelID ?? session?.modelID ?? ChatModelCatalog.defaultModelID(for: cli)
        let permissionMode = ChatPermissionMode(rawValue: event.permissionMode ?? "") ?? session?.permissionMode ?? .autoEdit
        let reasoningEffort = ChatReasoningEffort(rawValue: event.reasoningEffort ?? "") ?? session?.reasoningEffort ?? .high
        let request = QueuedChatRequest(
            id: requestUUID,
            text: text,
            displayText: text,
            project: project,
            cli: cli,
            modelID: modelID,
            contextModelID: modelID,
            contextWindow: Self.defaultContextWindow(for: modelID, cli: cli),
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            sessionMode: event.sessionId == nil ? .newSession : .resume,
            resumeSessionID: event.sessionId == nil ? nil : session?.externalSessionID
        )
        if let index = queuedRequests.firstIndex(where: { $0.id == requestUUID }) {
            queuedRequests[index] = request
        } else {
            queuedRequests.append(request)
        }
        updateRemoteQueueTranscriptMessage(requestID: requestID, sessionID: event.sessionId, text: text, status: event.status ?? "queued")
        statusText = event.message ?? "Mac 已接收远程消息"
        bumpStructureRevision()
        publishActivity()
    }

    private func updateRemoteQueueTranscriptMessage(requestID: String, sessionID: UUID?, text: String, status: String) {
        if status == "deleted" {
            messages.removeAll { $0.requestID == requestID && $0.status == "queued" }
            return
        }
        if let index = messages.firstIndex(where: { $0.requestID == requestID && $0.kind == .user }) {
            messages[index].sessionID = sessionID ?? messages[index].sessionID ?? currentSession?.id
            messages[index].text = text
            messages[index].status = status
            return
        }
        messages.append(ChatMessage(
            sessionID: sessionID ?? currentSession?.id,
            kind: .user,
            text: text,
            status: status,
            requestID: requestID
        ))
    }

    private func title(from text: String) -> String {
        let line = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "新会话"
        if line.count <= 30 { return line.isEmpty ? "新会话" : line }
        return String(line.prefix(30)) + "…"
    }

    private func checkAutoCompact() {
        // Claude Code compacts natively (better summaries, right timing), so for Claude the app
        // only bridges a late `/compact` fallback at 95% — covering 1M-window models where the
        // CLI's own auto-compaction never fires. Codex (GPT) has NO native auto-compaction in
        // app-server mode: its ~275K window just fills up and the turn dies, so the app must
        // bridge compaction itself by sending the `compact` request at the normal threshold.
        guard tokensTotal > 0 else { return }
        let usage = Double(tokensUsed) / Double(tokensTotal)
        // Re-arm once a previous compaction (or a fresh turn) has brought usage back down,
        // so a long session can auto-compact more than once instead of latching forever.
        if usage < Self.compactRearmThreshold {
            didAutoCompact = false
        }
        guard usage >= Self.compactThreshold else { return }

        let cli = (currentSession?.cli ?? activeRunRequest?.cli ?? .claude).visibleValue
        let triggerThreshold = cli == .codex ? Self.compactThreshold : Self.claudeCompactFallbackThreshold
        guard usage >= triggerThreshold, !didAutoCompact else {
            if !didAutoCompact {
                statusText = "上下文接近上限（CLI 将自动压缩）"
            }
            return
        }
        if activeBackend?.sendCompact() == true {
            didAutoCompact = true
            statusText = "上下文接近上限，自动压缩中…"
        } else {
            statusText = "上下文接近上限"
        }
    }

    // MARK: - VNC remote-control surface (spec §1.2 / §4.9 / §6.2)
    //
    // These methods are the canonical mutate API that the iOS thin-client
    // ultimately drives over the wire. Mac SwiftUI views may call them
    // directly (convenience wrappers around existing internals) or call the
    // legacy method names (`send`, `interrupt`, `cancelQueuedRequest`, …)
    // which are kept stable. The protocol-server agent will adapt these
    // signatures into the `PanelStateBroadcasting` protocol once the shared
    // DTO file from `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift`
    // lands in main.

    /// Convenience composer-driven send. Returns whether the request was
    /// accepted (queued or started).
    @discardableResult
    func sendFromComposer(
        text rawText: String,
        backendText rawBackendText: String? = nil,
        appendRuleText rawAppendRuleText: String? = nil,
        attachments: [ChatMessageAttachment] = [],
        project: ProjectItem?,
        cli: CLIType,
        modelID: String,
        contextModelID: String? = nil,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort,
        sessionMode: SessionMode,
        resumeSessionID: String?
    ) -> Bool {
        send(
            text: rawText,
            backendText: rawBackendText,
            appendRuleText: rawAppendRuleText,
            attachments: attachments,
            project: project,
            cli: cli,
            modelID: modelID,
            contextModelID: contextModelID,
            contextWindow: Self.defaultContextWindow(for: contextModelID ?? modelID, cli: cli),
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            sessionMode: sessionMode,
            resumeSessionID: resumeSessionID
        )
    }

    /// Alias for `interrupt(startQueuedAfterStop:)`. The iOS-side spec uses
    /// the verb `stop`; the existing Mac UI uses `interrupt`. Both call sites
    /// remain wire-compatible.
    func stop(startQueuedAfterStop: Bool = false) {
        interrupt(startQueuedAfterStop: startQueuedAfterStop)
    }

    /// Edit an already-queued request's text in place. If the request id no
    /// longer exists (e.g. it just started running) this is a no-op.
    func editQueuedRequest(_ id: UUID, text rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = queuedRequests.firstIndex(where: { $0.id == id }) else { return }
        let old = queuedRequests[index]
        let replacement = QueuedChatRequest(
            id: old.id,
            text: trimmed,
            displayText: trimmed,
            appendRuleText: old.appendRuleText,
            attachments: old.attachments,
            project: old.project,
            cli: old.cli,
            modelID: old.modelID,
            contextModelID: old.contextModelID,
            contextWindow: old.contextWindow,
            permissionMode: old.permissionMode,
            reasoningEffort: old.reasoningEffort,
            sessionMode: old.sessionMode,
            resumeSessionID: old.resumeSessionID,
            createdAt: old.createdAt
        )
        queuedRequests[index] = replacement
        bumpStructureRevision()
        persistCurrentSession(saveMessages: false)
        publishActivity()
    }

    /// Convenience wrapper matching the §1.2 spec name.
    func respondToInteractive(_ response: ChatInteractiveResponse) {
        respondToInteractiveRequest(response)
    }

    /// Switch the controller to a different session. The actual session
    /// loading flows through `loadFromAppState` once `AppState.selectedCLIHistoryID`
    /// is updated; this hook lets remote callers (and Mac UI shortcuts)
    /// trigger that without going through SwiftUI binding round-trips.
    func switchSession(_ sessionID: UUID, in appState: AppState) {
        guard !hasLiveRun || currentSessionID == sessionID else {
            publishActivity()
            return
        }
        guard let target = appState.cliHistory.first(where: { sessionUUIDComponent(in: $0.id) == sessionID.uuidString })
        else { return }
        appState.selectCLIHistory(target)
        guard appState.selectedCLIHistoryID == target.id else { return }
        let resolvedModelID = composerModelID.nonEmptyTrimmed ?? ChatModelCatalog.defaultClaudeModelID
        loadFromAppState(
            appState,
            modelID: resolvedModelID,
            permissionMode: composerPermissionMode,
            reasoningEffort: composerReasoningEffort
        )
    }

    /// Create a new draft (no-session-yet) chat for the given project, return
    /// a stable placeholder UUID that callers can use for follow-ups. The
    /// real `ChatSessionRecord` is allocated when the next `send` actually
    /// starts a run; until then the draft is just a UI state.
    @discardableResult
    func newDraftSession(projectId: UUID?) -> UUID {
        guard !hasLiveRun else {
            publishActivity()
            return currentSessionID ?? UUID()
        }
        resetToNewSession()
        return currentSessionID ?? UUID()
    }

    /// Push the composer text to the controller. Mac SwiftUI views still own
    /// their `@State` draftMessage; this method exists for the remote
    /// protocol to mirror what the iOS client types so Mac can show it in
    /// snapshot. Mac UI is free to ignore — it remains source of truth for
    /// its own composer field.
    func setComposerText(_ text: String) {
        guard composerText != text else { return }
        composerText = text
        notifySessionChanged()
    }

    func setCLI(_ cli: CLIType) {
        let visibleCLI = cli.visibleValue
        let normalizedModelID = ChatModelCatalog.compatibleModelID(composerModelID, cli: visibleCLI)
        let normalizedContextModelID = ChatModelCatalog.compatibleModelID(composerContextModelID ?? normalizedModelID, cli: visibleCLI)
        guard composerCLI != visibleCLI
            || composerModelID != normalizedModelID
            || composerContextModelID != normalizedContextModelID
        else { return }
        composerCLI = visibleCLI
        composerModelID = normalizedModelID
        composerContextModelID = normalizedContextModelID
        syncContextWindow(modelID: normalizedContextModelID, cli: visibleCLI)
        notifySessionChanged()
    }

    func setModel(_ modelID: String) {
        let normalizedModelID = ChatModelCatalog.compatibleModelID(modelID, cli: composerCLI)
        guard composerModelID != normalizedModelID || composerContextModelID != normalizedModelID else { return }
        composerModelID = normalizedModelID
        composerContextModelID = normalizedModelID
        syncContextWindow(modelID: normalizedModelID, cli: composerCLI)
        notifySessionChanged()
    }

    func setContextModel(_ modelID: String?) {
        guard composerContextModelID != modelID else { return }
        composerContextModelID = modelID
        notifySessionChanged()
    }

    func setPermissionMode(_ mode: ChatPermissionMode) {
        guard composerPermissionMode != mode else { return }
        composerPermissionMode = mode
        notifySessionChanged()
    }

    func setReasoningEffort(_ effort: ChatReasoningEffort) {
        guard composerReasoningEffort != effort else { return }
        composerReasoningEffort = effort
        notifySessionChanged()
    }

    func uploadAttachment(_ attachment: ChatMessageAttachment) {
        composerAttachments.append(attachment)
        notifySessionChanged()
    }

    func removeAttachment(id: UUID) {
        let before = composerAttachments.count
        composerAttachments.removeAll { $0.id == id }
        if composerAttachments.count != before {
            notifySessionChanged()
        }
    }

    // MARK: - Broadcasting hooks (exposed to RemoteChatBridge / future
    // PanelStateBroadcaster)
    //
    // The protocol-server agent's `PanelStateBroadcaster` will subscribe to
    // `objectWillChange` (or this `sessionChangePublisher`) to build the
    // snapshot/patch stream described in spec §4. We deliberately use Mac
    // internal types here — once the shared `RemoteVNCProtocol.swift` lands,
    // a small adapter file (added by main agent during merge) will translate
    // `PanelStatePayload` → `PanelStateSnapshot` and `RemoteCommand` →
    // `Command`.

    /// Synchronous read of the current session's panel state for snapshot
    /// production. Returns `nil` if no session is currently active.
    func snapshotPayload(for sessionID: UUID? = nil) -> PanelStatePayload? {
        let targetID = sessionID ?? currentSessionID
        guard let targetID, currentSessionID == targetID else { return nil }
        return PanelStatePayload(
            sessionID: targetID,
            messages: messages,
            queuedRequests: queuedRequests,
            status: status,
            statusText: statusText,
            isAwaitingFirstModelOutput: isAwaitingFirstModelOutput,
            isLoadingHistory: isLoadingHistory,
            tokensUsed: tokensUsed,
            tokensTotal: tokensTotal,
            activeRunStartedAt: currentSessionSnapshot?.activeRunStartedAt,
            isMirroringRemoteSession: isMirroringRemoteSession,
            composer: PanelStatePayload.Composer(
                text: composerText,
                cli: composerCLI,
                modelID: composerModelID,
                contextModelID: composerContextModelID,
                permissionMode: composerPermissionMode,
                reasoningEffort: composerReasoningEffort,
                attachments: composerAttachments
            ),
            capabilities: capabilities,
            structureRevision: structureRevision
        )
    }

    /// Dispatch a remote command from iOS / future VNC client. The mac-side
    /// adapter file (added during merge) will decode `Command` DTOs into
    /// these calls — we model the routing as a sum type so this worktree
    /// can compile without depending on protocol DTOs that aren't merged yet.
    @discardableResult
    func apply(remoteCommand command: RemoteCommand) async -> RemoteCommandAck {
        switch command {
        case .focusSession(let id):
            // Caller (server) drives `ChatRuntimeStore` to vend the right
            // controller; nothing local to do.
            return .ok(sessionId: id)
        case .newDraftSession(let projectId):
            let id = newDraftSession(projectId: projectId)
            return .ok(sessionId: id)
        case .composerSet(let text):
            setComposerText(text); return .ok(sessionId: currentSessionID)
        case .composerSetCLI(let cli):
            setCLI(cli); return .ok(sessionId: currentSessionID)
        case .composerSetModel(let modelID):
            setModel(modelID); return .ok(sessionId: currentSessionID)
        case .composerSetPermissionMode(let mode):
            setPermissionMode(mode); return .ok(sessionId: currentSessionID)
        case .composerSetReasoningEffort(let effort):
            setReasoningEffort(effort); return .ok(sessionId: currentSessionID)
        case .composerAttach(let attachment):
            uploadAttachment(attachment); return .ok(sessionId: currentSessionID)
        case .composerRemoveAttach(let id):
            removeAttachment(id: id); return .ok(sessionId: currentSessionID)
        case .composerSend(let project, let sessionMode, let resumeSessionID, let appendRuleText):
            let ok = sendFromComposer(
                text: composerText,
                appendRuleText: appendRuleText,
                attachments: composerAttachments,
                project: project,
                cli: composerCLI,
                modelID: composerModelID,
                contextModelID: composerContextModelID,
                permissionMode: composerPermissionMode,
                reasoningEffort: composerReasoningEffort,
                sessionMode: sessionMode,
                resumeSessionID: resumeSessionID
            )
            // Reset composer mirror after a successful send.
            if ok { composerText = ""; composerAttachments = []; notifySessionChanged() }
            return ok ? .ok(sessionId: currentSessionID) : .rejected("send refused")
        case .stop(let startQueuedAfterStop):
            stop(startQueuedAfterStop: startQueuedAfterStop)
            return .ok(sessionId: currentSessionID)
        case .flushQueue:
            // Audit B-P1-2: `flushQueue` now means "discard the entire queue",
            // matching the iOS UX text ("清空 +N 条排队"). For the legacy
            // semantics ("interrupt current + start next queued"), clients
            // should send `.interruptAndStartNext`.
            discardQueuedRequestsForNewChat()
            return .ok(sessionId: currentSessionID)
        case .interruptAndStartNext:
            interrupt(startQueuedAfterStop: true)
            return .ok(sessionId: currentSessionID)
        case .cancelQueued(let id):
            cancelQueuedRequest(id); return .ok(sessionId: currentSessionID)
        case .editQueued(let id, let text):
            editQueuedRequest(id, text: text); return .ok(sessionId: currentSessionID)
        case .respondPermission(let requestID, let decision):
            respondToPermission(requestID: requestID, decision: decision)
            return .ok(sessionId: currentSessionID)
        case .respondInteractive(let response):
            respondToInteractiveRequest(response)
            return .ok(sessionId: currentSessionID)
        case .requestSnapshot:
            return .ok(sessionId: currentSessionID)
        case .refreshCapabilities:
            refreshCapabilities(force: true)
            return .ok(sessionId: currentSessionID)
        }
    }

    private func notifySessionChanged() {
        sessionChangeSubject.send(currentSessionID)
    }

    private func sessionUUIDComponent(in historyID: String) -> String? {
        let parts = historyID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[1]) != nil else { return nil }
        return parts[1]
    }
}

// MARK: - VNC bridging types
//
// These are the *Mac-internal* equivalents of the DTOs from
// `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift` (created by the
// protocol-server agent in a parallel worktree). We don't depend on the
// shared file from this worktree — the merge agent writes a small adapter
// translating these types into the wire format.

struct PanelStatePayload {
    struct Composer {
        let text: String
        let cli: CLIType
        let modelID: String
        let contextModelID: String?
        let permissionMode: ChatPermissionMode
        let reasoningEffort: ChatReasoningEffort
        let attachments: [ChatMessageAttachment]
    }

    let sessionID: UUID
    let messages: [ChatMessage]
    let queuedRequests: [QueuedChatRequest]
    let status: ChatRunStatus
    let statusText: String
    let isAwaitingFirstModelOutput: Bool
    let isLoadingHistory: Bool
    let tokensUsed: Int
    let tokensTotal: Int
    let activeRunStartedAt: Date?
    let isMirroringRemoteSession: Bool
    let composer: Composer
    let capabilities: [CLIType: ChatCLICapability]
    let structureRevision: Int
}

/// Mac-internal mirror of `Command.Op` from
/// `共享代码/ChatCore/Sources/ChatCore/RemoteVNCProtocol.swift` (protocol-server
/// worktree). The merge adapter will decode the wire DTO into this enum.
enum RemoteCommand {
    case focusSession(UUID)
    case newDraftSession(projectId: UUID?)
    case composerSet(text: String)
    case composerSetCLI(CLIType)
    case composerSetModel(String)
    case composerSetPermissionMode(ChatPermissionMode)
    case composerSetReasoningEffort(ChatReasoningEffort)
    case composerAttach(ChatMessageAttachment)
    case composerRemoveAttach(UUID)
    case composerSend(project: ProjectItem, sessionMode: SessionMode, resumeSessionID: String?, appendRuleText: String?)
    case stop(startQueuedAfterStop: Bool)
    case flushQueue
    case interruptAndStartNext
    case cancelQueued(UUID)
    case editQueued(UUID, text: String)
    case respondPermission(requestID: String, decision: ChatPermissionDecision)
    case respondInteractive(ChatInteractiveResponse)
    case requestSnapshot
    case refreshCapabilities
}

enum RemoteCommandAck {
    case ok(sessionId: UUID?)
    case rejected(String)
    case error(String)
}
