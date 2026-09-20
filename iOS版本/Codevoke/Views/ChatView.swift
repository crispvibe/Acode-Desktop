import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import ImageIO

private struct ScrollGeometrySnapshot: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

private let maxAttachmentUploadBytes = 10 * 1024 * 1024
private let maxImageSourceBytes = 20 * 1024 * 1024
private let maxImageLongEdge: CGFloat = 2_000

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputFocused = false
    @State private var safeAreaInsets: EdgeInsets = .init()
    @State private var windowSize: CGSize = .zero
    @State private var inputChromeHeight: CGFloat = 92
    @State private var keyboardVisible = false
    @State private var keyboardOverlap: CGFloat = 0
    @State private var isNearBottom = true
    @State private var forceBottomOnNextMessages = true
    @State private var keepBottomPinnedDuringRun = false
    @State private var isAutoScrollScheduled = false
    @State private var directBottomScrollRequest = 0
    @State private var lastScrollViewportHeight: CGFloat = 0
    @State private var keyboardDismissScrollRequest = 0
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var previewingAttachment: RemoteUploadedAttachment?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var queueScrollResetID = UUID()
    private let maxVisibleQueueBubbles = 4
    private let queueBubbleHeight: CGFloat = 58
    private let queueBubbleSpacing: CGFloat = 8
    private let queueOverflowTextHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let observedSize = windowSize
            let visibleSize = observedSize.width > 1 && observedSize.height > 1 ? observedSize : proxy.size
            let topInset = effectiveTopInset(geometryTopInset: proxy.safeAreaInsets.top)
            let bottomInset = max(safeAreaInsets.bottom, proxy.safeAreaInsets.bottom, fallbackBottomInset)
            let topChromeHeight = topInset + 56
            let minimumMessageHeight = min(max(96, visibleSize.height * 0.22), 180)
            let effectiveInputChromeHeight = min(max(inputChromeHeight, 72), max(92, visibleSize.height * 0.45))
            let maximumKeyboardOverlap = max(0, visibleSize.height - topChromeHeight - effectiveInputChromeHeight - minimumMessageHeight)
            let effectiveKeyboardOverlap = min(keyboardOverlap, maximumKeyboardOverlap)
            let messageHeight = max(minimumMessageHeight, visibleSize.height - topChromeHeight - effectiveInputChromeHeight - effectiveKeyboardOverlap)

            ZStack(alignment: .top) {
                messageList
                    .frame(width: visibleSize.width, height: messageHeight)
                    .clipped()
                    .position(x: visibleSize.width / 2, y: topChromeHeight + messageHeight / 2)

                topChrome(topInset: topInset)
                    .frame(width: visibleSize.width, height: topChromeHeight, alignment: .top)
                    .position(x: visibleSize.width / 2, y: topChromeHeight / 2)
                    .zIndex(2)

                queueBarrage(width: visibleSize.width, topChromeHeight: topChromeHeight)
                    .zIndex(2.5)

                attachmentOverlay(width: visibleSize.width, bottomInset: bottomInset)
                    .position(x: visibleSize.width / 2, y: visibleSize.height - effectiveKeyboardOverlap - effectiveInputChromeHeight - 36)
                    .zIndex(2.8)

                inputChrome(bottomInset: bottomInset)
                    .frame(width: visibleSize.width, height: effectiveInputChromeHeight, alignment: .top)
                    .position(x: visibleSize.width / 2, y: visibleSize.height - effectiveKeyboardOverlap - effectiveInputChromeHeight / 2)
                    .zIndex(3)

                attachmentPreviewOverlay
                    .frame(width: visibleSize.width, height: visibleSize.height)
                    .zIndex(4)
            }
            .frame(width: visibleSize.width, height: visibleSize.height)
            .background {
                WindowSafeAreaReader(insets: $safeAreaInsets, size: $windowSize)
                    .frame(width: 0, height: 0)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardVisibility(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            resetKeyboardState(restoreBottomPosition: true)
        }
        .codevokeOnChange(of: inputFocused) { _, isFocused in
            if !isFocused {
                resetKeyboardState(restoreBottomPosition: true)
            }
        }
        .codevokeOnChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if isNearBottom {
                    forceBottomOnNextMessages = true
                }
                viewModel.resumeFromForeground()
            case .background:
                viewModel.suspendForBackground()
            default:
                break
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItems, matching: .images)
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCaptureView { image in
                Task { await uploadCapturedPhoto(image) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleFileImporterResult(result)
        }
        .codevokeOnChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await uploadPhotos(items) }
        }
        .animation(.easeOut(duration: 0.22), value: keyboardVisible)
        .animation(.easeOut(duration: 0.22), value: keyboardOverlap)
    }

    @ViewBuilder
    private func topChrome(topInset: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            VStack(spacing: 0) {
                Color.white
                    .frame(height: topInset)

                topBar
                    .frame(height: 56)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
            .background(Color.white)
        } else {
            let chromeShape = CodevokeBottomRoundedRectangle(radius: 28)
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topInset)

                topBar
                    .frame(height: 56)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: chromeShape)
            .background(Color.white.opacity(0.66), in: chromeShape)
            .overlay {
                chromeShape
                    .stroke(Color.codevokeHairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 8)
        }
    }

    private func inputChrome(bottomInset: CGFloat) -> some View {
        InputBarView(
            text: $viewModel.inputText,
            isFocused: $inputFocused,
            isSending: viewModel.isVisibleRunActive,
            isEnabled: viewModel.canSend,
            attachments: viewModel.attachments,
            isUploadingAttachment: viewModel.isUploadingAttachment,
            takePhoto: {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    isCameraPresented = true
                } else {
                    viewModel.lastError = L10n.string("当前设备不可用相机。")
                }
            },
            selectImage: {
                isPhotoPickerPresented = true
            },
            selectFile: {
                isFileImporterPresented = true
            },
            removeAttachment: { attachment in
                viewModel.removeAttachment(attachment)
            },
            previewAttachment: { attachment in
                if attachment.previewImage != nil {
                    previewingAttachment = attachment
                }
            },
            send: {
                Task {
                    await viewModel.sendCurrentMessage()
                    if viewModel.canSend {
                        inputFocused = true
                    }
                }
            },
            stop: {
                Task { await viewModel.stopGeneration() }
            }
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, keyboardVisible ? 10 : max(12, bottomInset + 8))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: InputChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(InputChromeHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 20 else { return }
            let visibleHeight = windowSize.height > 1 ? windowSize.height : (UIApplication.shared.codevokeActiveWindow?.bounds.height ?? 844)
            let measuredHeight = min(max(height, 72), max(92, visibleHeight * 0.45))
            guard abs(inputChromeHeight - measuredHeight) > 0.5 else { return }
            inputChromeHeight = measuredHeight
        }
    }

    @ViewBuilder
    private func attachmentOverlay(width: CGFloat, bottomInset: CGFloat) -> some View {
        if !viewModel.attachments.isEmpty || viewModel.isUploadingAttachment {
            AttachmentStripView(
                attachments: viewModel.attachments,
                isUploadingAttachment: viewModel.isUploadingAttachment,
                removeAttachment: { attachment in
                    viewModel.removeAttachment(attachment)
                },
                previewAttachment: { attachment in
                    if attachment.previewImage != nil {
                        previewingAttachment = attachment
                    }
                }
            )
            .frame(width: width - 24, height: 64, alignment: .leading)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var attachmentPreviewOverlay: some View {
        if let attachment = previewingAttachment, let image = attachment.previewImage {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        previewingAttachment = nil
                    }

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(windowSize.width * 0.82, 360), maxHeight: min(windowSize.height * 0.46, 420))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.9), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 18)
                    .onTapGesture {
                        previewingAttachment = nil
                    }
            }
        }
    }

    private func updateKeyboardVisibility(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            resetKeyboardState()
            return
        }
        guard let window = UIApplication.shared.codevokeActiveWindow else {
            let fallbackOverlap = max(0, frame.height)
            keyboardOverlap = fallbackOverlap
            keyboardVisible = fallbackOverlap > 0
            return
        }
        let frameInWindow = window.convert(frame, from: nil)
        let intersection = window.bounds.intersection(frameInWindow)
        let isDockedToBottom = !intersection.isNull && intersection.maxY >= window.bounds.maxY - 1
        let overlap = isDockedToBottom ? max(0, intersection.height) : 0
        let visibleOverlap = overlap > max(safeAreaInsets.bottom + 20, 60) ? overlap : 0
        keyboardOverlap = visibleOverlap
        keyboardVisible = visibleOverlap > 0
    }

    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        resetKeyboardState(restoreBottomPosition: true)
    }

    private func resetKeyboardState(restoreBottomPosition: Bool = false) {
        let shouldRestoreBottom = restoreBottomPosition && (keyboardVisible || keyboardOverlap > 0) && isNearBottom
        keyboardVisible = false
        keyboardOverlap = 0
        if shouldRestoreBottom {
            keyboardDismissScrollRequest += 1
        }
    }

    private func effectiveTopInset(geometryTopInset: CGFloat) -> CGFloat {
        let observedTopInset = max(safeAreaInsets.top, geometryTopInset)
        if observedTopInset > 0 {
            return max(0, observedTopInset - 6)
        }
        return fallbackTopInset
    }

    private var fallbackTopInset: CGFloat {
        let statusBarHeight = UIApplication.shared.codevokeStatusBarHeight
        if UIDevice.current.userInterfaceIdiom == .phone {
            return max(statusBarHeight, 56)
        }
        return statusBarHeight
    }

    private var fallbackBottomInset: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return 34
        }
        return 0
    }

    private var topBar: some View {
        ZStack {
            VStack(alignment: .center, spacing: 1) {
                Text(topBarProjectTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                HStack(spacing: 5) {
                    connectionStatusDot
                    Text(topBarDetailText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.codevokeMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 64)
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 8) {
            iconButton("gearshape") {
                viewModel.isSettingsPresented = true
            }

            Spacer()
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 48, height: 48)
            } else {
                iconButton("arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
            }
            }
        }
        .padding(.horizontal, 14)
    }

    private var queuedMessages: [ChatMessage] {
        viewModel.queuedMessages
    }

    private var currentQueuedMessageCount: Int {
        queuedMessages.count
    }

    @ViewBuilder
    private func queueBarrage(width: CGFloat, topChromeHeight: CGFloat) -> some View {
        let allMessages = queuedMessages
        let cardWidth = min(max(228, width * 0.68), 328)
        let overflowCount = hiddenQueuedMessageCount(in: allMessages)

        if allMessages.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: currentQueuedMessageCount > maxVisibleQueueBubbles) {
                        LazyVStack(alignment: .trailing, spacing: queueBubbleSpacing) {
                            Color.clear
                                .frame(height: 0)
                                .id("queue-top")
                            ForEach(Array(allMessages.enumerated()), id: \.element.id) { index, message in
                                queuedMessageBubble(
                                    title: L10n.format("队列 %d", index + 1),
                                    message: message,
                                    isPlaceholder: false
                                )
                            }
                        }
                    }
                    .frame(height: visibleQueueMessagesHeight, alignment: .top)
                    .id(queueScrollResetID)
                    .codevokeOnChange(of: currentQueuedMessageCount) { _, _ in
                        proxy.scrollTo("queue-top", anchor: .top)
                        queueScrollResetID = UUID()
                    }
                    .codevokeOnChange(of: allMessages.first?.id) { _, _ in
                        proxy.scrollTo("queue-top", anchor: .top)
                        queueScrollResetID = UUID()
                    }
                }

                if overflowCount > 0 {
                    Text(L10n.format("+%d 条排队中", overflowCount))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codevokeMuted)
                        .padding(.trailing, 4)
                        .frame(height: queueOverflowTextHeight, alignment: .center)
                        .contextMenu {
                            Button {
                                Task { await viewModel.flushQueueNow() }
                            } label: {
                                Label(L10n.string("发送"), systemImage: "arrow.up")
                            }
                        }
                }
            }
            .frame(width: cardWidth, alignment: .trailing)
            .position(x: width - cardWidth / 2 - 14, y: topChromeHeight + 12 + queueBarrageHeight)
            .allowsHitTesting(true)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: currentQueuedMessageCount)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: allMessages)
        }
    }

    private var queueBarrageHeight: CGFloat {
        guard currentQueuedMessageCount > 0 else { return 0 }
        let overflowHeight = currentQueuedMessageCount > maxVisibleQueueBubbles ? queueOverflowTextHeight + 8 : 0
        return (visibleQueueMessagesHeight + overflowHeight) / 2
    }

    private var visibleQueueMessagesHeight: CGFloat {
        let visibleCount = min(currentQueuedMessageCount, maxVisibleQueueBubbles)
        guard visibleCount > 0 else { return 0 }
        return CGFloat(visibleCount) * queueBubbleHeight + CGFloat(max(0, visibleCount - 1)) * queueBubbleSpacing
    }

    private func hiddenQueuedMessageCount(in messages: [ChatMessage]) -> Int {
        max(0, messages.count - maxVisibleQueueBubbles)
    }

    private func queuedMessageBubble(title: String, message: ChatMessage, isPlaceholder: Bool) -> some View {
        let text = message.text
        let bubbleShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.codevokeInk.opacity(isPlaceholder ? 0.45 : 0.78))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.82), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.codevokeMuted)
                    Text(L10n.key("长按操作"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.codevokeMuted.opacity(0.72))
                }
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.string("空消息") : text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: queueBubbleHeight, maxHeight: queueBubbleHeight, alignment: .leading)
        .background(Color.white, in: bubbleShape)
        .overlay {
            bubbleShape
                .stroke(Color.codevokeLine, lineWidth: 1)
        }
        .clipShape(bubbleShape)
        .contentShape(bubbleShape)
        .shadow(color: .black.opacity(0.11), radius: 18, x: 0, y: 10)
        .contextMenu {
            Button {
                Task { await viewModel.flushQueueNow() }
            } label: {
                Label(L10n.string("发送"), systemImage: "arrow.up")
            }
            Button {
                viewModel.beginEditingQueuedMessage(message)
            } label: {
                Label(L10n.string("编辑"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await viewModel.deleteQueuedMessage(message) }
            } label: {
                Label(L10n.string("删除"), systemImage: "trash")
            }
        }
        .accessibilityLabel(L10n.format("%@，长按可发送、编辑或删除", title))
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.hasMoreMessages || viewModel.isLoadingOlderMessages {
                        olderMessagesLoader
                    }
                    if let error = viewModel.lastError {
                        MessageRowView(message: ChatMessage(kind: .error, text: error, status: "failed"))
                    }
                    if viewModel.isLoadingMessages {
                        loadingMessagesCard
                    }
                    ForEach(viewModel.messageRows) { row in
                        switch row {
                        case .message(let message):
                            MessageRowView(
                                message: message,
                                streamingText: viewModel.streamingText(for: message.id),
                                onEdit: message.kind == .user ? { viewModel.inputText = message.text } : nil,
                                onPermissionDecision: { requestID, decision in
                                    viewModel.respondPermission(requestID: requestID, decision: decision)
                                },
                                onInteractiveSubmit: { response in
                                    viewModel.respondInteractive(response)
                                }
                            )
                                .id(message.id)
                        case .toolGroup(let id, let messages, let toolCount):
                            CollapsibleToolGroup(
                                id: id,
                                messages: messages,
                                toolCount: toolCount,
                                isExpanded: viewModel.isToolGroupExpanded(id),
                                streamingText: { viewModel.streamingText(for: $0) },
                                toggle: { viewModel.toggleToolGroup(id) },
                                onPermissionDecision: { requestID, decision in
                                    viewModel.respondPermission(requestID: requestID, decision: decision)
                                },
                                onInteractiveSubmit: { response in
                                    viewModel.respondInteractive(response)
                                }
                            )
                            .id(id)
                        }
                    }
                    if viewModel.shouldShowThinkingIndicator {
                        ThinkingIndicatorRow()
                            .id("thinking-indicator")
                    }
                    if viewModel.messages.isEmpty, viewModel.lastError == nil, !viewModel.isLoadingMessages {
                        emptyState
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { value in
                    if value.translation.height > 8 {
                        keepBottomPinnedDuringRun = false
                        forceBottomOnNextMessages = false
                    }
                }
            )
            .scrollDismissesKeyboard(.interactively)
            .transaction { $0.animation = nil }
            .background(
                BottomScrollController(
                    request: directBottomScrollRequest,
                    shouldFollowBottom: keepBottomPinnedDuringRun || forceBottomOnNextMessages || isNearBottom
                )
            )
            .codevokeScrollGeometry { snapshot in
                let distanceFromBottom = max(0, snapshot.contentHeight - snapshot.viewportHeight - snapshot.offsetY)
                let nearBottom = distanceFromBottom < 160
                let wasNearBottom = isNearBottom
                let viewportChanged = lastScrollViewportHeight > 0 && abs(snapshot.viewportHeight - lastScrollViewportHeight) > 0.5
                lastScrollViewportHeight = snapshot.viewportHeight
                if isNearBottom != nearBottom {
                    isNearBottom = nearBottom
                }
                if viewportChanged && (keepBottomPinnedDuringRun || forceBottomOnNextMessages || wasNearBottom || nearBottom) {
                    scheduleAutoScrollToBottom(proxy)
                }
                if distanceFromBottom > 320 && !keepBottomPinnedDuringRun {
                    forceBottomOnNextMessages = false
                }

            }
            .codevokeOnChange(of: viewModel.messageListUpdateSignal) { _, signal in
                if signal.lastMessageID != nil {
                    if keepBottomPinnedDuringRun || forceBottomOnNextMessages || isNearBottom {
                        forceBottomOnNextMessages = false
                        scheduleAutoScrollToBottom(proxy)
                    }
                } else {
                    scheduleAutoScrollToBottom(proxy)
                }
            }
            .codevokeOnChange(of: viewModel.streamingTextUpdateSignal) { _, _ in
                if keepBottomPinnedDuringRun || forceBottomOnNextMessages || isNearBottom {
                    scheduleAutoScrollToBottom(proxy)
                }
            }
            .codevokeOnChange(of: viewModel.selectedSession?.id) { _, _ in
                forceBottomOnNextMessages = true
            }
            .codevokeOnChange(of: viewModel.scrollToBottomRequestID) { _, _ in
                forceBottomOnNextMessages = false
                keepBottomPinnedDuringRun = true
                scrollToBottomAfterLayout(proxy)
            }
            .codevokeOnChange(of: inputChromeHeight) { oldHeight, newHeight in
                guard abs(oldHeight - newHeight) > 0.5 else { return }
                if keepBottomPinnedDuringRun || forceBottomOnNextMessages || isNearBottom {
                    scrollToBottomAfterLayout(proxy)
                }
            }
            .codevokeOnChange(of: viewModel.isVisibleRunActive) { _, isActive in
                if !isActive {
                    keepBottomPinnedDuringRun = false
                } else if isNearBottom {
                    keepBottomPinnedDuringRun = true
                }
            }
            .codevokeOnChange(of: keyboardDismissScrollRequest) { _, _ in
                scrollToBottomAfterLayout(proxy)
            }
            .onAppear {
                forceBottomOnNextMessages = true
                scrollToBottomAfterLayout(proxy)
            }
            .codevokeOnChange(of: scenePhase) { _, phase in
                if phase == .active, forceBottomOnNextMessages || isNearBottom {
                    scrollToBottomAfterLayout(proxy)
                }
            }
        }
    }

    private func scrollToBottomAfterLayout(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            scrollToMaterializedBottom(proxy)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollToMaterializedBottom(proxy)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            scrollToMaterializedBottom(proxy)
        }
    }

    private func scheduleAutoScrollToBottom(_ proxy: ScrollViewProxy) {
        guard !isAutoScrollScheduled else { return }
        isAutoScrollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scrollToMaterializedBottom(proxy)
            isAutoScrollScheduled = false
        }
    }

    private func scrollToMaterializedBottom(_ proxy: ScrollViewProxy) {
        if let lastRowID = viewModel.messageRows.last?.id {
            proxy.scrollTo(lastRowID, anchor: .bottom)
        } else if viewModel.shouldShowThinkingIndicator {
            proxy.scrollTo("thinking-indicator", anchor: .bottom)
        }
        proxy.scrollTo("bottom", anchor: .bottom)
        requestDirectBottomScroll()
    }

    private func requestDirectBottomScroll() {
        directBottomScrollRequest = directBottomScrollRequest &+ 1
    }

    private var olderMessagesLoader: some View {
        HStack(spacing: 8) {
            if viewModel.isLoadingOlderMessages {
                ProgressView()
                    .controlSize(.mini)
                Text(L10n.key("加载更早消息…"))
            } else {
                Image(systemName: "arrow.up.circle")
                Text(L10n.key("上滑加载更早消息"))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.codevokeMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .task {
            await viewModel.loadOlderMessagesIfNeeded()
        }
    }

    private var loadingMessagesCard: some View {
        GlassCard(cornerRadius: 22) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.key("加载会话消息中…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.codevokeMuted)
                Spacer()
            }
            .padding(14)
        }
    }

    private var emptyState: some View {
        GlassCard(cornerRadius: 28) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Text(L10n.key("准备开始远程对话"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Text(L10n.key("选择项目后，底部输入框会把消息发送到电脑端 acode。"))
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.codevokeMuted)
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label(L10n.string("重新连接"), systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.black, in: Capsule())
                }
                .buttonStyle(.codevokePress)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 120)
    }

    private var connectionStatusDot: some View {
        let connected = viewModel.effectiveConnectionStatus == "已连接"
        return Circle()
            .fill(connected ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
            .shadow(color: (connected ? Color.green : Color.black).opacity(0.25), radius: 4, x: 0, y: 1)
            .accessibilityLabel(L10n.string(connected ? "已连接" : "未连接"))
    }

    private var topBarDetailText: String {
        L10n.string(viewModel.runtimeStatus.isEmpty ? viewModel.navigationSubtitle : viewModel.runtimeStatus)
    }

    private var topBarProjectTitle: String {
        if let name = viewModel.selectedProject?.name, !name.isEmpty {
            return name
        }
        return "acode"
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.codevokeInk)
                .frame(width: 44, height: 44)
                .codevokeGlass(cornerRadius: 22)
                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.codevokePress)
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await uploadFiles(urls) }
        case .failure(let error):
            viewModel.lastError = error.localizedDescription
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let filename = photoFilename(for: item)
            guard let prepared = preparedImageAttachment(data: data, filename: filename) else { continue }
            await viewModel.uploadAttachment(filename: prepared.filename, data: prepared.data, previewData: prepared.previewData)
        }
    }

    private func uploadCapturedPhoto(_ image: UIImage) async {
        guard let data = resizedImage(image).jpegData(compressionQuality: 0.8), data.count <= maxAttachmentUploadBytes else {
            viewModel.lastError = L10n.string("照片处理失败或超过 10MB。")
            return
        }
        await viewModel.uploadAttachment(filename: "camera-\(UUID().uuidString).jpg", data: data, previewData: data)
    }

    private func uploadFiles(_ urls: [URL]) async {
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let isImage = isImageFile(url)
                if let size = fileSize(for: url) {
                    if isImage && size > maxImageSourceBytes {
                        viewModel.lastError = L10n.string("图片不能超过 20MB。")
                        continue
                    }
                    if !isImage && size > maxAttachmentUploadBytes {
                        viewModel.lastError = L10n.string("附件不能超过 10MB。")
                        continue
                    }
                }
                let data = try Data(contentsOf: url)
                if isImage {
                    guard let prepared = preparedImageAttachment(data: data, filename: url.lastPathComponent) else { continue }
                    await viewModel.uploadAttachment(filename: prepared.filename, data: prepared.data, previewData: prepared.previewData)
                } else {
                    await viewModel.uploadAttachment(filename: url.lastPathComponent, data: data, previewData: nil)
                }
            } catch {
                viewModel.lastError = error.localizedDescription
            }
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           contentType.conforms(to: .image) {
            return true
        }
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func fileSize(for url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private func preparedImageAttachment(data: Data, filename: String) -> (filename: String, data: Data, previewData: Data)? {
        guard data.count <= maxImageSourceBytes else {
            viewModel.lastError = L10n.string("图片不能超过 20MB。")
            return nil
        }
        guard let image = downsampledImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else {
            viewModel.lastError = L10n.string("图片处理失败。")
            return nil
        }
        guard jpeg.count <= maxAttachmentUploadBytes else {
            viewModel.lastError = L10n.string("图片压缩后仍超过 10MB。")
            return nil
        }
        return (filename: jpgFilename(from: filename), data: jpeg, previewData: jpeg)
    }

    private func downsampledImage(data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxImageLongEdge)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: image)
    }

    private func resizedImage(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxImageLongEdge, longest > 0 else { return image }
        let scale = maxImageLongEdge / longest
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func jpgFilename(from filename: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return "\(stem.isEmpty ? UUID().uuidString : stem).jpg"
    }

    private func photoFilename(for item: PhotosPickerItem) -> String {
        let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        return "photo-\(UUID().uuidString).\(fileExtension)"
    }
}

