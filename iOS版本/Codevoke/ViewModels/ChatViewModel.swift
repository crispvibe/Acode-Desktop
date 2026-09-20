import Foundation
import Combine
import ChatCore

// MARK: - Local view-helper structs

/// Message-list update signal —— view 用它做"是否需要滚到底"等判断。每次 messages 数组
/// 实际变化时单调递增。
struct MessageListUpdateSignal: Equatable {
    let revision: Int
    let count: Int
    let lastMessageID: UUID?
}

struct StreamingTextUpdateSignal: Equatable {
    let revision: Int
    let totalTextLength: Int
}

enum ChatMessageListRow: Identifiable {
    case message(ChatMessage)
    case toolGroup(id: UUID, messages: [ChatMessage], toolCount: Int)

    var id: UUID {
        switch self {
        case .message(let message): return message.id
        case .toolGroup(let id, _, _): return id
        }
    }
}

/// 一条尚未被 server ack 的本地命令。断线重连后会按 enqueue 顺序重发。
private struct PendingCommand {
    let command: Command
    let enqueuedAt: Date
}

private struct RemoteRecoveryRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Connection & UI state (本地)

    @Published var config: RemoteChatConfig
    @Published var connectionStatus = "未连接"
    @Published var lastError: String?

    @Published var isSidebarVisible = false
    @Published var isSettingsPresented = false
    @Published var collapseToolsByDefault: Bool {
        didSet { UserDefaults.standard.set(collapseToolsByDefault, forKey: "ui.collapseTools") }
    }
    @Published var expandedToolGroupIDs: Set<UUID> = []

    /// composer 文本是本地 `@State` —— 主代理决策不每键击都发 `composerSet`，
    /// 仅在 send 时携带。
    @Published var inputText = ""

    /// 滚动到底部脉冲事件。
    @Published var scrollToBottomRequestID = UUID()

    /// 本地待发送/已上传附件占位（上传完成后转成 ChatMessageAttachment 走 composerAttach）。
    @Published var attachments: [RemoteUploadedAttachment] = []
    @Published var isUploadingAttachment = false

    // MARK: - File tree (HTTP-only)

    @Published var fileEntries: [RemoteProjectFileEntry] = []
    @Published var currentFilePath = ""
    @Published var parentFilePath: String?
    @Published var isLoadingFiles = false
    @Published var fileError: String?

    @Published var isRefreshing = false

    // MARK: - Authoritative server snapshot (镜像)

    /// 当前聚焦会话的最新 snapshot；所有业务渲染都从这里读。
    @Published private(set) var currentSnapshot: PanelStateSnapshot?

    /// 触发 view 滚动判断的脉冲（messages 引用变更时递增）。
    @Published private(set) var messageListUpdateSignal = MessageListUpdateSignal(revision: 0, count: 0, lastMessageID: nil)
    private var messageListRevision = 0
    private var lastMessageArrayCount: Int = -1
    private var lastMessageLastID: UUID?
    @Published private(set) var streamingTextUpdateSignal = StreamingTextUpdateSignal(revision: 0, totalTextLength: 0)
    private var streamingTextRevision = 0
    private var lastStreamingTextSignature = ""

    /// 本地正在编辑的队列消息 id（纯本地 UI 状态，不算业务）。
    @Published var editingQueuedRequestID: String?

    // MARK: - Networking

    private var remoteTransport: RemoteTransport?
    private var webSocketGeneration = 0
    /// Audit A-P1: consecutive auto-reconnect attempts since the last
    /// successful connect. Drives exponential backoff (1s → 2s → 4s → 8s →
    /// 16s → 30s cap). Reset to 0 on a successful `onConnect`.
    private var reconnectAttempt: Int = 0
    private var panelStateEnvelopeSequence = 0
    private var refreshRequestSnapshotAfterConnect = false
    private var foregroundRefreshTask: Task<Void, Never>?
    private var uploadStateRevision = 0
    private let maxAttachmentBytes = 10 * 1024 * 1024
    private let maxTotalAttachmentBytes = 20 * 1024 * 1024
    private var supportsActiveDirectHTTP: Bool {
        config.isComplete
    }

    /// snapshot/patch 镜像。
    private let mirror = PanelStateMirror()

    /// 合并窗口：流式期间 host 每 ~30ms 推一个 patch，绝大多数只改
    /// streamingTexts/statusText/tokens 这类"外观"字段。这类 patch 仍然立即
    /// 并入 mirror（保住 baseRevision 链、数据不丢），但 `@Published` 的发布
    /// 合并到一个尾部 flush —— 否则每个 patch 都会触发整列重建 +
    /// 正在流式的那行整段 markdown/block 重解析（缓存 key 是全量文本，追加式
    /// 增长意味着每个 patch 都是 cache miss 的 O(n) 重解析）。
    private var pendingCosmeticSnapshot: PanelStateSnapshot?
    private var cosmeticPublishTask: Task<Void, Never>?
    private static let cosmeticPublishDelayNanoseconds: UInt64 = 80_000_000
    private var recoveredSessionsByProjectId: [UUID: [PanelSessionDTO]] = [:]
    private var recoveredMessagesBySessionId: [UUID: [ChatMessage]] = [:]
    private var recoveredMessagePageStateBySessionId: [UUID: (nextBeforeIndex: Int?, hasMore: Bool)] = [:]
    private var recoveredSelectedSessionId: UUID?
    @Published private var loadingOlderMessageSessionIds: Set<UUID> = []
    private var pendingRecoveryContinuations: [UUID: CheckedContinuation<RemoteRecoveryResponse, Error>] = [:]
    private static let recoveryRequestTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// 当前希望聚焦的 sessionId（=nil 表示草稿）。server 收到 `focusSession` 后会
    /// 在新 sessionId 的 snapshot 里设置 `currentSessionId`。
    private var focusedSessionId: UUID?
    private var pendingFocusedSessionId: UUID?
    private var pendingProjectFocusId: UUID?
    private var pendingProjectFocusTimeoutTask: Task<Void, Never>?
    private var pendingFocusedSessionTimeoutTask: Task<Void, Never>?

    private static let persistedProjectFocusKey = "remote.focus.projectId"
    private static let persistedSessionFocusKey = "remote.focus.sessionId"

    /// Audit P0：切会话/切项目超时之前是 2s，server 端从磁盘恢复历史经常超过这个值，
    /// 表现为用户每切一次就弹"切换会话超时"。延长到 8s，给磁盘 IO / CLI 恢复足够时间。
    /// 真的超时也不再写 `lastError` 弹给用户 —— 后台已经自动重发 requestSnapshot 兜底，
    /// 用户看不到红色错误更直观。
    private static let pendingFocusTimeoutNanoseconds: UInt64 = 8_000_000_000

    // MARK: - Idempotent command queue

    /// `commandId -> PendingCommand`。已发送但未 ack 的命令。
    /// - 断线重连后按 enqueue 顺序重发同 commandId，避免 server 重复执行。
    /// - ack 到达即移除；超过 200 条强制丢弃最早的（防内存爆炸）。
    private var pendingCommands: [(id: UUID, value: PendingCommand)] = []
    private let pendingCommandLimit = 200

    /// FIFO send chain. Every `sendCommand` chains onto the previous task's
    /// completion so commands hit the wire in the order they were enqueued.
    /// `sendCurrentMessage` relies on this — without it, `composerSet` and
    /// `composerSend` race and the latter often arrives at an empty composer,
    /// which the server rejects silently and the message never executes.
    private var sendChain: Task<Void, Never>?

    // MARK: - Init

    init(initialConfig: RemoteChatConfig? = nil) {
        let defaults = UserDefaults.standard
        var resolved = initialConfig ?? RemoteChatConfig(
            macHost: defaults.string(forKey: "remote.macHost") ?? "",
            port: defaults.object(forKey: "remote.port") == nil ? DeviceConnectViewModel.defaultPort : defaults.integer(forKey: "remote.port")
        )
        // 凭据不落 UserDefaults——持久化的只有 hostId 指针，重启后从这里
        // 回 EndpointStore（Keychain）取 token/fp（§6 EndpointStore）。
        if resolved.hostId == nil {
            resolved.hostId = defaults.string(forKey: "remote.hostId")
        }
        if let hostId = resolved.hostId, let record = EndpointStore.shared.record(forHostId: hostId) {
            resolved.hostName = record.name
            resolved.authToken = record.token
            resolved.certFP = record.certFP
        }
        config = resolved
        collapseToolsByDefault = defaults.object(forKey: "ui.collapseTools") == nil ? true : defaults.bool(forKey: "ui.collapseTools")
        _localSelectedProjectId = defaults.string(forKey: Self.persistedProjectFocusKey).flatMap(UUID.init(uuidString:))
        focusedSessionId = defaults.string(forKey: Self.persistedSessionFocusKey).flatMap(UUID.init(uuidString:))
        isSettingsPresented = !config.isComplete
    }

    // MARK: - Connection lifecycle

    /// 保存连接配置并重连。
    func saveConnectionConfig() {
        let defaults = UserDefaults.standard
        defaults.set(config.macHost, forKey: "remote.macHost")
        defaults.set(config.port, forKey: "remote.port")
        // hostId 只是指针；token/fp 始终在 EndpointStore 的 Keychain 里。
        if let hostId = config.hostId {
            defaults.set(hostId, forKey: "remote.hostId")
        } else {
            defaults.removeObject(forKey: "remote.hostId")
        }
        // Drop keys from the pre-LAN-only builds.
        defaults.removeObject(forKey: "remote.token")
        defaults.removeObject(forKey: "remote.connectionId")
        defaults.removeObject(forKey: "remote.transport")
        defaults.removeObject(forKey: "remote.reason")
        webSocketGeneration += 1
        disconnectCurrentTransport()
        mirror.clearAll()
        currentSnapshot = nil
        isSettingsPresented = false
        Task { await refresh() }
    }

    /// 旧 API 兼容入口。
    func saveConfig() {
        saveConnectionConfig()
    }

    /// 兼容旧调用 —— iOS 不再写偏好，CLI/model 是 server 权威。
    func savePreferences(refetchModels: Bool = false) {
        // No-op: CLI/model/permission/reasoning 都是 server 权威。
    }

    /// 前台恢复：若 WS 已断则重连，否则什么都不做。
    func reconnectIfNeeded() {
        guard config.isComplete else { return }
        if remoteTransport?.isConnected == true { return }
        ensureWebSocketConnected(reason: "reconnect on foreground")
    }

    /// 回前台自动恢复：复用手动刷新路径，覆盖半死连接和已断连接。
    func resumeFromForeground() {
        guard config.isComplete else { return }
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.appendDebug("foreground resume: auto refresh")
            await self.refresh()
        }
    }

    /// 进入后台前关闭 WS，避免半死连接。
    func suspendForBackground() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        guard remoteTransport != nil else { return }
        appendDebug("WS suspend for background")
        webSocketGeneration += 1
        disconnectCurrentTransport()
        connectionStatus = "未连接"
    }

    /// "刷新" —— 用户主动要求 server 重推状态，并重拉当前项目文件树。
    func refresh() async {
        guard config.isComplete else {
            connectionStatus = "未连接"
            isSettingsPresented = true
            return
        }
        guard !isRefreshing else {
            appendDebug("refresh skipped: already running")
            return
        }
        isRefreshing = true
        let startedAt = Date()
        appendDebug("refresh start status=\(connectionStatus) wsConnected=\(remoteTransport?.isConnected == true)")
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            appendDebug(String(format: "refresh end elapsed=%.2fs status=%@", elapsed, connectionStatus))
            isRefreshing = false
        }
        lastError = nil
        do {
            if supportsActiveDirectHTTP {
                if config.isPaired {
                    // 已配对主机跳过单一地址的 /health 预检：持久化的地址可能
                    // 已失效但其它 eps 可用，交给 RemoteWanTransport 逐条竞速判定。
                    appendDebug("refresh health preflight skipped: paired transport races endpoints")
                } else {
                    do {
                        let client = makeHTTPClient()
                        _ = try await client.fetchHealth()
                        appendDebug("refresh health ok")
                    } catch {
                        throw error
                    }
                }
            } else {
                throw RemoteChatError.missingConfiguration
            }

            let wasConnected = remoteTransport?.isConnected == true
            let forceReconnect = !wasConnected
            let baselineEnvelopeSequence = panelStateEnvelopeSequence
            appendDebug("refresh ws force=\(forceReconnect) wasConnected=\(wasConnected) status=\(connectionStatus)")

            if forceReconnect {
                refreshRequestSnapshotAfterConnect = true
            }
            let didStartOrHaveConnection = ensureWebSocketConnected(reason: "refresh", force: forceReconnect)
            appendDebug("refresh reconnectTriggered=\(forceReconnect) connectionReadyOrStarted=\(didStartOrHaveConnection)")

            if !forceReconnect, didStartOrHaveConnection {
                sendRefreshSnapshotRequest(reason: "refresh connected")
                Task { @MainActor [weak self] in
                    _ = await self?.loadRecoveredCatalog(reason: "refresh connected")
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let filesReloaded = await self.reloadFilesForRefresh()
                self.appendDebug("refresh filesReloaded=\(filesReloaded)")
            }

            let panelStateTimeout: UInt64 = 3_000_000_000
            let receivedPanelState = await waitForPanelState(after: baselineEnvelopeSequence, timeoutNanoseconds: panelStateTimeout)
            appendDebug("refresh panelStateReceived=\(receivedPanelState)")
            if !receivedPanelState, !forceReconnect, didStartOrHaveConnection {
                appendDebug("refresh panel_state timeout; escalating to force reconnect")
                refreshRequestSnapshotAfterConnect = true
                let forceStarted = ensureWebSocketConnected(reason: "refresh panel_state timeout", force: true)
                appendDebug("refresh forceReconnectAfterTimeout started=\(forceStarted)")
            }
        } catch {
            if Self.isCancellation(error) { return }
            lastError = error.localizedDescription
            connectionStatus = "连接失败"
            appendDebug("refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - User intents → Commands

    /// "新对话"按钮。先聚焦项目再建草稿，避免 Mac 端用旧 cwd 启动 CLI。
    func startNewChat() {
        guard let selectedProjectId = pendingProjectFocusId ?? selectedProject?.id else {
            appendDebug("startNewChat: no project selected")
            return
        }
        cancelCosmeticPublish()
        clearPendingFocusedSessionId()
        pendingProjectFocusId = selectedProjectId
        focusedSessionId = nil
        persistRemoteFocus(projectId: selectedProjectId, sessionId: nil)
        schedulePendingProjectFocusTimeout(projectId: selectedProjectId)
        sendCommand(Command(op: .focusProject, args: CommandArgs(projectId: selectedProjectId)))
        sendCommand(Command(op: .newDraftSession, args: CommandArgs(projectId: selectedProjectId)))
        clearComposerStateForContextSwitch()
        isSidebarVisible = false
    }

    /// 选项目 —— 先切远端项目，再通过恢复通道补齐会话、消息和文件列表。
    func selectProject(_ project: PanelProjectDTO) async {
        cancelCosmeticPublish()
        clearPendingFocusedSessionId()
        pendingProjectFocusId = project.id
        focusedSessionId = nil
        recoveredSelectedSessionId = nil
        persistRemoteFocus(projectId: project.id, sessionId: nil)
        schedulePendingProjectFocusTimeout(projectId: project.id)
        autoLoadedProjectId = nil
        fileEntries = []
        fileError = nil
        currentFilePath = ""
        parentFilePath = nil
        currentSnapshot = nil
        bumpMessageListSignalIfChanged(messages: [])
        bumpStreamingTextSignalIfChanged(streamingTexts: [])
        clearComposerStateForContextSwitch()
        sendCommand(Command(op: .focusProject, args: CommandArgs(projectId: project.id)))
        await loadRecoveredSessions(for: project.id, autoOpenLatest: true)
        await loadFilesIfPossible(projectId: project.id, path: "")
        isSidebarVisible = false
    }

    /// 选模型 —— 走 server 权威 composerSetModel。
    func selectModel(_ model: PanelModelDTO) {
        sendCommand(Command(
            op: .composerSetModel,
            args: CommandArgs(
                cli: model.cli.isEmpty ? nil : model.cli,
                modelID: model.id,
                expectedProjectId: currentExpectedProjectId,
                expectedSessionId: currentExpectedSessionId
            )
        ))
    }

    /// 切 CLI —— 走 server 权威 composerSetCLI。
    /// cli 是 String 透传字段（host 端可新增取值），这里只拦空串不做白名单。
    func selectCLI(_ cli: String) {
        let trimmed = cli.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        sendCommand(Command(op: .composerSetCLI, args: CommandArgs(cli: trimmed, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
    }

    /// Audit C-02: switch permission mode (auto / ask / bypass) via server.
    func selectPermissionMode(_ mode: String) {
        sendCommand(Command(op: .composerSetPermissionMode, args: CommandArgs(permissionMode: mode, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
    }

    /// Audit C-02: switch reasoning effort (low / medium / high) via server.
    func selectReasoningEffort(_ effort: String) {
        sendCommand(Command(op: .composerSetReasoningEffort, args: CommandArgs(reasoningEffort: effort, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
    }

    /// 选会话 —— focusSession。
    func selectSession(_ session: PanelSessionDTO) async {
        cancelCosmeticPublish()
        clearPendingProjectFocusId()
        // Audit C-04: if the session belongs to a different project than the
        // one currently highlighted in the sidebar, sync `_localSelectedProjectId`
        // so the header / file tree follow the actual conversation context.
        if let projectId = session.projectId, projectId != _localSelectedProjectId {
            _localSelectedProjectId = projectId
            // Reset file tree state for the new project.
            fileEntries = []
            fileError = nil
            currentFilePath = ""
            parentFilePath = nil
            autoLoadedProjectId = nil
            await loadFilesIfPossible(projectId: projectId, path: "")
        }
        clearComposerStateForContextSwitch()
        setPendingFocusedSessionId(session.id)
        persistRemoteFocus(projectId: session.projectId ?? _localSelectedProjectId, sessionId: session.id)
        // 立刻把 mirror 里已知的本会话 snapshot 拿出来贴上 —— 用户点击后能马上看到
        // 聊天记录，而不是等 server 回完 focusSession 才出现内容。server 后续会推送
        // 更新版本通过 handleEnvelope 覆盖。
        if let cached = mirror.snapshot(for: session.id) {
            currentSnapshot = cached
            bumpMessageListSignalIfChanged(messages: cached.messages)
            bumpStreamingTextSignalIfChanged(streamingTexts: cached.streamingTexts)
        }
        sendCommand(Command(op: .focusSession, sessionId: session.id, args: CommandArgs(sessionId: session.id)))
        await loadRecoveredMessages(sessionId: session.id, expectedProjectId: session.projectId ?? _localSelectedProjectId, prependOlder: false)
        isSidebarVisible = false
    }

    /// 发送消息。
    func sendCurrentMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let expectedProjectId = currentExpectedProjectId
        let expectedSessionId = currentExpectedSessionId

        // 1. 把附件挂到 server composer。
        for attachment in attachments {
            let dto = ChatMessageAttachment(
                id: attachment.id,
                kind: attachment.previewData != nil ? .image : .file,
                filename: attachment.filename,
                path: attachment.path,
                thumbnailData: nil
            )
            sendCommand(Command(
                op: .composerAttach,
                sessionId: expectedSessionId,
                args: CommandArgs(attachment: dto, expectedProjectId: expectedProjectId, expectedSessionId: expectedSessionId)
            ))
        }

        // 2. 把 composer 文本同步到 server。
        sendCommand(Command(
            op: .composerSet,
            sessionId: expectedSessionId,
            args: CommandArgs(text: trimmed, expectedProjectId: expectedProjectId, expectedSessionId: expectedSessionId)
        ))

        // 3. 触发 send。
        sendCommand(Command(
            op: .composerSend,
            sessionId: expectedSessionId,
            args: CommandArgs(expectedProjectId: expectedProjectId, expectedSessionId: expectedSessionId)
        ))

        // 4. 清本地 composer。
        clearComposerStateForSend()
        scrollToBottomRequestID = UUID()
    }

    /// 停止生成。
    func stopGeneration() async {
        sendCommand(Command(op: .stop, args: CommandArgs(startQueuedAfterStop: false)))
    }

    func respondPermission(requestID: String, decision: String) {
        sendCommand(Command(
            op: .respondPermission,
            sessionId: currentExpectedSessionId,
            args: CommandArgs(
                permissionRequestId: requestID,
                decision: decision,
                expectedProjectId: currentExpectedProjectId,
                expectedSessionId: currentExpectedSessionId
            )
        ))
    }

    func respondInteractive(_ response: ChatInteractiveResponse) {
        sendCommand(Command(
            op: .respondInteractive,
            sessionId: currentExpectedSessionId,
            args: CommandArgs(
                interactiveRequestId: response.requestID,
                interactiveResponse: response,
                expectedProjectId: currentExpectedProjectId,
                expectedSessionId: currentExpectedSessionId
            )
        ))
    }

    /// flush 全部队列（用户长按"+N 条排队中"操作)。
    func flushQueueNow() async {
        sendCommand(Command(op: .flushQueue))
    }

    /// 删除一条队列消息。
    func deleteQueuedMessage(_ message: ChatMessage) async {
        guard let queueId = message.id as UUID? else { return }
        sendCommand(Command(op: .cancelQueued, args: CommandArgs(requestId: queueId.uuidString, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
    }

    /// 编辑一条队列消息。
    func beginEditingQueuedMessage(_ message: ChatMessage) {
        editingQueuedRequestID = message.id.uuidString
        inputText = message.text
    }

    func commitEditedQueuedMessage() {
        guard let editingID = editingQueuedRequestID else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendCommand(Command(op: .editQueued, args: CommandArgs(text: trimmed, requestId: editingID, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
        inputText = ""
        editingQueuedRequestID = nil
    }

    // MARK: - File tree

    func openFileEntry(_ entry: RemoteProjectFileEntry) async {
        guard entry.isDirectory, let projectId = selectedProject?.id else { return }
        await loadFilesIfPossible(projectId: projectId, path: entry.relativePath)
    }

    func absolutePath(for entry: RemoteProjectFileEntry) -> String? {
        guard let project = selectedProject else { return nil }
        let rootPath = project.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = entry.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rootPath.isEmpty else { return relativePath.isEmpty ? "/" : "/\(relativePath)" }
        return relativePath.isEmpty ? "/\(rootPath)" : "/\(rootPath)/\(relativePath)"
    }

    func insertPathIntoInput(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = trimmedPath
        } else {
            inputText += "\n\(trimmedPath)"
        }
        isSidebarVisible = false
    }

    func openParentDirectory() async {
        guard let projectId = selectedProject?.id, let parentFilePath else { return }
        await loadFilesIfPossible(projectId: projectId, path: parentFilePath)
    }

    @discardableResult
    private func loadFilesIfPossible(projectId: UUID, path: String) async -> Bool {
        guard supportsActiveDirectHTTP else {
            isLoadingFiles = true
            defer { isLoadingFiles = false }
            do {
                let response = try await performRecoveryRequest(RemoteRecoveryRequest(op: .projectFiles, projectId: projectId, path: path))
                guard response.status == .ok, let files = response.files else {
                    throw RemoteRecoveryRequestError(message: response.message ?? L10n.string("文件列表读取失败，请稍后重试。"))
                }
                guard isCurrentProjectId(projectId) else {
                    appendDebug("files reload ignored stale project=\(projectId) path=\(path)")
                    return false
                }
                fileEntries = files.entries.map {
                    RemoteProjectFileEntry(name: $0.name, relativePath: $0.relativePath, isDirectory: $0.isDirectory)
                }
                currentFilePath = files.path
                parentFilePath = files.parentPath
                fileError = nil
                autoLoadedProjectId = projectId
                appendDebug("files reload via data channel ok project=\(projectId) path=\(path) count=\(files.entries.count)")
                return true
            } catch {
                if Self.isCancellation(error) { return false }
                fileError = error.localizedDescription
                appendDebug("files reload via data channel failed project=\(projectId) path=\(path): \(error.localizedDescription)")
                return false
            }
        }
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            let result = try await makeHTTPClient().fetchProjectFiles(projectId: projectId, path: path)
            guard isCurrentProjectId(projectId) else {
                appendDebug("files reload ignored stale project=\(projectId) path=\(path)")
                return false
            }
            fileEntries = result.entries
            currentFilePath = result.path
            parentFilePath = result.parentPath
            fileError = nil
            autoLoadedProjectId = projectId
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            fileError = error.localizedDescription
            appendDebug("files reload failed project=\(projectId) path=\(path): \(error.localizedDescription)")
            return false
        }
    }

    private func reloadFilesForRefresh() async -> Bool {
        guard let project = selectedProject else {
            appendDebug("refresh filesReload skipped: no selected project")
            return false
        }
        let path = currentFilePath
        appendDebug("refresh filesReload start project=\(project.id) path=\(path)")
        return await loadFilesIfPossible(projectId: project.id, path: path)
    }

    /// 收到 snapshot 后自动拉一次当前推导项目的根目录文件。
    /// 节流条件:
    /// - 已经为这个 projectId 自动加载过 → 跳过(用户手动 selectProject 会重置 `autoLoadedProjectId`)
    /// - 正在加载 → 跳过(避免风暴)
    /// - 没有可用项目 → 跳过
    /// 这避免了每条 snapshot/patch 都打一次 HTTP 请求 (memory: CPU/内存)。
    private func autoLoadFilesForCurrentProjectIfNeeded() {
        guard !isLoadingFiles else { return }
        guard let project = selectedProject else { return }
        if autoLoadedProjectId == project.id, !fileEntries.isEmpty { return }
        // 用户主动切换项目时已经手动触发过加载;这里只兜底"从未加载过文件树"的初始场景。
        guard fileEntries.isEmpty else { return }
        fileError = nil
        let projectId = project.id
        Task { [weak self] in
            await self?.loadFilesIfPossible(projectId: projectId, path: "")
        }
    }

    /// 上一次自动加载的项目 id,用来避免重复刷文件树。
    private var autoLoadedProjectId: UUID?

    private func resetFiles() {
        fileEntries = []
        currentFilePath = ""
        parentFilePath = nil
        fileError = nil
    }

    // MARK: - Attachment upload (HTTP)

    private func clearComposerStateForContextSwitch() {
        uploadStateRevision &+= 1
        inputText = ""
        attachments.removeAll()
        editingQueuedRequestID = nil
        isUploadingAttachment = false
    }

    private func clearComposerStateForSend() {
        uploadStateRevision &+= 1
        inputText = ""
        attachments.removeAll()
        editingQueuedRequestID = nil
        isUploadingAttachment = false
    }

    func uploadAttachment(filename: String, data: Data, previewData: Data?) async {
        guard data.count <= maxAttachmentBytes else {
            lastError = L10n.string("附件不能超过 10MB。")
            return
        }
        guard attachments.reduce(data.count, { $0 + $1.approximateSize }) <= maxTotalAttachmentBytes else {
            lastError = L10n.string("本次附件总大小不能超过 20MB。")
            return
        }
        let startRevision = uploadStateRevision
        let targetProjectId = currentExpectedProjectId
        let targetSessionId = currentExpectedSessionId
        isUploadingAttachment = true
        defer {
            if uploadStateRevision == startRevision {
                isUploadingAttachment = false
            }
        }
        do {
            let uploaded: RemoteUploadedAttachment
            if supportsActiveDirectHTTP {
                let response = try await makeHTTPClient().uploadAttachment(filename: filename, data: data)
                uploaded = RemoteUploadedAttachment(filename: response.filename, path: response.path, previewData: previewData, approximateSize: data.count)
            } else {
                let response = try await performRecoveryRequest(RemoteRecoveryRequest(
                    op: .uploadAttachment,
                    filename: filename,
                    contentBase64: data.base64EncodedString()
                ))
                guard response.status == .ok, let attachmentUpload = response.attachmentUpload else {
                    throw RemoteRecoveryRequestError(message: response.message ?? L10n.string("附件上传失败，请稍后重试。"))
                }
                uploaded = RemoteUploadedAttachment(filename: attachmentUpload.filename, path: attachmentUpload.path, previewData: previewData, approximateSize: data.count)
            }
            guard uploadStateRevision == startRevision,
                  targetProjectId == currentExpectedProjectId,
                  targetSessionId == currentExpectedSessionId else {
                appendDebug("upload result ignored after context switch: \(filename)")
                return
            }
            attachments.append(uploaded)
        } catch {
            guard uploadStateRevision == startRevision else { return }
            lastError = error.localizedDescription
            appendDebug("upload failed: \(error.localizedDescription)")
        }
    }

    func removeAttachment(_ attachment: RemoteUploadedAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        sendCommand(Command(op: .composerRemoveAttach, args: CommandArgs(attachmentId: attachment.id, expectedProjectId: currentExpectedProjectId, expectedSessionId: currentExpectedSessionId)))
    }

    // MARK: - Recovery data channel

    private func performRecoveryRequest(_ request: RemoteRecoveryRequest) async throws -> RemoteRecoveryResponse {
        guard let transport = remoteTransport, transport.canSendFrames else {
            throw RemoteRecoveryRequestError(message: L10n.string("远程连接尚未就绪，请稍后重试。"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRecoveryContinuations[request.requestId] = continuation
            Task { @MainActor [weak self, weak transport] in
                do {
                    guard let transport else { throw RemoteChatError.missingConfiguration }
                    try await transport.sendRecoveryRequest(request)
                } catch {
                    self?.settleRecoveryRequest(id: request.requestId, result: .failure(error))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.recoveryRequestTimeoutNanoseconds)
                self?.settleRecoveryRequest(
                    id: request.requestId,
                    result: .failure(RemoteRecoveryRequestError(message: L10n.string("远程数据加载超时，请刷新后重试。")))
                )
            }
        }
    }

    private func settleRecoveryRequest(id: UUID, result: Result<RemoteRecoveryResponse, Error>) {
        guard let continuation = pendingRecoveryContinuations.removeValue(forKey: id) else { return }
        switch result {
        case .success(let response):
            continuation.resume(returning: response)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func handleRecoveryResponse(_ response: RemoteRecoveryResponse) {
        settleRecoveryRequest(id: response.requestId, result: .success(response))
    }

    @discardableResult
    private func loadRecoveredCatalog(reason: String) async -> Bool {
        do {
            let requestedProjectId = pendingProjectFocusId ?? _localSelectedProjectId
            let response = try await performRecoveryRequest(RemoteRecoveryRequest(op: .catalog, projectId: requestedProjectId))
            guard response.status == .ok else {
                throw RemoteRecoveryRequestError(message: response.message ?? L10n.string("远程目录加载失败，请刷新后重试。"))
            }
            let projects = response.projects ?? []
            let models = response.models ?? []
            let sessions = response.sessions ?? []
            mirror.updateCatalog(projects: projects, models: models, sessions: sessions)

            var selectedProjectId = requestedProjectId
            if let currentSelectedProjectId = selectedProjectId,
               !projects.contains(where: { $0.id == currentSelectedProjectId }) {
                selectedProjectId = nil
            }
            if selectedProjectId == nil,
               let focusedSessionId,
               let projectId = sessions.first(where: { $0.id == focusedSessionId })?.projectId {
                selectedProjectId = projectId
            }
            if selectedProjectId == nil {
                selectedProjectId = projects.first?.id
            }
            if let selectedProjectId {
                _localSelectedProjectId = selectedProjectId
                recoveredSessionsByProjectId[selectedProjectId] = PanelSessionFilters.sessions(sessions, forSelectedProjectId: selectedProjectId)
                persistRemoteFocus(projectId: selectedProjectId, sessionId: focusedSessionId)
            }

            objectWillChange.send()
            appendDebug("catalog recovery ok reason=\(reason) projects=\(projects.count) sessions=\(sessions.count) models=\(models.count) selectedProject=\(selectedProjectId?.uuidString ?? "nil")")
            return true
        } catch {
            if Self.isCancellation(error) { return false }
            appendDebug("catalog recovery failed reason=\(reason): \(error.localizedDescription)")
            return false
        }
    }

    private func loadRecoveredSessions(for projectId: UUID, autoOpenLatest: Bool) async {
        do {
            let response = try await performRecoveryRequest(RemoteRecoveryRequest(op: .sessions, projectId: projectId))
            guard response.status == .ok else {
                throw RemoteRecoveryRequestError(message: response.message ?? L10n.string("聊天记录加载失败，请刷新后重试。"))
            }
            guard isCurrentProjectId(projectId) else {
                appendDebug("sessions recovery ignored stale project=\(projectId)")
                return
            }
            let sessions = response.sessions ?? []
            recoveredSessionsByProjectId[projectId] = sessions
            appendDebug("sessions recovery ok project=\(projectId) count=\(sessions.count)")
            guard autoOpenLatest, let latest = sessions.first else {
                if sessions.isEmpty, selectedProject?.id == projectId {
                    recoveredSelectedSessionId = nil
                    bumpMessageListSignalIfChanged(messages: [])
                }
                return
            }
            recoveredSelectedSessionId = latest.id
            setPendingFocusedSessionId(latest.id)
            persistRemoteFocus(projectId: projectId, sessionId: latest.id)
            sendCommand(Command(op: .focusSession, sessionId: latest.id, args: CommandArgs(sessionId: latest.id)))
            await loadRecoveredMessages(sessionId: latest.id, expectedProjectId: projectId, prependOlder: false)
        } catch {
            if Self.isCancellation(error) { return }
            appendDebug("sessions recovery failed project=\(projectId): \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    private func loadRecoveredMessages(sessionId: UUID, expectedProjectId: UUID?, prependOlder: Bool) async {
        if prependOlder {
            guard !loadingOlderMessageSessionIds.contains(sessionId) else { return }
            loadingOlderMessageSessionIds.insert(sessionId)
        }
        defer {
            if prependOlder {
                loadingOlderMessageSessionIds.remove(sessionId)
            }
        }
        do {
            let before = prependOlder ? recoveredMessagePageStateBySessionId[sessionId]?.nextBeforeIndex : nil
            let response = try await performRecoveryRequest(RemoteRecoveryRequest(op: .messages, sessionId: sessionId, limit: 120, before: before, page: true))
            guard response.status == .ok, let page = response.messagePage else {
                throw RemoteRecoveryRequestError(message: response.message ?? L10n.string("聊天记录加载失败，请刷新后重试。"))
            }
            if let expectedProjectId, !isCurrentProjectId(expectedProjectId) {
                appendDebug("messages recovery ignored stale project=\(expectedProjectId) session=\(sessionId)")
                return
            }
            guard isCurrentSessionId(sessionId) || prependOlder else {
                appendDebug("messages recovery ignored stale session=\(sessionId)")
                return
            }
            let existing = recoveredMessagesBySessionId[sessionId] ?? []
            let nextMessages = prependOlder ? page.messages + existing : page.messages
            recoveredMessagesBySessionId[sessionId] = nextMessages
            let hasOlderPage = page.hasMore
                && !page.messages.isEmpty
                && (!prependOlder || page.nextBeforeIndex != before)
            recoveredMessagePageStateBySessionId[sessionId] = (page.nextBeforeIndex, hasOlderPage)
            recoveredSelectedSessionId = sessionId
            bumpMessageListSignalIfChanged(messages: displayMessages(snapshot: currentSnapshot))
            appendDebug("messages recovery ok session=\(sessionId) count=\(page.messages.count) hasMore=\(page.hasMore)")
        } catch {
            if Self.isCancellation(error) { return }
            appendDebug("messages recovery failed session=\(sessionId): \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Snapshot-derived view helpers

    /// 当前面板派生属性。view 直接读 currentSnapshot 也行；这些便捷属性少几行模板。
    var messages: [ChatMessage] { displayMessages(snapshot: currentSnapshot) }
    private func displayMessages(snapshot: PanelStateSnapshot?) -> [ChatMessage] {
        let expectedSessionId = recoveredSelectedSessionId ?? pendingFocusedSessionId ?? focusedSessionId
        if let expectedSessionId {
            let snapshotSessionId = snapshot?.currentSessionId ?? snapshot?.sessionId
            if snapshotSessionId == expectedSessionId, let snapshot {
                return snapshot.messages
            }
            return recoveredMessagesBySessionId[expectedSessionId] ?? []
        }
        return snapshot?.messages ?? []
    }

    var messageRows: [ChatMessageListRow] {
        messages
            .filter { message in
                !ChatMessageFilter.shouldHideMessage(
                    kind: message.kind,
                    title: message.title,
                    subtitle: message.subtitle,
                    text: message.text
                )
            }
            .map(ChatMessageListRow.message)
    }
    var queuedMessages: [ChatMessage] {
        // 把 server 的 PanelQueuedRequestDTO 转 ChatMessage 给现有 UI；避免改一堆 view。
        (currentSnapshot?.queuedRequests ?? []).map { item in
            ChatMessage(
                id: item.id,
                kind: .user,
                text: item.text,
                status: "queued",
                attachments: item.attachments
            )
        }
    }
    var queuedMessageCount: Int { currentSnapshot?.queuedRequests.count ?? 0 }
    var isVisibleRunActive: Bool { isActiveStatus(currentSnapshot?.status) }
    var runtimeStatus: String { currentSnapshot?.statusText ?? "" }
    var shouldShowThinkingIndicator: Bool {
        currentSnapshot?.isAwaitingFirstModelOutput ?? false
    }

    /// 给某条消息当前的流式文本（reasoning/正文）。
    func streamingText(for messageID: UUID) -> String? {
        // Bug B: snapshot streamingTexts are indexed so reasoning/body deltas render without per-row scans.
        mirror.streamingText(for: messageID, sessionId: currentSnapshot?.sessionId)?.text
            ?? mirror.latestKnownStreamingText(for: messageID)?.text
    }

    // composer 的 server 权威字段
    var selectedCLI: String { currentSnapshot?.composer.cli ?? "claude" }
    var selectedModelID: String { currentSnapshot?.composer.modelID ?? "default" }
    var selectedPermissionMode: String { currentSnapshot?.composer.permissionMode ?? "autoEdit" }
    var selectedReasoningEffort: String { currentSnapshot?.composer.reasoningEffort ?? "high" }

    /// Audit C-03: expose per-CLI capability so SettingsCLIPage can render
    /// errorMessage / executableAvailable.
    func capability(forCLI cli: String) -> PanelCapabilityDTO? {
        currentSnapshot?.capabilities.first(where: { $0.cli == cli })
    }
    /// 侧栏"模型"卡片用的展示标题。
    /// 优先：当前 composer.modelID 在 models 列表的 title → 当前 CLI 的 default model
    /// → 当前 CLI 的第一个 model → 第一个 model → modelID 原文 → "默认模型"。
    /// 避免出现 modelID == "" 时 title 也是空字符串导致卡片一片空白。
    var selectedModelTitle: String {
        let snapshot = currentSnapshot
        let id = snapshot?.composer.modelID ?? ""
        let modelList = snapshot?.models ?? []
        let cli = snapshot?.composer.cli ?? "claude"
        if !id.isEmpty, let match = modelList.first(where: { $0.id == id && $0.cli == cli }) {
            return match.title.isEmpty ? id : match.title
        }
        if let defaultForCLI = modelList.first(where: { $0.cli == cli && $0.isDefault }) {
            return defaultForCLI.title.isEmpty ? defaultForCLI.id : defaultForCLI.title
        }
        if let firstForCLI = modelList.first(where: { $0.cli == cli }) {
            return firstForCLI.title.isEmpty ? firstForCLI.id : firstForCLI.title
        }
        if let first = modelList.first {
            return first.title.isEmpty ? first.id : first.title
        }
        return id.isEmpty ? L10n.string("默认模型") : id
    }

    var projects: [PanelProjectDTO] { currentSnapshot?.projects ?? mirror.latestKnownProjects }
    var models: [PanelModelDTO] { currentSnapshot?.models ?? mirror.latestKnownModels }
    var selectedCLIModels: [PanelModelDTO] {
        models.filter { $0.cli == selectedCLI }
    }
    var sessions: [PanelSessionDTO] {
        if let projectId = selectedProject?.id,
           let recovered = recoveredSessionsByProjectId[projectId] {
            return recovered
        }
        let all = currentSnapshot?.sessions ?? mirror.latestKnownSessions
        // Bug A: sidebar history follows the same fallback-selected project that the project list highlights.
        return PanelSessionFilters.sessions(all, forSelectedProjectId: selectedProject?.id)
    }

    /// "选中的项目"是本地 UI 状态（用户在侧栏选了哪个），与 server 端的"当前会话所属项目"不一定一致。
    private var _localSelectedProjectId: UUID?

    var selectedProject: PanelProjectDTO? {
        if let id = pendingProjectFocusId,
           let project = projects.first(where: { $0.id == id }) {
            return project
        }
        if let id = _localSelectedProjectId,
           let project = projects.first(where: { $0.id == id }) {
            return project
        }
        return nil
    }

    var selectedSession: PanelSessionDTO? {
        if let id = recoveredSelectedSessionId ?? pendingFocusedSessionId ?? focusedSessionId,
           let session = sessions.first(where: { $0.id == id }) {
            return session
        }
        guard let session = serverSelectedSession else { return nil }
        if let selectedProjectId = pendingProjectFocusId ?? _localSelectedProjectId,
           session.projectId != selectedProjectId {
            return nil
        }
        return session
    }

    private var serverSelectedSession: PanelSessionDTO? {
        guard let currentID = currentSnapshot?.currentSessionId else { return nil }
        return (currentSnapshot?.sessions ?? []).first { $0.id == currentID }
    }

    private var currentExpectedProjectId: UUID? {
        pendingProjectFocusId ?? selectedProject?.id
    }

    private var currentExpectedSessionId: UUID? {
        pendingFocusedSessionId ?? focusedSessionId ?? selectedSession?.id
    }

    private func isCurrentProjectId(_ projectId: UUID) -> Bool {
        if let pendingProjectFocusId {
            return projectId == pendingProjectFocusId
        }
        return projectId == _localSelectedProjectId || projectId == selectedProject?.id
    }

    private func isCurrentSessionId(_ sessionId: UUID) -> Bool {
        if let pendingFocusedSessionId {
            return sessionId == pendingFocusedSessionId
        }
        return sessionId == recoveredSelectedSessionId
            || sessionId == focusedSessionId
            || sessionId == selectedSession?.id
    }

    var canSend: Bool {
        config.isComplete && (currentSnapshot?.composer.isEnabled ?? false || !messages.isEmpty || selectedProject != nil)
    }

    var navigationSubtitle: String {
        if let selectedSession { return selectedSession.title }
        if selectedProject != nil { return "新对话" }
        return "选择项目"
    }

    var effectiveConnectionStatus: String {
        connectionStatus
    }

    var topBarStatusText: String {
        let subtitle = navigationSubtitle
        let detail = runtimeStatus.isEmpty ? subtitle : runtimeStatus
        return detail.isEmpty ? effectiveConnectionStatus : "\(effectiveConnectionStatus) · \(detail)"
    }

    var sidebarState: ChatSidebarState {
        ChatSidebarState(
            connectionStatus: effectiveConnectionStatus,
            projects: projects,
            models: selectedCLIModels,
            selectedCLI: selectedCLI,
            selectedModelID: selectedModelID,
            selectedModelTitle: selectedModelTitle,
            sessions: sessions,
            selectedProjectID: selectedProject?.id,
            selectedSessionID: selectedSession?.id,
            currentFilePath: currentFilePath,
            parentFilePath: parentFilePath,
            fileEntries: fileEntries,
            fileError: fileError,
            isRefreshing: isRefreshing,
            isLoadingMessages: currentSnapshot?.isLoadingHistory ?? false,
            isLoadingFiles: isLoadingFiles,
            hasSelectedProject: selectedProject != nil
        )
    }

    var isWaitingForInitialSnapshot: Bool { currentSnapshot == nil && effectiveConnectionStatus == "已连接" && selectedProject != nil }

    // 兼容旧 view 字段
    var hasMoreMessages: Bool {
        guard let sessionId = selectedSession?.id else { return false }
        return recoveredMessagePageStateBySessionId[sessionId]?.hasMore ?? false
    }
    var isLoadingOlderMessages: Bool {
        guard let sessionId = selectedSession?.id else { return false }
        return loadingOlderMessageSessionIds.contains(sessionId)
    }
    var olderMessagesAnchorID: UUID? {
        get { nil }
        set { _ = newValue }
    }
    var isLoadingMessages: Bool { currentSnapshot?.isLoadingHistory ?? isWaitingForInitialSnapshot }

    func loadOlderMessagesIfNeeded() async {
        guard let sessionId = selectedSession?.id,
              recoveredMessagePageStateBySessionId[sessionId]?.hasMore == true else { return }
        await loadRecoveredMessages(sessionId: sessionId, expectedProjectId: currentExpectedProjectId, prependOlder: true)
    }

    func requestScrollToBottom() {
        scrollToBottomRequestID = UUID()
    }

    func isToolGroupExpanded(_ id: UUID) -> Bool {
        expandedToolGroupIDs.contains(id)
    }

    func toggleToolGroup(_ id: UUID) {
        if expandedToolGroupIDs.contains(id) {
            expandedToolGroupIDs.remove(id)
        } else {
            expandedToolGroupIDs.insert(id)
        }
    }

    // MARK: - Command sending & ack queue

    private func sendCommand(_ command: Command) {
        // 入队幂等表
        let pending = PendingCommand(command: command, enqueuedAt: Date())
        pendingCommands.append((id: command.commandId, value: pending))
        if pendingCommands.count > pendingCommandLimit {
            pendingCommands.removeFirst(pendingCommands.count - pendingCommandLimit)
        }
        // Audit B-P1-5: control-plane ops (stop / respondPermission /
        // respondInteractive / cancelQueued / flushQueue) must NOT sit
        // behind the FIFO sendChain — otherwise pressing "stop" while three
        // sends are still queued takes hundreds of ms to take effect.
        // Fire-and-forget them on an independent Task so they jump ahead.
        // Order-sensitive ops (composer*, newDraftSession, focusSession,
        // requestSnapshot, refreshCapabilities) still go through sendChain
        // so `composerSet -> composerSend` ordering is preserved.
        if Self.isControlPlaneOp(command.op) {
            Task { [weak self] in
                guard let self else { return }
                guard let transport = self.remoteTransport else {
                    await MainActor.run {
                        self.appendDebug("send control op \(command.op.rawValue) skipped: transport not ready")
                    }
                    return
                }
                do {
                    try await transport.sendCommand(command)
                } catch {
                    await MainActor.run {
                        self.appendDebug("send control op \(command.op.rawValue) failed: \(error.localizedDescription)")
                    }
                }
            }
            return
        }
        // FIFO via task chain — see `sendChain` doc. Independent `Task` per
        // command would race and break `composerSet → composerSend` ordering.
        let previous = sendChain
        sendChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard let transport = self.remoteTransport else {
                self.appendDebug("send command \(command.op.rawValue) skipped: transport not ready")
                return
            }
            do {
                try await transport.sendCommand(command)
            } catch {
                self.appendDebug("send command \(command.op.rawValue) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func isControlPlaneOp(_ op: Command.Op) -> Bool {
        switch op {
        case .stop, .respondPermission, .respondInteractive, .cancelQueued, .flushQueue, .interruptAndStartNext:
            return true
        default:
            return false
        }
    }

    private func handleAck(_ ack: CommandAck) {
        // Audit C-01: lookup the original pending entry BEFORE removing it
        // from the queue. The previous order removed first and then looked
        // up by id, which always returned nil — so the `newDraftSession ->
        // auto focusSession` path never triggered and tapping "新对话"
        // appeared broken to the user.
        let pendingEntry = pendingCommandsByIdLookup(id: ack.commandId)
        if let idx = pendingCommands.firstIndex(where: { $0.id == ack.commandId }) {
            pendingCommands.remove(at: idx)
        }
        if let entry = pendingEntry {
            switch ack.status {
            case .ok:
                switch entry.command.op {
                case .newDraftSession:
                    if let sessionId = ack.sessionId {
                        setPendingFocusedSessionId(sessionId)
                    } else {
                        focusedSessionId = nil
                        clearPendingFocusedSessionId()
                    }
                case .composerSend:
                    if let sessionId = ack.sessionId {
                        setPendingFocusedSessionId(sessionId)
                    }
                case .focusSession:
                    if let sessionId = ack.sessionId ?? entry.command.args.sessionId ?? entry.command.sessionId {
                        setPendingFocusedSessionId(sessionId)
                    }
                case .focusProject:
                    if let sessionId = ack.sessionId {
                        setPendingFocusedSessionId(sessionId)
                    } else {
                        focusedSessionId = nil
                        clearPendingFocusedSessionId()
                    }
                default:
                    break
                }
            case .error, .rejected:
                switch entry.command.op {
                case .focusProject:
                    clearPendingProjectFocusId()
                case .focusSession, .newDraftSession:
                    clearPendingFocusedSessionId()
                default:
                    break
                }
            }
        }
        if ack.status == .error || ack.status == .rejected {
            if let msg = ack.message, !msg.isEmpty {
                lastError = msg
            }
        }
    }

    private func pendingCommandsByIdLookup(id: UUID) -> PendingCommand? {
        pendingCommands.first(where: { $0.id == id })?.value
    }

    private func sendRefreshSnapshotRequest(reason: String, sessionIdOverride: UUID?? = nil) {
        let targetSessionId = sessionIdOverride ?? focusedSessionId
        let command = Command(op: .requestSnapshot, sessionId: targetSessionId)
        appendDebug("refresh requestSnapshot queued reason=\(reason) command=\(command.commandId) session=\(targetSessionId?.uuidString ?? "draft")")
        sendCommand(command)
    }

    private func clearPendingProjectFocusId() {
        pendingProjectFocusTimeoutTask?.cancel()
        pendingProjectFocusTimeoutTask = nil
        pendingProjectFocusId = nil
    }

    private func schedulePendingProjectFocusTimeout(projectId: UUID) {
        pendingProjectFocusTimeoutTask?.cancel()
        pendingProjectFocusTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingFocusTimeoutNanoseconds)
            guard let self, !Task.isCancelled, self.pendingProjectFocusId == projectId else { return }
            // 不再把"切项目超时"作为 lastError 弹给用户 —— 后台已自动重发 requestSnapshot，
            // 用户看一闪而过的红字只会困惑。debugLog 留底即可。
            self.appendDebug("focusProject timeout (will resync via requestSnapshot)")
            self.clearPendingProjectFocusId()
            self.sendRefreshSnapshotRequest(reason: "focusProject timeout", sessionIdOverride: .some(nil))
        }
    }

    private func ensurePendingProjectFocusTimeout(projectId: UUID) {
        guard pendingProjectFocusTimeoutTask == nil else { return }
        schedulePendingProjectFocusTimeout(projectId: projectId)
    }

    private func setPendingFocusedSessionId(_ sessionId: UUID) {
        pendingFocusedSessionId = sessionId
        schedulePendingFocusedSessionTimeout(sessionId: sessionId)
    }

    private func clearPendingFocusedSessionId() {
        pendingFocusedSessionTimeoutTask?.cancel()
        pendingFocusedSessionTimeoutTask = nil
        pendingFocusedSessionId = nil
    }

    private func schedulePendingFocusedSessionTimeout(sessionId: UUID) {
        pendingFocusedSessionTimeoutTask?.cancel()
        pendingFocusedSessionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingFocusTimeoutNanoseconds)
            guard let self, !Task.isCancelled, self.pendingFocusedSessionId == sessionId else { return }
            // 同 focusProject：自动重发 requestSnapshot，不再弹红字。
            self.appendDebug("focusSession timeout sid=\(sessionId.uuidString) (will resync via requestSnapshot)")
            self.clearPendingFocusedSessionId()
            self.sendRefreshSnapshotRequest(reason: "focusSession timeout", sessionIdOverride: .some(sessionId))
        }
    }

    private func waitForPanelState(after baselineSequence: Int, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while panelStateEnvelopeSequence <= baselineSequence {
            if Task.isCancelled { return false }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// 重连后重发未 ack 的命令。
    private func replayPendingCommands() {
        let snapshot = pendingCommands
        Task { [weak self] in
            guard let self else { return }
            for entry in snapshot {
                guard let transport = self.remoteTransport else {
                    self.appendDebug("replay command \(entry.value.command.op.rawValue) skipped: transport not ready")
                    return
                }
                do {
                    try await transport.sendCommand(entry.value.command)
                } catch {
                    self.appendDebug("replay command \(entry.value.command.op.rawValue) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - WS handling

    @discardableResult
    private func ensureWebSocketConnected(reason: String, force: Bool = false) -> Bool {
        if force {
            appendDebug("WS force reconnect: \(reason)")
            webSocketGeneration += 1
            disconnectCurrentTransport()
        } else if remoteTransport?.isConnected == true {
            appendDebug("WS connect skipped: already connected reason=\(reason)")
            return true
        } else if connectionStatus == "连接中", remoteTransport != nil {
            appendDebug("WS connect skipped: already connecting reason=\(reason)")
            return true
        }
        guard config.isComplete else { return false }
        appendDebug("WS connect: \(reason) host=\(config.macHost):\(config.port) paired=\(config.isPaired)")
        connectionStatus = "连接中"
        let generation = webSocketGeneration
        // §6：已配对主机走 RemoteWanTransport（lastGood 先行 + eps 并行竞速，
        // SPKI pin + Bearer）；LAN/WAN 同一条 wss 路径，差别只在候选地址。
        // 未配对目标保留原单地址实现——连不上属预期，UI 会引导先配对。
        let client: RemoteTransport
        if config.isPaired {
            let wan = RemoteWanTransport(config: config)
            wan.onEndpointSelected = { [weak self] endpoint in
                self?.adoptSelectedEndpoint(endpoint)
            }
            client = wan
        } else {
            client = RemoteWebSocketClient(config: config, session: httpSession())
        }
        return startTransport(client, generation: generation)
    }

    @discardableResult
    private func startTransport(_ client: RemoteTransport, generation: Int) -> Bool {
        remoteTransport = client
        wireTransportCallbacks(client, generation: generation)
        if client.isConnected {
            client.onConnect?()
            return true
        }
        do {
            try client.connect()
        } catch {
            appendDebug("WS connect failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            refreshRequestSnapshotAfterConnect = false
            connectionStatus = "连接失败"
            return false
        }
        return true
    }

    private func wireTransportCallbacks(_ client: RemoteTransport, generation: Int) {
        client.onConnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.connectionStatus = "已连接"
                self.reconnectAttempt = 0
                _ = await self.loadRecoveredCatalog(reason: "lan connect")
                let resumeSessionID = self.focusedSessionId
                if let resumeSessionID {
                    let lastRev = self.mirror.currentRevision(for: resumeSessionID)
                    do {
                        try await client.sendResume(sessionId: resumeSessionID, lastRevision: lastRev)
                    } catch {
                        self.appendDebug("resume failed: \(error.localizedDescription)")
                    }
                } else if let projectId = self.pendingProjectFocusId ?? self._localSelectedProjectId {
                    self.pendingProjectFocusId = projectId
                    self.sendCommand(Command(op: .focusProject, args: CommandArgs(projectId: projectId)))
                    let shouldAutoOpenLatest = self.focusedSessionId == nil
                    Task { @MainActor [weak self] in
                        await self?.loadRecoveredSessions(for: projectId, autoOpenLatest: shouldAutoOpenLatest)
                    }
                } else {
                    do {
                        try await client.sendResume(sessionId: nil, lastRevision: nil)
                    } catch {
                        self.appendDebug("bootstrap resume failed: \(error.localizedDescription)")
                    }
                }
                self.replayPendingCommands()
                self.sendRefreshSnapshotRequest(reason: "remote transport open")
                if self.refreshRequestSnapshotAfterConnect {
                    self.refreshRequestSnapshotAfterConnect = false
                    self.sendRefreshSnapshotRequest(reason: "refresh reconnect")
                }
            }
        }
        client.onEnvelope = { [weak self] envelope in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.handleEnvelope(envelope)
            }
        }
        client.onAck = { [weak self] ack in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.handleAck(ack)
            }
        }
        client.onRecoveryResponse = { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.handleRecoveryResponse(response)
            }
        }
        client.onDecodeFailure = { [weak self] preview in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.appendDebug("WS decode failed: \(preview)")
            }
        }
        client.onDisconnect = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isActiveTransport(client, generation: generation) else { return }
                self.connectionStatus = "未连接"
                self.failPendingRecoveryRequests(message: L10n.string("远程连接已断开，请重新连接。"))
                if let error {
                    self.appendDebug("WS disconnected: \(error.localizedDescription)")
                    // 需要用户动作的失败（§6）：地址失效引导重配对/回 LAN，
                    // 鉴权失败与证书轮换引导重新配对；未配对配置给配对指引。
                    // 其余瞬断交给自动重连，不打扰用户。
                    if let remoteError = error as? RemoteChatError {
                        switch remoteError {
                        case .unauthorized, .certificateMismatch, .endpointsStale:
                            self.lastError = remoteError.localizedDescription
                        default:
                            break
                        }
                    } else if !self.config.isPaired {
                        self.lastError = L10n.string("该设备尚未配对，请返回设备列表扫码或输入连接串完成配对。")
                    }
                }
                self.scheduleReconnect(generation: generation)
            }
        }
    }

    /// WAN 竞速胜出后把 config 的主目标对齐到实际可用地址——/files、
    /// /attachments 等 HTTP 调用跟随同一 endpoint，并持久化供下次启动竞速。
    private func adoptSelectedEndpoint(_ endpoint: RemoteEndpoint) {
        guard endpoint.isValid else { return }
        guard config.macHost != endpoint.a || config.port != endpoint.p else { return }
        appendDebug("WS endpoint adopted: \(endpoint.displayText)")
        config.macHost = endpoint.a
        config.port = endpoint.p
        let defaults = UserDefaults.standard
        defaults.set(endpoint.a, forKey: "remote.macHost")
        defaults.set(endpoint.p, forKey: "remote.port")
    }

    private func disconnectCurrentTransport() {
        cancelCosmeticPublish()
        remoteTransport?.disconnect()
        remoteTransport = nil
        failPendingRecoveryRequests(message: L10n.string("远程连接已断开，请重新连接。"))
    }

    private func failPendingRecoveryRequests(message: String) {
        let error = RemoteRecoveryRequestError(message: message)
        for id in Array(pendingRecoveryContinuations.keys) {
            settleRecoveryRequest(id: id, result: .failure(error))
        }
    }

    private func isActiveTransport(_ transport: RemoteTransport, generation: Int) -> Bool {
        guard webSocketGeneration == generation, let active = remoteTransport else { return false }
        return ObjectIdentifier(active as AnyObject) == ObjectIdentifier(transport as AnyObject)
    }

    private func scheduleReconnect(generation: Int) {
        // Audit A-P1: exponential backoff 1s → 2s → 4s → 8s → 16s → 30s cap.
        let attempt = reconnectAttempt
        reconnectAttempt = min(attempt + 1, 5)
        let baseSeconds: UInt64
        switch attempt {
        case 0: baseSeconds = 1
        case 1: baseSeconds = 2
        case 2: baseSeconds = 4
        case 3: baseSeconds = 8
        case 4: baseSeconds = 16
        default: baseSeconds = 30
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: baseSeconds * 1_000_000_000)
            guard let self, self.webSocketGeneration == generation else { return }
            self.ensureWebSocketConnected(reason: "auto reconnect")
        }
    }

    private func handleEnvelope(_ envelope: PanelStateEnvelope) {
        panelStateEnvelopeSequence &+= 1
        switch envelope.kind {
        case .snapshot:
            guard let snapshot = envelope.snapshot else { return }
            guard shouldAccept(snapshot) else {
                mirror.updateCatalog(snapshot: snapshot)
                adoptCatalogSnapshotIfNeeded(snapshot)
                appendDebug("ignored unfocused snapshot sid=\(snapshot.sessionId?.uuidString ?? "draft") current=\(snapshot.currentSessionId?.uuidString ?? "nil")")
                return
            }
            cancelCosmeticPublish()
            mirror.apply(snapshot: snapshot)
            adoptSnapshotIfFocused(snapshot)
        case .patch:
            guard let patch = envelope.patch else { return }
            guard shouldAccept(patch) else {
                mirror.updateCatalog(patch: patch)
                appendDebug("ignored unfocused patch sid=\(patch.sessionId?.uuidString ?? "draft") rev=\(patch.revision)")
                return
            }
            if let merged = mirror.apply(patch: patch) {
                if patch.touchesOnlyCosmeticFields {
                    scheduleCosmeticPublish(merged)
                } else {
                    cancelCosmeticPublish()
                    adoptSnapshotIfFocused(merged)
                }
            } else {
                // base 不匹配 —— 主动请求 fresh snapshot。
                appendDebug("patch base mismatch sid=\(patch.sessionId?.uuidString ?? "draft") rev=\(patch.revision); requesting snapshot")
                sendCommand(Command(op: .requestSnapshot, sessionId: patch.sessionId))
            }
        }
    }

    /// 外观 patch 的尾部发布：mirror 已合并完成，这里只决定何时让
    /// `currentSnapshot`/滚动信号真正 fire 到 UI。
    private func scheduleCosmeticPublish(_ snapshot: PanelStateSnapshot) {
        pendingCosmeticSnapshot = snapshot
        guard cosmeticPublishTask == nil else { return }
        cosmeticPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.cosmeticPublishDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.cosmeticPublishTask = nil
            guard let pending = self.pendingCosmeticSnapshot else { return }
            self.pendingCosmeticSnapshot = nil
            self.adoptSnapshotIfFocused(pending)
        }
    }

    /// 结构性变化（snapshot/非外观 patch）或上下文切换前，丢弃尚未发布
    /// 的合并快照 —— 否则一个迟到的 flush 会把切会话前的旧状态贴回来。
    private func cancelCosmeticPublish() {
        cosmeticPublishTask?.cancel()
        cosmeticPublishTask = nil
        pendingCosmeticSnapshot = nil
    }

    private func shouldAccept(_ snapshot: PanelStateSnapshot) -> Bool {
        if let pendingFocusedSessionId {
            if snapshot.currentSessionId == pendingFocusedSessionId || snapshot.sessionId == pendingFocusedSessionId {
                return true
            }
            if !snapshot.sessions.contains(where: { $0.id == pendingFocusedSessionId }) {
                appendDebug("cleared stale pending focus sid=\(pendingFocusedSessionId.uuidString)")
                clearPendingFocusedSessionId()
                return shouldAcceptBootstrapSnapshot(snapshot)
            }
            return false
        }
        if let focusedSessionId {
            if snapshot.currentSessionId == focusedSessionId || snapshot.sessionId == focusedSessionId {
                return true
            }
            if !snapshot.sessions.contains(where: { $0.id == focusedSessionId }) {
                appendDebug("cleared stale focused session sid=\(focusedSessionId.uuidString)")
                self.focusedSessionId = nil
                recoveredSelectedSessionId = nil
                persistRemoteFocus(projectId: _localSelectedProjectId, sessionId: nil)
                return shouldAcceptBootstrapSnapshot(snapshot)
            }
            return false
        }
        guard let selectedProjectId = pendingProjectFocusId ?? _localSelectedProjectId else {
            return shouldAcceptBootstrapSnapshot(snapshot)
        }
        if let currentSessionId = snapshot.currentSessionId {
            return snapshot.sessions.first(where: { $0.id == currentSessionId })?.projectId == selectedProjectId
        }
        return pendingProjectFocusId != nil && snapshot.sessionId == nil
    }

    private func shouldAcceptBootstrapSnapshot(_ snapshot: PanelStateSnapshot) -> Bool {
        !snapshot.projects.isEmpty || !snapshot.models.isEmpty || !snapshot.sessions.isEmpty || snapshot.sessionId == nil
    }

    private func adoptCatalogSnapshotIfNeeded(_ snapshot: PanelStateSnapshot) {
        guard currentSnapshot == nil, shouldAcceptBootstrapSnapshot(snapshot) else { return }
        cancelCosmeticPublish()
        currentSnapshot = snapshot
        if focusedSessionId == nil {
            focusedSessionId = snapshot.currentSessionId ?? snapshot.sessionId
            recoveredSelectedSessionId = focusedSessionId
        }
        if _localSelectedProjectId == nil || !snapshot.projects.contains(where: { $0.id == _localSelectedProjectId }) {
            if let focusedSessionId,
               let projectId = projectId(for: focusedSessionId, in: snapshot) {
                _localSelectedProjectId = projectId
            } else if let firstProjectId = snapshot.projects.first?.id {
                _localSelectedProjectId = firstProjectId
            }
        }
        persistRemoteFocus(projectId: _localSelectedProjectId, sessionId: focusedSessionId)
        appendDebug("adopted bootstrap catalog snapshot projects=\(snapshot.projects.count) sessions=\(snapshot.sessions.count) models=\(snapshot.models.count)")
        autoLoadFilesForCurrentProjectIfNeeded()
    }

    private func shouldAccept(_ patch: PanelStatePatch) -> Bool {
        if let pendingFocusedSessionId {
            return patch.sessionId == pendingFocusedSessionId
        }
        if let focusedSessionId {
            return patch.sessionId == focusedSessionId
        }
        guard pendingProjectFocusId != nil || _localSelectedProjectId != nil else { return false }
        return patch.sessionId == nil && currentSnapshot?.sessionId == nil
    }

    private func adoptSnapshotIfFocused(_ snapshot: PanelStateSnapshot) {
        // 只采用当前聚焦 session 的 snapshot。其他 session 的 envelope 留在 mirror 缓存。
        if let pendingFocusedSessionId {
            // 1) 直接命中：snapshot 已经反映了我们想 focus 的 session。
            if snapshot.currentSessionId == pendingFocusedSessionId {
                focusedSessionId = pendingFocusedSessionId
                recoveredSelectedSessionId = pendingFocusedSessionId
                persistRemoteFocus(projectId: projectId(for: pendingFocusedSessionId, in: snapshot) ?? _localSelectedProjectId, sessionId: pendingFocusedSessionId)
                clearPendingFocusedSessionId()
            }
            // 2) Session 还在 pending，但本次 envelope 就是为这个 session 准备的（patch/snapshot
            //    的 sessionId 字段命中）—— 也认为 focus 已经到位，立刻显示内容，避免
            //    UI 空白直到 8s 超时。
            else if snapshot.sessionId == pendingFocusedSessionId {
                focusedSessionId = pendingFocusedSessionId
                recoveredSelectedSessionId = pendingFocusedSessionId
                persistRemoteFocus(projectId: projectId(for: pendingFocusedSessionId, in: snapshot) ?? _localSelectedProjectId, sessionId: pendingFocusedSessionId)
                clearPendingFocusedSessionId()
            }
            // 3) 还没到位：但 mirror 可能已经有这个 session 的 snapshot 缓存（之前的连接
            //    或 server 已经发过），先把缓存里的内容贴出来给用户看，别空白。
            else if let cached = mirror.snapshot(for: pendingFocusedSessionId) {
                currentSnapshot = cached
                bumpMessageListSignalIfChanged(messages: cached.messages)
                bumpStreamingTextSignalIfChanged(streamingTexts: cached.streamingTexts)
                return
            } else {
                return
            }
        } else if focusedSessionId == nil || focusedSessionId == snapshot.sessionId || focusedSessionId == snapshot.currentSessionId {
            if let adoptedSessionId = snapshot.currentSessionId ?? snapshot.sessionId {
                focusedSessionId = adoptedSessionId
                recoveredSelectedSessionId = adoptedSessionId
                persistRemoteFocus(projectId: projectId(for: adoptedSessionId, in: snapshot) ?? _localSelectedProjectId, sessionId: adoptedSessionId)
            }
        } else {
            return
        }

        var shouldCommitPendingProjectFocus = false
        if let pendingProjectFocusId {
            if let currentSessionId = snapshot.currentSessionId {
                shouldCommitPendingProjectFocus = snapshot.sessions.first(where: { $0.id == currentSessionId })?.projectId == pendingProjectFocusId
                if !shouldCommitPendingProjectFocus {
                    ensurePendingProjectFocusTimeout(projectId: pendingProjectFocusId)
                }
            } else {
                shouldCommitPendingProjectFocus = true
            }
        }

        currentSnapshot = snapshot
        if _localSelectedProjectId == nil {
            if let focusedSessionId,
               let projectId = projectId(for: focusedSessionId, in: snapshot) {
                _localSelectedProjectId = projectId
                persistRemoteFocus(projectId: projectId, sessionId: focusedSessionId)
            } else if let firstProjectId = snapshot.projects.first?.id {
                _localSelectedProjectId = firstProjectId
                persistRemoteFocus(projectId: firstProjectId, sessionId: focusedSessionId)
            }
        }
        if let pendingProjectFocusId, shouldCommitPendingProjectFocus {
            _localSelectedProjectId = pendingProjectFocusId
            persistRemoteFocus(projectId: pendingProjectFocusId, sessionId: focusedSessionId)
            clearPendingProjectFocusId()
            Task { [weak self] in
                await self?.loadFilesIfPossible(projectId: pendingProjectFocusId, path: "")
            }
        }
        bumpMessageListSignalIfChanged(messages: snapshot.messages)
        bumpStreamingTextSignalIfChanged(streamingTexts: snapshot.streamingTexts)
        // 收到 snapshot 后，如果用户还没看到任何文件,自动用当前选中的项目
        // (snapshot 推导出来或第一个项目)拉一次根目录。节流避免重复请求。
        autoLoadFilesForCurrentProjectIfNeeded()
    }

    private func projectId(for sessionId: UUID, in snapshot: PanelStateSnapshot) -> UUID? {
        snapshot.sessions.first(where: { $0.id == sessionId })?.projectId
    }

    private func persistRemoteFocus(projectId: UUID?, sessionId: UUID?) {
        let defaults = UserDefaults.standard
        if let projectId {
            defaults.set(projectId.uuidString, forKey: Self.persistedProjectFocusKey)
        } else {
            defaults.removeObject(forKey: Self.persistedProjectFocusKey)
        }
        if let sessionId {
            defaults.set(sessionId.uuidString, forKey: Self.persistedSessionFocusKey)
        } else {
            defaults.removeObject(forKey: Self.persistedSessionFocusKey)
        }
    }

    private func bumpMessageListSignalIfChanged(messages: [ChatMessage]) {
        let lastID = messages.last?.id
        if messages.count != lastMessageArrayCount || lastID != lastMessageLastID {
            messageListRevision &+= 1
            lastMessageArrayCount = messages.count
            lastMessageLastID = lastID
            messageListUpdateSignal = MessageListUpdateSignal(
                revision: messageListRevision,
                count: messages.count,
                lastMessageID: lastID
            )
        }
    }

    private func bumpStreamingTextSignalIfChanged(streamingTexts: [PanelStreamingTextDTO]) {
        let signature = streamingTexts
            .sorted { $0.messageId.uuidString < $1.messageId.uuidString }
            .map { "\($0.messageId.uuidString):\($0.text.count):\($0.text.hashValue):\($0.status):\($0.requestId ?? "")" }
            .joined(separator: "|")
        guard signature != lastStreamingTextSignature else { return }
        streamingTextRevision &+= 1
        lastStreamingTextSignature = signature
        streamingTextUpdateSignal = StreamingTextUpdateSignal(
            revision: streamingTextRevision,
            totalTextLength: streamingTexts.reduce(0) { $0 + $1.text.count }
        )
    }

    private func isActiveStatus(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw {
        case "starting", "streaming", "waitingPermission", "waitingInput", "stopping":
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private func makeHTTPClient() -> RemoteHTTPClient {
        RemoteHTTPClient(config: config, session: httpSession()) { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendDebug(message)
            }
        }
    }

    /// 已配对主机的 HTTP（/connect_info 之外的 /files、/attachments 等）必须走
    /// SPKI-pin session（§4.2/§4.3）。按 certFP 缓存复用，避免每次请求新建
    /// URLSession（不 invalidate 会泄漏 delegate）。
    private var cachedHTTPSession: (fp: String, session: URLSession)?
    private func httpSession() -> URLSession {
        guard let fp = config.certFP, !RemoteWanCredentials.normalizeFP(fp).isEmpty else {
            return .shared
        }
        if let cached = cachedHTTPSession, cached.fp == fp {
            return cached.session
        }
        cachedHTTPSession?.session.invalidateAndCancel()
        let (session, _) = RemoteSecureSessionFactory.pinnedSession(certFP: fp)
        cachedHTTPSession = (fp, session)
        return session
    }

    private func appendDebug(_ line: String) {
#if DEBUG
        print("[CodevokeRemote] \(line)")
#endif
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private extension PanelStatePatch {
    /// 仅外观字段变化的 patch 允许合并发布；任何结构性字段（消息列表、
    /// 会话/项目目录、composer、运行状态机、权限/交互卡片等）一旦出现
    /// 必须立即发布，保证交互正确性和状态翻转的及时性。
    /// 允许延迟的字段：streamingTexts / statusText / isAwaitingFirstModelOutput
    /// / tokensUsed / tokensTotal —— 全部只影响渲染外观。
    var touchesOnlyCosmeticFields: Bool {
        projects == nil && models == nil && sessions == nil
            && currentSessionId == nil && messages == nil && queuedRequests == nil
            && status == nil && isLoadingHistory == nil
            && activeRunStartedAt == nil && isMirroringRemoteSession == nil
            && composer == nil && capabilities == nil
    }
}
