import AppKit
import CoreServices
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private let appStateFileEventCallback: FSEventStreamCallback = { _, context, _, eventPaths, _, _ in
    guard let context else { return }
    let appState = Unmanaged<AppState>.fromOpaque(context).takeUnretainedValue()
    let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
    Task { @MainActor [weak appState] in
        appState?.handleFileEventPaths(paths)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [ProjectItem]
    @Published var selectedProjectID: UUID?
    @Published var rootNodes: [FileNode] = [] { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published var childCache: [String: [FileNode]] = [:] { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published var expandedFileTreePaths: Set<String> = [] { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published private(set) var visibleFileTreeRows: [VisibleFileTreeRow] = []
    @Published private(set) var isFileTreeLoading = false
    @Published private(set) var loadingFileTreeNodeIDs: Set<String> = [] { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published var renamingFileTreePath: String?
    @Published var renamingDraftName = ""
    @Published var pendingFileTreeScrollTargetID: String?
    @Published var selectedFileTreePaths: Set<String> = [] { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published var openTabs: [EditorTab] = [] { didSet { rebuildVisibleFileTreeRowsIfDirtyPathsChanged() } }
    @Published var selectedTabID: UUID? { didSet { setNeedsRebuildVisibleFileTreeRows() } }
    @Published var launchHistory: [LaunchRecord]
    @Published var cliHistory: [CLIHistorySession] = []
    @Published var selectedMode: SessionMode = .newSession
    @Published var selectedCLI: CLIType
    @Published var selectedTerminal: TerminalType
    @Published var resumeSessionId = ""
    @Published var selectedHistoryProjectPath: String?
    @Published var selectedCLIHistoryID: String?
    @Published var isChatHistorySelectionVisuallySuppressed = false
    @Published var chatConversationSerial = UUID()
    let cursorStore = EditorCursorStore()
    @Published var editorJumpRequest: EditorJumpRequest?
    @Published var errorMessage: String?
    @Published var permissionPrompt: PermissionPrompt?
    @Published var settings: AppSettings
    @Published var showSettings: Bool = false

    deinit {
        MainActor.assumeIsolated {
            if let remoteChatSessionsObserver {
                NotificationCenter.default.removeObserver(remoteChatSessionsObserver)
            }
            if let remoteMirrorBeginToken {
                RemoteSessionMirrorBus.shared.unsubscribeFromBegins(token: remoteMirrorBeginToken)
            }
            stopFileEventStream()
        }
    }

    private var scanner: FileTreeScanner
    private var pendingRestoreCLIHistoryID: String?
    private struct PendingFileTreeCreation {
        let parentURL: URL
        let isDirectory: Bool
        let parentID: String?
    }

    private var cliHistoryRefreshGeneration = 0
    private var isCLIHistoryRefreshInFlight = false
    private var pendingCLIHistoryRefresh = false
    private var pendingOpenLatestChatProjectID: UUID?
    private var fileTreeScanGeneration = 0
    private var cachedDirtyFileTreePaths: Set<String> = []
    private var pendingVisibleRowsRebuild = false
    private var pendingFileTreeCreations: [String: PendingFileTreeCreation] = [:]
    private var fileTreeSelectionAnchorPath: String?
    private var editorLoadGenerations: [UUID: UUID] = [:]
    private var hasShownFolderPermissionOnboardingThisLaunch = false
    private var fileEventStream: FSEventStreamRef?
    private var remoteChatSessionsObserver: NSObjectProtocol?
    private var remoteMirrorBeginToken: UUID?
    private static let externalEditorProjectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init() {
        var settings = ProjectStore.loadSettings()
        settings.defaultCLI = settings.defaultCLI.visibleValue
        settings.chatCLI = settings.chatCLI.visibleValue
        let loadedProjects = ProjectStore.loadProjects().sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        let restoredProjectID = settings.lastSelectedProjectPath.flatMap { savedPath in
            loadedProjects.first { Self.normalizedProjectPath($0.path) == Self.normalizedProjectPath(savedPath) }?.id
        }
        if restoredProjectID == nil, settings.lastSelectedProjectPath != nil || settings.lastSelectedCLIHistoryID != nil {
            settings.lastSelectedProjectPath = loadedProjects.first?.path
            settings.lastSelectedCLIHistoryID = nil
            try? ProjectStore.saveSettings(settings)
        }
        self.settings = settings
        self.projects = loadedProjects
        self.launchHistory = LaunchHistoryStore.load().sorted { $0.createdAt > $1.createdAt }
        self.cliHistory = Self.loadCLIHistory()
        self.selectedCLI = settings.chatCLI
        self.selectedTerminal = settings.defaultTerminal
        self.scanner = FileTreeScanner(ignoredNames: Set(settings.ignoredFolders))
        self.selectedProjectID = restoredProjectID ?? loadedProjects.first?.id
        self.pendingRestoreCLIHistoryID = settings.lastSelectedCLIHistoryID
        self.remoteChatSessionsObserver = NotificationCenter.default.addObserver(forName: .remoteChatSessionsDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                if let session = notification.userInfo?["session"] as? ChatSessionRecord {
                    self?.upsertPersistedChatSession(session)
                } else {
                    self?.refreshCLIHistory()
                }
            }
        }
        self.remoteMirrorBeginToken = RemoteSessionMirrorBus.shared.subscribeToBegins { [weak self] event in
            guard let self else { return }
            if case .beginRun(let session, _) = event {
                self.upsertPersistedChatSession(session)
            }
        }
        RemoteChatServerController.shared.startIfNeeded()
        refreshProjectContext()
    }

    var selectedProject: ProjectItem? {
        projects.first { $0.id == selectedProjectID }
    }

    var cursorLine: Int {
        get { cursorStore.line }
        set { cursorStore.update(line: newValue, column: cursorStore.column) }
    }

    var cursorColumn: Int {
        get { cursorStore.column }
        set { cursorStore.update(line: cursorStore.line, column: newValue) }
    }

    private func project(matching path: String?) -> ProjectItem? {
        guard let normalizedPath = Self.normalizedProjectPath(path) else { return nil }
        return projects.first { Self.normalizedProjectPath($0.path) == normalizedPath }
    }

    private func persistWorkspaceSelection(projectPath: String?, historyID: String?, clearPending: Bool = true) {
        settings.lastSelectedProjectPath = projectPath
        settings.lastSelectedCLIHistoryID = historyID
        if clearPending {
            pendingRestoreCLIHistoryID = nil
        }
        do {
            try ProjectStore.saveSettings(settings)
        } catch {
            show(error)
        }
    }

    func preservingWorkspaceSelectionForRemoteFocus<T>(_ body: () -> T) -> T {
        let savedProjectID = selectedProjectID
        let savedProjectPath = selectedProject?.path
        let savedCLI = selectedCLI
        let savedMode = selectedMode
        let savedResumeSessionId = resumeSessionId
        let savedHistoryProjectPath = selectedHistoryProjectPath
        let savedHistoryID = selectedCLIHistoryID
        let savedSuppressed = isChatHistorySelectionVisuallySuppressed
        let savedSerial = chatConversationSerial
        let result = body()
        selectedProjectID = savedProjectID
        selectedCLI = savedCLI
        selectedMode = savedMode
        resumeSessionId = savedResumeSessionId
        selectedHistoryProjectPath = savedHistoryProjectPath
        selectedCLIHistoryID = savedHistoryID
        isChatHistorySelectionVisuallySuppressed = savedSuppressed
        chatConversationSerial = savedSerial
        persistWorkspaceSelection(projectPath: savedProjectPath, historyID: savedHistoryID)
        return result
    }

    private func restorePendingHistorySelectionIfPossible(finalizeIfMissing: Bool) {
        guard let historyID = pendingRestoreCLIHistoryID else { return }
        guard let session = cliHistory.first(where: { $0.id == historyID }) else {
            if finalizeIfMissing {
                pendingRestoreCLIHistoryID = nil
                persistWorkspaceSelection(projectPath: selectedProject?.path, historyID: nil, clearPending: false)
            }
            return
        }
        guard let matchingProject = project(matching: session.projectPath) else {
            pendingRestoreCLIHistoryID = nil
            persistWorkspaceSelection(projectPath: selectedProject?.path, historyID: nil, clearPending: false)
            return
        }
        selectedProjectID = matchingProject.id
        selectedCLI = session.cli.visibleValue
        selectedMode = .resume
        resumeSessionId = session.sessionId
        selectedHistoryProjectPath = session.projectPath
        selectedCLIHistoryID = session.id
        isChatHistorySelectionVisuallySuppressed = false
        chatConversationSerial = UUID()
        persistWorkspaceSelection(projectPath: matchingProject.path, historyID: session.id)
    }

    func upsertPersistedChatSession(_ session: ChatSessionRecord) {
        guard let historySession = ChatSessionStore.historySessions(from: [session]).first else { return }
        var history = cliHistory.filter { $0.id != historySession.id }
        history.insert(historySession, at: 0)
        history.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        if cliHistory != history {
            cliHistory = history
        }
    }

    func adoptPersistedChatSession(_ session: ChatSessionRecord) {
        adoptPersistedChatSession(session, allowProjectSwitch: false)
    }

    func adoptPersistedChatSession(_ session: ChatSessionRecord, allowProjectSwitch: Bool) {
        if allowProjectSwitch,
           let matchingProject = project(matching: session.projectPath),
           selectedProjectID != matchingProject.id {
            selectedProjectID = matchingProject.id
            refreshProjectContext()
        }
        guard let currentProject = selectedProject,
              Self.normalizedProjectPath(currentProject.path) == Self.normalizedProjectPath(session.projectPath) else { return }
        let historyID = "\(session.cli.rawValue):\(session.id.uuidString)"
        let sessionID = session.id.uuidString
        guard selectedCLI != session.cli.visibleValue
            || selectedMode != .resume
            || resumeSessionId != sessionID
            || selectedHistoryProjectPath != session.projectPath
            || selectedCLIHistoryID != historyID else { return }
        selectedCLI = session.cli.visibleValue
        selectedMode = .resume
        resumeSessionId = sessionID
        selectedHistoryProjectPath = session.projectPath
        selectedCLIHistoryID = historyID
        isChatHistorySelectionVisuallySuppressed = false
        chatConversationSerial = UUID()
        persistWorkspaceSelection(projectPath: currentProject.path, historyID: historyID)
    }

    nonisolated static func normalizedProjectPath(_ path: String?) -> String? {
        guard var normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else { return nil }
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return (normalized as NSString).resolvingSymlinksInPath
    }

    var selectedTab: EditorTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    private func setNeedsRebuildVisibleFileTreeRows() {
        guard !pendingVisibleRowsRebuild else { return }
        pendingVisibleRowsRebuild = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingVisibleRowsRebuild = false
            rebuildVisibleFileTreeRows()
        }
    }

    private func rebuildVisibleFileTreeRows() {
        cachedDirtyFileTreePaths = dirtyFileTreePaths
        visibleFileTreeRows = FileTreeLayout.visibleRows(
            rootNodes: rootNodes,
            childCache: childCache,
            expandedPaths: expandedFileTreePaths,
            loadingNodeIDs: loadingFileTreeNodeIDs,
            selectedURL: selectedTab?.url,
            selectedFileTreePaths: selectedFileTreePaths,
            modifiedFilePaths: cachedDirtyFileTreePaths
        )
    }

    private func rebuildVisibleFileTreeRowsIfDirtyPathsChanged() {
        let nextDirtyPaths = dirtyFileTreePaths
        guard nextDirtyPaths != cachedDirtyFileTreePaths else { return }
        setNeedsRebuildVisibleFileTreeRows()
    }

    private var dirtyFileTreePaths: Set<String> {
        Set(openTabs.lazy.filter(\.isDirty).map { Self.normalizedFileTreePath($0.url.path) })
    }

    var breadcrumb: String {
        guard let project = selectedProject else { return "未选择项目" }
        guard let tab = selectedTab else { return project.name }
        return "\(project.name) / \(tab.url.deletingLastPathComponent().lastPathComponent) / \(tab.title)"
    }

    var commandPreview: String {
        guard let projectPath = selectedHistoryProjectPath ?? selectedProject?.path else { return "选择项目后生成命令" }
        let sessionId = resumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandBuilder.command(
            projectPath: projectPath,
            cli: selectedCLI,
            mode: selectedMode,
            sessionId: sessionId.isEmpty ? nil : sessionId
        )
    }

    func addProject() {
        guard confirmDiscardUnsavedChangesIfNeeded() else { return }
        do {
            guard let project = try ProjectStore.chooseProjectDirectory() else { return }
            projects.removeAll { $0.path == project.path }
            projects.insert(project, at: 0)
            selectedProjectID = project.id
            try ProjectStore.saveProjects(projects)
            refreshProjectContext()
            persistWorkspaceSelection(projectPath: project.path, historyID: nil)
        } catch {
            show(error)
        }
    }

    func removeProject(_ project: ProjectItem) {
        if selectedProjectID == project.id {
            guard confirmDiscardUnsavedChangesIfNeeded() else { return }
        }
        projects.removeAll { $0.id == project.id }
        if selectedProjectID == project.id {
            selectedProjectID = projects.first?.id
        }
        do {
            try ProjectStore.saveProjects(projects)
            refreshProjectContext()
            persistWorkspaceSelection(projectPath: selectedProject?.path, historyID: nil)
        } catch {
            show(error)
        }
    }

    @discardableResult
    func selectProject(_ project: ProjectItem) -> Bool {
        guard selectedProjectID != project.id else { return true }
        guard confirmDiscardUnsavedChangesIfNeeded() else { return false }
        selectProjectWithoutChatSelection(project)
        persistWorkspaceSelection(projectPath: project.path, historyID: nil)
        return true
    }

    @discardableResult
    func selectProjectOpeningLatestChat(_ project: ProjectItem, preferredLatestSession: CLIHistorySession? = nil) -> Bool {
        let didSwitchProject = selectedProjectID != project.id
        if didSwitchProject {
            guard confirmDiscardUnsavedChangesIfNeeded() else { return false }
            selectProjectWithoutChatSelection(project)
        }
        pendingOpenLatestChatProjectID = project.id
        let displayedLatestSession = preferredLatestSession.flatMap { candidate in
            cliHistory.first { $0.id == candidate.id }
        }
        let latestSession = displayedLatestSession ?? latestCLIHistorySession(for: project, in: cliHistory)
        if let latestSession {
            pendingOpenLatestChatProjectID = nil
            selectCLIHistory(latestSession)
        } else {
            pendingOpenLatestChatProjectID = nil
            selectedHistoryProjectPath = nil
            selectedCLIHistoryID = nil
            isChatHistorySelectionVisuallySuppressed = false
            selectedMode = .newSession
            resumeSessionId = ""
            chatConversationSerial = UUID()
            persistWorkspaceSelection(projectPath: project.path, historyID: nil)
            if !didSwitchProject {
                refreshCLIHistory()
            }
        }
        return true
    }

    private func latestCLIHistorySession(for project: ProjectItem, in history: [CLIHistorySession]) -> CLIHistorySession? {
        guard let projectPath = Self.normalizedProjectPath(project.path) else { return nil }
        return history.first { Self.normalizedProjectPath($0.projectPath) == projectPath }
    }

    private func clearChatHistorySelectionForFileFocus() {
        isChatHistorySelectionVisuallySuppressed = true
    }

    private func selectProjectWithoutChatSelection(_ project: ProjectItem) {
        selectedProjectID = project.id
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastOpenedAt = Date()
            projects[index].updatedAt = Date()
            try? ProjectStore.saveProjects(projects)
        }
        refreshProjectContext()
    }

    func refreshProjectContext() {
        stopFileEventStream()
        isFileTreeLoading = selectedProject != nil
        loadingFileTreeNodeIDs = []
        rootNodes = []
        childCache = [:]
        expandedFileTreePaths = selectedProject.map { ProjectStore.loadExpandedFileTreePaths(for: $0.path) } ?? []
        renamingFileTreePath = nil
        renamingDraftName = ""
        pendingFileTreeCreations.removeAll()
        pendingFileTreeScrollTargetID = nil
        selectedFileTreePaths = []
        fileTreeSelectionAnchorPath = nil
        pendingOpenLatestChatProjectID = nil
        isChatHistorySelectionVisuallySuppressed = false
        selectedHistoryProjectPath = nil
        selectedCLIHistoryID = nil
        selectedMode = .newSession
        resumeSessionId = ""
        openTabs.removeAll()
        selectedTabID = nil
        cursorStore.update(line: 1, column: 1)
        editorJumpRequest = nil
        refreshFileTree()
        refreshCLIHistory()
        startFileEventStreamIfNeeded()
    }

    func refreshFileTree() {
        guard let project = selectedProject else {
            isFileTreeLoading = false
            loadingFileTreeNodeIDs = []
            rootNodes = []
            childCache = [:]
            return
        }
        fileTreeScanGeneration += 1
        let generation = fileTreeScanGeneration
        let ignoredNames = scanner.ignoredNames
        let expandedPaths = expandedFileTreePaths
        isFileTreeLoading = true
        loadingFileTreeNodeIDs = []
        Task.detached(priority: .utility) { [weak self, project, ignoredNames, expandedPaths] in
            let scanner = FileTreeScanner(ignoredNames: ignoredNames)
            do {
                let root = try ProjectStore.resolveURL(for: project)
                let didStart = try Self.beginScopedAccess(root, deniedError: .projectAuthorizationLost)
                defer { if didStart { root.stopAccessingSecurityScopedResource() } }

                let rootNodes = try scanner.scanChildren(of: root)
                let rootLoadingIDs = Self.loadingNodeIDs(in: rootNodes, expandedPaths: expandedPaths)
                await Self.applyInitialFileTreeScanResult(
                    rootNodes,
                    rootLoadingIDs: rootLoadingIDs,
                    generation: generation,
                    projectID: project.id,
                    state: self
                )
                await Self.restoreExpandedFileTreeNodes(
                    rootNodes,
                    expandedPaths: expandedPaths,
                    scanner: scanner,
                    generation: generation,
                    projectID: project.id,
                    state: self
                )
            } catch {
                await Self.applyFailedFileTreeScanResult(
                    error,
                    generation: generation,
                    projectID: project.id,
                    state: self
                )
            }
        }
    }

    @MainActor
    private static func applyInitialFileTreeScanResult(_ rootNodes: [FileNode], rootLoadingIDs: Set<String>, generation: Int, projectID: UUID, state: AppState?) {
        guard let state, state.fileTreeScanGeneration == generation, state.selectedProjectID == projectID else { return }
        state.rootNodes = rootNodes
        state.childCache = [:]
        state.loadingFileTreeNodeIDs = rootLoadingIDs
        state.isFileTreeLoading = false
    }

    @MainActor
    private static func applyFailedFileTreeScanResult(_ error: Error, generation: Int, projectID: UUID, state: AppState?) {
        guard let state, state.fileTreeScanGeneration == generation, state.selectedProjectID == projectID else { return }
        state.isFileTreeLoading = false
        state.loadingFileTreeNodeIDs = []
        state.rootNodes = []
        state.childCache = [:]
        state.show(error)
    }

    func loadChildren(for node: FileNode) {
        guard node.isDirectory, childCache[node.id] == nil, !loadingFileTreeNodeIDs.contains(node.id), let project = selectedProject else { return }
        let generation = fileTreeScanGeneration
        let ignoredNames = scanner.ignoredNames
        loadingFileTreeNodeIDs.insert(node.id)
        Task.detached(priority: .utility) { [project, node, ignoredNames] in
            do {
                let children = try Self.scanDirectory(node.url, project: project, ignoredNames: ignoredNames)
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    self.loadingFileTreeNodeIDs.remove(node.id)
                    let mergedChildren = self.mergingPendingCreations(into: children, parentID: node.id)
                    self.childCache[node.id] = mergedChildren
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    self.loadingFileTreeNodeIDs.remove(node.id)
                    self.childCache[node.id] = []
                    self.show(error)
                }
            }
        }
    }

    private nonisolated static func loadingNodeIDs(in nodes: [FileNode], expandedPaths: Set<String>) -> Set<String> {
        Set(nodes.lazy.filter { $0.isDirectory && expandedPaths.contains(normalizedFileTreePath($0.url.path)) }.map(\.id))
    }

    private nonisolated static func scanDirectory(_ directory: URL, project: ProjectItem, ignoredNames: Set<String>) throws -> [FileNode] {
        let scanner = FileTreeScanner(ignoredNames: ignoredNames)
        let root = try ProjectStore.resolveURL(for: project)
        let didStart = try Self.beginScopedAccess(root, deniedError: .projectAuthorizationLost)
        defer { if didStart { root.stopAccessingSecurityScopedResource() } }
        return try scanner.scanChildren(of: directory)
    }

    private nonisolated static func restoreExpandedFileTreeNodes(
        _ nodes: [FileNode],
        expandedPaths: Set<String>,
        scanner: FileTreeScanner,
        generation: Int,
        projectID: UUID,
        state: AppState?
    ) async {
        let batchSize = 24
        var pendingCache: [String: [FileNode]] = [:]

        func flushPendingCache() async {
            guard !pendingCache.isEmpty else { return }
            let updates = pendingCache
            pendingCache.removeAll(keepingCapacity: true)
            await MainActor.run {
                guard let state, state.fileTreeScanGeneration == generation, state.selectedProjectID == projectID else { return }
                var mergedCache = state.childCache
                var remainingLoadingIDs = state.loadingFileTreeNodeIDs
                for (id, children) in updates {
                    mergedCache[id] = children
                    remainingLoadingIDs.remove(id)
                }
                state.childCache = mergedCache
                state.loadingFileTreeNodeIDs = remainingLoadingIDs
            }
        }

        func restoreVisibleChain(_ nodes: [FileNode]) async {
            for node in nodes where node.isDirectory && expandedPaths.contains(Self.normalizedFileTreePath(node.url.path)) {
                await MainActor.run {
                    guard let state, state.fileTreeScanGeneration == generation, state.selectedProjectID == projectID else { return }
                    if state.childCache[node.id] == nil {
                        state.loadingFileTreeNodeIDs.insert(node.id)
                    }
                }

                do {
                    let children = try scanner.scanChildren(of: node.url)
                    pendingCache[node.id] = children
                    if pendingCache.count >= batchSize {
                        await flushPendingCache()
                    }
                    let expandedChildren = children.filter { $0.isDirectory && expandedPaths.contains(Self.normalizedFileTreePath($0.url.path)) }
                    if !expandedChildren.isEmpty {
                        await restoreVisibleChain(expandedChildren)
                    }
                } catch {
                    await MainActor.run {
                        guard let state, state.fileTreeScanGeneration == generation, state.selectedProjectID == projectID else { return }
                        state.loadingFileTreeNodeIDs.remove(node.id)
                        state.childCache[node.id] = []
                        state.show(error)
                    }
                }
            }
        }

        await restoreVisibleChain(nodes)
        await flushPendingCache()
    }

    func isFileTreeNodeExpanded(_ node: FileNode) -> Bool {
        expandedFileTreePaths.contains(Self.normalizedFileTreePath(node.url.path))
    }

    func toggleFileTreeNode(_ node: FileNode) {
        guard node.isDirectory, let project = selectedProject else { return }
        let path = Self.normalizedFileTreePath(node.url.path)
        if expandedFileTreePaths.contains(path) {
            expandedFileTreePaths.remove(path)
        } else {
            expandedFileTreePaths.insert(path)
            loadChildren(for: node)
        }
        try? ProjectStore.saveExpandedFileTreePaths(expandedFileTreePaths, for: project.path)
    }

    func loadVisibleFileTreeChildrenIfNeeded(for node: FileNode) {
        guard node.isDirectory,
              expandedFileTreePaths.contains(Self.normalizedFileTreePath(node.url.path)),
              childCache[node.id] == nil else { return }
        loadChildren(for: node)
    }

    func selectFileTreeNode(_ node: FileNode, modifiers: EventModifiers) {
        let path = Self.normalizedFileTreePath(node.url.path)
        let visibleNodePaths = visibleFileTreeRows.compactMap { row -> String? in
            guard let node = row.node, !node.isPendingCreation else { return nil }
            return Self.normalizedFileTreePath(node.url.path)
        }
        if modifiers.contains(.shift),
           let anchor = fileTreeSelectionAnchorPath,
           let start = visibleNodePaths.firstIndex(of: anchor),
           let end = visibleNodePaths.firstIndex(of: path) {
            let range = start <= end ? start...end : end...start
            selectedFileTreePaths = Set(visibleNodePaths[range])
            return
        }
        if modifiers.contains(.command) {
            if selectedFileTreePaths.contains(path) {
                selectedFileTreePaths.remove(path)
            } else {
                selectedFileTreePaths.insert(path)
                fileTreeSelectionAnchorPath = path
            }
            if selectedFileTreePaths.isEmpty {
                fileTreeSelectionAnchorPath = nil
            }
            return
        }
        selectedFileTreePaths = [path]
        fileTreeSelectionAnchorPath = path
    }

    func handleFileTreeActivation(_ node: FileNode, modifiers: EventModifiers) {
        selectFileTreeNode(node, modifiers: modifiers)
        guard !modifiers.contains(.command), !modifiers.contains(.shift) else { return }
        if node.isDirectory {
            toggleFileTreeNode(node)
        } else {
            openFile(node)
        }
    }

    var selectedFileTreeNodes: [FileNode] {
        guard !selectedFileTreePaths.isEmpty else { return [] }
        let selectedPaths = selectedFileTreePaths
        return visibleFileTreeRows.compactMap { row in
            guard let node = row.node,
                  selectedPaths.contains(Self.normalizedFileTreePath(node.url.path)),
                  !node.isPendingCreation else { return nil }
            return node
        }
    }

    func copySelectedFileTreeItems() {
        let nodes = selectedFileTreeNodes
        guard !nodes.isEmpty else { return }
        writeFileURLsToPasteboard(nodes.map(\.url))
    }

    func pasteFileTreeItems(into targetFolder: FileNode? = nil) {
        guard let destinationFolder = fileTreePasteDestination(targetFolder: targetFolder),
              let sourceURLs = fileURLsFromPasteboard(),
              !sourceURLs.isEmpty else { return }
        importFiles(sourceURLs, into: destinationFolder)
    }

    func moveSelectedFileTreeItemsToTrash() {
        moveFileTreeNodesToTrash(selectedFileTreeNodes)
    }

    func importDroppedFileTreeItems(_ providers: [NSItemProvider], into targetFolder: FileNode) -> Bool {
        guard targetFolder.isDirectory else { return false }
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.canLoadObject(ofClass: URL.self) }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor [weak self] in
                        self?.importFiles([url], into: targetFolder.url)
                    }
                }
                continue
            }
            let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
                guard let url = Self.fileURL(fromPasteboardItem: item) else { return }
                Task { @MainActor [weak self] in
                    self?.importFiles([url], into: targetFolder.url)
                }
            }
        }
        return true
    }

    func copyAbsolutePath(_ node: FileNode) {
        copyToPasteboard(node.url.path)
    }

    func copyRelativePath(_ node: FileNode) {
        guard let project = selectedProject else { return }
        let projectPath = Self.normalizedFileTreePath(project.path)
        let nodePath = Self.normalizedFileTreePath(node.url.path)
        if nodePath == projectPath {
            copyToPasteboard(".")
        } else if nodePath.hasPrefix(projectPath + "/") {
            copyToPasteboard(String(nodePath.dropFirst(projectPath.count + 1)))
        } else {
            errorMessage = "只能复制当前项目内文件的相对路径。"
        }
    }

    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func openInFinder(_ node: FileNode) {
        NSWorkspace.shared.open(node.isDirectory ? node.url : node.url.deletingLastPathComponent())
    }

    func refreshFileTreeNode(_ node: FileNode) {
        guard node.isDirectory, let project = selectedProject else {
            refreshFileTree()
            return
        }
        let generation = fileTreeScanGeneration
        let ignoredNames = scanner.ignoredNames
        loadingFileTreeNodeIDs.insert(node.id)
        Task.detached(priority: .utility) { [project, node, ignoredNames] in
            do {
                let children = try Self.scanDirectory(node.url, project: project, ignoredNames: ignoredNames)
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    self.loadingFileTreeNodeIDs.remove(node.id)
                    let mergedChildren = self.mergingPendingCreations(into: children, parentID: node.id)
                    self.childCache[node.id] = mergedChildren
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    self.loadingFileTreeNodeIDs.remove(node.id)
                    self.show(error)
                }
            }
        }
    }

    func beginCreateFileInProjectRoot() {
        guard let project = selectedProject else { return }
        createFileTreeItemForRename(in: URL(fileURLWithPath: project.path, isDirectory: true), isDirectory: false)
    }

    func beginCreateFolderInProjectRoot() {
        guard let project = selectedProject else { return }
        createFileTreeItemForRename(in: URL(fileURLWithPath: project.path, isDirectory: true), isDirectory: true)
    }

    func beginCreateFile(in folder: FileNode) {
        guard folder.isDirectory else { return }
        createFileTreeItemForRename(in: folder.url, isDirectory: false)
    }

    func beginCreateFolder(in folder: FileNode) {
        guard folder.isDirectory else { return }
        createFileTreeItemForRename(in: folder.url, isDirectory: true)
    }

    func beginRenameFileTreeNode(_ node: FileNode) {
        renamingDraftName = node.name
        renamingFileTreePath = Self.normalizedFileTreePath(node.url.path)
        pendingFileTreeScrollTargetID = node.id
    }

    @discardableResult
    func commitFileTreeNodeRename(_ node: FileNode, to name: String) -> Bool {
        let didRename = node.isPendingCreation
            ? commitPendingFileTreeCreation(node, to: name)
            : renameFileTreeNode(node, to: name)
        if didRename {
            renamingFileTreePath = nil
            renamingDraftName = ""
        }
        return didRename
    }

    func cancelFileTreeNodeRename(_ node: FileNode) {
        guard renamingFileTreePath == Self.normalizedFileTreePath(node.url.path) else { return }
        if node.isPendingCreation, let creation = pendingFileTreeCreations.removeValue(forKey: node.id) {
            removeFileTreeNodeFromCache(id: node.id, parentID: creation.parentID)
        }
        renamingFileTreePath = nil
        renamingDraftName = ""
    }

    func moveFileTreeNodeToTrash(_ node: FileNode) {
        let selected = selectedFileTreeNodes
        if selected.contains(where: { Self.normalizedFileTreePath($0.url.path) == Self.normalizedFileTreePath(node.url.path) }) {
            moveFileTreeNodesToTrash(selected)
        } else {
            moveFileTreeNodesToTrash([node])
        }
    }

    private func moveFileTreeNodesToTrash(_ nodes: [FileNode]) {
        let nodes = filteredTopLevelFileTreeNodes(nodes)
        guard !nodes.isEmpty, confirmMoveToTrash(nodes) else { return }
        let affectedTabs = nodes.flatMap { openTabs(under: $0.url, isDirectory: $0.isDirectory) }
        guard confirmDiscardUnsavedTabsIfNeeded(affectedTabs) else { return }
        do {
            guard let project = selectedProject else { return }
            let parentFolders = Set(nodes.map { Self.normalizedFileTreePath($0.url.deletingLastPathComponent().path) })
            try withProjectAccess(project) { _ in
                for node in nodes {
                    guard isProjectURL(node.url, in: project) else { throw AppStateError.fileOutsideProject }
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: node.url, resultingItemURL: &resultingURL)
                }
            }
            openTabs.removeAll { tab in
                affectedTabs.contains { $0.id == tab.id }
            }
            if let selectedTabID, !openTabs.contains(where: { $0.id == selectedTabID }) {
                self.selectedTabID = openTabs.last?.id
            }
            selectedFileTreePaths.subtract(nodes.map { Self.normalizedFileTreePath($0.url.path) })
            for folder in parentFolders {
                incrementallyUpdateFolder(URL(fileURLWithPath: folder, isDirectory: true))
            }
        } catch {
            show(error)
        }
    }

    private func createFileTreeItemForRename(in folderURL: URL, isDirectory: Bool) {
        do {
            guard let project = selectedProject else { return }
            guard isProjectURL(folderURL, in: project) else { throw AppStateError.fileOutsideProject }
            let parentID = parentListID(for: folderURL, project: project)
            let name = availableFileTreeName(in: folderURL, preferredName: isDirectory ? "Untitled Folder" : "Untitled.txt")
            let pendingURL = folderURL.appendingPathComponent("__pending_\(UUID().uuidString)__", isDirectory: isDirectory)
            let pendingNode = FileNode(url: pendingURL, name: name, isDirectory: isDirectory, isPendingCreation: true)
            pendingFileTreeCreations[pendingNode.id] = PendingFileTreeCreation(parentURL: folderURL, isDirectory: isDirectory, parentID: parentID)
            expandedFileTreePaths.insert(Self.normalizedFileTreePath(folderURL.path))
            try? ProjectStore.saveExpandedFileTreePaths(expandedFileTreePaths, for: project.path)
            if parentID == nil {
                rootNodes.insert(pendingNode, at: 0)
            } else if let parentID {
                childCache[parentID, default: []].insert(pendingNode, at: 0)
            }
            renamingDraftName = name
            renamingFileTreePath = Self.normalizedFileTreePath(pendingURL.path)
            pendingFileTreeScrollTargetID = pendingNode.id
        } catch {
            show(error)
        }
    }

    private func availableFileTreeName(in folderURL: URL, preferredName: String) -> String {
        let preferredURL = folderURL.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else { return preferredName }

        let nsName = preferredName as NSString
        let baseName = nsName.deletingPathExtension
        let pathExtension = nsName.pathExtension
        for index in 2...999 {
            let candidate = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            let candidateURL = folderURL.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidate
            }
        }
        return UUID().uuidString + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
    }

    private func commitPendingFileTreeCreation(_ node: FileNode, to rawName: String) -> Bool {
        do {
            guard let creation = pendingFileTreeCreations[node.id] else { return false }
            guard let project = selectedProject else { return false }
            let name = try validatedFileTreeName(rawName)
            let destination = creation.parentURL.appendingPathComponent(name, isDirectory: creation.isDirectory)
            guard isProjectURL(destination, in: project) else { throw AppStateError.fileOutsideProject }
            try withProjectAccess(project) { _ in
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw AppStateError.fileAlreadyExists(name)
                }
                if creation.isDirectory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                } else if !FileManager.default.createFile(atPath: destination.path, contents: Data()) {
                    throw AppStateError.fileOperationFailed
                }
            }
            pendingFileTreeCreations.removeValue(forKey: node.id)
            let createdNode = FileNode(url: destination, name: name, isDirectory: creation.isDirectory)
            replaceFileTreeNodeInCache(id: node.id, parentID: creation.parentID, with: createdNode)
            pendingFileTreeScrollTargetID = createdNode.id
            incrementallyUpdateFolder(creation.parentURL)
            return true
        } catch {
            show(error)
            renamingFileTreePath = Self.normalizedFileTreePath(node.url.path)
            return false
        }
    }

    private func renameFileTreeNode(_ node: FileNode, to rawName: String) -> Bool {
        do {
            let name = try validatedFileTreeName(rawName)
            guard name != node.name else { return true }
            let parentURL = node.url.deletingLastPathComponent()
            let destination = parentURL.appendingPathComponent(name, isDirectory: node.isDirectory)
            guard let project = selectedProject else { return false }
            guard isProjectURL(node.url, in: project), isProjectURL(destination, in: project) else { throw AppStateError.fileOutsideProject }
            let affectedTabs = openTabs(under: node.url, isDirectory: node.isDirectory)
            guard confirmDiscardUnsavedTabsIfNeeded(affectedTabs) else { return false }
            try withProjectAccess(project) { _ in
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw AppStateError.fileAlreadyExists(name)
                }
                try FileManager.default.moveItem(at: node.url, to: destination)
            }
            retargetOpenTabs(from: node.url, to: destination, isDirectory: node.isDirectory)
            remapExpandedFileTreePaths(from: node.url, to: destination)
            if node.isDirectory {
                migrateChildCacheKeys(from: node.url, to: destination)
            }
            pendingFileTreeScrollTargetID = destination.path
            incrementallyUpdateFolder(parentURL)
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func writeFileURLsToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func fileURLsFromPasteboard() -> [URL]? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL)
        }
        if let raw = pasteboard.string(forType: .string) {
            let urls = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .compactMap { value -> URL? in
                    if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
                        return url
                    }
                    if value.hasPrefix("/") {
                        return URL(fileURLWithPath: value)
                    }
                    return nil
                }
            if !urls.isEmpty { return urls }
        }
        return nil
    }

    private func fileTreePasteDestination(targetFolder: FileNode?) -> URL? {
        if let targetFolder, targetFolder.isDirectory { return targetFolder.url }
        if selectedFileTreeNodes.count == 1, let selected = selectedFileTreeNodes.first {
            return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
        }
        guard let project = selectedProject else { return nil }
        return URL(fileURLWithPath: project.path, isDirectory: true)
    }

    private func importFiles(_ sourceURLs: [URL], into destinationFolder: URL) {
        do {
            guard let project = selectedProject else { return }
            let destinationFolder = destinationFolder.standardizedFileURL.resolvingSymlinksInPath()
            guard isProjectURL(destinationFolder, in: project) else { throw AppStateError.fileOutsideProject }
            try withProjectAccess(project) { _ in
                for sourceURL in sourceURLs {
                    let sourceURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                    guard sourceURL.isFileURL else { continue }
                    guard !isURL(destinationFolder, inside: sourceURL) else { throw AppStateError.fileOperationFailed }
                    let destination = uniqueDestinationURL(for: sourceURL.lastPathComponent, in: destinationFolder, isDirectory: sourceURL.hasDirectoryPath)
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }
            }
            expandedFileTreePaths.insert(Self.normalizedFileTreePath(destinationFolder.path))
            try? ProjectStore.saveExpandedFileTreePaths(expandedFileTreePaths, for: project.path)
            incrementallyUpdateFolder(destinationFolder)
        } catch {
            show(error)
        }
    }

    private func uniqueDestinationURL(for fileName: String, in folderURL: URL, isDirectory: Bool) -> URL {
        let preferredURL = folderURL.appendingPathComponent(fileName, isDirectory: isDirectory)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else { return preferredURL }
        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension.isEmpty ? fileName : nsName.deletingPathExtension
        let pathExtension = nsName.pathExtension
        for index in 2...999 {
            let candidateName = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            let candidateURL = folderURL.appendingPathComponent(candidateName, isDirectory: isDirectory)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return folderURL.appendingPathComponent("\(UUID().uuidString)-\(fileName)", isDirectory: isDirectory)
    }

    private nonisolated static func fileURL(fromPasteboardItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, let swiftURL = url as URL?, swiftURL.isFileURL { return swiftURL }
        if let data = item as? Data,
           let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { return url }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        }
        if let raw = item as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL { return url }
            if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        }
        return nil
    }

    private func filteredTopLevelFileTreeNodes(_ nodes: [FileNode]) -> [FileNode] {
        let sorted = nodes.sorted { Self.normalizedFileTreePath($0.url.path).count < Self.normalizedFileTreePath($1.url.path).count }
        var kept: [FileNode] = []
        for node in sorted {
            let path = Self.normalizedFileTreePath(node.url.path)
            if kept.contains(where: { keptNode in
                let keptPath = Self.normalizedFileTreePath(keptNode.url.path)
                return path == keptPath || path.hasPrefix(keptPath + "/")
            }) {
                continue
            }
            kept.append(node)
        }
        return kept
    }

    private func isProjectURL(_ url: URL, in project: ProjectItem) -> Bool {
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return isURL(fileURL, inside: projectURL)
    }

    private func project(containing fileURL: URL) -> ProjectItem? {
        projects
            .sorted { Self.normalizedFileTreePath($0.path).count > Self.normalizedFileTreePath($1.path).count }
            .first { isProjectURL(fileURL, in: $0) }
    }

    private func isURL(_ fileURL: URL, inside projectURL: URL) -> Bool {
        let projectPath = Self.normalizedFileTreePath(projectURL.path)
        let filePath = Self.normalizedFileTreePath(fileURL.path)
        return filePath == projectPath || filePath.hasPrefix(projectPath + "/")
    }

    private func validatedFileTreeName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppStateError.emptyFileName }
        guard !name.contains("/") && name != "." && name != ".." else { throw AppStateError.invalidFileName }
        return name
    }

    private func promptFileTreeName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational

        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func confirmMoveToTrash(_ nodes: [FileNode]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "移到废纸篓？"
        if nodes.count == 1, let node = nodes.first {
            alert.informativeText = "“\(node.name)”会被移到废纸篓。"
        } else {
            alert.informativeText = "\(nodes.count) 个项目会被移到废纸篓。"
        }
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openTabs(under url: URL, isDirectory: Bool) -> [EditorTab] {
        let path = Self.normalizedFileTreePath(url.path)
        return openTabs.filter { tab in
            let tabPath = Self.normalizedFileTreePath(tab.url.path)
            if isDirectory {
                return tabPath == path || tabPath.hasPrefix(path + "/")
            }
            return tabPath == path
        }
    }

    private func retargetOpenTabs(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = Self.normalizedFileTreePath(oldURL.path)
        let newPath = Self.normalizedFileTreePath(newURL.path)
        for index in openTabs.indices {
            let tabPath = Self.normalizedFileTreePath(openTabs[index].url.path)
            let updatedPath: String?
            if isDirectory, tabPath == oldPath || tabPath.hasPrefix(oldPath + "/") {
                updatedPath = newPath + String(tabPath.dropFirst(oldPath.count))
            } else if !isDirectory, tabPath == oldPath {
                updatedPath = newPath
            } else {
                updatedPath = nil
            }
            if let updatedPath {
                let updatedURL = URL(fileURLWithPath: updatedPath)
                openTabs[index].url = updatedURL
                openTabs[index].title = updatedURL.lastPathComponent
                openTabs[index].preview = retargetPreview(openTabs[index].preview, to: updatedURL)
            }
        }
        setNeedsRebuildVisibleFileTreeRows()
    }

    private func retargetPreview(_ preview: EditorPreview?, to url: URL) -> EditorPreview? {
        guard case .image(let descriptor) = preview else { return preview }
        let bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return .image(ImagePreviewDescriptor(
            url: url,
            byteCount: descriptor.byteCount,
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            modifiedAt: fileModifiedAt(url) ?? descriptor.modifiedAt,
            bookmarkData: bookmarkData
        ))
    }

    private func remapExpandedFileTreePaths(from oldURL: URL, to newURL: URL) {
        let oldPath = Self.normalizedFileTreePath(oldURL.path)
        let newPath = Self.normalizedFileTreePath(newURL.path)
        expandedFileTreePaths = Set(expandedFileTreePaths.map { path in
            if path == oldPath || path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
        if let project = selectedProject {
            try? ProjectStore.saveExpandedFileTreePaths(expandedFileTreePaths, for: project.path)
        }
    }

    private func incrementallyUpdateFolder(_ folderURL: URL) {
        guard let project = selectedProject else { return }
        let folderPath = Self.normalizedFileTreePath(folderURL.path)
        let projectPath = Self.normalizedFileTreePath(project.path)
        guard folderPath == projectPath || folderPath.hasPrefix(projectPath + "/") else { return }
        let generation = fileTreeScanGeneration
        let ignoredNames = scanner.ignoredNames
        let parentID = folderPath == projectPath ? nil : nodeID(forDirectoryPath: folderPath)
        Task.detached(priority: .utility) { [project, folderURL, ignoredNames] in
            do {
                let children = try Self.scanDirectory(folderURL, project: project, ignoredNames: ignoredNames)
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    let mergedChildren = self.mergingPendingCreations(into: children, parentID: parentID)
                    if parentID == nil {
                        self.rootNodes = mergedChildren
                    } else if let parentID {
                        self.childCache[parentID] = mergedChildren
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                    self.show(error)
                }
            }
        }
    }

    private func nodeID(forDirectoryPath path: String) -> String? {
        if let node = rootNodes.first(where: { $0.isDirectory && Self.normalizedFileTreePath($0.url.path) == path }) {
            return node.id
        }
        for children in childCache.values {
            if let node = children.first(where: { $0.isDirectory && Self.normalizedFileTreePath($0.url.path) == path }) {
                return node.id
            }
        }
        return path
    }

    private func parentListID(for folderURL: URL, project: ProjectItem) -> String? {
        Self.normalizedFileTreePath(folderURL.path) == Self.normalizedFileTreePath(project.path) ? nil : nodeID(forDirectoryPath: Self.normalizedFileTreePath(folderURL.path))
    }

    private func mergingPendingCreations(into children: [FileNode], parentID: String?) -> [FileNode] {
        let pendingChildren = pendingFileTreeCreations.keys.compactMap { id -> FileNode? in
            guard let creation = pendingFileTreeCreations[id], creation.parentID == parentID else { return nil }
            return fileTreeNode(withID: id)
        }
        let pendingIDs = Set(pendingChildren.map(\.id))
        return pendingChildren + children.filter { !pendingIDs.contains($0.id) }
    }

    private func fileTreeNode(withID id: String) -> FileNode? {
        if let node = rootNodes.first(where: { $0.id == id }) { return node }
        for children in childCache.values {
            if let node = children.first(where: { $0.id == id }) { return node }
        }
        return nil
    }

    private func removeFileTreeNodeFromCache(id: String, parentID: String?) {
        if parentID == nil {
            rootNodes.removeAll { $0.id == id }
        } else if let parentID {
            childCache[parentID, default: []].removeAll { $0.id == id }
        }
    }

    private func replaceFileTreeNodeInCache(id: String, parentID: String?, with node: FileNode) {
        if parentID == nil {
            rootNodes.removeAll { $0.id == id }
            rootNodes.insert(node, at: 0)
        } else if let parentID {
            childCache[parentID, default: []].removeAll { $0.id == id }
            childCache[parentID, default: []].insert(node, at: 0)
        }
    }

    private func migrateChildCacheKeys(from oldURL: URL, to newURL: URL) {
        let oldPath = Self.normalizedFileTreePath(oldURL.path)
        let newPath = Self.normalizedFileTreePath(newURL.path)
        var migratedCache: [String: [FileNode]] = [:]
        for (key, children) in childCache {
            let normalizedKey = Self.normalizedFileTreePath(key)
            let nextKey: String
            if normalizedKey == oldPath || normalizedKey.hasPrefix(oldPath + "/") {
                nextKey = newPath + String(normalizedKey.dropFirst(oldPath.count))
            } else {
                nextKey = key
            }
            migratedCache[nextKey] = children.map { child in
                let childPath = Self.normalizedFileTreePath(child.url.path)
                guard childPath == oldPath || childPath.hasPrefix(oldPath + "/") else { return child }
                let updatedPath = newPath + String(childPath.dropFirst(oldPath.count))
                return FileNode(url: URL(fileURLWithPath: updatedPath, isDirectory: child.isDirectory), name: URL(fileURLWithPath: updatedPath).lastPathComponent, isDirectory: child.isDirectory, isPendingCreation: child.isPendingCreation)
            }
        }
        childCache = migratedCache
    }

    private func startFileEventStreamIfNeeded() {
        guard fileEventStream == nil, let project = selectedProject else { return }
        let projectPath = Self.normalizedFileTreePath(project.path)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagIgnoreSelf |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            appStateFileEventCallback,
            &context,
            [projectPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if FSEventStreamStart(stream) {
            fileEventStream = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func stopFileEventStream() {
        guard let stream = fileEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fileEventStream = nil
    }

    fileprivate func handleFileEventPaths(_ paths: [String]) {
        guard let project = selectedProject else { return }
        let projectPath = Self.normalizedFileTreePath(project.path)
        let ignoredNames = scanner.ignoredNames
        let generation = fileTreeScanGeneration
        Task.detached(priority: .utility) { [paths, projectPath, ignoredNames] in
            let folderPaths = Self.folderPathsForFileEvents(paths, projectPath: projectPath, ignoredNames: ignoredNames)
            await MainActor.run { [weak self] in
                guard let self, self.fileTreeScanGeneration == generation, self.selectedProjectID == project.id else { return }
                for folderPath in folderPaths where self.shouldIncrementallyUpdateFolder(path: folderPath, projectPath: projectPath) {
                    self.incrementallyUpdateFolder(URL(fileURLWithPath: folderPath, isDirectory: true))
                }
            }
        }
    }

    private nonisolated static func folderPathsForFileEvents(_ paths: [String], projectPath: String, ignoredNames: Set<String>) -> Set<String> {
        var folderPaths = Set<String>()
        for rawPath in paths {
            let path = normalizedFileTreePath(rawPath)
            guard path == projectPath || path.hasPrefix(projectPath + "/") else { continue }
            guard !isIgnoredFileEventPath(path, projectPath: projectPath, ignoredNames: ignoredNames) else { continue }
            if path == projectPath {
                folderPaths.insert(projectPath)
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                folderPaths.insert(path)
            }
            let parentPath = (path as NSString).deletingLastPathComponent
            if parentPath == projectPath || parentPath.hasPrefix(projectPath + "/") {
                folderPaths.insert(parentPath)
            }
        }
        return folderPaths
    }

    private nonisolated static func isIgnoredFileEventPath(_ path: String, projectPath: String, ignoredNames: Set<String>) -> Bool {
        guard path.hasPrefix(projectPath + "/") else { return false }
        let relativePath = String(path.dropFirst(projectPath.count + 1))
        return relativePath.split(separator: "/").contains { ignoredNames.contains(String($0)) }
    }

    private func shouldIncrementallyUpdateFolder(path: String, projectPath: String) -> Bool {
        if path == projectPath { return true }
        guard let node = fileTreeNodeForDirectoryPath(path) else { return false }
        return childCache[node.id] != nil
    }

    private func fileTreeNodeForDirectoryPath(_ path: String) -> FileNode? {
        if let node = rootNodes.first(where: { $0.isDirectory && Self.normalizedFileTreePath($0.url.path) == path }) {
            return node
        }
        for children in childCache.values {
            if let node = children.first(where: { $0.isDirectory && Self.normalizedFileTreePath($0.url.path) == path }) {
                return node
            }
        }
        return nil
    }

    private func expandFileTree(to fileURL: URL, in project: ProjectItem) {
        let projectPath = (project.path as NSString).standardizingPath
        let filePath = (fileURL.path as NSString).standardizingPath
        var ancestorPaths: [String] = []
        var current = (filePath as NSString).deletingLastPathComponent
        while current.hasPrefix(projectPath + "/") {
            ancestorPaths.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        guard !ancestorPaths.isEmpty else { return }
        ancestorPaths.reversed().forEach { expandedFileTreePaths.insert(Self.normalizedFileTreePath($0)) }
        try? ProjectStore.saveExpandedFileTreePaths(expandedFileTreePaths, for: project.path)

        refreshFileTree()
    }

    private func jumpEditorIfNeeded(tabID: UUID, line: Int?, column: Int?) {
        guard let line else { return }
        editorJumpRequest = EditorJumpRequest(tabID: tabID, line: line, column: column ?? 1)
    }

    nonisolated private static func normalizedFileTreePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    func openFile(_ node: FileNode) {
        guard !node.isDirectory, let project = selectedProject else { return }
        clearChatHistorySelectionForFileFocus()
        if let existing = openTabs.first(where: { $0.url == node.url }) {
            selectedTabID = existing.id
            return
        }

        let tabID = appendLoadingEditorTab(url: node.url, projectId: project.id, isExternal: false)
        loadEditorTabContent(tabID: tabID, url: node.url, project: project, accessURL: nil, line: nil, column: nil)
    }

    func openFile(path rawPath: String, line: Int? = nil, column: Int? = nil) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.looksLikeOpenablePath(trimmed) else { return }
        let url: URL
        if trimmed.hasPrefix("file://"), let fileURL = URL(string: trimmed) {
            url = fileURL
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else if let project = selectedProject {
            url = URL(fileURLWithPath: project.path).appendingPathComponent(trimmed)
        } else {
            return
        }
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileURL.isFileURL, !fileURL.hasDirectoryPath else { return }
        guard Self.isExistingRegularFile(fileURL) else { return }

        if let project = project(containing: fileURL) {
            openProjectFileURL(fileURL, in: project, line: line, column: column)
            return
        }

        if let scopedFolderURL = authorizedFolderURL(containing: fileURL) {
            openExternalFileURL(fileURL, line: line, column: column, scopeURL: scopedFolderURL)
            return
        }

        openExternalFileURL(fileURL, line: line, column: column)
    }

    private func openProjectFileURL(_ fileURL: URL, in project: ProjectItem, line: Int?, column: Int?) {
        guard Self.isOpenableFileURL(fileURL, accessURL: try? ProjectStore.resolveURL(for: project)) else { return }
        clearChatHistorySelectionForFileFocus()
        if selectedProjectID == project.id {
            expandFileTree(to: fileURL, in: project)
        }
        if let existing = openTabs.first(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath() == fileURL }) {
            selectedTabID = existing.id
            jumpEditorIfNeeded(tabID: existing.id, line: line, column: column)
            return
        }
        let tabID = appendLoadingEditorTab(url: fileURL, projectId: project.id, isExternal: false)
        loadEditorTabContent(tabID: tabID, url: fileURL, project: project, accessURL: nil, line: line, column: column)
    }

    func openExternalFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                self?.openExternalFileURLs(panel.urls)
            }
        }
    }

    private func openExternalFileURLs(_ urls: [URL]) {
        for url in urls {
            openExternalFileURL(url)
        }
    }

    private func requestExternalFileAccess(for fileURL: URL, line: Int?, column: Int?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.prompt = "允许打开"
        panel.message = "请选择“\(fileURL.lastPathComponent)”以允许在编辑器中打开。"
        panel.begin { [weak self] response in
            guard response == .OK, let approvedURL = panel.url else { return }
            Task { @MainActor [weak self] in
                let approvedFileURL = approvedURL.standardizedFileURL.resolvingSymlinksInPath()
                guard approvedFileURL == fileURL else {
                    self?.errorMessage = "请选择对话中引用的同一个文件。"
                    return
                }
                self?.openExternalFileURL(approvedURL, line: line, column: column)
            }
        }
    }

    private func authorizedFolderURL(containing fileURL: URL) -> URL? {
        let fileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        for folder in settings.authorizedFolders {
            var isStale = false
            guard let folderURL = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else { continue }
            let resolvedFolderURL = folderURL.standardizedFileURL.resolvingSymlinksInPath()
            if isURL(fileURL, inside: resolvedFolderURL) {
                return folderURL
            }
        }
        return nil
    }

    private func openExternalFileURL(_ url: URL, line: Int? = nil, column: Int? = nil, scopeURL: URL? = nil) {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isExistingRegularFile(fileURL) else { return }
        guard Self.canReadFile(fileURL, accessURL: scopeURL) else {
            showFileAccessPrompt(for: fileURL)
            return
        }
        clearChatHistorySelectionForFileFocus()
        let filePath = Self.normalizedFileTreePath(fileURL.path)
        if let existing = openTabs.first(where: { Self.normalizedFileTreePath($0.url.standardizedFileURL.resolvingSymlinksInPath().path) == filePath }) {
            selectedTabID = existing.id
            jumpEditorIfNeeded(tabID: existing.id, line: line, column: column)
            return
        }
        let tabID = appendLoadingEditorTab(url: fileURL, projectId: Self.externalEditorProjectID, isExternal: true)
        loadEditorTabContent(tabID: tabID, url: fileURL, project: nil, accessURL: scopeURL, line: line, column: column)
    }

    private nonisolated static func isOpenableFileURL(_ url: URL, accessURL: URL? = nil) -> Bool {
        guard url.isFileURL else { return false }
        let didStartAccess = accessURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartAccess {
                accessURL?.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private nonisolated static func isExistingRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private nonisolated static func canReadFile(_ url: URL, accessURL: URL?) -> Bool {
        let didStartAccess = accessURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartAccess {
                accessURL?.stopAccessingSecurityScopedResource()
            }
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Begins best-effort security-scoped access to `url`. This app is non-sandboxed, so
    /// `startAccessingSecurityScopedResource()` often returns false even when the file is
    /// fully readable (e.g. after the user grants Full Disk Access, or once a bookmark goes
    /// stale across an app update). Treat that as an authorization failure only when the
    /// path is genuinely unreadable. Returns whether scoped access started — the caller must
    /// stop it via `stopAccessingSecurityScopedResource()` only when the result is true.
    private nonisolated static func beginScopedAccess(_ url: URL, deniedError: AppStateError) throws -> Bool {
        let didStart = url.startAccessingSecurityScopedResource()
        if !didStart && !FileManager.default.isReadableFile(atPath: url.path) {
            throw deniedError
        }
        return didStart
    }

    /// Rebase a file URL from the project's stored root path onto the currently resolved root.
    /// Returns the original URL unchanged when the root hasn't moved or the file isn't under it
    /// (the common case), so normal saves are unaffected.
    private nonisolated static func rebasedFileURL(_ url: URL, fromRoot oldRootPath: String, toRoot newRoot: URL) -> URL {
        let oldRoot = (oldRootPath as NSString).standardizingPath
        let newRootPath = newRoot.standardizedFileURL.path
        guard !oldRoot.isEmpty, newRootPath != oldRoot else { return url }
        let filePath = url.standardizedFileURL.path
        guard filePath == oldRoot || filePath.hasPrefix(oldRoot + "/") else { return url }
        let relative = String(filePath.dropFirst(oldRoot.count)).drop(while: { $0 == "/" })
        return newRoot.appendingPathComponent(String(relative))
    }

    private nonisolated static func looksLikeOpenablePath(_ path: String) -> Bool {
        if path.hasPrefix("file://") || path.hasPrefix("/") { return true }
        if path.contains("/") { return true }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return name.count > ext.count + 1
    }

    @discardableResult
    private func appendLoadingEditorTab(url: URL, projectId: UUID, isExternal: Bool) -> UUID {
        let tab = EditorTab(
            id: UUID(),
            projectId: projectId,
            url: url,
            title: url.lastPathComponent,
            text: "",
            savedText: "",
            isDirty: false,
            isExternal: isExternal,
            openedAt: Date(),
            lastActiveAt: Date(),
            modifiedAt: Date(),
            preview: nil,
            isLoadingContent: true,
            loadErrorMessage: nil
        )
        openTabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    private func loadEditorTabContent(tabID: UUID, url: URL, project: ProjectItem?, accessURL: URL?, line: Int?, column: Int?) {
        let generation = UUID()
        editorLoadGenerations[tabID] = generation
        Task.detached(priority: .userInitiated) { [weak self, url, project, accessURL] in
            do {
                let result = try Self.loadEditorFileResult(url: url, project: project, accessURL: accessURL)
                await MainActor.run { [weak self] in
                    self?.applyLoadedEditorFile(result, to: tabID, generation: generation, line: line, column: column)
                }
            } catch {
                let message = Self.message(for: error)
                let isAuthorizationError = Self.isProjectAuthorizationError(error)
                await MainActor.run { [weak self] in
                    self?.applyEditorLoadFailure(message, to: tabID, generation: generation)
                    // A project file we should be able to read got denied — surface an
                    // actionable re-authorize prompt instead of just a dead tab error.
                    if isAuthorizationError, project != nil {
                        self?.showProjectReauthorizePrompt()
                    }
                }
            }
        }
    }

    private func applyLoadedEditorFile(_ result: LoadedEditorFileResult, to tabID: UUID, generation: UUID, line: Int?, column: Int?) {
        guard editorLoadGenerations[tabID] == generation,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        editorLoadGenerations.removeValue(forKey: tabID)
        let text: String
        let preview: EditorPreview?
        switch result.content {
        case .text(let value):
            text = value
            preview = nil
        case .preview(let value):
            text = ""
            preview = value
        }
        openTabs[index].text = text
        openTabs[index].savedText = text
        openTabs[index].isDirty = false
        openTabs[index].modifiedAt = result.modifiedAt
        openTabs[index].preview = preview
        openTabs[index].isLoadingContent = false
        openTabs[index].loadErrorMessage = nil
        jumpEditorIfNeeded(tabID: tabID, line: line, column: column)
    }

    private func applyEditorLoadFailure(_ message: String, to tabID: UUID, generation: UUID) {
        guard editorLoadGenerations[tabID] == generation,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        editorLoadGenerations.removeValue(forKey: tabID)
        openTabs[index].isLoadingContent = false
        openTabs[index].loadErrorMessage = message
        openTabs[index].preview = nil
        openTabs[index].text = ""
        openTabs[index].savedText = ""
        openTabs[index].isDirty = false
    }

    func selectTab(_ tab: EditorTab) {
        selectedTabID = tab.id
        if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
            openTabs[index].lastActiveAt = Date()
        }
    }

    func closeTab(_ tab: EditorTab) {
        guard let index = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        guard confirmDiscardUnsavedTabsIfNeeded([tab]) else { return }
        editorLoadGenerations.removeValue(forKey: tab.id)
        openTabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = openTabs.indices.contains(index) ? openTabs[index].id : openTabs.last?.id
        }
    }

    func updateText(tabID: UUID, text: String) {
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[index].text = text
        openTabs[index].isDirty = text != openTabs[index].savedText
    }

    func saveSelectedTab() {
        guard let id = selectedTabID else { return }
        saveTab(id: id)
    }

    @discardableResult
    func saveTab(id: UUID) -> Bool {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return false }
        return saveTab(at: index)
    }

    @discardableResult
    private func saveTab(at index: Int) -> Bool {
        do {
            let tab = openTabs[index]
            guard tab.isTextEditable else { return true }
            let modifiedAt: Date
            if tab.isExternal {
                let accessURL = authorizedFolderURL(containing: tab.url) ?? tab.url
                let didStart = try Self.beginScopedAccess(accessURL, deniedError: .externalFileAuthorizationLost)
                defer {
                    if didStart { accessURL.stopAccessingSecurityScopedResource() }
                }
                try validateNoExternalModification(for: tab)
                try tab.text.write(to: tab.url, atomically: true, encoding: .utf8)
                modifiedAt = fileModifiedAt(tab.url) ?? Date()
            } else if let project = selectedProject {
                modifiedAt = try withProjectAccess(project) { root in
                    // If the project folder was moved/renamed (security-scoped bookmark follows
                    // the inode, so `root` diverges from the stored path), rebase the write
                    // target onto the resolved root so we never silently write to the stale
                    // (possibly recreated) old location. No-op in the normal case.
                    let target = Self.rebasedFileURL(tab.url, fromRoot: project.path, toRoot: root)
                    try validateNoExternalModification(for: tab, at: target)
                    try tab.text.write(to: target, atomically: true, encoding: .utf8)
                    return fileModifiedAt(target) ?? Date()
                }
            } else {
                throw AppStateError.missingProjectForSave
            }
            openTabs[index].savedText = tab.text
            openTabs[index].isDirty = false
            openTabs[index].modifiedAt = modifiedAt
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func validateNoExternalModification(for tab: EditorTab, at url: URL? = nil) throws {
        let target = url ?? tab.url
        do {
            let currentText = try Self.readTextFile(target)
            if currentText != tab.savedText {
                throw AppStateError.fileModifiedExternally
            }
        } catch let appError as AppStateError {
            // 已经是结构化错误（fileModifiedExternally / projectAuthorizationLost 等），原样抛出。
            throw appError
        } catch {
            // 其他异常说明文件不再可读为之前那种 UTF-8 文本——可能 claude 把它写成了二进制、
            // 改了编码、或暂时被占用。统一视为"已被外部修改"，避免直接覆盖造成数据丢失。
            throw AppStateError.fileModifiedExternally
        }
    }

    private func fileModifiedAt(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func setMode(_ mode: SessionMode) {
        isChatHistorySelectionVisuallySuppressed = false
        selectedMode = mode
        if mode != .resume {
            selectedHistoryProjectPath = nil
        }
    }

    func selectLaunchRecord(_ record: LaunchRecord) {
        isChatHistorySelectionVisuallySuppressed = false
        selectedCLI = record.cliType.visibleValue
        selectedTerminal = record.terminal
        selectedMode = record.mode
        resumeSessionId = record.sessionId ?? ""
        selectedHistoryProjectPath = record.mode == .resume ? record.projectPath : nil
    }

    func startNewChat(for project: ProjectItem? = nil) {
        if let project, selectedProjectID != project.id {
            guard selectProject(project) else { return }
        }
        selectedHistoryProjectPath = nil
        selectedCLIHistoryID = nil
        isChatHistorySelectionVisuallySuppressed = false
        selectedMode = .newSession
        resumeSessionId = ""
        chatConversationSerial = UUID()
        persistWorkspaceSelection(projectPath: selectedProject?.path, historyID: nil)
    }

    func selectCLIHistory(_ session: CLIHistorySession) {
        // The synthetic "新对话" draft row has no on-disk session, so resuming it would run
        // `claude --resume __draft__` against a session that doesn't exist. Treat selecting it
        // as staying in (or returning to) a fresh new-session state instead.
        if session.isDraft {
            startNewChat(for: project(matching: session.projectPath))
            return
        }
        let matchingProject = project(matching: session.projectPath)
        if selectedProjectID != matchingProject?.id {
            guard confirmDiscardUnsavedChangesIfNeeded() else { return }
            selectedProjectID = matchingProject?.id
            if let matchingProject, let index = projects.firstIndex(where: { $0.id == matchingProject.id }) {
                projects[index].lastOpenedAt = Date()
                projects[index].updatedAt = Date()
                try? ProjectStore.saveProjects(projects)
            }
            refreshProjectContext()
        }
        selectedCLI = session.cli.visibleValue
        selectedMode = .resume
        resumeSessionId = session.sessionId
        selectedHistoryProjectPath = session.projectPath
        selectedCLIHistoryID = session.id
        isChatHistorySelectionVisuallySuppressed = false
        chatConversationSerial = UUID()
        persistWorkspaceSelection(projectPath: matchingProject?.path ?? session.projectPath ?? selectedProject?.path, historyID: session.id)
    }

    func deleteCLIHistory(_ session: CLIHistorySession) {
        cliHistory.removeAll { $0.id == session.id }
        if selectedCLIHistoryID == session.id {
            startNewChat()
        }

        Task { [weak self] in
            do {
                let history = try await Task.detached(priority: .utility) { () throws -> [CLIHistorySession] in
                    try Self.deleteCLIHistoryFiles(session: session)
                    return Self.loadCLIHistory()
                }.value
                guard let self else { return }
                self.cliHistory = history.filter { $0.id != session.id }
            } catch {
                guard let self else { return }
                self.show(error)
                self.refreshCLIHistory()
            }
        }
    }

    nonisolated private static func deleteCLIHistoryFiles(session: CLIHistorySession) throws {
        guard session.storageKey == ChatSessionStore.storageKey else { return }
        try ChatSessionStore.deleteSession(id: session.sessionId)
    }

    nonisolated private static func loadCLIHistory() -> [CLIHistorySession] {
        ChatSessionStore.historySessions(from: ChatSessionStore.loadSessions())
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandPreview, forType: .string)
    }

    /// Open the default terminal in the selected project and launch an interactive Claude
    /// session with full permissions: `cd <project> && claude --dangerously-skip-permissions`.
    func openClaudeInTerminal() {
        guard let projectPath = selectedHistoryProjectPath ?? selectedProject?.path else {
            errorMessage = "请先添加并选择项目。"
            return
        }
        let command = "cd \(Self.shellQuoted(projectPath)) && claude --dangerously-skip-permissions"
        let terminal = selectedTerminal
        Task {
            do {
                try await TerminalLauncher.launch(command: command, terminal: terminal)
            } catch {
                show(error)
            }
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func openTerminal() {
        guard let projectPath = selectedHistoryProjectPath ?? selectedProject?.path else {
            errorMessage = "请先添加并选择项目。"
            return
        }
        let projectId = selectedProject?.id ?? UUID()
        let projectName = selectedProject?.name ?? URL(fileURLWithPath: projectPath).lastPathComponent
        let command = commandPreview
        let cli = selectedCLI
        let mode = selectedMode
        let sessionId = resumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = selectedTerminal

        Task {
            do {
                try await TerminalLauncher.launch(command: command, terminal: terminal)
                let now = Date()
                let record = LaunchRecord(
                    id: UUID(),
                    projectId: projectId,
                    projectName: projectName,
                    projectPath: projectPath,
                    cliType: cli,
                    mode: mode,
                    sessionId: sessionId.isEmpty ? nil : sessionId,
                    title: mode.title,
                    command: command,
                    terminal: terminal,
                    source: "本地",
                    createdAt: now,
                    launchedAt: now
                )
                launchHistory.insert(record, at: 0)
                try LaunchHistoryStore.save(launchHistory)
            } catch {
                show(error)
            }
        }
    }

    func refreshCLIHistory() {
        if isCLIHistoryRefreshInFlight {
            pendingCLIHistoryRefresh = true
            return
        }
        isCLIHistoryRefreshInFlight = true
        cliHistoryRefreshGeneration += 1
        let generation = cliHistoryRefreshGeneration
        Task { [weak self] in
            let history = await Task.detached(priority: .utility) {
                Self.loadCLIHistory()
            }.value
            guard let self else { return }
            if self.cliHistoryRefreshGeneration == generation {
                if self.cliHistory != history {
                    self.cliHistory = history
                }
                self.clearStaleCLIHistorySelectionIfNeeded(in: history)
                self.restorePendingHistorySelectionIfPossible(finalizeIfMissing: true)
                self.fulfillPendingOpenLatestChatSelection(in: history)
            }
            self.isCLIHistoryRefreshInFlight = false
            if self.pendingCLIHistoryRefresh {
                self.pendingCLIHistoryRefresh = false
                self.refreshCLIHistory()
            }
        }
    }

    private func clearStaleCLIHistorySelectionIfNeeded(in history: [CLIHistorySession]) {
        guard let selectedCLIHistoryID, !history.contains(where: { $0.id == selectedCLIHistoryID }) else { return }
        selectedHistoryProjectPath = nil
        self.selectedCLIHistoryID = nil
        selectedMode = .newSession
        resumeSessionId = ""
        isChatHistorySelectionVisuallySuppressed = false
        chatConversationSerial = UUID()
        persistWorkspaceSelection(projectPath: selectedProject?.path, historyID: nil)
    }

    private func fulfillPendingOpenLatestChatSelection(in history: [CLIHistorySession]) {
        guard let projectID = pendingOpenLatestChatProjectID else { return }
        guard selectedProjectID == projectID,
              selectedCLIHistoryID == nil,
              let project = selectedProject else {
            pendingOpenLatestChatProjectID = nil
            return
        }
        pendingOpenLatestChatProjectID = nil
        if let latestSession = latestCLIHistorySession(for: project, in: history) {
            selectCLIHistory(latestSession)
        }
    }

    func showFolderPermissionOnboardingIfNeeded() {
        guard !hasShownFolderPermissionOnboardingThisLaunch,
              !settings.hasSeenFolderPermissionOnboarding,
              settings.authorizedFolders.isEmpty,
              permissionPrompt == nil else { return }
        hasShownFolderPermissionOnboardingThisLaunch = true
        permissionPrompt = PermissionPrompt(
            title: "授权常用文件夹",
            message: "你可以现在选择桌面、下载、文稿或常用工作目录。acode 只会获得你在系统面板中明确选择的文件夹权限，之后打开这些位置的文件会减少重复授权。",
            primaryButtonTitle: "选择文件夹授权",
            secondaryButtonTitle: "稍后",
            action: .authorizeCommonFolders,
            secondaryAction: .dismissFolderPermissionOnboarding
        )
    }

    func addAuthorizedFolder() {
        presentAuthorizedFolderPanel(allowsMultipleSelection: false, markOnboardingSeenOnSuccess: false)
    }

    private func presentAuthorizedFolderPanel(allowsMultipleSelection: Bool, markOnboardingSeenOnSuccess: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.prompt = "授权文件夹"
        panel.message = allowsMultipleSelection
            ? "选择桌面、下载、文稿或常用工作目录后，acode 会复用这些用户授权的文件夹权限。"
            : "选择后，acode 可复用该文件夹权限，减少再次打开其中文件时的授权弹窗。"
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.storeAuthorizedFolders(panel.urls, markOnboardingSeenOnSuccess: markOnboardingSeenOnSuccess)
            }
        }
    }

    func removeAuthorizedFolder(_ folder: AuthorizedFolder) {
        settings.authorizedFolders.removeAll { $0.id == folder.id }
        do {
            try ProjectStore.saveSettings(settings)
        } catch {
            show(error)
        }
    }

    private func storeAuthorizedFolders(_ urls: [URL], markOnboardingSeenOnSuccess: Bool) {
        do {
            for url in urls {
                let folderURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let bookmarkData = try folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let folderPath = Self.normalizedFileTreePath(folderURL.path)
                settings.authorizedFolders.removeAll { Self.normalizedFileTreePath($0.path) == folderPath }
                settings.authorizedFolders.append(
                    AuthorizedFolder(
                        id: UUID(),
                        name: folderURL.lastPathComponent.isEmpty ? folderPath : folderURL.lastPathComponent,
                        path: folderPath,
                        bookmarkData: bookmarkData,
                        createdAt: Date()
                    )
                )
            }
            if markOnboardingSeenOnSuccess {
                settings.hasSeenFolderPermissionOnboarding = true
            }
            try ProjectStore.saveSettings(settings)
        } catch {
            show(error)
        }
    }

    func saveSettings(
        defaultCLI: CLIType,
        defaultTerminal: TerminalType,
        showCommandPreview: Bool,
        appendRuleEnabled: Bool,
        appendRuleText: String,
        ignoredFolders: [String]
    ) {
        let didChangeIgnoredFolders = settings.ignoredFolders != ignoredFolders
        let didChangeDefaultCLI = settings.defaultCLI.visibleValue != defaultCLI.visibleValue
        // Mutate in place so we don't accidentally wipe newer fields the caller
        // doesn't know about (remote chat server config, custom model IDs, etc.).
        settings.defaultTerminal = defaultTerminal
        settings.defaultCLI = defaultCLI
        settings.showCommandPreview = showCommandPreview
        settings.appendRuleEnabled = appendRuleEnabled
        settings.appendRuleText = appendRuleText
        settings.ignoredFolders = ignoredFolders
        selectedTerminal = defaultTerminal
        if didChangeIgnoredFolders {
            scanner = FileTreeScanner(ignoredNames: Set(ignoredFolders))
        }
        do {
            try ProjectStore.saveSettings(settings)
            if didChangeIgnoredFolders {
                refreshFileTree()
            }
            if didChangeDefaultCLI {
                refreshCLIHistory()
            }
        } catch {
            show(error)
        }
    }

    func updateChatPanelWidth(_ width: Double) {
        guard width > 0, settings.chatPanelWidth != width else { return }
        settings.chatPanelWidth = width
        try? ProjectStore.saveSettings(settings)
    }

    func updateSidebarProjectSectionHeight(_ height: Double) {
        guard height > 0, settings.sidebarProjectSectionHeight != height else { return }
        settings.sidebarProjectSectionHeight = height
        try? ProjectStore.saveSettings(settings)
    }

    func saveChatSelection(
        cli: CLIType,
        permissionMode: ChatPermissionMode,
        modelID: String,
        reasoningEffort: ChatReasoningEffort? = nil
    ) {
        let cli = cli.visibleValue
        settings.chatCLI = cli
        settings.chatPermissionMode = permissionMode
        switch cli {
        case .codex:
            settings.selectedCodexModelID = modelID
            if let reasoningEffort {
                settings.selectedCodexReasoningEffort = reasoningEffort
            }
        case .claude, .custom:
            settings.selectedClaudeModelID = modelID
            if let reasoningEffort {
                settings.selectedClaudeReasoningEffort = reasoningEffort
            }
        default:
            // 第三方 CLI 各自记忆模型/思考强度，互不覆盖。
            settings.selectedModelIDsByCLI[cli.rawValue] = modelID
            if let reasoningEffort {
                settings.selectedReasoningEffortsByCLI[cli.rawValue] = reasoningEffort
            }
        }
        selectedCLI = cli
        do {
            try ProjectStore.saveSettings(settings)
        } catch {
            show(error)
        }
    }

    func bindingForTabText(_ id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.openTabs.first(where: { $0.id == id })?.text ?? "" },
            set: { [weak self] newValue in self?.updateText(tabID: id, text: newValue) }
        )
    }

    private struct LoadedEditorFileResult {
        let content: LoadedEditorFile
        let modifiedAt: Date
    }

    private enum LoadedEditorFile {
        case text(String)
        case preview(EditorPreview)
    }

    private nonisolated static func loadEditorFileResult(url: URL, project: ProjectItem?, accessURL: URL?) throws -> LoadedEditorFileResult {
        if let project {
            let root = try ProjectStore.resolveURL(for: project)
            let didStart = try Self.beginScopedAccess(root, deniedError: .projectAuthorizationLost)
            defer { if didStart { root.stopAccessingSecurityScopedResource() } }
            let content = try readEditorFile(url)
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return LoadedEditorFileResult(content: content, modifiedAt: modifiedAt)
        }

        guard let accessURL else { throw AppStateError.externalFileAuthorizationLost }
        let didStart = try Self.beginScopedAccess(accessURL, deniedError: .externalFileAuthorizationLost)
        defer { if didStart { accessURL.stopAccessingSecurityScopedResource() } }
        let content = try readEditorFile(url)
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return LoadedEditorFileResult(content: content, modifiedAt: modifiedAt)
    }

    private nonisolated static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "操作失败：\(error.localizedDescription)"
    }

    private nonisolated static func readEditorFile(_ url: URL) throws -> LoadedEditorFile {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .contentModificationDateKey])
        let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let size = values.fileSize ?? 0

        if contentType?.conforms(to: .pdf) == true {
            let data = try readPreviewData(url, size: size)
            return .preview(.pdf(data, isValid: PDFDocument(data: data) != nil))
        }

        if contentType?.conforms(to: .image) == true {
            return .preview(.image(try readImagePreviewDescriptor(url, size: size, modifiedAt: values.contentModificationDate)))
        }

        return .text(try readTextFile(url, size: size))
    }

    private nonisolated static func readImagePreviewDescriptor(_ url: URL, size: Int, modifiedAt: Date?) throws -> ImagePreviewDescriptor {
        if size > 50 * 1024 * 1024 {
            throw AppStateError.previewFileTooLarge
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = Self.imageDimension(properties[kCGImagePropertyPixelWidth]),
              let height = Self.imageDimension(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0 else {
            throw AppStateError.unsupportedPreview
        }
        let pixels = Int64(width) * Int64(height)
        guard pixels <= 100_000_000, pixels * 4 <= 384 * 1024 * 1024 else {
            throw AppStateError.imageDimensionsTooLarge(width, height)
        }
        let bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ImagePreviewDescriptor(url: url, byteCount: size, pixelWidth: width, pixelHeight: height, modifiedAt: modifiedAt, bookmarkData: bookmarkData)
    }

    private nonisolated static func imageDimension(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private nonisolated static func readPreviewData(_ url: URL, size: Int) throws -> Data {
        if size > 50 * 1024 * 1024 {
            throw AppStateError.previewFileTooLarge
        }
        return try Data(contentsOf: url)
    }

    private nonisolated static func readTextFile(_ url: URL, size: Int? = nil) throws -> String {
        let fileSize: Int
        if let size {
            fileSize = size
        } else {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            fileSize = values.fileSize ?? 0
        }

        if fileSize > 5 * 1024 * 1024 {
            throw AppStateError.fileTooLarge
        }

        let data = try Data(contentsOf: url)
        if data.prefix(4096).contains(0) {
            throw AppStateError.binaryFile
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppStateError.unsupportedEncoding
        }
        return text
    }

    private func withProjectAccess<T>(_ project: ProjectItem, operation: (URL) throws -> T) throws -> T {
        let url = try ProjectStore.resolveURL(for: project)
        let didStart = try Self.beginScopedAccess(url, deniedError: .projectAuthorizationLost)
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try operation(url)
    }

    private func confirmDiscardUnsavedChangesIfNeeded() -> Bool {
        confirmDiscardUnsavedTabsIfNeeded(openTabs)
    }

    private func confirmDiscardUnsavedTabsIfNeeded(_ tabs: [EditorTab]) -> Bool {
        let dirtyTabs = tabs.filter(\.isDirty)
        guard !dirtyTabs.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = dirtyTabs.count == 1 ? "保存对“\(dirtyTabs[0].title)”的修改？" : "保存 \(dirtyTabs.count) 个已修改文件？"
        alert.informativeText = "不保存会丢失当前编辑内容。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirtyTabs.allSatisfy { tab in
                guard let index = openTabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                return saveTab(at: index)
            }
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func show(_ error: Error) {
        if error is ProjectStoreError || Self.isProjectAuthorizationError(error) {
            showFullDiskAccessPrompt()
            return
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            errorMessage = description
        } else {
            errorMessage = "操作失败：\(error.localizedDescription)"
        }
    }

    private nonisolated static func isProjectAuthorizationError(_ error: Error) -> Bool {
        guard let appError = error as? AppStateError else { return false }
        if case .projectAuthorizationLost = appError {
            return true
        }
        return false
    }

    private func showFileAccessPrompt(for fileURL: URL) {
        permissionPrompt = PermissionPrompt(
            title: "需要文件访问权限",
            message: "macOS 拒绝读取“\(fileURL.lastPathComponent)”。可到系统设置里给 acode 开启完整磁盘访问，之后切换项目和打开外部文件会少很多重复授权。",
            primaryButtonTitle: "打开完整磁盘访问",
            secondaryButtonTitle: "知道了",
            action: .openFullDiskAccessSettings
        )
    }

    private func showFullDiskAccessPrompt() {
        permissionPrompt = PermissionPrompt(
            title: "需要完整磁盘访问",
            message: "macOS 的完整磁盘访问必须由用户在系统设置中开启。开启后重启 acode，项目切换、读取文件和打开外部文件会复用系统权限。",
            primaryButtonTitle: "打开系统设置",
            secondaryButtonTitle: "稍后",
            action: .openFullDiskAccessSettings
        )
    }

    /// A project file failed to read (commonly: the project sits in a TCC-protected folder like
    /// ~/Desktop and its security-scoped bookmark went stale across an app update). Offer a
    /// direct "re-authorize" (re-pick the folder → fresh bookmark) plus the Full Disk Access path.
    private func showProjectReauthorizePrompt() {
        guard let project = selectedProject else {
            showFullDiskAccessPrompt()
            return
        }
        permissionPrompt = PermissionPrompt(
            title: "需要重新授权项目",
            message: "macOS 拒绝读取项目「\(project.name)」内的文件——通常是项目在桌面/文稿等受保护目录、授权已失效。点“重新授权”重新选择该项目文件夹即可恢复访问；或开启完整磁盘访问一劳永逸。",
            primaryButtonTitle: "重新授权",
            secondaryButtonTitle: "打开完整磁盘访问",
            action: .reauthorizeProject(project.id),
            secondaryAction: .openFullDiskAccessSettings
        )
    }

    /// Re-pick the project's folder via NSOpenPanel to mint a fresh security-scoped bookmark,
    /// restoring access after a stale bookmark.
    func reauthorizeProject(_ projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: project.path, isDirectory: true)
        panel.message = "重新选择项目文件夹「\(project.name)」以恢复访问权限。"
        panel.prompt = "授权"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            projects[index].bookmarkData = bookmark
            projects[index].path = url.path
            projects[index].updatedAt = Date()
            try ProjectStore.saveProjects(projects)
        } catch {
            show(error)
        }
    }

    func handlePermissionPromptAction(_ action: PermissionPrompt.Action) {
        switch action {
        case .openFullDiskAccessSettings:
            Self.openFullDiskAccessSettings()
            permissionPrompt = nil
        case .authorizeCommonFolders:
            permissionPrompt = nil
            presentAuthorizedFolderPanel(allowsMultipleSelection: true, markOnboardingSeenOnSuccess: true)
        case .dismissFolderPermissionOnboarding:
            permissionPrompt = nil
            settings.hasSeenFolderPermissionOnboarding = true
            do {
                try ProjectStore.saveSettings(settings)
            } catch {
                show(error)
            }
        case .reauthorizeProject(let projectID):
            permissionPrompt = nil
            reauthorizeProject(projectID)
        }
    }

    private nonisolated static func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

struct PermissionPrompt: Identifiable, Equatable {
    enum Action: Equatable {
        case openFullDiskAccessSettings
        case authorizeCommonFolders
        case dismissFolderPermissionOnboarding
        case reauthorizeProject(UUID)
    }

    let id = UUID()
    var title: String
    var message: String
    var primaryButtonTitle: String
    var secondaryButtonTitle: String
    var action: Action
    var secondaryAction: Action? = nil
}

@MainActor
final class EditorCursorStore: ObservableObject {
    @Published private(set) var line: Int = 1
    @Published private(set) var column: Int = 1

    func update(line: Int, column: Int) {
        let normalizedLine = max(1, line)
        let normalizedColumn = max(1, column)
        guard self.line != normalizedLine || self.column != normalizedColumn else { return }
        self.line = normalizedLine
        self.column = normalizedColumn
    }
}

private enum AppStateError: LocalizedError {
    case fileTooLarge
    case previewFileTooLarge
    case imageDimensionsTooLarge(Int, Int)
    case binaryFile
    case unsupportedEncoding
    case unsupportedPreview
    case missingProjectForSave
    case emptyFileName
    case invalidFileName
    case fileAlreadyExists(String)
    case fileOutsideProject
    case fileModifiedExternally
    case fileOperationFailed
    case projectAuthorizationLost
    case externalFileAuthorizationLost

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "文件过大，暂不支持打开超过 5 MB 的文本文件。"
        case .previewFileTooLarge: "文件过大，暂不支持预览超过 50 MB 的文件。"
        case .imageDimensionsTooLarge(let width, let height): "图片尺寸过大（\(width)×\(height)），暂不支持在编辑器中预览。"
        case .binaryFile: "这是二进制文件，暂不支持在编辑器中打开。"
        case .unsupportedEncoding: "文件编码不是 UTF-8，暂不支持打开。"
        case .unsupportedPreview: "这个文件暂不支持在编辑器中预览。"
        case .missingProjectForSave: "当前文件不在已授权项目中，无法保存。"
        case .emptyFileName: "名称不能为空。"
        case .invalidFileName: "名称不能包含路径分隔符，也不能是 . 或 ..。"
        case .fileAlreadyExists(let name): "“\(name)”已经存在。"
        case .fileOutsideProject: "只能操作当前项目内的文件。"
        case .fileModifiedExternally: "文件已被外部修改，已停止保存以避免覆盖。请重新打开文件或先处理外部变更。"
        case .fileOperationFailed: "文件操作失败。"
        case .projectAuthorizationLost: "项目目录授权失效，请重新添加或重新授权项目。"
        case .externalFileAuthorizationLost: "外部文件授权失效，请重新打开文件后再保存。"
        }
    }
}