private struct InputChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 92

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

struct WindowSafeAreaReader: UIViewRepresentable {
    @Binding var insets: EdgeInsets
    @Binding var size: CGSize

    func makeUIView(context: Context) -> SafeAreaProbeView {
        let view = SafeAreaProbeView()
        view.onWindowMetricsChange = { uiInsets, uiSize in
            insets = EdgeInsets(
                top: uiInsets.top,
                leading: uiInsets.left,
                bottom: uiInsets.bottom,
                trailing: uiInsets.right
            )
            size = uiSize
        }
        return view
    }

    func updateUIView(_ uiView: SafeAreaProbeView, context: Context) {
        uiView.onWindowMetricsChange = { uiInsets, uiSize in
            insets = EdgeInsets(
                top: uiInsets.top,
                leading: uiInsets.left,
                bottom: uiInsets.bottom,
                trailing: uiInsets.right
            )
            size = uiSize
        }
        uiView.publishWindowMetrics()
    }
}

final class SafeAreaProbeView: UIView {
    var onWindowMetricsChange: ((UIEdgeInsets, CGSize) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        publishWindowMetrics()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        publishWindowMetrics()
    }

    func publishWindowMetrics() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onWindowMetricsChange?(
                self.window?.safeAreaInsets ?? self.safeAreaInsets,
                self.window?.bounds.size ?? self.bounds.size
            )
        }
    }
}

