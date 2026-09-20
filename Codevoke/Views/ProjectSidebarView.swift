import SwiftUI

struct ProjectSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var chatRuntimeStore: ChatRuntimeStore
    @State private var projectToRemove: ProjectItem?
    @State private var historyToRemove: CLIHistorySession?
    @State private var expandedProjectID: UUID?
    @State private var sessionsByProjectKeyCache: [String: [CLIHistorySession]] = [:]
    @State private var projectSectionHeight: CGFloat = 252
    @State private var dragStartProjectSectionHeight: CGFloat?
    @State private var isHoveringProjectResizeHandle = false
    @State private var hasLoadedProjectSectionHeight = false

    private let minProjectSectionHeight: CGFloat = 150
    private let minFileSectionHeight: CGFloat = 180
    private let projectFileResizeHandleHeight: CGFloat = 12
    private let sidebarFooterReservedHeight: CGFloat = 46

    private var storedProjectSectionHeight: Double {
        get { appState.settings.sidebarProjectSectionHeight }
        nonmutating set {
            guard appState.settings.sidebarProjectSectionHeight != newValue else { return }
            appState.updateSidebarProjectSectionHeight(newValue)
        }
    }

    var body: some View {
        GlassPanel {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    projectSection
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(height: clampedProjectSectionHeight(projectSectionHeight, availableHeight: proxy.size.height), alignment: .top)

                    projectFileResizeHandle(availableHeight: proxy.size.height)

                    fileSection
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 0)
                        .frame(minHeight: minFileSectionHeight, maxHeight: .infinity, alignment: .top)

                    Divider().opacity(0.24)
                        .padding(.horizontal, 14)

                    settingsButton
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
                .onAppear {
                    syncProjectSectionHeight(availableHeight: proxy.size.height, shouldPersist: true)
                }
                .onChange(of: proxy.size.height) { _, _ in
                    syncProjectSectionHeight(availableHeight: proxy.size.height, shouldPersist: dragStartProjectSectionHeight == nil)
                }
            }
        }
        .onAppear {
            chatRuntimeStore.refreshPersistedActivities()
            expandedProjectID = appState.selectedProjectID
            rebuildSessionsByProjectKeyCache()
        }
        .onReceive(appState.$cliHistory) { _ in
            rebuildSessionsByProjectKeyCache()
        }
        .onChange(of: appState.selectedCLI) { _, _ in
            rebuildSessionsByProjectKeyCache()
        }
        .onChange(of: appState.selectedProjectID) { _, selectedProjectID in
            expandedProjectID = selectedProjectID
        }
        .alert("移除项目？", isPresented: Binding(
            get: { projectToRemove != nil },
            set: { if !$0 { projectToRemove = nil } }
        )) {
            Button("取消", role: .cancel) { projectToRemove = nil }
            Button("移除", role: .destructive) {
                if let project = projectToRemove {
                    appState.removeProject(project)
                }
                projectToRemove = nil
            }
        } message: {
            Text("只会从 Codevoke 的项目列表移除“\(projectToRemove?.name ?? "该项目")”，不会删除磁盘上的文件夹。")
        }
        .alert("删除历史会话？", isPresented: Binding(
            get: { historyToRemove != nil },
            set: { if !$0 { historyToRemove = nil } }
        )) {
            Button("取消", role: .cancel) { historyToRemove = nil }
            Button("删除") {
                let session = historyToRemove
                historyToRemove = nil
                if let session {
                    chatRuntimeStore.removeRuntime(for: session, discardingState: appState.selectedCLIHistoryID == session.id)
                    appState.deleteCLIHistory(session)
                }
            }
        } message: {
            let activity = historyToRemove.flatMap { chatRuntimeStore.activity(for: $0) }
            if let activity, activity.status.isRunning {
                Text("该会话仍在运行，删除后会停止后台任务并移除本地历史。")
            } else {
                Text("会从本地 CLI 历史中删除“\(historyToRemove?.title ?? "该会话")”。")
            }
        }
    }

    private var projectSection: some View {
        let sessionsByKey = sessionsByProjectKeyCache
        let selectedSessionID = appState.isChatHistorySelectionVisuallySuppressed ? nil : appState.selectedCLIHistoryID
        return VStack(spacing: 12) {
            HStack {
                Text("项目")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: appState.addProject) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CircularIconButtonStyle(size: 30, background: AppTheme.controlSurface, border: AppTheme.hairline))
            }

            if appState.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("添加一个项目开始")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.projects) { project in
                            let sessions = sessionsByKey[projectHistoryKey(for: project.path), default: []]
                            ProjectRow(
                                project: project,
                                sessions: sessions,
                                selectedSessionID: selectedSessionID,
                                activityForSession: { chatRuntimeStore.activity(for: $0) },
                                isSelected: project.id == appState.selectedProjectID,
                                onSelect: { toggleProjectExpansion(project, latestSession: sessions.first) },
                                onRemove: { projectToRemove = project },
                                onSelectSession: { appState.selectCLIHistory($0) },
                                onRemoveSession: { historyToRemove = $0 }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func projectFileResizeHandle(availableHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Rectangle()
                .fill(AppTheme.weakHairline)
                .frame(height: 1)
                .padding(.horizontal, 14)
            Capsule()
                .fill(isHoveringProjectResizeHandle || dragStartProjectSectionHeight != nil ? AppTheme.resizeHandleActive : AppTheme.resizeHandle)
                .frame(width: 46, height: 3)
        }
        .frame(height: projectFileResizeHandleHeight)
        .contentShape(Rectangle())
        .overlay {
            ResizeHandleInputView(
                axis: .vertical,
                onHover: { isHoveringProjectResizeHandle = $0 },
                onDragBegan: {
                    dragStartProjectSectionHeight = projectSectionHeight
                },
                onDragChanged: { translationY in
                    let startHeight = dragStartProjectSectionHeight ?? projectSectionHeight
                    setProjectSectionHeight(clampedProjectSectionHeight(startHeight - translationY, availableHeight: availableHeight))
                },
                onDragEnded: { translationY in
                    let startHeight = dragStartProjectSectionHeight ?? projectSectionHeight
                    let finalHeight = clampedProjectSectionHeight(startHeight - translationY, availableHeight: availableHeight)
                    setProjectSectionHeight(finalHeight)
                    dragStartProjectSectionHeight = nil
                    storedProjectSectionHeight = Double(finalHeight)
                }
            )
        }
        .help("拖动调整项目和文件区域高度")
    }

    private func clampedProjectSectionHeight(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let availableMax = availableHeight > 0
            ? max(minProjectSectionHeight, availableHeight - minFileSectionHeight - projectFileResizeHandleHeight - sidebarFooterReservedHeight)
            : max(height, minProjectSectionHeight)
        return min(max(height, minProjectSectionHeight), availableMax)
    }

    private func setProjectSectionHeight(_ height: CGFloat) {
        guard abs(projectSectionHeight - height) >= 0.5 else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            projectSectionHeight = height
        }
    }

    private func syncProjectSectionHeight(availableHeight: CGFloat, shouldPersist: Bool) {
        let sourceHeight = hasLoadedProjectSectionHeight ? projectSectionHeight : CGFloat(storedProjectSectionHeight)
        let clampedHeight = clampedProjectSectionHeight(sourceHeight, availableHeight: availableHeight)
        setProjectSectionHeight(clampedHeight)
        hasLoadedProjectSectionHeight = true
        if shouldPersist {
            storedProjectSectionHeight = Double(clampedHeight)
        }
    }

    private func toggleProjectExpansion(_ project: ProjectItem, latestSession: CLIHistorySession?) {
        if appState.selectedProjectID == project.id {
            // Re-clicking the already-selected project: only toggle the expansion of
            // its session list. Do not re-enter project-switch flow (which would
            // overwrite an in-progress new-chat draft via selectCLIHistory).
            if expandedProjectID == project.id {
                expandedProjectID = nil
            } else {
                expandedProjectID = project.id
            }
            return
        }
        if appState.selectProjectOpeningLatestChat(project, preferredLatestSession: latestSession) {
            expandedProjectID = project.id
        }
    }

    private func rebuildSessionsByProjectKeyCache() {
        var grouped: [String: [CLIHistorySession]] = [:]
        let selectedCLI = appState.selectedCLI.visibleValue
        for session in appState.cliHistory where session.cli.visibleValue == selectedCLI {
            guard let key = session.projectPath.map(projectHistoryKey) else { continue }
            grouped[key, default: []].append(session)
        }
        sessionsByProjectKeyCache = grouped
    }

    private func normalizedPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    private func projectHistoryKey(for projectPath: String) -> String {
        normalizedPath(projectPath)
    }

    private var fileSection: some View {
        let visibleRows = appState.visibleFileTreeRows
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("文件")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                newFileMenu
                Button(action: appState.refreshFileTree) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(CircularIconButtonStyle(size: 26, background: AppTheme.controlSurface, border: AppTheme.hairline))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if appState.selectedProject == nil {
                            Text("未选择项目")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(11)
                        } else if appState.isFileTreeLoading && appState.rootNodes.isEmpty {
                            Text("正在加载文件…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(11)
                        } else if appState.rootNodes.isEmpty {
                            Text("没有可显示的文件")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(11)
                        } else {
                            ForEach(visibleRows) { row in
                                FileTreeItemView(
                                    row: row,
                                    onActivate: appState.handleFileTreeActivation,
                                    onOpen: appState.openFile,
                                    onCreateFile: appState.beginCreateFile,
                                    onCreateFolder: appState.beginCreateFolder,
                                    onRefresh: appState.refreshFileTreeNode,
                                    onReveal: appState.revealInFinder,
                                    onOpenInFinder: appState.openInFinder,
                                    onCopyAbsolutePath: appState.copyAbsolutePath,
                                    onCopyRelativePath: appState.copyRelativePath,
                                    onRename: appState.beginRenameFileTreeNode,
                                    onCommitRename: appState.commitFileTreeNodeRename,
                                    onCancelRename: appState.cancelFileTreeNodeRename,
                                    onMoveToTrash: appState.moveFileTreeNodeToTrash,
                                    onImportDroppedFiles: appState.importDroppedFileTreeItems,
                                    renamingPath: appState.renamingFileTreePath,
                                    renameText: $appState.renamingDraftName
                                )
                                .id(row.id)
                                .onAppear {
                                    if let node = row.node {
                                        appState.loadVisibleFileTreeChildrenIfNeeded(for: node)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                    .animation(.easeOut(duration: 0.18), value: visibleRows.map(\.id))
                }
                .overlay(
                    FileTreeKeyboardBridge(
                        onCopy: appState.copySelectedFileTreeItems,
                        onPaste: { appState.pasteFileTreeItems() },
                        onDelete: appState.moveSelectedFileTreeItemsToTrash
                    )
                    .allowsHitTesting(false)
                )
                .onChange(of: appState.pendingFileTreeScrollTargetID) { _, targetID in
                    scrollToPendingFileTreeTarget(targetID, visibleRowIDs: visibleRows.map(\.id), proxy: proxy)
                }
                .onChange(of: visibleRows.map(\.id)) { _, rowIDs in
                    scrollToPendingFileTreeTarget(appState.pendingFileTreeScrollTargetID, visibleRowIDs: rowIDs, proxy: proxy)
                }
            }
        }
    }

    private func scrollToPendingFileTreeTarget(_ targetID: String?, visibleRowIDs: [String], proxy: ScrollViewProxy) {
        guard let targetID, visibleRowIDs.contains(targetID) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
            DispatchQueue.main.async {
                appState.pendingFileTreeScrollTargetID = nil
            }
        }
    }

    private var newFileMenu: some View {
        Menu {
            Button("新建文件", systemImage: "doc.badge.plus") {
                appState.beginCreateFileInProjectRoot()
            }
            Button("新建文件夹", systemImage: "folder.badge.plus") {
                appState.beginCreateFolderInProjectRoot()
            }
        } label: {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(AppTheme.controlSurface)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(AppTheme.hairline, lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(appState.selectedProject == nil)
        .help("新建文件或文件夹")
    }

    private var settingsButton: some View {
        Button(action: { appState.showSettings = true }) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                Text("acode 设置")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FileTreeKeyboardBridge: NSViewRepresentable {
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> FileTreeKeyboardBridgeView {
        let view = FileTreeKeyboardBridgeView()
        view.onCopy = onCopy
        view.onPaste = onPaste
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: FileTreeKeyboardBridgeView, context: Context) {
        nsView.onCopy = onCopy
        nsView.onPaste = onPaste
        nsView.onDelete = onDelete
    }
}

private final class FileTreeKeyboardBridgeView: NSView {
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerMonitorIfNeeded()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private var keyMonitor: Any?

    private func registerMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window === event.window, self.isMouseInsideView else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    private var isMouseInsideView: Bool {
        guard let window, let event = NSApp.currentEvent else { return false }
        let location = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return bounds.contains(location) && event.window === window
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control), characters == "c" {
            onCopy?()
            return true
        }
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control), characters == "v" {
            onPaste?()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return true
        }
        return false
    }
}

private struct ProjectRow: View {
    let project: ProjectItem
    let sessions: [CLIHistorySession]
    let selectedSessionID: String?
    let activityForSession: (CLIHistorySession) -> ChatSessionActivity?
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onSelectSession: (CLIHistorySession) -> Void
    let onRemoveSession: (CLIHistorySession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Button(action: onSelect) {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        Text(project.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                if let projectActivityIndicator {
                    if projectActivityIndicator.isRunning {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 18, height: 18)
                            .help(projectActivityIndicator.help)
                    } else {
                        Circle()
                            .fill(projectActivityIndicator.color)
                            .frame(width: 7, height: 7)
                            .frame(width: 18, height: 18)
                            .help(projectActivityIndicator.help)
                    }
                }

                sidebarIconButton(systemImage: "trash", help: "从列表移除项目，不删除文件夹", action: onRemove)
                    .padding(.trailing, 4)
            }
            .background(isSelected ? AppTheme.selectedSurface : AppTheme.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.weakHairline, lineWidth: 1)
            )

            if isSelected && !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sessions) { session in
                        HistorySessionRow(
                            session: session,
                            activity: activityForSession(session),
                            isSelected: selectedSessionID == session.id,
                            onSelect: { onSelectSession(session) },
                            onRemove: { onRemoveSession(session) }
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var projectActivityIndicator: (isRunning: Bool, color: Color, help: String)? {
        let activities = sessions.compactMap(activityForSession)
        if activities.contains(where: { $0.status.isRunning }) {
            return (true, .clear, "运行中")
        }
        if !activities.isEmpty && activities.count == sessions.count && activities.allSatisfy({ $0.status == .completed }) {
            return (false, .green, "已完成")
        }
        return nil
    }

    private func sidebarIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(CircularIconButtonStyle(size: 28))
        .foregroundStyle(.tertiary)
        .help(help)
    }
}

private struct HistorySessionRow: View {
    let session: CLIHistorySession
    let activity: ChatSessionActivity?
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    Text(session.title)
                        .font(.system(size: 11.5, weight: .regular))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 29)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if let activity {
                sessionActivityIndicator(activity)
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
            }

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(CircularIconButtonStyle(size: 24))
            .foregroundStyle(.tertiary)
            .help("删除历史会话")
        }
        .padding(.trailing, 6)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func sessionActivityIndicator(_ activity: ChatSessionActivity) -> some View {
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

    private func activityIndicatorColor(for activity: ChatSessionActivity) -> Color {
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

    private func activityIndicatorHelp(for activity: ChatSessionActivity) -> String {
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
}
