import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var chatPanelWidth: CGFloat = 420
    @State private var dragStartChatPanelWidth: CGFloat?
    @State private var isHoveringResizeHandle = false
    @State private var workbenchContentWidth: CGFloat = 0

    /// Bridge between SwiftUI `@AppStorage`-style read/write and `appState.settings`.
    /// We can't use a property wrapper here because `appState` is injected via the
    /// environment, so we hand-roll a getter/setter that both reads + persists.
    private var storedChatPanelWidth: Double {
        get { appState.settings.chatPanelWidth }
        nonmutating set {
            guard appState.settings.chatPanelWidth != newValue else { return }
            appState.updateChatPanelWidth(newValue)
        }
    }

    private let minChatPanelWidth: CGFloat = 260
    private let minEditorWidth: CGFloat = 320
    private let resizeHandleWidth: CGFloat = 12

    var body: some View {
        rootContent
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(minWidth: 1320, minHeight: 760)
        .background(rootWindowBackground)
        .alert("提示", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("好") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert(item: Binding(
            get: { appState.permissionPrompt },
            set: { appState.permissionPrompt = $0 }
        )) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text(prompt.primaryButtonTitle)) {
                    appState.handlePermissionPromptAction(prompt.action)
                },
                secondaryButton: .cancel(Text(prompt.secondaryButtonTitle)) {
                    if let secondaryAction = prompt.secondaryAction {
                        appState.handlePermissionPromptAction(secondaryAction)
                    } else {
                        appState.permissionPrompt = nil
                    }
                }
            )
        }
    }

    private var rootContent: AnyView {
        if appState.showSettings {
            AnyView(SettingsPageView())
        } else {
            AnyView(workbenchLayout)
        }
    }

    private var rootWindowBackground: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            AppTheme.windowTint
        }
        .ignoresSafeArea()
    }

    private var workbenchLayout: some View {
        HStack(spacing: 6) {
            ProjectSidebarView()
                .frame(width: 228)

            workbenchCard
        }
    }

    private var workbenchCard: some View {
        VStack(spacing: 0) {
            EditorTabBarView()

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    EditorAreaView()
                        .frame(minWidth: minEditorWidth, maxWidth: .infinity, maxHeight: .infinity)

                    resizeHandle

                    ChatPanelView()
                        .frame(width: clampedChatPanelWidth(chatPanelWidth, availableWidth: proxy.size.width))
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                            transaction.animation = nil
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
                .onAppear {
                    workbenchContentWidth = proxy.size.width
                    let clampedWidth = clampedChatPanelWidth(CGFloat(storedChatPanelWidth), availableWidth: proxy.size.width)
                    setChatPanelWidth(clampedWidth)
                    storedChatPanelWidth = Double(clampedWidth)
                }
                .onChange(of: proxy.size.width) { _, width in
                    workbenchContentWidth = width
                    let clampedWidth = clampedChatPanelWidth(chatPanelWidth, availableWidth: width)
                    setChatPanelWidth(clampedWidth)
                    if dragStartChatPanelWidth == nil {
                        storedChatPanelWidth = Double(clampedWidth)
                    }
                }
            }
        }
        .background(AppTheme.editorSurface.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .shadow(color: AppTheme.softShadow, radius: 16, y: 8)
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Capsule()
                .fill(isHoveringResizeHandle || dragStartChatPanelWidth != nil ? AppTheme.resizeHandleActive : AppTheme.resizeHandle)
                .frame(width: 3, height: 46)
        }
        .frame(width: resizeHandleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            ResizeHandleInputView(
                onHover: { isHoveringResizeHandle = $0 },
                onDragBegan: {
                    dragStartChatPanelWidth = chatPanelWidth
                },
                onDragChanged: { translationX in
                    let startWidth = dragStartChatPanelWidth ?? chatPanelWidth
                    setChatPanelWidth(clampedChatPanelWidth(startWidth - translationX, availableWidth: workbenchContentWidth))
                },
                onDragEnded: { translationX in
                    let startWidth = dragStartChatPanelWidth ?? chatPanelWidth
                    let finalWidth = clampedChatPanelWidth(startWidth - translationX, availableWidth: workbenchContentWidth)
                    setChatPanelWidth(finalWidth)
                    dragStartChatPanelWidth = nil
                    storedChatPanelWidth = Double(finalWidth)
                }
            )
        }
        .help("拖动调整编辑器和对话卡片宽度")
    }

    private func clampedChatPanelWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let availableMax = availableWidth > 0
            ? max(minChatPanelWidth, availableWidth - minEditorWidth - resizeHandleWidth)
            : max(width, minChatPanelWidth)
        return min(max(width, minChatPanelWidth), availableMax)
    }

    private func setChatPanelWidth(_ width: CGFloat) {
        guard abs(chatPanelWidth - width) >= 0.5 else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chatPanelWidth = width
        }
    }
}