private extension View {
    @ViewBuilder
    func codevokeScrollGeometry(_ action: @escaping (ScrollGeometrySnapshot) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: ScrollGeometrySnapshot.self) { geo in
                ScrollGeometrySnapshot(
                    offsetY: geo.contentOffset.y,
                    contentHeight: geo.contentSize.height,
                    viewportHeight: geo.containerSize.height
                )
            } action: { _, snapshot in
                action(snapshot)
            }
        } else {
            self.background(LegacyScrollMetricsReader(action: action))
        }
    }
}

private struct LegacyScrollMetricsReader: UIViewRepresentable {
    let action: (ScrollGeometrySnapshot) -> Void

    func makeUIView(context: Context) -> LegacyScrollMetricsProbe {
        let view = LegacyScrollMetricsProbe()
        view.onSnapshot = action
        return view
    }

    func updateUIView(_ uiView: LegacyScrollMetricsProbe, context: Context) {
        uiView.onSnapshot = action
        uiView.attachIfNeeded()
    }
}

private struct BottomScrollController: UIViewRepresentable {
    let request: Int
    let shouldFollowBottom: Bool

    func makeUIView(context: Context) -> BottomScrollProbe {
        BottomScrollProbe()
    }

    func updateUIView(_ uiView: BottomScrollProbe, context: Context) {
        uiView.shouldFollowBottom = shouldFollowBottom
        uiView.attachIfNeeded()
        if shouldFollowBottom {
            uiView.performRequest(request)
        } else {
            uiView.cancelPendingScrolls()
        }
    }
}

