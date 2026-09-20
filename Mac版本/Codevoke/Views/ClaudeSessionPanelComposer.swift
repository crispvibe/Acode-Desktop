import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ChatPanelView {
    var composer: some View {
        VStack(spacing: 0) {
            if !chatState.queuedRequests.isEmpty {
                queuedRequestsView
            }

            composerCard
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(chatPanelSurface)
    }

    var queuedRequestsView: some View {
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4
        let visibleRows = min(chatState.queuedRequests.count, 3)
        let height = CGFloat(visibleRows) * rowHeight + CGFloat(max(visibleRows - 1, 0)) * rowSpacing

        return ScrollView {
            VStack(spacing: rowSpacing) {
                ForEach(Array(chatState.queuedRequests.enumerated()), id: \.element.id) { index, request in
                    HStack(spacing: 7) {
                        HStack(spacing: 7) {
                            Text("#\(index + 1)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .leading)
                            Text(request.displayText.components(separatedBy: .newlines).first ?? request.displayText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay(QueuedRequestDragSource(id: request.id, previewText: request.displayText))

                        Button {
                            editQueuedRequest(request)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .buttonStyle(MiniIconButtonStyle())
                        .foregroundStyle(.tertiary)
                        .help("编辑队列消息")
                        Button {
                            chatState.cancelQueuedRequest(request.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(MiniIconButtonStyle())
                        .foregroundStyle(.tertiary)
                        .help("删除队列消息")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: rowHeight)
                    .background(AppTheme.toolMutedSurface)
                    .background(NonWindowDraggableArea())
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onDrag {
                        queuedRequestDragProvider(for: request)
                    }
                    .help("拖到输入框编辑")
                }
            }
        }
        .frame(height: height)
    }

    func queuedRequestDragProvider(for request: QueuedChatRequest) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: queuedRequestDragTypeIdentifier, visibility: .all) { completion in
            completion(request.id.uuidString.data(using: .utf8), nil)
            return nil
        }
        provider.suggestedName = request.displayText.components(separatedBy: .newlines).first
        return provider
    }

    var composerCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ChatComposerTextView(
                    text: $draftMessage,
                    hasMarkedText: $composerHasMarkedText,
                    suggestedCommand: $suggestedCommand,
                    measuredHeight: $composerTextHeight,
                    focusRequest: composerFocusRequest,
                    onSubmit: sendMessage,
                    onFilesDropped: appendDroppedPaths,
                    onFilesPasted: appendPastedPaths,
                    onQueuedRequestDropped: { editQueuedRequest($0) }
                )
                    .frame(height: composerTextHeight)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
                    .padding(.bottom, 1)

                if draftMessage.isEmpty && !composerHasMarkedText {
                    Text(editingMessageID == nil ? "输入你的需求" : "编辑上一条消息")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 18)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }

            if !attachedPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedPaths, id: \.self) { path in
                            attachmentPill(title: displayNameForAttachedPath(path), path: path, removable: true) {
                                attachedPaths.removeAll { $0 == path }
                            }
                            .help(path)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }

            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    iconOnlyButton(systemImage: "plus", tint: .secondary, action: openFilesForComposer)

                    selectorButton(title: appState.selectedCLI.displayName, systemImage: "terminal", tint: .primary, picker: .cli, maxTitleWidth: 78)
                    selectorButton(title: permissionMode.shortTitle, systemImage: permissionMode.systemImage, tint: permissionMode.tint, picker: .permission, maxTitleWidth: 30)
                    selectorButton(title: selectedModelTitle, systemImage: "cpu", tint: .primary, picker: .model, maxTitleWidth: 92)
                    selectorButton(title: selectedReasoningTitle, systemImage: "brain.head.profile", tint: .primary, picker: .reasoning, maxTitleWidth: 36)

                    if editingMessageID != nil {
                        Button("取消") {
                            editingMessageID = nil
                            clearComposerText()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                actionButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
        .background(composerCardSurface)
        .background(NonWindowDraggableArea())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .onDrop(of: [queuedRequestDragTypeIdentifier, UTType.fileURL.identifier, UTType.url.identifier], isTargeted: nil, perform: handleDroppedItems)
    }

    func globalPickerLayer(_ picker: ChatPicker) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { activePicker = nil }

            pickerOverlay(picker)
                .padding(.horizontal, 12)
                .padding(.bottom, pickerLayerBottomInset)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        }
    }

    var pickerLayerBottomInset: CGFloat {
        composerTextHeight + 64 + (attachedPaths.isEmpty ? 0 : 30)
    }

    func attachmentPill(title: String, path: String?, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: attachmentIconName(for: title, path: path))
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .lineLimit(1)
                if removable {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.toolMutedSurface)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!removable)
    }

    func attachmentIconName(for title: String, path: String?) -> String {
        let value = (path ?? title).lowercased()
        if title == "粘贴文本" || value.contains("pasted-text-") || value.hasSuffix(".txt") || value.hasSuffix(".md") { return "text.page" }
        if [".png", ".jpg", ".jpeg", ".gif", ".webp", ".tiff"].contains(where: value.hasSuffix) { return "photo" }
        return "paperclip"
    }

    @ViewBuilder
    func pickerOverlay(_ picker: ChatPicker) -> some View {
        switch picker {
        case .cli:
            customPickerPanel(picker)
                .padding(.leading, 42)
        case .permission:
            customPickerPanel(picker)
                .padding(.leading, 128)
        case .model:
            HStack {
                Spacer(minLength: 0)
                customPickerPanel(picker)
                    .padding(.trailing, 52)
            }
        case .reasoning:
            HStack {
                Spacer(minLength: 0)
                customPickerPanel(picker)
                    .padding(.trailing, 18)
            }
        }
    }

    func customPickerPanel(_ picker: ChatPicker) -> some View {
        let panelMaxWidth: CGFloat = picker == .model ? 300 : (picker == .reasoning ? 160 : 220)

        return VStack(alignment: .leading, spacing: 4) {
            switch picker {
            case .cli:
                ForEach(CLIType.visibleCases) { cli in
                    pickerOption(title: cli.displayName, isSelected: appState.selectedCLI == cli) {
                        if appState.selectedCLI != cli {
                            appState.selectedCLI = cli
                            appState.startNewChat()
                        }
                        selectedModelID = persistedModelID(for: cli)
                        reasoningEffort = persistedReasoningEffort(for: cli)
                        normalizeSelectedModel()
                        normalizeReasoningEffort()
                        persistChatSelection()
                        activePicker = nil
                    }
                }
            case .permission:
                ForEach(ChatPermissionMode.allCases) { mode in
                    pickerOption(title: mode.title, isSelected: permissionMode == mode) {
                        selectPermissionMode(mode)
                    }
                }
            case .model:
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(modelService.options(for: appState.selectedCLI)) { model in
                            pickerOption(title: model.title, isSelected: selectedModelID == model.id) {
                                selectedModelID = model.id
                                syncSelectedContextWindow()
                                persistChatSelection()
                                activePicker = nil
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 220)
                Divider().opacity(0.28)
                HStack(spacing: 6) {
                    TextField("添加模型 ID", text: $customModelInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(AppTheme.toolSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                    Button("添加") {
                        addCustomModel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(AppTheme.toolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                    .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .reasoning:
                ForEach(ChatReasoningEffort.options(for: appState.selectedCLI, modelID: selectedModelID)) { effort in
                    pickerOption(title: effort.menuTitle(for: appState.selectedCLI, modelID: selectedModelID), isSelected: reasoningEffort == effort) {
                        selectReasoningEffort(effort)
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: panelMaxWidth, alignment: .leading)
        .background(AppTheme.toolSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    func pickerOption(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? Color.primary.opacity(0.78) : Color.secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(isSelected ? AppTheme.toolMutedSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.weakHairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    func selectorButton(
        title: String,
        systemImage: String,
        tint: Color,
        picker: ChatPicker,
        maxTitleWidth: CGFloat? = nil
    ) -> some View {
        let titleWidth = selectorTitleFrameWidth(for: title, maxTitleWidth: maxTitleWidth)

        return Button {
            activePicker = activePicker == picker ? nil : picker
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 10)
                    .foregroundStyle(tint.opacity(0.7))
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: titleWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Color.primary.opacity(0.68))
            .frame(minHeight: 22)
            .padding(.vertical, 3)
            .padding(.horizontal, 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    func selectorTitleFrameWidth(for title: String, maxTitleWidth: CGFloat?) -> CGFloat? {
        guard let maxTitleWidth else { return nil }
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let measuredWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return min(max(measuredWidth, 8), maxTitleWidth)
    }

    var actionButton: some View {
        Button(action: primaryAction) {
            Image(systemName: primaryActionIconName)
                .font(.system(size: primaryActionIconName == "pause.fill" ? 11 : 12, weight: .semibold))
        }
        .buttonStyle(CircularIconButtonStyle(size: 24, background: actionButtonBackground, border: AppTheme.hairline))
        .padding(2)
        .contentShape(Rectangle())
        .foregroundStyle(actionButtonForeground)
        .disabled((!canSend && chatState.queuedRequests.isEmpty && !chatState.status.isRunning) || (!canSend && chatState.hasPendingPlanConfirmation))
        .help(primaryActionHelp)
    }

    var primaryActionIconName: String {
        if shouldSendQueuedMessageNow { return "arrow.up" }
        return chatState.status.isRunning && !canSend && !chatState.isMirroringRemoteSession ? "pause.fill" : "arrow.up"
    }

    var primaryActionHelp: String {
        if chatState.firstWaitingInteractiveRequest != nil && canSend { return "用输入内容回答选择题" }
        if chatState.hasPendingPlanConfirmation && !canSend { return "等待用户确认方案" }
        if shouldSendQueuedMessageNow { return "发送队首队列消息" }
        if chatState.isMirroringRemoteSession {
            return canSend ? "加入队列，等待 iOS 远程任务结束后发送" : "iOS 远程任务运行中"
        }
        if chatState.status.isRunning {
            return canSend ? "加入队列" : "停止当前任务"
        }
        if !chatState.queuedRequests.isEmpty && canSend { return "加入队列" }
        return "发送"
    }

    var actionButtonBackground: Color {
        chatState.status.isRunning || canSend || !chatState.queuedRequests.isEmpty ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035)
    }

    var actionButtonForeground: Color {
        chatState.status.isRunning || canSend || !chatState.queuedRequests.isEmpty ? Color.secondary : Color.secondary.opacity(0.55)
    }

    func primaryAction() {
        if shouldSendQueuedMessageNow {
            sendQueuedMessageNow()
        } else if chatState.status.isRunning && !canSend && !chatState.isMirroringRemoteSession {
            chatState.interrupt()
        } else {
            sendMessage()
        }
    }

    var shouldSendQueuedMessageNow: Bool {
        !canSend && !chatState.queuedRequests.isEmpty && !chatState.isMirroringRemoteSession && !chatState.hasPendingPlanConfirmation
    }

    var projectName: String {
        if let project = appState.selectedProject { return project.name }
        if appState.selectedHistoryProjectPath?.nonEmptyTrimmed != nil { return "未添加项目历史" }
        return "未选择项目"
    }

    var projectPath: String {
        if let project = appState.selectedProject { return project.path }
        if let historyPath = appState.selectedHistoryProjectPath?.nonEmptyTrimmed { return "请先添加项目：\(historyPath)" }
        return "请选择项目目录"
    }

    var currentProjectHistorySessions: [CLIHistorySession] {
        guard let projectPath = appState.selectedProject?.path ?? appState.selectedHistoryProjectPath?.nonEmptyTrimmed else { return [] }
        let projectKey = projectHistoryKey(for: projectPath)
        let selectedCLI = appState.selectedCLI.visibleValue
        let diskSessions = appState.cliHistory.filter { session in
            guard session.cli.visibleValue == selectedCLI,
                  let sessionProjectPath = session.projectPath else { return false }
            return projectHistoryKey(for: sessionProjectPath) == projectKey
        }
        if let draft = draftHistorySession {
            return [draft] + diskSessions
        }
        return diskSessions
    }

    // A brand-new, not-yet-sent conversation has no on-disk session file, so it would be invisible
    // in the history list until the first message lands. Surface a synthetic "新对话" row for it so
    // the conversation appears in the left list the moment it is created.
    var draftHistorySession: CLIHistorySession? {
        guard let project = appState.selectedProject else { return nil }
        guard appState.selectedMode == .newSession,
              appState.selectedCLIHistoryID == nil,
              chatState.messages.isEmpty,
              !chatState.hasLiveRun else { return nil }
        return CLIHistorySession(
            cli: appState.selectedCLI.visibleValue,
            sessionId: CLIHistorySession.draftSessionId,
            title: "新对话",
            projectPath: project.path,
            storageKey: nil,
            storagePath: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func normalizedPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    func projectHistoryKey(for projectPath: String) -> String {
        normalizedPath(projectPath)
    }

    var selectedModelTitle: String {
        modelService.title(for: selectedModelID, cli: appState.selectedCLI)
    }

    var selectedReasoningTitle: String {
        reasoningEffort.menuTitle(for: appState.selectedCLI, modelID: selectedModelID)
    }

    var composerDraftKey: String {
        if let historyID = appState.selectedCLIHistoryID {
            return "history:\(historyID)"
        }
        let sessionID = appState.resumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.selectedMode == .resume, !sessionID.isEmpty {
            return "history:\(appState.selectedCLI.visibleValue.rawValue):\(sessionID)"
        }
        let projectPath = appState.selectedHistoryProjectPath ?? appState.selectedProject?.path ?? "none"
        return "new:\((projectPath as NSString).standardizingPath)"
    }

    var canSend: Bool {
        let hasDraft = !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachedPaths = attachedPaths.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return appState.selectedProject != nil && (hasDraft || hasAttachedPaths)
    }

    var capabilityText: String {
        let cli = appState.selectedCLI.visibleValue
        guard let capability = chatState.capabilities[cli] else { return "正在检测 \(cli.displayName)…" }
        if let error = capability.errorMessage { return error }
        return "\(cli.displayName) · \(capability.version ?? "未知版本") · \(capability.executablePath ?? cli.executable)"
    }

    func startNewChat() {
        let previousState = chatState
        if !previousState.hasLiveRun {
            previousState.discardQueuedRequestsForNewChat()
        }
        appState.startNewChat(for: appState.selectedProject)
    }

    func openCommandInTerminal() {
        appState.openClaudeInTerminal()
    }

    func showCopyToast() {
        withAnimation(.easeOut(duration: 0.12)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.18)) {
                showCopiedToast = false
            }
        }
    }

    func sendMessage() {
        // If a 选择题 (AskUserQuestion) is awaiting an answer, route the typed text into the
        // interactive response (custom input) instead of starting/queuing a NEW turn — otherwise
        // the CLI stays blocked on its control_response and the run appears to hang.
        let interactiveAnswer = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !interactiveAnswer.isEmpty, chatState.firstWaitingInteractiveRequest != nil {
            chatState.answerPendingInteractiveWithCustomText(interactiveAnswer)
            clearComposerText()
            attachedPaths.removeAll()
            return
        }
        if !canSend && !chatState.queuedRequests.isEmpty {
            sendQueuedMessageNow()
            return
        }
        guard canSend else { return }
        if let editingMessageID, !chatState.status.isRunning {
            chatState.removeMessageThread(editingMessageID)
            self.editingMessageID = nil
        }
        let displayPrompt = displayComposedPrompt
        let backendDisplayPrompt = composedPrompt
        let appendRuleText = activeAppendRuleText
        let attachments = attachmentsForCurrentDraft()
        let didStart = chatState.send(
            text: displayPrompt,
            backendText: backendPrompt(backendDisplayPrompt, appendRuleText: appendRuleText),
            appendRuleText: appendRuleText,
            attachments: attachments,
            project: appState.selectedProject,
            cli: appState.selectedCLI,
            modelID: selectedModelID,
            contextModelID: selectedContextModelID,
            contextWindow: selectedContextWindow,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            sessionMode: appState.selectedMode,
            resumeSessionID: appState.resumeSessionId
        )
        if didStart {
            clearComposerText()
            attachedPaths.removeAll()
        }
        // Request the bottom-follow AFTER the message is appended so the scroll cascade has
        // the new trailing row to anchor on, rather than scrolling the old/empty content.
        requestTranscriptBottomFollow()
    }

    func sendQueuedMessageNow() {
        guard !chatState.queuedRequests.isEmpty else { return }
        requestTranscriptBottomFollow()
        chatState.interrupt(startQueuedAfterStop: true)
    }

    func requestTranscriptBottomFollow() {
        transcriptUserIntent = .followBottom
        isTranscriptAtBottom = true
        transcriptScrollKick = UUID()
        requestNSScrollToBottom()
    }

    func requestNSScrollToBottom() {
        nsScrollToBottomToken &+= 1
    }

    func cancelPendingTranscriptBottomScrolls() {
        pendingTranscriptScrollTask?.cancel()
        pendingTranscriptScrollTask = nil
        pendingStreamingScrollTask?.cancel()
        pendingStreamingScrollTask = nil
    }

    func scrollTranscriptIfFollowing(_ proxy: ScrollViewProxy, animated: Bool) {
        guard transcriptUserIntent == .followBottom else { return }
        scrollTranscriptToBottomOnce(proxy)
    }

    func scheduleStreamingScrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard transcriptUserIntent == .followBottom else { return }
        pendingStreamingScrollTask?.cancel()
        pendingStreamingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            scrollTranscriptToBottomOnce(proxy)
        }
    }

    func scheduleLayoutScrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard transcriptUserIntent == .followBottom else { return }
        pendingStreamingScrollTask?.cancel()
        pendingStreamingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            scrollTranscriptToBottomOnce(proxy)
        }
    }

    /// A single, gentle scroll to the bottom anchor (the trailing spacer). Targeting the SAME
    /// anchor as the AppKit observer (which scrolls to content max, incl. the spacer) keeps the
    /// two engines from fighting over a 24pt difference, and preserves the gap between the last
    /// row and the input box. Used while following during streaming / on content changes.
    func scrollTranscriptToBottomOnce(_ proxy: ScrollViewProxy) {
        guard transcriptUserIntent == .followBottom else { return }
        proxy.scrollTo(transcriptBottomID, anchor: .bottom)
    }

    func scrollTranscriptToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // The 6-step retry loop is reserved for OPEN / conversation-switch / explicit kicks,
        // where the LazyVStack is still materializing rows and a single scroll may land before
        // the trailing rows exist. Targets the bottom spacer (same anchor as the AppKit engine)
        // so the two don't tug the offset back and forth.
        pendingTranscriptScrollTask?.cancel()
        pendingTranscriptScrollTask = Task { @MainActor in
            for (index, delay) in [16_000_000, 90_000_000, 180_000_000, 320_000_000, 600_000_000, 1_000_000_000].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                guard !Task.isCancelled, transcriptUserIntent == .followBottom else { return }
                if animated && index == 0 {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            }
        }
    }

    func scrollTranscriptToPendingTarget(_ proxy: ScrollViewProxy) {
        guard let targetID = transcriptScrollTargetID else { return }
        pendingTranscriptScrollTask?.cancel()
        pendingTranscriptScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            proxy.scrollTo(targetID, anchor: .top)
            transcriptScrollTargetID = nil
        }
    }

    func clearComposerText() {
        draftMessage = ""
        composerHasMarkedText = false
        composerTextHeight = composerMinimumTextHeight
        clearSuggestedCommand()
        persistComposerDraft("")
    }


    func switchComposerDraft(from oldKey: String, to newKey: String) {
        persistComposerDraft(draftMessage, for: oldKey)
        ChatSessionStore.flushPendingDrafts()
        attachedPaths.removeAll()
        activateComposerDraftKey(newKey)
    }

    func activateComposerDraftKey(_ key: String) {
        activeComposerDraftKey = key
        draftMessage = ChatSessionStore.draft(for: key)
        composerHasMarkedText = false
        composerTextHeight = composerMinimumTextHeight
        clearSuggestedCommand()
    }

    func persistComposerDraft(_ text: String, for key: String? = nil) {
        let draftKey = key ?? activeComposerDraftKey
        guard !draftKey.isEmpty else { return }
        try? ChatSessionStore.saveDraft(text, for: draftKey)
    }

    var composedPrompt: String {
        buildComposedPrompt()
    }

    var displayComposedPrompt: String {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "已附加文件" : text
    }

    func buildComposedPrompt() -> String {
        var parts = [draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)]
        let paths = attachedPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !paths.isEmpty {
            parts.append("Attached paths:\n" + paths.joined(separator: "\n"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func attachmentsForCurrentDraft() -> [ChatMessageAttachment] {
        attachedPaths.compactMap { attachment(for: $0) }
    }

    func attachment(for rawPath: String) -> ChatMessageAttachment? {
        let standardizedPath = (rawPath as NSString).standardizingPath
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

    func isImageAttachment(_ url: URL) -> Bool {
        let lowercased = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic", "heif"].contains(lowercased)
    }

    func thumbnailData(for url: URL) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    func displayNameForAttachedPath(_ path: String) -> String {
        let standardizedPath = (path as NSString).standardizingPath
        let fileName = URL(fileURLWithPath: standardizedPath).lastPathComponent
        return fileName.isEmpty ? "附件" : fileName
    }

    var activeAppendRuleText: String? {
        guard appState.settings.appendRuleEnabled else { return nil }
        return appState.settings.appendRuleText.nonEmptyTrimmed
    }

    func backendPrompt(_ displayPrompt: String, appendRuleText: String?) -> String {
        guard let appendRuleText else { return displayPrompt }
        return "\(displayPrompt)\n\n附加规则：\n\(appendRuleText)"
    }

    func cycleThinkingPhrase() {
        let currentIndex = Self.thinkingPhrases.firstIndex(of: loadingThinkingText) ?? -1
        let next = Self.thinkingPhrases[(currentIndex + 1) % Self.thinkingPhrases.count]
        withAnimation(.easeInOut(duration: 0.18)) {
            loadingThinkingText = next
        }
    }

    func clearSuggestedCommand() {
        suggestedCommand = nil
    }

    func openFilesForComposer() {
        activePicker = nil

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            panel.urls.forEach { appendDroppedPath($0.path) }
        }
    }

    func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(queuedRequestDragTypeIdentifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: queuedRequestDragTypeIdentifier, options: nil) { item, _ in
                    if let id = queuedRequestID(from: item) {
                        DispatchQueue.main.async {
                            editQueuedRequest(id)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let path = pathFromDroppedItem(item) {
                        appendDroppedPath(path)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let path = pathFromDroppedItem(item) {
                        appendDroppedPath(path)
                    }
                }
            }
        }
        return handled
    }

    func queuedRequestID(from item: NSSecureCoding?) -> UUID? {
        if let data = item as? Data,
           let raw = String(data: data, encoding: .utf8) {
            return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let raw = item as? String {
            return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func pathFromDroppedItem(_ item: NSSecureCoding?) -> String? {
        if let url = item as? URL, url.isFileURL {
            return url.path
        }
        if let data = item as? Data,
           let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           url.isFileURL {
            return url.path
        }
        return nil
    }

    func appendDroppedPaths(_ paths: [String]) {
        DispatchQueue.main.async {
            for path in paths { insertReferencePathIntoDraft(path) }
        }
    }

    func appendPastedPaths(_ paths: [String]) -> Bool {
        appendAttachedPathCandidates(paths)
    }

    func appendDroppedPath(_ path: String) {
        DispatchQueue.main.async {
            insertReferencePathIntoDraft(path)
        }
    }

    /// Insert a dragged/dropped file or image as plain, selectable absolute-path text into the
    /// composer — prefixed "图片"/"文件" so the model knows what it is — instead of a separate
    /// attachment chip. Keeping it as text means the path stays copyable and unambiguous.
    func insertReferencePathIntoDraft(_ rawPath: String) {
        guard let standardized = standardizedExistingPath(from: rawPath) else { return }
        let label = Self.isImageReferencePath(standardized) ? "图片" : "文件"
        let token = "\(label) \(standardized)"
        if draftMessage.isEmpty {
            draftMessage = token + " "
        } else if draftMessage.hasSuffix(" ") || draftMessage.hasSuffix("\n") {
            draftMessage += token + " "
        } else {
            draftMessage += " " + token + " "
        }
        persistComposerDraft(draftMessage)
    }

    static func isImageReferencePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff", "tif", "svg", "ico"].contains(ext)
    }

    @discardableResult
    func appendAttachedPathCandidates(_ paths: [String]) -> Bool {
        var didAppend = false
        for path in paths {
            guard let standardized = standardizedExistingPath(from: path), !attachedPaths.contains(standardized) else { continue }
            attachedPaths.append(standardized)
            didAppend = true
        }
        return didAppend
    }

    func standardizedExistingPath(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = normalizedPastedPath(trimmed)
        let candidates: [String]
        if path.hasPrefix("/") {
            candidates = [path]
        } else if let projectPath = appState.selectedProject?.path {
            candidates = [
                URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(path).path,
                path
            ]
        } else {
            candidates = [path]
        }
        return candidates
            .map { ($0 as NSString).standardizingPath }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    func normalizedPastedPath(_ value: String) -> String {
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value.hasPrefix("~") ? (value as NSString).expandingTildeInPath : value
    }


    func copyMessage(_ message: ChatMessage) {
        copyText(chatState.streamingTextStore.text(for: message.id) ?? message.text)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func editQueuedRequest(_ request: QueuedChatRequest) {
        draftMessage = editableQueuedText(request.displayText)
        clearSuggestedCommand()
        attachedPaths = request.attachments.map(\.path)
        if attachedPaths.isEmpty {
            attachedPaths = queuedAttachmentPaths(request.text)
        }
        chatState.cancelQueuedRequest(request.id)
        composerFocusRequest += 1
    }

    func editQueuedRequest(_ id: UUID) {
        guard let request = chatState.queuedRequests.first(where: { $0.id == id }) else { return }
        editQueuedRequest(request)
    }

    func editableQueuedText(_ text: String) -> String {
        splitAttachedPathsBlock(from: text).text
    }

    func queuedAttachmentPaths(_ text: String) -> [String] {
        splitAttachedPathsBlock(from: text).attachments
    }

    func splitAttachedPathsBlock(from text: String) -> (text: String, attachments: [String]) {
        let marker = "Attached paths:\n"
        let body: String
        let attachmentText: String
        if let range = text.range(of: "\n\n" + marker) {
            body = String(text[..<range.lowerBound])
            attachmentText = String(text[range.upperBound...])
        } else if text.hasPrefix(marker) {
            body = ""
            attachmentText = String(text.dropFirst(marker.count))
        } else {
            let value = text.components(separatedBy: "\n\nCurrent file:").first ?? text
            return (value.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let attachmentBody = attachmentText.components(separatedBy: "\n\nCurrent file:").first ?? attachmentText
        let attachments = attachmentBody.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
    }

    func editMessage(_ message: ChatMessage) {
        guard !chatState.status.isRunning else { return }
        editingMessageID = message.id
        draftMessage = message.text
        clearSuggestedCommand()
    }

    func addCustomModel() {
        let id = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        modelService.addCustomModel(id: id, cli: appState.selectedCLI)
        selectedModelID = id
        customModelInput = ""
        syncSelectedContextWindow()
        persistChatSelection()
        activePicker = nil
    }

    func applyPersistedChatSelection() {
        permissionMode = appState.settings.chatPermissionMode
        selectedModelID = persistedModelID(for: appState.selectedCLI)
        normalizeSelectedModel()
        reasoningEffort = persistedReasoningEffort(for: appState.selectedCLI)
        normalizeReasoningEffort()
    }

    func persistedModelID(for cli: CLIType) -> String {
        cli.visibleValue == .codex ? appState.settings.selectedCodexModelID : appState.settings.selectedClaudeModelID
    }

    func persistedReasoningEffort(for cli: CLIType) -> ChatReasoningEffort {
        cli.visibleValue == .codex ? appState.settings.selectedCodexReasoningEffort : appState.settings.selectedClaudeReasoningEffort
    }

    func persistChatSelection() {
        appState.saveChatSelection(
            cli: appState.selectedCLI,
            permissionMode: permissionMode,
            modelID: selectedModelID,
            reasoningEffort: reasoningEffort
        )
    }

    func selectPermissionMode(_ mode: ChatPermissionMode) {
        guard mode != permissionMode else {
            activePicker = nil
            return
        }
        if mode == .fullAccess, !confirmFullAccessMode() {
            activePicker = nil
            return
        }
        permissionMode = mode
        persistChatSelection()
        activePicker = nil
    }

    func selectReasoningEffort(_ effort: ChatReasoningEffort) {
        reasoningEffort = effort
        normalizeReasoningEffort()
        persistChatSelection()
        activePicker = nil
    }

    func confirmFullAccessMode() -> Bool {
        let alert = NSAlert()
        alert.messageText = "启用完全访问权限？"
        alert.informativeText = "Claude 会使用 bypassPermissions，Codex 会使用 danger-full-access，可能跳过文件修改和命令执行确认。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func normalizeSelectedModel() {
        let options = modelService.options(for: appState.selectedCLI)
        if !options.contains(where: { $0.id == selectedModelID }) {
            let executionModelID = ChatModelCatalog.executionModelID(for: selectedModelID)
            selectedModelID = options.first {
                ChatModelCatalog.executionModelID(for: $0.id) == executionModelID
            }?.id ?? modelService.defaultModelID(for: appState.selectedCLI)
        }
        syncSelectedContextWindow()
    }

    func normalizeReasoningEffort() {
        let options = ChatReasoningEffort.options(for: appState.selectedCLI, modelID: selectedModelID)
        if !options.contains(reasoningEffort) {
            reasoningEffort = options.contains(.xhigh) ? .xhigh : .high
        }
    }

    func resetReasoningEffortToConfiguredDefault() {
        reasoningEffort = modelService.defaultReasoningEffort(for: appState.selectedCLI)
        normalizeReasoningEffort()
    }

    var selectedContextModelID: String {
        modelService.contextModelID(for: selectedModelID, cli: appState.selectedCLI)
    }

    var selectedContextWindow: Int {
        modelService.contextWindow(for: selectedContextModelID, cli: appState.selectedCLI)
    }

    func syncSelectedContextWindow() {
        chatState.syncContextWindow(
            modelID: selectedContextModelID,
            cli: appState.selectedCLI,
            contextWindow: selectedContextWindow
        )
    }

    func iconOnlyButton(systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
        }
        .buttonStyle(CircularIconButtonStyle(size: 28))
        .foregroundStyle(tint)
    }

    func iconAction(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .medium))
        }
        .buttonStyle(MiniIconButtonStyle(width: 18, height: 18, cornerRadius: 6))
        .foregroundStyle(.tertiary)
        .help(help)
    }
}
