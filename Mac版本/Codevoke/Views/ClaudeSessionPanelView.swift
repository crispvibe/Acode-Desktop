import AppKit
import Combine
import ChatUI
import SwiftUI
import UniformTypeIdentifiers

let queuedRequestDragTypeIdentifier = "com.codevoke.queued-request"
let queuedRequestPasteboardType = NSPasteboard.PasteboardType(queuedRequestDragTypeIdentifier)

extension String {
    var renderCacheFingerprint: String {
        "\(count):\(hashValue)"
    }
}

enum TranscriptUserIntent {
    case followBottom
    case reviewing
}

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var modelService: ChatModelService
    @EnvironmentObject var chatRuntimeStore: ChatRuntimeStore
    @State var draftMessage = ""
    @State var editingMessageID: UUID?
    @State var selectedModelID = ChatModelCatalog.defaultClaudeModelID
    @State var permissionMode = ChatPermissionMode.autoEdit
    @State var reasoningEffort = ChatReasoningEffort.high
    @State var activePicker: ChatPicker?
    @State var customModelInput = ""
    @State var showCopiedToast = false
    @State var showProjectHistoryPopover = false
    @State var historyToRemoveFromHeader: CLIHistorySession?
    @State var attachedPaths: [String] = []
    @State var expandedTranscriptMessageIDs: Set<UUID> = []
    @State var collapsedInlineToolIDs: Set<UUID> = []
    @State var expandedToolBatchIDs: Set<String> = []
    @State var transcriptScrollKick = UUID()
    @State var transcriptScrollTargetID: String?
    @State var composerHasMarkedText = false
    @State var composerFocusRequest = 0
    @State var suggestedCommand: ComposerSuggestedCommand?
    @State var transcriptUserIntent = TranscriptUserIntent.followBottom
    @State var isTranscriptAtBottom = true
    @State var composerTextHeight: CGFloat = 42
    @State var composerChromeHeight: CGFloat = 0
    @State var decisionOverlayContentHeight: CGFloat = 0
    @State var selectedSubagentDetail: SubagentDetailRequest?
    @State var selectedAppendRulePreview: AppendRulePreview?
    @State var loadingThinkingText = Self.thinkingPhrases[0]
    @State var activeComposerDraftKey = ""
    @State var cachedTranscriptRevision = -1
    @State var cachedTranscriptProjectKey = ""
    @State var cachedTranscriptStructureKey = ChatTranscriptStructureKey.empty
    @State var cachedTranscriptItems: [ChatTranscriptItem] = []
    @State var transcriptVisibleMessageLimit = ChatPanelState.historyInitialMessageLimit
    @State var pendingTranscriptRefreshRevision: Int?
    @State var isTranscriptRefreshScheduled = false
    @State var transcriptRefreshGeneration = 0
    @State var transcriptContentHeight: CGFloat = 0
    @State var transcriptBuildTask: Task<Void, Never>?
    @State var pendingTranscriptScrollTask: Task<Void, Never>?
    @State var pendingStreamingScrollTask: Task<Void, Never>?
    @State var nsScrollToBottomToken: Int = 0
    let transcriptInitialMessageLimit = ChatPanelState.historyInitialMessageLimit
    let transcriptMessagePageSize = ChatPanelState.historyInitialMessageLimit
    let transcriptBackgroundBuildThreshold = 120
    static let thinkingPhrases = [
        "正在思考…",
        "正在整理上下文…",
        "正在生成回答…",
        "马上开始输出…"
    ]

    let transcriptBottomID = "bottom"
    let composerMinimumTextHeight: CGFloat = 42
    let transcriptBottomTolerance: CGFloat = 4
    let chatSurfaceTint = AppTheme.chatSurfaceTint
    let composerCardTint = AppTheme.composerSurfaceTint

    var chatState: ChatPanelState {
        chatRuntimeStore.state(
            for: appState,
            modelID: selectedModelID,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.28)

                transcript

                composer
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ComposerChromeHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
            }
            .onPreferenceChange(ComposerChromeHeightPreferenceKey.self) { height in
                guard abs(composerChromeHeight - height) > 0.5 else { return }
                composerChromeHeight = height
            }

            if showCopiedToast {
                Text("复制成功")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.82))
                    .clipShape(Capsule())
                    .transition(.opacity)
                    .zIndex(900)
            }

            if let activePicker {
                globalPickerLayer(activePicker)
                    .zIndex(1_000)
            }

            agentRunningOverlay()
                .zIndex(950)

            pendingDecisionOverlay()
                .zIndex(980)
        }
        .background(chatPanelSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .onAppear {
            applyPersistedChatSelection()
            syncSelectedContextWindow()
            activateComposerDraftKey(composerDraftKey)
            refreshTranscriptItems()
        }
        .onChange(of: composerDraftKey) { oldKey, newKey in
            switchComposerDraft(from: oldKey, to: newKey)
        }
        .onChange(of: draftMessage) { _, newValue in
            persistComposerDraft(newValue)
        }
        .onChange(of: appState.chatConversationSerial) { _, _ in
            applyPersistedChatSelection()
            normalizeReasoningEffort()
            syncSelectedContextWindow()
            clearSuggestedCommand()
            attachedPaths.removeAll()
        }
        .onChange(of: appState.selectedCLI) { _, _ in
            selectedModelID = persistedModelID(for: appState.selectedCLI)
            normalizeSelectedModel()
            reasoningEffort = persistedReasoningEffort(for: appState.selectedCLI)
            normalizeReasoningEffort()
            syncSelectedContextWindow()
            persistChatSelection()
            attachedPaths.removeAll()
            transcriptUserIntent = .followBottom
            isTranscriptAtBottom = true
            activePicker = nil
        }
        .onChange(of: selectedModelID) { _, _ in
            normalizeReasoningEffort()
            syncSelectedContextWindow()
            persistChatSelection()
        }
        .onReceive(chatState.$structureRevision) { revision in
            scheduleTranscriptRefresh(revision: revision)
        }
        .onChange(of: appState.selectedProject?.path) { _, _ in
            attachedPaths.removeAll()
            showProjectHistoryPopover = false
        }
        .alert("删除历史会话？", isPresented: Binding(
            get: { historyToRemoveFromHeader != nil },
            set: { if !$0 { historyToRemoveFromHeader = nil } }
        )) {
            Button("取消", role: .cancel) { historyToRemoveFromHeader = nil }
            Button("删除", role: .destructive) {
                let session = historyToRemoveFromHeader
                historyToRemoveFromHeader = nil
                if let session {
                    chatRuntimeStore.removeRuntime(for: session, discardingState: appState.selectedCLIHistoryID == session.id)
                    appState.deleteCLIHistory(session)
                }
            }
        } message: {
            let activity = historyToRemoveFromHeader.flatMap { chatRuntimeStore.activity(for: $0) }
            if let activity, activity.status.isRunning {
                Text("该会话仍在运行，删除后会停止后台任务并移除本地历史。")
            } else {
                Text("会从本地 CLI 历史中删除“\(historyToRemoveFromHeader?.title ?? "该会话")”。")
            }
        }
        .sheet(item: $selectedSubagentDetail) { request in
            SubagentTranscriptSheet(request: request)
        }
        .sheet(item: $selectedAppendRulePreview) { preview in
            AppendRulePreviewSheet(text: preview.text)
        }
        .task(id: chatState.isAwaitingFirstModelOutput) {
            guard chatState.isAwaitingFirstModelOutput else { return }
            cycleThinkingPhrase()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                cycleThinkingPhrase()
            }
        }
    }

    var chatPanelSurface: some View {
        ZStack {
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .opacity(0.86)
            chatSurfaceTint
        }
    }

    var composerCardSurface: some View {
        ZStack {
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .opacity(0.72)
            composerCardTint
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            appIdentity

            projectHistoryButton

            Spacer(minLength: 10)

            terminalFallbackActions

            Button(action: startNewChat) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("新对话")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Color.primary.opacity(0.055))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(appState.selectedProject == nil)
            .opacity(appState.selectedProject == nil ? 0.45 : 1)
            .help("新建对话")
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 2)
        .background(WindowDraggableArea())
    }

    var projectHistoryButton: some View {
        Button {
            showProjectHistoryPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.78))
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.selectedProject == nil && appState.selectedHistoryProjectPath == nil)
        .opacity(appState.selectedProject == nil && appState.selectedHistoryProjectPath == nil ? 0.55 : 1)
        .help("显示会话历史")
        .popover(isPresented: $showProjectHistoryPopover, arrowEdge: .top) {
            projectHistoryCard
        }
    }

    var projectHistoryCard: some View {
        let sessions = currentProjectHistorySessions
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("会话历史记录")
                        .font(.system(size: 13, weight: .semibold))
                    Text(projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    showProjectHistoryPopover = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("关闭")
            }

            Text(projectPath)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Divider().opacity(0.24)

            if sessions.isEmpty {
                Text("暂无历史会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(sessions) { session in
                            projectHistorySessionRow(session)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    func projectHistorySessionRow(_ session: CLIHistorySession) -> some View {
        let activity = session.isDraft ? nil : chatRuntimeStore.activity(for: session)
        let isSelected = session.isDraft
            ? (appState.selectedMode == .newSession && appState.selectedCLIHistoryID == nil)
            : appState.selectedCLIHistoryID == session.id
        return HStack(spacing: 0) {
            Button {
                if session.isDraft {
                    startNewChat()
                } else {
                    appState.selectCLIHistory(session)
                }
                showProjectHistoryPopover = false
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    if session.isDraft {
                        Text("尚未开始 · 草稿")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !session.relativeUpdatedText.isEmpty {
                        Text("\(session.sourceLabel) · \(session.relativeUpdatedText)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            if let activity {
                sessionActivityIndicator(activity)
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
            }

            if !session.isDraft {
                Button {
                    historyToRemoveFromHeader = session
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("删除历史会话")
            }
        }
        .padding(.trailing, 4)
        .background(isSelected ? AppTheme.selectedSurface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    func sessionActivityIndicator(_ activity: ChatSessionActivity) -> some View {
        if activity.status.isRunning {
            ProgressView()
                .scaleEffect(0.45)
                .frame(width: 18, height: 18)
                .help(activity.statusText.isEmpty ? "运行中" : activity.statusText)
        } else {
            Circle()
                .fill(activityIndicatorColor(for: activity))
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
                .help(activityIndicatorHelp(for: activity))
        }
    }

    func activityIndicatorColor(for activity: ChatSessionActivity) -> Color {
        switch activity.status {
        case .completed:
            return .green
        case .failed, .unsupportedVersion:
            return .red
        case .waitingPermission, .waitingInput:
            return .orange
        case .idle:
            return activity.queuedCount > 0 ? .blue : .secondary.opacity(0.45)
        case .starting, .streaming, .stopping:
            return .blue
        }
    }

    func activityIndicatorHelp(for activity: ChatSessionActivity) -> String {
        if !activity.statusText.isEmpty { return activity.statusText }
        switch activity.status {
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .unsupportedVersion:
            return "CLI 版本不支持"
        case .waitingPermission:
            return "等待权限确认"
        case .waitingInput:
            return "等待输入"
        case .idle:
            return activity.queuedCount > 0 ? "队列中有 \(activity.queuedCount) 条消息" : "就绪"
        case .starting, .streaming:
            return "运行中"
        case .stopping:
            return "正在停止"
        }
    }

    var terminalFallbackActions: some View {
        HStack(spacing: 4) {
            Button(action: openCommandInTerminal) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(CircularIconButtonStyle(size: 30, background: Color.primary.opacity(0.055)))
            .foregroundStyle(.secondary)
            .disabled(appState.selectedProject == nil && appState.selectedHistoryProjectPath == nil)
            .help("在终端中打开 Claude（cd 项目 + 完全权限）")
        }
    }

    var appIdentity: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(appDisplayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .layoutPriority(1)
    }

    var appIconImage: NSImage {
        Self.cachedAppIconImage
    }

    static let cachedAppIconImage: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }()

    var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "acode"
    }

    var transcript: some View {
        let items = windowedTranscriptItems
        let lastVisibleMessageID = lastVisibleTranscriptMessageID(in: items)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    transcriptContent(items: items, lastVisibleMessageID: lastVisibleMessageID)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 24)
                        .id(transcriptBottomID)
                }
                .background(transcriptHeightReader)
                .background(
                    TranscriptScrollObserver(
                        onBottomStateChanged: { isAtBottom in
                            isTranscriptAtBottom = isAtBottom
                        },
                        onNearTop: {
                            loadEarlierTranscriptIfNeeded()
                        },
                        onUserScroll: {
                            transcriptUserIntent = .reviewing
                            cancelPendingTranscriptBottomScrolls()
                        },
                        shouldFollowBottom: transcriptUserIntent == .followBottom,
                        scrollToBottomToken: nsScrollToBottomToken
                    )
                )
            }
            .scrollIndicators(.automatic)
            .background(Color.clear)
            .background(NonWindowDraggableArea())
            .overlay(alignment: .center) {
                if chatState.isLoadingHistory {
                    historyLoadingOverlay
                }
            }
            .overlay(alignment: .bottomTrailing) {
                backToLatestButton()
            }
            .onAppear {
                refreshTranscriptItems()
                scrollTranscriptToBottom(proxy, animated: false)
                requestNSScrollToBottom()
            }
            .onChange(of: appState.chatConversationSerial) { _, _ in
                transcriptVisibleMessageLimit = transcriptInitialMessageLimit
                transcriptUserIntent = .followBottom
                isTranscriptAtBottom = true
                refreshTranscriptItems(force: true)
                scrollTranscriptToBottom(proxy, animated: false)
                requestNSScrollToBottom()
            }
            .onChange(of: cachedTranscriptItems.count) { _, _ in
                scrollTranscriptIfFollowing(proxy, animated: false)
                scrollTranscriptToPendingTarget(proxy)
            }
            .onChange(of: cachedTranscriptItems.last?.id) { _, _ in
                scrollTranscriptIfFollowing(proxy, animated: false)
            }
            .onPreferenceChange(TranscriptContentHeightPreferenceKey.self) { height in
                guard abs(transcriptContentHeight - height) > 0.5 else { return }
                // Height is an OUTPUT of scrolling: a LazyVStack realizes/de-realizes rows as
                // we scroll, so its measured height keeps changing. Driving a scroll from it
                // creates a feedback loop that juts the transcript up and down (worst on long
                // history and while tall edit-diff cards materialize). Record the height only —
                // scrolling is driven by discrete content changes and streaming deltas.
                transcriptContentHeight = height
            }
            .onChange(of: composerChromeHeight) { oldHeight, newHeight in
                guard oldHeight > 0 else { return }
                guard abs(oldHeight - newHeight) > 0.5 else { return }
                scheduleLayoutScrollIfFollowing(proxy)
            }
            .onReceive(chatState.streamingTextStore.$entries.map { _ in () }) { _ in
                scheduleTranscriptRefresh(revision: chatState.structureRevision)
                scheduleStreamingScrollIfFollowing(proxy)
            }
            .onChange(of: transcriptScrollKick) { _, _ in
                scrollTranscriptToBottom(proxy, animated: false)
                requestNSScrollToBottom()
            }
            .onChange(of: transcriptScrollTargetID) { _, _ in
                scrollTranscriptToPendingTarget(proxy)
            }
        }
    }

    var transcriptHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TranscriptContentHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    @ViewBuilder
    func transcriptContent(items: [ChatTranscriptItem], lastVisibleMessageID: UUID?) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if appState.selectedProject == nil {
                emptyProjectState
            } else if items.isEmpty && chatState.currentSessionID == nil && !chatState.isLoadingHistory && chatState.messages.isEmpty && chatState.status == .idle {
                emptyChatState
            } else if items.isEmpty {
                transcriptUnavailableState
            } else {
                if hiddenTranscriptMessageCount > 0 {
                    loadEarlierTranscriptButton(hiddenCount: hiddenTranscriptMessageCount)
                }
                ForEach(items) { item in
                    transcriptRow(item, lastVisibleMessageID: lastVisibleMessageID)
                        .equatable()
                        .id(item.id)
                }
            }
        }
    }

    func transcriptRow(_ item: ChatTranscriptItem, lastVisibleMessageID: UUID?) -> EquatableTranscriptItemRow {
        EquatableTranscriptItemRow(
            item: item,
            expandedMessageIDs: expandedTranscriptMessageIDs,
            collapsedInlineToolIDs: collapsedInlineToolIDs,
            expandedToolBatchIDs: expandedToolBatchIDs,
            isRunning: chatState.status.isRunning,
            lastVisibleMessageID: lastVisibleMessageID,
            loadingText: loadingThinkingText,
            content: { AnyView(transcriptItemRow($0, lastVisibleMessageID: lastVisibleMessageID)) }
        )
    }

    var windowedTranscriptItems: [ChatTranscriptItem] {
        cachedTranscriptItems
    }

    var visibleTranscriptMessages: [ChatMessage] {
        guard chatState.messages.count > transcriptVisibleMessageLimit else { return chatState.messages }
        return Array(chatState.messages.suffix(transcriptVisibleMessageLimit))
    }

    var hiddenTranscriptMessageCount: Int {
        loadedHiddenTranscriptMessageCount + chatState.unloadedEarlierMessageCount
    }

    var loadedHiddenTranscriptMessageCount: Int {
        max(0, chatState.messages.count - transcriptVisibleMessageLimit)
    }

    func lastVisibleTranscriptMessageID(in items: [ChatTranscriptItem]) -> UUID? {
        items.reversed().compactMap(\.lastMessageID).first
    }

    struct TranscriptBuildSnapshot {
        let messages: [ChatMessage]
        let isAwaitingFirstModelOutput: Bool
        let isLoadingHistory: Bool
        let hasProject: Bool
        let streamingTexts: [UUID: String]
    }

    func scheduleTranscriptRefresh(revision: Int) {
        pendingTranscriptRefreshRevision = revision
        guard !isTranscriptRefreshScheduled else { return }
        isTranscriptRefreshScheduled = true
        DispatchQueue.main.async {
            isTranscriptRefreshScheduled = false
            let revision: Int
            if let pendingRevision = pendingTranscriptRefreshRevision {
                revision = pendingRevision
            } else {
                revision = chatState.structureRevision
            }
            pendingTranscriptRefreshRevision = nil
            refreshTranscriptItems(revision: revision)
        }
    }

    func refreshTranscriptItems(revision receivedRevision: Int? = nil, force: Bool = false) {
        let revision = receivedRevision ?? chatState.structureRevision
        let projectKey = appState.selectedProject?.path ?? appState.selectedHistoryProjectPath ?? ""
        let structureKey = transcriptStructureKey(projectKey: projectKey)
        guard force || cachedTranscriptRevision != revision || cachedTranscriptProjectKey != projectKey || cachedTranscriptStructureKey != structureKey else { return }

        let shouldRebuild = force || cachedTranscriptProjectKey != projectKey || cachedTranscriptStructureKey != structureKey
        let snapshot = transcriptBuildSnapshot()
        // Force inline build when:
        //   * the caller explicitly asks (session switch / project change), OR
        //   * the transcript structure/project changed, so stale rows should not stay on screen, OR
        //   * the visible items are currently empty but the underlying messages aren't —
        //     this is the post-load transition where the user otherwise sees a transient
        //     blank panel during the background build.
        let shouldForceInline = force
            || shouldRebuild
            || (cachedTranscriptItems.isEmpty && !snapshot.messages.isEmpty)
        if !shouldForceInline && snapshot.messages.count > transcriptBackgroundBuildThreshold {
            transcriptRefreshGeneration &+= 1
            let generation = transcriptRefreshGeneration
            let currentItems = cachedTranscriptItems
            transcriptBuildTask?.cancel()
            transcriptBuildTask = Task {
                let nextItems = await Task.detached(priority: .userInitiated) {
                    shouldRebuild
                        ? Self.buildTranscriptItems(snapshot: snapshot)
                        : Self.refreshedTranscriptItems(currentItems, snapshot: snapshot)
                }.value
                await MainActor.run {
                    guard generation == transcriptRefreshGeneration, !Task.isCancelled else { return }
                    cachedTranscriptItems = nextItems
                    cachedTranscriptStructureKey = structureKey
                    cachedTranscriptRevision = revision
                    cachedTranscriptProjectKey = projectKey
                    transcriptBuildTask = nil
                }
            }
            return
        }

        transcriptRefreshGeneration &+= 1
        transcriptBuildTask?.cancel()
        transcriptBuildTask = nil
        cachedTranscriptItems = shouldRebuild
            ? Self.buildTranscriptItems(snapshot: snapshot)
            : Self.refreshedTranscriptItems(cachedTranscriptItems, snapshot: snapshot)
        cachedTranscriptStructureKey = structureKey
        cachedTranscriptRevision = revision
        cachedTranscriptProjectKey = projectKey
    }

    func transcriptBuildSnapshot() -> TranscriptBuildSnapshot {
        let messages = visibleTranscriptMessages
        let streamingTexts = Dictionary(uniqueKeysWithValues: messages.compactMap { message -> (UUID, String)? in
            guard message.isStreaming, let text = chatState.streamingTextStore.text(for: message.id) else { return nil }
            return (message.id, text)
        })
        return TranscriptBuildSnapshot(
            messages: messages,
            isAwaitingFirstModelOutput: chatState.isAwaitingFirstModelOutput,
            isLoadingHistory: chatState.isLoadingHistory,
            hasProject: appState.selectedProject != nil,
            streamingTexts: streamingTexts
        )
    }

    func transcriptStructureKey(projectKey: String) -> ChatTranscriptStructureKey {
        ChatTranscriptStructureKey(
            projectKey: projectKey,
            isLoading: chatState.isAwaitingFirstModelOutput,
            messages: visibleTranscriptMessages.compactMap { message in
                guard shouldShowInTranscript(message) else { return nil }
                let streamingTextLength = message.isStreaming
                    ? chatState.streamingTextStore.text(for: message.id)?.utf8.count ?? 0
                    : 0
                return ChatTranscriptStructureKey.MessageFingerprint(
                    id: message.id,
                    kind: message.kind,
                    isStreaming: message.isStreaming,
                    streamingTextLength: streamingTextLength,
                    title: message.title,
                    subtitle: message.subtitle,
                    status: message.status,
                    requestID: message.requestID,
                    attachmentsSignature: chatAttachmentSignature(message.attachments)
                )
            }
        )
    }

    func refreshedTranscriptItems(_ items: [ChatTranscriptItem]) -> [ChatTranscriptItem] {
        Self.refreshedTranscriptItems(items, snapshot: transcriptBuildSnapshot())
    }

    nonisolated private static func refreshedTranscriptItems(_ items: [ChatTranscriptItem], snapshot: TranscriptBuildSnapshot) -> [ChatTranscriptItem] {
        let messagesByID = Dictionary(uniqueKeysWithValues: snapshot.messages.map { ($0.id, $0) })
        return items.compactMap { item in
            switch item {
            case .message(let message):
                return messagesByID[message.id].map(ChatTranscriptItem.message)
            case .toolGroup(let group):
                guard let primary = messagesByID[group.primary.id] else { return nil }
                let responses = group.responses.compactMap { messagesByID[$0.id] }
                return .toolGroup(ToolInvocationGroup(primary: primary, responses: responses))
            case .toolBatch(let batch):
                let groups = batch.groups.compactMap { group -> ToolInvocationGroup? in
                    guard let primary = messagesByID[group.primary.id] else { return nil }
                    let responses = group.responses.compactMap { messagesByID[$0.id] }
                    return ToolInvocationGroup(primary: primary, responses: responses)
                }
                return groups.isEmpty ? nil : .toolBatch(ToolBatchGroup(groups: groups))
            case .loading:
                return snapshot.isAwaitingFirstModelOutput && snapshot.hasProject ? .loading : nil
            }
        }
    }

    func buildTranscriptItems() -> [ChatTranscriptItem] {
        Self.buildTranscriptItems(snapshot: transcriptBuildSnapshot())
    }

    nonisolated private static func buildTranscriptItems(snapshot: TranscriptBuildSnapshot) -> [ChatTranscriptItem] {
        let messages = snapshot.messages
        var items: [ChatTranscriptItem] = []
        items.reserveCapacity(messages.count + 1)
        var seenErrorMessages = Set<String>()
        var groupedMessageIDs = Set<UUID>()
        for index in messages.indices {
            let message = messages[index]
            guard shouldShowInTranscript(message, snapshot: snapshot), !groupedMessageIDs.contains(message.id) else { continue }
            if message.kind == .error {
                let key = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard seenErrorMessages.insert(key).inserted else { continue }
            }
            if let group = toolInvocationGroup(startingAt: index, messages: messages, groupedMessageIDs: groupedMessageIDs, snapshot: snapshot) {
                groupedMessageIDs.formUnion(group.responses.map(\.id))
                items.append(.toolGroup(group))
            } else {
                items.append(.message(message))
            }
        }
        if snapshot.isAwaitingFirstModelOutput && snapshot.hasProject {
            items.append(.loading)
        }
        return coalesceToolBatches(items)
    }

    nonisolated private static func coalesceToolBatches(_ items: [ChatTranscriptItem]) -> [ChatTranscriptItem] {
        var result: [ChatTranscriptItem] = []
        result.reserveCapacity(items.count)
        var run: [ToolInvocationGroup] = []
        func flush() {
            if run.count >= 2 {
                result.append(.toolBatch(ToolBatchGroup(groups: run)))
            } else {
                result.append(contentsOf: run.map(ChatTranscriptItem.toolGroup))
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if case .toolGroup(let group) = item, isBatchableToolGroup(group) {
                run.append(group)
            } else {
                flush()
                result.append(item)
            }
        }
        flush()
        return result
    }

    nonisolated private static func isBatchableToolGroup(_ group: ToolInvocationGroup) -> Bool {
        ["read", "grep", "glob"].contains(group.primary.toolKindKey)
    }

    nonisolated private static func toolInvocationGroup(startingAt index: Int, messages: [ChatMessage], groupedMessageIDs: Set<UUID>, snapshot: TranscriptBuildSnapshot) -> ToolInvocationGroup? {
        let primary = messages[index]
        guard primary.isToolInvocationStart else { return nil }
        var responses: [ChatMessage] = []
        for candidate in messages.dropFirst(index + 1) {
            guard shouldShowInTranscript(candidate, snapshot: snapshot), !groupedMessageIDs.contains(candidate.id) else { continue }
            if candidate.isToolInvocationFeedback(for: primary) {
                responses.append(candidate)
                continue
            }
            if candidate.isToolInvocationBoundary || primary.toolCorrelationID == nil || !responses.isEmpty {
                break
            }
        }
        guard !responses.isEmpty else { return nil }
        return ToolInvocationGroup(primary: primary, responses: responses)
    }

    func shouldShowInTranscript(_ message: ChatMessage) -> Bool {
        let streamingText = message.isStreaming ? chatState.streamingTextStore.text(for: message.id) : nil
        return Self.shouldShowInTranscript(message, streamingText: streamingText, isAwaitingFirstModelOutput: chatState.isAwaitingFirstModelOutput)
    }

    nonisolated private static func shouldShowInTranscript(_ message: ChatMessage, snapshot: TranscriptBuildSnapshot) -> Bool {
        shouldShowInTranscript(
            message,
            streamingText: snapshot.streamingTexts[message.id],
            isAwaitingFirstModelOutput: snapshot.isAwaitingFirstModelOutput
        )
    }

    nonisolated private static func shouldShowInTranscript(_ message: ChatMessage, streamingText: String?, isAwaitingFirstModelOutput: Bool) -> Bool {
        guard !message.isBackendLaunchCommand else { return false }
        guard !message.isNoisyRawTranscriptEvent else { return false }
        guard message.kind.isVisibleInTranscript else { return false }
        switch message.kind {
        case .reasoning:
            let source = message.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard source != "codex" else { return false }
            let text = message.isStreaming ? (streamingText ?? message.text) : message.text
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasText || (message.isStreaming && !isAwaitingFirstModelOutput)
        case .assistant:
            let text = message.isStreaming ? (streamingText ?? message.text) : message.text
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasText || (message.isStreaming && !isAwaitingFirstModelOutput)
        case .error:
            return message.isStreaming || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .toolCall, .toolResult, .command, .commandOutput, .diff:
            return message.isStreaming
                || !message.title.isEmpty
                || !message.subtitle.isEmpty
                || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .result, .rawOutput:
            let text = message.isStreaming ? (streamingText ?? message.text) : message.text
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !message.isNoisyRawTranscriptEvent
        default:
            return true
        }
    }

    var emptyProjectState: some View {
        Text(appState.selectedHistoryProjectPath?.nonEmptyTrimmed == nil ? "先选择一个项目。" : "该历史会话属于未添加项目，请先添加项目目录以继续内嵌对话。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var transcriptUnavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chatState.messages.isEmpty ? "正在整理输出…" : "当前窗口内没有可直接展示的消息")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if hiddenTranscriptMessageCount > 0 {
                loadEarlierTranscriptButton(hiddenCount: hiddenTranscriptMessageCount)
            } else if !chatState.messages.isEmpty {
                Text("收到的事件可能是状态或原始输出，正在等待可显示内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func loadEarlierTranscriptIfNeeded() {
        guard hiddenTranscriptMessageCount > 0,
              transcriptScrollTargetID == nil,
              let firstItemID = windowedTranscriptItems.first?.id else { return }
        let shouldLoadEarlierPage = loadedHiddenTranscriptMessageCount < transcriptMessagePageSize && chatState.canLoadEarlierHistory
        transcriptUserIntent = .reviewing
        cancelPendingTranscriptBottomScrolls()
        transcriptScrollTargetID = firstItemID
        transcriptVisibleMessageLimit += transcriptMessagePageSize
        if shouldLoadEarlierPage {
            chatState.loadEarlierHistoryMessages(limit: transcriptMessagePageSize)
        }
        refreshTranscriptItems(force: true)
    }

    func loadEarlierTranscriptButton(hiddenCount: Int) -> some View {
        Button {
            loadEarlierTranscriptIfNeeded()
        } label: {
            Text("加载更早的 \(hiddenCount) 条消息")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.controlSurface.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func backToLatestButton() -> some View {
        if transcriptUserIntent == .reviewing && !isTranscriptAtBottom {
            Button {
                requestTranscriptBottomFollow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .semibold))
                    Text("回到最新")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(AppTheme.controlSurface.opacity(0.88))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
        }
    }

    var historyLoadingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("正在加载历史会话…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Text("长会话会在后台读取，界面不会再被同步阻塞。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(AppTheme.controlSurface.opacity(0.55))
    }

    var emptyChatState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发送消息开始真实 CLI 会话。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Text(capabilityText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func transcriptItemRow(_ item: ChatTranscriptItem, lastVisibleMessageID: UUID?) -> some View {
        switch item {
        case .message(let message):
            messageRow(message, lastVisibleMessageID: lastVisibleMessageID)
        case .toolGroup(let group):
            if group.primary.isExitPlanModeCall {
                if isActivePendingDecision(group.primary) {
                    EmptyView() // shown in the floating decision overlay
                } else {
                    planConfirmationRow(group.primary)
                }
            } else if group.primary.isAgentTool {
                agentTranscriptRow(group.primary, context: group.responses.last ?? group.primary)
            } else {
                toolInvocationRow(group)
            }
        case .toolBatch(let batch):
            toolBatchRow(batch)
        case .loading:
            loadingMessageRow
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
        }
    }

    @ViewBuilder
    func messageRow(_ message: ChatMessage, lastVisibleMessageID: UUID?) -> some View {
        switch message.kind {
        case .user:
            userMessageRow(message)
        case .assistant:
            assistantMessageRow(message)
        case .reasoning:
            reasoningMessageRow(message, lastVisibleMessageID: lastVisibleMessageID)
        case .error:
            errorMessageRow(message)
        case .toolCall, .toolResult, .command, .commandOutput, .diff:
            if message.isExitPlanModeCall {
                if isActivePendingDecision(message) {
                    EmptyView() // shown in the floating decision overlay
                } else {
                    planConfirmationRow(message)
                }
            } else if message.isAgentTool {
                agentTranscriptRow(message, context: message)
            } else {
                toolInvocationRow(message)
            }
        case .permissionRequest:
            if isActivePendingDecision(message) {
                EmptyView() // shown in the floating decision overlay
            } else {
                permissionRequestRow(message)
            }
        case .interactiveRequest:
            if isActivePendingDecision(message) {
                EmptyView() // shown in the floating decision overlay
            } else {
                interactiveRequestRow(message)
            }
        case .system, .result, .rawOutput:
            EmptyView()
        }
    }

    func rawEventRow(_ message: ChatMessage) -> some View {
        let title = message.kind == .result ? "result" : (message.title.nonEmptyTrimmed ?? "raw output")
        let body = message.toolDetailPreviewText.nonEmptyTrimmed ?? message.text
        return DisclosureGroup {
            toolTextPreview(body)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let subtitle = message.subtitle.nonEmptyTrimmed {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func userMessageRow(_ message: ChatMessage) -> some View {
        let legacyContent = parsedUserMessageContent(message.text)
        let text = message.attachments.isEmpty ? legacyContent.text : message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = message.attachments.isEmpty ? legacyContent.attachments.map(legacyAttachment) : message.attachments
        return HStack(alignment: .top) {
            Spacer(minLength: 34)

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 6) {
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                    if !attachments.isEmpty {
                        messageAttachmentStrip(attachments)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(AppTheme.toolMutedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                messageActionBar(message, alignment: .trailing, appendRuleText: message.appendRuleText?.nonEmptyTrimmed)
            }
        }
    }

    func parsedUserMessageContent(_ text: String) -> (text: String, attachments: [String]) {
        let parsed = splitAttachedPathsBlock(from: text)
        guard !parsed.attachments.isEmpty else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        return parsed
    }

    func legacyAttachment(_ path: String) -> ChatMessageAttachment {
        let standardizedPath = (path as NSString).standardizingPath
        let url = URL(fileURLWithPath: standardizedPath)
        let filename = url.lastPathComponent.isEmpty ? "附件" : url.lastPathComponent
        if isImageAttachment(url) {
            return ChatMessageAttachment(
                kind: .image,
                filename: filename,
                path: standardizedPath,
                thumbnailData: thumbnailData(for: url)
            )
        }
        return ChatMessageAttachment(kind: .file, filename: filename, path: standardizedPath)
    }

    func messageAttachmentStrip(_ attachments: [ChatMessageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    messageAttachmentTile(attachment)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 260, alignment: .trailing)
    }

    @ViewBuilder
    func messageAttachmentTile(_ attachment: ChatMessageAttachment) -> some View {
        let isImage = attachment.kind == .image
        Button {
            appState.openFile(path: attachment.path, line: nil, column: nil)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isImage, let data = attachment.thumbnailData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipped()
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: isImage ? "photo" : "doc")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(attachment.filename)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.middle)
                                .frame(width: 46)
                        }
                        .frame(width: 56, height: 56)
                    }
                }
                .background(AppTheme.controlSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.hairline, lineWidth: 1)
                )

                Image(systemName: isImage ? "photo" : "doc")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .padding(4)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .help(attachment.path)
    }

    func appendRuleCard(_ text: String) -> some View {
        Button {
            selectedAppendRulePreview = AppendRulePreview(text: text)
        } label: {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 9, weight: .medium))
        }
        .buttonStyle(MiniIconButtonStyle(width: 18, height: 18, cornerRadius: 6))
        .foregroundStyle(.tertiary)
        .help("查看追加规则")
    }

    func assistantMessageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AssistantMessageContent(
                text: message.text,
                isStreaming: message.isStreaming,
                messageID: message.id,
                streamingTextStore: chatState.streamingTextStore,
                onOpenFile: openFileReference
            )
        }
    }

    func openFileReference(_ reference: FileReference) {
        appState.openFile(path: reference.path, line: reference.line, column: reference.column)
    }

    var loadingMessageRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text(loadingThinkingText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func errorMessageRow(_ message: ChatMessage) -> some View {
        Text(message.text)
            .font(.system(size: 12))
            .lineSpacing(2)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func toolInvocationRow(_ message: ChatMessage) -> some View {
        if shouldShowCurrentCLIToolCards {
            // Only file-change tools (Write/Edit/MultiEdit) and failed tools keep their rich,
            // expandable detail. Every other (successful) tool collapses to a single static
            // line — no chevron, no detail body, no payload parsing — the main perf win.
            let isRich = isFileChangeTool(message) || message.toolStatusKind == .failed
            toolInvocationCard(message, statusMessage: message, isDetailVisible: isRich, isInlineDetail: isRich, isCollapsible: false) {
                toolDetailCard(message)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    func toolInvocationRow(_ group: ToolInvocationGroup) -> some View {
        if shouldShowCurrentCLIToolCards {
            let statusMessage = group.responses.last ?? group.primary
            let isRich = isFileChangeTool(group.primary)
                || group.primary.toolStatusKind == .failed
                || statusMessage.toolStatusKind == .failed
            toolInvocationCard(group.primary, statusMessage: statusMessage, isDetailVisible: isRich, isInlineDetail: isRich, isCollapsible: false, feedbackCount: group.responses.count) {
                toolDetailCard(group)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    var shouldShowCurrentCLIToolCards: Bool {
        true
    }

    @ViewBuilder
    func toolBatchRow(_ batch: ToolBatchGroup) -> some View {
        let expanded = expandedToolBatchIDs.contains(batch.id)
        VStack(alignment: .leading, spacing: expanded ? 4 : 0) {
            toolBatchHeader(batch, expanded: expanded)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(batch.groups) { group in
                        toolInvocationRow(group)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func toolBatchHeader(_ batch: ToolBatchGroup, expanded: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.58))
                .frame(width: 9)
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.58))
                .frame(width: 13, height: 13)
            Text(toolBatchSummaryText(batch))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                toggleToolBatch(batch.id)
            }
        }
        .help(expanded ? "折叠工具步骤" : "展开工具步骤")
    }

    func toolBatchSummaryText(_ batch: ToolBatchGroup) -> String {
        var counts: [String: Int] = [:]
        for group in batch.groups {
            counts[group.primary.toolKindKey, default: 0] += 1
        }
        let labels: [(String, String)] = [("read", "读取"), ("grep", "搜索"), ("glob", "匹配")]
        let parts = labels.compactMap { key, label -> String? in
            guard let count = counts[key], count > 0 else { return nil }
            return "\(label) \(count)"
        }
        let prefix = parts.isEmpty ? "工具" : parts.joined(separator: " · ")
        return "\(prefix) · 共 \(batch.groups.count) 步"
    }

    func toggleToolBatch(_ id: String) {
        if expandedToolBatchIDs.contains(id) {
            expandedToolBatchIDs.remove(id)
        } else {
            expandedToolBatchIDs.insert(id)
        }
    }

    func toolInvocationCard<Detail: View>(
        _ message: ChatMessage,
        statusMessage: ChatMessage,
        isDetailVisible: Bool,
        isInlineDetail: Bool,
        isCollapsible: Bool = true,
        feedbackCount: Int = 0,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        let hidesHeader = (isTodoTool(message) || isTodoTool(statusMessage) || isFileChangeTool(message)) && isDetailVisible
        return VStack(alignment: .leading, spacing: 0) {
            if !hidesHeader {
                toolInvocationHeader(
                    message,
                    statusMessage: statusMessage,
                    isExpanded: isDetailVisible,
                    isInlineDetail: isInlineDetail,
                    isCollapsible: isCollapsible,
                    feedbackCount: feedbackCount
                )
            }

            if isDetailVisible {
                detail()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, hidesHeader ? 0 : 22)
                    .padding(.trailing, 6)
                    .padding(.top, hidesHeader ? 0 : 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, isDetailVisible ? 2 : 0)
    }

    func toolInvocationHeader(
        _ message: ChatMessage,
        statusMessage: ChatMessage? = nil,
        isExpanded: Bool,
        isInlineDetail: Bool = false,
        isCollapsible: Bool = true,
        feedbackCount: Int = 0
    ) -> some View {
        let summary = ToolInvocationSummaryCache.summary(for: message)
        return HStack(alignment: .center, spacing: 5) {
            HStack(spacing: 4) {
                if isCollapsible {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.58))
                        .frame(width: 9)
                }

                Image(systemName: message.toolSystemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.58))
                    .frame(width: 13, height: 13)

                Text(summary.primaryTitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(3)

            if let summaryText = toolHeaderSummary(for: message, resultMessage: statusMessage, summary: summary, feedbackCount: feedbackCount) {
                if let filePath = summary.filePath, message.toolHeaderFileIsOpenable {
                    Button {
                        openFileReference(FileReference(path: filePath))
                    } label: {
                        Text(summaryText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("打开 \(filePath)")
                    .layoutPriority(0)
                } else {
                    Text(summaryText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCollapsible else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                toggleToolDetail(message.id, isInlineDetail: isInlineDetail)
            }
        }
        .help(summary.primaryTitle)
    }

    func shouldShowInlineToolDetail(_ message: ChatMessage) -> Bool {
        guard isInlineDetailTool(message) else { return false }
        if isAlwaysVisibleTool(message) { return true }
        return message.isStreaming || message.toolStatusKind == .failed
    }

    func shouldShowInlineToolDetail(_ group: ToolInvocationGroup) -> Bool {
        let result = group.responses.last ?? group.primary
        if isAlwaysVisibleTool(group.primary) || isAlwaysVisibleTool(result) { return true }
        return group.primary.isStreaming || result.isStreaming || group.primary.toolStatusKind == .failed || result.toolStatusKind == .failed
    }

    func isInlineDetailTool(_ message: ChatMessage) -> Bool {
        let toolKey = message.toolKindKey
        return message.kind == .toolResult
            || isFileChangeTool(message)
            || message.isTerminalTool
            || toolKey == "agent"
            || ["read", "grep", "glob", "todowrite"].contains(toolKey)
    }

    func isFileChangeTool(_ message: ChatMessage) -> Bool {
        let toolKey = message.toolKindKey
        return message.kind == .diff || ["edit", "write", "create", "create_file", "new_file", "multi_edit", "multiedit"].contains(toolKey)
    }

    func isTodoTool(_ message: ChatMessage) -> Bool {
        message.toolKindKey == "todowrite"
    }

    func isAlwaysVisibleTool(_ message: ChatMessage) -> Bool {
        ["todowrite", "askquestion", "askuserquestion"].contains(message.toolKindKey) || message.isAgentTool || isFileChangeTool(message)
    }

    func isTextOnlyTool(_ message: ChatMessage) -> Bool {
        message.toolKindKey == "read" || message.isTerminalTool
    }

    func toolHeaderSummary(for message: ChatMessage, resultMessage: ChatMessage?, summary: ToolInvocationSummary, feedbackCount: Int) -> String? {
        let toolKey = message.toolKindKey
        let result = resultMessage ?? message
        if message.isTerminalTool {
            return result.toolExecutedCommand.map { "$ \(Self.inlinePreview($0, limit: 80))" } ?? message.toolExecutedCommand.map { "$ \(Self.inlinePreview($0, limit: 80))" }
        }
        if toolKey == "read" {
            return (message.toolFilePath ?? summary.filePath).map { ($0 as NSString).lastPathComponent }
        }
        if toolKey == "grep" {
            return message.toolSearchPattern.map { "pattern: \(Self.inlinePreview($0, limit: 44))" }
        }
        if toolKey == "glob" {
            return message.toolSearchPattern.map { "pattern: \(Self.inlinePreview($0, limit: 44))" }
        }
        if toolKey == "todowrite" {
            return nil
        }
        if message.isAgentTool {
            return message.subagentDisplayTitle
        }
        if isFileChangeTool(message) {
            let path = result.toolFilePath ?? message.toolFilePath ?? summary.filePath ?? result.toolCodePreview?.path ?? message.toolCodePreview?.path
            let status = result.toolCodePreview?.stats ?? message.toolCodePreview?.stats ?? result.diffStatsSummary ?? message.diffStatsSummary ?? "已更新"
            if let path {
                return "\(path) · \(status)"
            }
            return status
        }
        if feedbackCount > 0 {
            return "反馈 \(feedbackCount)"
        }
        if let path = summary.filePath ?? message.toolFilePath {
            return (path as NSString).lastPathComponent
        }
        return summary.plainSummary
    }

    private static func inlinePreview(_ text: String, limit: Int) -> String {
        let value = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    func relativeToolPath(_ path: String) -> String {
        let standardizedPath = (path as NSString).standardizingPath
        guard let projectPath = appState.selectedProject?.path else { return path }
        let root = (projectPath as NSString).standardizingPath
        if standardizedPath == root { return (standardizedPath as NSString).lastPathComponent }
        if standardizedPath.hasPrefix(root + "/") {
            return String(standardizedPath.dropFirst(root.count + 1))
        }
        return path
    }

    func subagentDetailButton(_ message: ChatMessage, summary: ToolInvocationSummary) -> some View {
        Button {
            guard let request = message.subagentDetailRequest(projectPath: appState.selectedProject?.path ?? appState.selectedHistoryProjectPath) else { return }
            selectedSubagentDetail = request
        } label: {
            Text("process")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("打开子代理过程")
    }

    func toolFileButton(path: String) -> some View {
        let reference = FileReference(path: path)
        return FileReferenceButton(reference: reference, onOpenFile: openFileReference)
    }

    func toolSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.toolSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
    }

    func toolDetailHeader(_ title: String, detailText: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if !detailText.isEmpty {
                iconAction("doc.on.doc", help: "复制详情") {
                    copyText(detailText)
                }
            }
        }
    }

    @ViewBuilder
    func toolDetailCard(_ message: ChatMessage) -> some View {
        if message.isTerminalTool {
            terminalDetailView(message)
        } else if message.toolStatusKind == .failed {
            toolFailureSummaryCard(message)
        } else {
            structuredToolDetailView(message, context: nil)
        }
    }

    @ViewBuilder
    func toolDetailCard(_ group: ToolInvocationGroup) -> some View {
        let result = group.responses.last ?? group.primary
        if group.primary.isTerminalTool || result.isTerminalTool {
            terminalDetailView(result, context: group.primary)
        } else if group.primary.toolStatusKind == .failed || result.toolStatusKind == .failed {
            toolFailureSummaryCard(result)
        } else {
            structuredToolDetailView(result, context: group.primary)
        }
    }

    func toolRunningPlaceholder() -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text("Running...")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func toolFailureSummaryCard(_ message: ChatMessage) -> some View {
        Text(Self.inlinePreview(message.text, limit: 600).nonEmptyTrimmed ?? "执行失败")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(6)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.toolMutedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    func toolDetailSection(_ message: ChatMessage, label: String?, context: ChatMessage? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            structuredToolDetailView(message, context: context)
        }
    }

    @ViewBuilder
    func structuredToolDetailView(_ message: ChatMessage, context: ChatMessage?) -> some View {
        let primary = context ?? message
        let payload = ToolPayloadCache.payload(for: message, context: primary)
        switch payload {
        case .read(let payload):
            readPreviewCard(payload, message: message)
        case .grep(let payload):
            searchResultCard(payload, context: primary, title: "匹配结果", emptyTitle: "无匹配结果", mode: .grep)
        case .glob(let payload):
            searchResultCard(payload, context: primary, title: "文件列表", emptyTitle: "无匹配文件", mode: .glob)
        case .diff(let payload):
            fileChangePreviewCard(payload, message: message, primary: primary)
        case .terminal(let payload):
            terminalDetailView(payload, message: message, context: primary)
        case .todo(let payload):
            todoDetailCard(payload, context: primary)
        case .agent(let payload):
            subagentSummaryCard(payload, message: message, context: primary)
        case .mcp(let payload), .plain(let payload):
            semanticToolDetailCard(payload, message: message, context: primary)
        }
    }

    func toolRequestCard(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message)
        return semanticToolDetailCard(payload.semanticFallback, message: message, context: message)
    }

    func searchRequestCard(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message)
        return semanticToolDetailCard(payload.semanticFallback, message: message, context: message)
    }

    @ViewBuilder
    func fileChangePreviewCard(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticDiffPayload(message: message, context: message)
        fileChangePreviewCard(payload, message: message, primary: message)
    }

    @ViewBuilder
    func fileChangePreviewCard(_ message: ChatMessage, primary: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: primary).semanticDiffPayload(message: message, context: primary)
        fileChangePreviewCard(payload, message: message, primary: primary)
    }

    @ViewBuilder
    func fileChangePreviewCard(_ payload: DiffPayload, message: ChatMessage, primary: ChatMessage) -> some View {
        if let preview = message.toolCodePreview ?? primary.toolCodePreview {
            toolCodePreviewCard(preview)
        } else if let streaming = message.streamingToolCodePreview ?? primary.streamingToolCodePreview {
            // Render the shell immediately and stream Write/Edit content in as it arrives,
            // instead of waiting for the full tool input JSON (and the "已完成文件修改" placeholder).
            toolCodePreviewCard(streaming)
        } else if message.kind == .diff || primary.kind == .diff {
            toolDiffPreviewCard(message.kind == .diff ? message : primary)
        } else if message.isStreaming || primary.isStreaming {
            // Still waiting on the first tool-input chunk: show a running placeholder rather than
            // the "已完成文件修改" summary, which falsely reads as finished mid-stream.
            toolRunningPlaceholder()
        } else {
            fileChangeSummaryCard(payload, primary: primary)
        }
    }

    func fileChangeSummaryCard(_ payload: DiffPayload, primary: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                toolVisualTitle(payload.path.map(relativeToolPath) ?? "代码变更", systemImage: "plus.forwardslash.minus", tint: primary.toolTint)
                Spacer(minLength: 0)
                Text(payload.stats ?? primary.toolCodePreview?.stats ?? "已更新")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.toolMutedSurface)
                    .clipShape(Capsule())
            }
            Text("已完成文件修改")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.toolMutedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    func readPreviewCard(_ message: ChatMessage, path: String?) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticReadPayload(message: message, path: path)
        return readPreviewCard(payload, message: message)
    }

    func readPreviewCard(_ payload: ReadPayload, message: ChatMessage) -> some View {
        let lines = Array(payload.lines.prefix(200))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Text("\(payload.lines.count) lines")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ToolCodePreviewView(lines: lines, firstLine: payload.startLine, maxHeight: 260)
            if payload.lines.count > lines.count {
                Text("+\(payload.lines.count - lines.count) more lines")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let path = payload.path {
                    Button("Open file") { openFileReference(FileReference(path: path)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Button("Copy") { copyText(payload.copyText) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    enum ToolSearchResultMode {
        case grep
        case glob
    }

    func searchResultCard(_ message: ChatMessage, title: String, emptyTitle: String) -> some View {
        let mode: ToolSearchResultMode = message.toolKindKey == "glob" ? .glob : .grep
        if mode == .glob {
            let payload = ToolPayloadCache.payload(for: message, context: message).semanticGlobPayload(message: message)
            return AnyView(searchResultCard(payload, context: message, title: title, emptyTitle: emptyTitle, mode: .glob))
        }
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticGrepPayload(message: message)
        return AnyView(searchResultCard(payload, context: message, title: title, emptyTitle: emptyTitle, mode: .grep))
    }

    func searchResultCard(_ message: ChatMessage, context: ChatMessage, title: String, emptyTitle: String, mode: ToolSearchResultMode) -> some View {
        if mode == .glob {
            let payload = ToolPayloadCache.payload(for: message, context: context).semanticGlobPayload(message: message)
            return AnyView(searchResultCard(payload, context: context, title: title, emptyTitle: emptyTitle, mode: .glob))
        }
        let payload = ToolPayloadCache.payload(for: message, context: context).semanticGrepPayload(message: message)
        return AnyView(searchResultCard(payload, context: context, title: title, emptyTitle: emptyTitle, mode: .grep))
    }

    func searchResultCard(_ payload: GrepPayload, context: ChatMessage, title: String, emptyTitle: String, mode: ToolSearchResultMode) -> some View {
        searchResultCard(lines: payload.matches, context: context, title: title, emptyTitle: emptyTitle, mode: mode)
    }

    func searchResultCard(_ payload: GlobPayload, context: ChatMessage, title: String, emptyTitle: String, mode: ToolSearchResultMode) -> some View {
        searchResultCard(lines: payload.files, context: context, title: title, emptyTitle: emptyTitle, mode: mode)
    }

    func searchResultCard(lines: [String], context _: ChatMessage, title _: String, emptyTitle: String, mode: ToolSearchResultMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if lines.isEmpty {
                    Text(emptyTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(mode == .glob ? "\(lines.count) files" : "\(lines.count) matches")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if mode == .glob {
                ToolFileGrid(paths: lines, onOpenFile: openFileReference)
            } else {
                ToolMatchTable(lines: lines, onOpenFile: openFileReference)
            }
        }
    }

    func genericToolDetailCard(_ message: ChatMessage) -> some View {
        genericToolDetailCard(message, context: message)
    }

    func genericToolDetailCard(_ message: ChatMessage, context: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: context).semanticFallback
        return semanticToolDetailCard(payload, message: message, context: context)
    }

    func semanticToolDetailCard(_ payload: McpPayload, message: ChatMessage, context: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                toolVisualTitle(payload.title, systemImage: context.toolSystemImage, tint: context.toolTint)
                Spacer(minLength: 0)
                if payload.isParseFallback {
                    Text("Plain text")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.toolMutedSurface)
                        .clipShape(Capsule())
                }
            }
            toolBusinessFields(payload.fields)
            if payload.resultPreview.isEmpty {
                Text("无可视化结果")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.toolMutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                toolTextPreview(Self.compactLargeText(payload.resultPreview, maxLines: 80))
            }
            if !payload.rawText.isEmpty && payload.rawText != payload.resultPreview {
                DisclosureGroup {
                    toolTextPreview(payload.rawText)
                        .padding(.top, 4)
                } label: {
                    Text("展开完整 MCP 回调")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(9)
                .background(AppTheme.toolMutedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if message.toolStatusKind == .failed {
                Button("Retry") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    func todoDetailCard(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticTodoPayload(message: message, context: message)
        return todoDetailCard(payload, context: message)
    }

    func todoDetailCard(_ message: ChatMessage, context: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: context).semanticTodoPayload(message: message, context: context)
        return todoDetailCard(payload, context: context)
    }

    func todoDetailCard(_ payload: TodoPayload, context _: ChatMessage) -> some View {
        let rows = Array(payload.rows.prefix(40))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text("任务列表")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                Spacer(minLength: 8)
                if let counts = todoCountsText(rows: rows) {
                    Text(counts)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("暂无任务")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        TodoToolRow(row: row)
                        if index < rows.count - 1 {
                            Divider()
                                .opacity(0.10)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.controlSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.weakHairline, lineWidth: 1)
        )
    }

    func todoCountsText(_ message: ChatMessage) -> String? {
        todoCountsText(rows: message.todoTaskRows)
    }

    func todoCountsText(rows: [(content: String, status: String)]) -> String? {
        guard !rows.isEmpty else { return nil }
        let inProgress = rows.filter { $0.status == "in_progress" || $0.status == "in progress" }.count
        let completed = rows.filter { $0.status == "completed" }.count
        let added = max(rows.count - inProgress - completed, 0)
        return "新增 \(added) · 进行中 \(inProgress) · 已完成 \(completed)"
    }

    func toolDiffPreviewCard(_ message: ChatMessage) -> some View {
        let lines = Array(message.diffLines.lazy
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("+++") && !$0.hasPrefix("---") && !$0.hasPrefix("@@") }
            .map(toolCodePreviewLine))
        let preview = ToolCodePreview(
            title: message.toolFilePath.map { ($0 as NSString).lastPathComponent } ?? "changes.diff",
            path: message.toolFilePath ?? "changes.diff",
            stats: message.diffStatsSummary ?? "代码变更",
            changeStats: ToolChangeStats(
                added: message.diffLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count,
                removed: message.diffLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            ),
            lines: lines
        )
        return toolCodePreviewCard(preview)
    }

    func toolCodePreviewLine(from rawLine: String) -> ToolCodePreview.Line {
        if rawLine.hasPrefix("+") {
            return ToolCodePreview.Line(marker: "+", text: String(rawLine.dropFirst()), tint: .green)
        }
        if rawLine.hasPrefix("-") {
            return ToolCodePreview.Line(marker: "-", text: String(rawLine.dropFirst()), tint: .red)
        }
        let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
        return ToolCodePreview.Line(marker: " ", text: text.isEmpty ? " " : text, tint: .secondary)
    }

    func toolVisualTitle(_ title: String, systemImage: String) -> some View {
        toolVisualTitle(title, systemImage: systemImage, tint: Color.accentColor)
    }

    func toolVisualTitle(_ title: String, systemImage: String, tint _: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    func toolPathRow(_ path: String) -> some View {
        Button {
            openFileReference(FileReference(path: path))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(relativeToolPath(path))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.toolMutedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(path)
    }

    @ViewBuilder
    func toolBusinessFields(_ fields: [ToolBusinessField]) -> some View {
        if fields.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Business params")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.key)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(toolInlineValue(field.value))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.78))
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.toolMutedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
        }
    }

    func toolTextPreview(_ text: String) -> some View {
        FileReferenceText(
            text: Self.compactLargeText(text, maxLines: 100),
            font: .system(size: 10, design: .monospaced),
            baseColor: .secondary,
            lineSpacing: 2,
            parseMarkdown: false,
            cacheID: "tool-preview:\(text.count)",
            onOpenFile: openFileReference
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func toolInlineValue(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 180 else { return normalized }
        return String(normalized.prefix(180)) + "…"
    }

    func toolContentLines(from message: ChatMessage) -> [String] {
        message.toolContentLines
    }

    func subagentSummaryCard(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticAgentPayload(message: message, context: message)
        return subagentSummaryCard(payload, message: message, context: message)
    }

    func subagentSummaryCard(_ message: ChatMessage, context: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: context).semanticAgentPayload(message: message, context: context)
        return subagentSummaryCard(payload, message: message, context: context)
    }

    /// Whether a finished tool_result already exists for this agent call.
    func agentToolResultExists(for requestID: String?) -> Bool {
        guard let requestID = requestID?.nonEmptyTrimmed else { return false }
        return chatState.messages.contains { $0.kind == .toolResult && $0.requestID == requestID }
    }

    /// An agent call is "running" only within the current turn until its tool_result arrives.
    /// Earlier-turn / history agents are always considered done so they render their result row.
    func isAgentRunning(_ message: ChatMessage) -> Bool {
        guard message.isAgentTool, chatState.status.isRunning else { return false }
        guard isInCurrentTurn(message) else { return false }
        if agentToolResultExists(for: message.requestID) { return false }
        return true
    }

    private func isInCurrentTurn(_ message: ChatMessage) -> Bool {
        let messages = chatState.messages
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return false }
        let turnStart = messages.lastIndex(where: { $0.kind == .user }).map { $0 + 1 } ?? 0
        return index >= turnStart
    }

    /// Agent calls don't render an inline card while running — a floating progress pill above
    /// the composer represents them instead (see agentRunningOverlay). Once complete they
    /// collapse to a single tappable line that opens the full sub-agent transcript.
    @ViewBuilder
    func agentTranscriptRow(_ message: ChatMessage, context: ChatMessage) -> some View {
        if isAgentRunning(message) {
            EmptyView()
        } else {
            agentResultRow(message, context: context)
        }
    }

    func agentResultRow(_ message: ChatMessage, context: ChatMessage) -> some View {
        let request = subagentTranscriptRequest(message: message, context: context)
        let title = context.subagentDisplayTitle.nonEmptyTrimmed ?? message.subagentDisplayTitle.nonEmptyTrimmed ?? "Agent"
        return HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 13, height: 13)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if request != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let request else { return }
            selectedSubagentDetail = request
        }
        .help(title)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Agent calls currently in flight, used to drive the floating progress pill. Scoped to the
    /// CURRENT turn (after the last user message) so completed agents from earlier turns / loaded
    /// history don't get counted as "running" (which produced the bogus "N 个 Agent 运行中").
    var runningAgentMessages: [ChatMessage] {
        guard chatState.status.isRunning else { return [] }
        let messages = chatState.messages
        let turnStart = messages.lastIndex(where: { $0.kind == .user }).map { $0 + 1 } ?? 0
        guard turnStart < messages.count else { return [] }
        let turnMessages = messages[turnStart...]
        var resultRequestIDs = Set<String>()
        for message in turnMessages where message.kind == .toolResult {
            if let requestID = message.requestID?.nonEmptyTrimmed {
                resultRequestIDs.insert(requestID)
            }
        }
        return turnMessages.filter { message in
            guard message.isAgentTool, message.kind == .toolCall else { return false }
            // Without a request id we can't tell whether it finished, so don't surface it.
            guard let requestID = message.requestID?.nonEmptyTrimmed else { return false }
            return !resultRequestIDs.contains(requestID)
        }
    }

    @ViewBuilder
    func agentRunningOverlay() -> some View {
        let agents = runningAgentMessages
        if !agents.isEmpty {
            let title = agents.last?.subagentDisplayTitle.nonEmptyTrimmed
            let label = agents.count > 1 ? "\(agents.count) 个 Agent 运行中…" : "Agent 运行中：\(title ?? "子任务")"
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.weakHairline, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, composerChromeHeight + 10)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private enum PendingDecision {
        case permission(ChatMessage)
        case interactive(ChatMessage)
        case plan(ChatMessage)
    }

    /// The decision currently awaiting the user (permission y/n, AskUserQuestion选择题, or
    /// plan execution confirmation). These pop up in a floating layer above the composer
    /// (IDE quick-pick style) instead of rendering inline in the transcript.
    private var activePendingDecision: PendingDecision? {
        for message in chatState.messages.reversed() {
            if message.kind == .permissionRequest, message.status == "waiting" {
                return .permission(message)
            }
            if message.kind == .interactiveRequest, (message.interactiveRequest?.status ?? .waiting) == .waiting {
                return .interactive(message)
            }
            if message.isExitPlanModeCall, canActOnExitPlanMode(for: message) {
                return .plan(message)
            }
            if message.kind == .user { break }
        }
        return nil
    }

    private func decisionMessageID(_ decision: PendingDecision) -> UUID {
        switch decision {
        case .permission(let message), .interactive(let message), .plan(let message):
            return message.id
        }
    }

    /// Single source of truth shared by the overlay and the inline transcript: a message is
    /// suppressed inline iff it is the one currently shown in the floating decision overlay.
    /// This guarantees the two can never disagree (which could otherwise hide a prompt).
    private func isActivePendingDecision(_ message: ChatMessage) -> Bool {
        guard let decision = activePendingDecision else { return false }
        return decisionMessageID(decision) == message.id
    }

    @ViewBuilder
    func pendingDecisionOverlay() -> some View {
        if let decision = activePendingDecision {
            let maxOverlayHeight: CGFloat = 460
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ScrollView {
                    decisionCard(decision)
                        .padding(14)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: DecisionOverlayHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                }
                .frame(height: min(max(decisionOverlayContentHeight, 1), maxOverlayHeight))
                .scrollBounceBehavior(.basedOnSize)
                .id(decisionMessageID(decision))
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.hairline, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 16, y: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, composerChromeHeight + 10)
            }
            .frame(maxWidth: .infinity)
            .onPreferenceChange(DecisionOverlayHeightPreferenceKey.self) { height in
                guard abs(decisionOverlayContentHeight - height) > 0.5 else { return }
                decisionOverlayContentHeight = height
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func decisionCard(_ decision: PendingDecision) -> some View {
        switch decision {
        case .permission(let message):
            permissionRequestRow(message)
        case .interactive(let message):
            interactiveRequestRow(message)
        case .plan(let message):
            planConfirmationRow(message)
        }
    }

    func subagentSummaryCard(_ payload: AgentPayload, message: ChatMessage, context: ChatMessage) -> some View {
        let request = subagentTranscriptRequest(message: message, context: context)
        let title = payload.title.nonEmptyTrimmed ?? "Agent"
        let prompt = payload.prompt ?? title
        return HStack(alignment: .top, spacing: 8) {
            Text(prompt)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let request {
                Button {
                    selectedSubagentDetail = request
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看子代理详情")
                .accessibilityLabel("查看子代理详情")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.controlSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.weakHairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard let request else { return }
            selectedSubagentDetail = request
        }
    }

    func subagentTranscriptRequest(message: ChatMessage, context: ChatMessage) -> SubagentDetailRequest? {
        let projectPath = appState.selectedProject?.path ?? appState.selectedHistoryProjectPath
        let base = context.subagentDetailRequest(projectPath: projectPath) ?? message.subagentDetailRequest(projectPath: projectPath)
        guard let base else { return nil }
        guard base.agentID == nil else { return base }
        let correlatedID = correlatedSubagentID(for: context) ?? correlatedSubagentID(for: message)
        return SubagentDetailRequest(agentID: correlatedID, agentType: base.agentType, description: base.description, projectPath: base.projectPath)
    }

    func correlatedSubagentID(for message: ChatMessage) -> String? {
        guard let requestID = message.requestID?.nonEmptyTrimmed else { return nil }
        return chatState.messages.lazy
            .filter { $0.kind == .system && $0.subtitle.lowercased() == "task_started" }
            .first { $0.taskStartedToolUseID == requestID }?
            .subagentTaskID
    }

    static let codePreviewMaxHeight: CGFloat = 200

    func toolCodePreviewCard(_ preview: ToolCodePreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    openFileReference(FileReference(path: preview.path))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text((preview.path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                .help(preview.path)

                Spacer(minLength: 0)

                if preview.changeStats.hasChanges {
                    changeCountPill("+\(preview.changeStats.added)", tint: .green)
                    changeCountPill("-\(preview.changeStats.removed)", tint: .red)
                } else {
                    Text(preview.stats)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.codePreviewHeaderSurface)

            Divider().opacity(0.18)

            ScrollView(.horizontal, showsIndicators: true) {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                            toolCodeChangeLine(line, lineNumber: index + 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.codePreviewMaxHeight)
            }
        }
        .background(AppTheme.codePreviewSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .shadow(color: AppTheme.softShadow, radius: 8, x: 0, y: 3)
    }

    func changeCountPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint.opacity(0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    func toolCodeChangeLine(_ line: ToolCodePreview.Line, lineNumber: Int) -> some View {
        let isAdded = line.marker == "+"
        let isRemoved = line.marker == "-"
        let tint = isAdded ? Color.green : (isRemoved ? Color.red : Color.secondary)
        return HStack(alignment: .top, spacing: 0) {
            Text("\(lineNumber)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line.marker)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle((isAdded || isRemoved) ? tint.opacity(0.9) : Color.secondary)
                .frame(width: 18, alignment: .center)
            Text(line.text)
                .font(.system(size: 10, weight: isAdded || isRemoved ? .medium : .regular, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(isAdded || isRemoved ? 0.9 : 0.78))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .background(isAdded ? Color.green.opacity(0.14) : (isRemoved ? Color.red.opacity(0.13) : AppTheme.toolMutedSurface))
    }

    func terminalDetailView(_ message: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: message).semanticBashPayload(message: message, context: message)
        return terminalDetailView(payload, message: message, context: message)
    }

    func terminalDetailView(_ message: ChatMessage, context: ChatMessage) -> some View {
        let payload = ToolPayloadCache.payload(for: message, context: context).semanticBashPayload(message: message, context: context)
        return terminalDetailView(payload, message: message, context: context)
    }

    @ViewBuilder
    func terminalDetailView(_ payload: BashPayload, message: ChatMessage, context: ChatMessage) -> some View {
        let isStreaming = message.isStreaming || context.isStreaming
        if isStreaming {
            StreamingTerminalOutputBlock(
                store: chatState.streamingTextStore,
                message: message,
                context: context,
                command: payload.command,
                fallbackSections: payload.sections,
                exitCode: payload.exitCode,
                onOpenFile: openFileReference
            )
        } else {
            TerminalOutputBlock(
                sections: TerminalFlowBuilder.sections(command: payload.command, sections: payload.sections, exitCode: payload.exitCode, isStreaming: false),
                isStreaming: false,
                onOpenFile: openFileReference
            )
        }
    }

    func terminalPreviewText(_ text: String) -> String {
        Self.compactLargeText(text, maxLines: 600)
    }

    private static func compactLargeText(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines || text.count > 4_000 else { return text }
        let headCount = min(80, maxLines / 3)
        let tailCount = max(1, maxLines - headCount)
        let head = lines.prefix(headCount)
        let tail = lines.suffix(tailCount)
        return (Array(head) + ["...", "+\(max(lines.count - head.count - tail.count, 0)) folded lines", "..."] + Array(tail)).joined(separator: "\n")
    }

    func interactiveRequestRow(_ message: ChatMessage) -> some View {
        ChatInteractiveRequestCard(message: message, chatState: chatState)
    }

    func reasoningMessageRow(_ message: ChatMessage, lastVisibleMessageID: UUID?) -> some View {
        // Keep the thinking block expanded while it's streaming (even if a tool/text row has
        // since appeared after it), so reasoning renders live instead of staying collapsed.
        let isThinking = message.isStreaming
        let isExpanded = isThinking || expandedTranscriptMessageIDs.contains(message.id)

        return VStack(alignment: .leading, spacing: 5) {
            Button {
                toggleTranscriptMessage(message.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)

                    Text("thinking")
                        .font(.system(size: 12, weight: .medium))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                StreamingAssistantTextView(
                    store: chatState.streamingTextStore,
                    messageID: message.id,
                    fallbackText: message.text,
                    textColor: .secondaryLabelColor
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 19)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func toggleTranscriptMessage(_ id: UUID) {
        if expandedTranscriptMessageIDs.contains(id) {
            expandedTranscriptMessageIDs.remove(id)
        } else {
            expandedTranscriptMessageIDs.insert(id)
        }
    }

    func toggleToolDetail(_ id: UUID, isInlineDetail: Bool) {
        if isInlineDetail {
            expandedTranscriptMessageIDs.remove(id)
            if collapsedInlineToolIDs.contains(id) {
                collapsedInlineToolIDs.remove(id)
            } else {
                collapsedInlineToolIDs.insert(id)
            }
        } else {
            toggleTranscriptMessage(id)
        }
    }

    func fileEditRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("edit")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)

                Text(message.title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(message.status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(message.diffLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(line.diffTint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 60)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func permissionRequestRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(message.title.isEmpty ? "需要权限" : message.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if message.status == "waiting" {
                HStack(spacing: 8) {
                    permissionActionButton("拒绝") {
                        if let requestID = message.requestID {
                            chatState.respondToPermission(requestID: requestID, decision: .deny)
                        }
                    }

                    permissionActionButton("允许") {
                        if let requestID = message.requestID {
                            chatState.respondToPermission(requestID: requestID, decision: .allow)
                        }
                    }

                    permissionActionButton("本会话允许") {
                        if let requestID = message.requestID {
                            chatState.respondToPermission(requestID: requestID, decision: .allowForSession)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(AppTheme.secondaryCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    @ViewBuilder
    func planConfirmationRow(_ message: ChatMessage) -> some View {
        let canAct = canActOnExitPlanMode(for: message)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .frame(width: 22, height: 22)
                    .background(AppTheme.toolMutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(AppTheme.weakHairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("待执行方案")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(canAct ? "确认后会继续执行已规划的操作。" : "该方案已处理。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                ToolStatusBadge(kind: canAct ? .running : .success, label: canAct ? "等待确认" : "已处理")
            }

            if canAct {
                HStack(spacing: 8) {
                    planConfirmationButton(
                        title: "取消方案",
                        systemImage: "xmark.circle",
                        isPrimary: false,
                        action: { cancelExitPlanMode(message) }
                    )

                    planConfirmationButton(
                        title: "继续执行方案",
                        systemImage: "play.circle.fill",
                        isPrimary: true,
                        action: { confirmExitPlanMode(message) }
                    )
                }

                Text("点继续将自动发送确认消息。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(AppTheme.secondaryCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.weakHairline, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func planConfirmationButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .foregroundStyle(isPrimary ? Color.primary.opacity(0.84) : Color.secondary)
            .background(isPrimary ? AppTheme.toolMutedSurface : AppTheme.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.weakHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    func canActOnExitPlanMode(for message: ChatMessage) -> Bool {
        guard !chatState.isLoadingHistory else { return false }
        guard !chatState.status.isRunning else { return false }
        // Only the latest plan in the transcript is actionable; older plans are historical.
        return latestExitPlanModeMessageID == message.id
    }

    var latestExitPlanModeMessageID: UUID? {
        for message in chatState.messages.reversed() {
            if message.isExitPlanModeCall {
                return message.id
            }
            if message.kind == .user {
                return nil
            }
        }
        return nil
    }

    func confirmExitPlanMode(_ message: ChatMessage) {
        guard let project = appState.selectedProject else { return }
        let displayPrompt = "确认执行该方案。"
        let backendPrompt = "Yes, please proceed with the plan as outlined."
        requestTranscriptBottomFollow()
        _ = chatState.send(
            text: displayPrompt,
            backendText: backendPrompt,
            appendRuleText: nil,
            project: project,
            cli: appState.selectedCLI,
            modelID: selectedModelID,
            contextModelID: selectedContextModelID,
            contextWindow: selectedContextWindow,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            sessionMode: appState.selectedMode,
            resumeSessionID: appState.resumeSessionId,
            prioritizeBeforeQueuedRequests: true
        )
    }

    func cancelExitPlanMode(_ message: ChatMessage) {
        if chatState.status.isRunning {
            chatState.interrupt()
        } else {
            // Inform the assistant the plan is rejected so it doesn't silently stall.
            guard let project = appState.selectedProject else { return }
            let displayPrompt = "暂不执行此方案。"
            let backendPrompt = "Please do not proceed with the plan. Stop and wait for new instructions."
            requestTranscriptBottomFollow()
            _ = chatState.send(
                text: displayPrompt,
                backendText: backendPrompt,
                appendRuleText: nil,
                project: project,
                cli: appState.selectedCLI,
                modelID: selectedModelID,
                contextModelID: selectedContextModelID,
                contextWindow: selectedContextWindow,
                permissionMode: permissionMode,
                reasoningEffort: reasoningEffort,
                sessionMode: appState.selectedMode,
                resumeSessionID: appState.resumeSessionId,
                prioritizeBeforeQueuedRequests: true
            )
        }
    }

    func processedHeader(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            Text(message.status.isEmpty ? "assistant" : message.status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("›")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    func messageActionBar(_ message: ChatMessage, alignment: HorizontalAlignment, appendRuleText: String? = nil) -> some View {
        HStack(spacing: 4) {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }

            HStack(spacing: 1) {
                if let appendRuleText {
                    appendRuleCard(appendRuleText)
                }

                if message.kind == .user {
                    iconAction("pencil", help: "编辑") {
                        editMessage(message)
                    }
                }

                iconAction("doc.on.doc", help: "复制消息") {
                    copyMessage(message)
                    showCopyToast()
                }
            }

            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
    }
}