private final class BottomScrollProbe: UIView {
    var shouldFollowBottom = true
    private weak var observedScrollView: UIScrollView?
    private var lastRequest: Int?
    private var pendingWorkItems: [DispatchWorkItem] = []
    private let retryDelays: [TimeInterval] = [0.0, 0.05, 0.16, 0.35, 0.7]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
    }

    deinit {
        cancelPendingScrolls()
    }

    func attachIfNeeded() {
        guard window != nil else { return }
        if observedScrollView == nil {
            observedScrollView = nearestScrollView()
        }
    }

    func performRequest(_ request: Int) {
        guard lastRequest != request else { return }
        lastRequest = request
        scheduleScrollToBottom()
    }

    func cancelPendingScrolls() {
        pendingWorkItems.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }

    private func scheduleScrollToBottom() {
        guard shouldFollowBottom else { return }
        cancelPendingScrolls()
        for delay in retryDelays {
            let workItem = DispatchWorkItem { [weak self] in
                self?.scrollToBottom()
            }
            pendingWorkItems.append(workItem)
            if delay <= 0 {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }
    }

    private func scrollToBottom() {
        guard shouldFollowBottom else { return }
        guard let scrollView = observedScrollView ?? nearestScrollView() else { return }
        observedScrollView = scrollView
        scrollView.layoutIfNeeded()
        let viewportHeight = scrollView.bounds.height
        guard viewportHeight > 0 else { return }
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - viewportHeight + inset.bottom)
        let target = CGPoint(x: scrollView.contentOffset.x, y: maxY)
        if abs(scrollView.contentOffset.y - target.y) > 0.5 {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    private func nearestScrollView() -> UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }
}

private final class LegacyScrollMetricsProbe: UIView {
    var onSnapshot: ((ScrollGeometrySnapshot) -> Void)?
    private weak var observedScrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
        publishSnapshot()
    }

    func attachIfNeeded() {
        guard window != nil else { return }
        guard let scrollView = nearestScrollView(), scrollView !== observedScrollView else {
            publishSnapshot()
            return
        }
        observedScrollView = scrollView
        observations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.publishSnapshot()
            },
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.publishSnapshot()
            },
            scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.publishSnapshot()
            }
        ]
        publishSnapshot()
    }

    private func nearestScrollView() -> UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    private func publishSnapshot() {
        guard let scrollView = observedScrollView else { return }
        let snapshot = ScrollGeometrySnapshot(
            offsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height
        )
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }
}

extension UIApplication {
    var codevokeActiveWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: { $0.isKeyWindow })
    }

    var codevokeStatusBarHeight: CGFloat {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .statusBarManager?
            .statusBarFrame
            .height ?? 0
    }
}
