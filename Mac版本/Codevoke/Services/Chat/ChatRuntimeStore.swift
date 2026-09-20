import Combine
import Foundation
import UserNotifications

@MainActor
final class ChatRuntimeStore: ObservableObject {
    private var statesByKey: [String: ChatPanelState] = [:]
    private weak var lastKnownState: ChatPanelState?
    private var lastKnownRuntimeKey: String?
    private var lastKnownProjectID: UUID?
    // LRU order (oldest first) of distinct in-memory session states, used to evict idle ones.
    private var lruOrder: [ObjectIdentifier] = []
    // Keep at most this many idle (finished, non-visible) session states in memory; the rest
    // are evicted (they reload from disk on re-select). Bounds memory for users who visit many
    // conversations. Running / queued / visible states are never evicted.
    private let maxRetainedIdleStates = 12
    private var activityRefreshGeneration = 0
    private var remoteChatSessionsObserver: NSObjectProtocol?
    @Published private var activityBySessionID: [String: ChatSessionActivity] = [:]

    init() {
        refreshPersistedActivities()
        remoteChatSessionsObserver = NotificationCenter.default.addObserver(forName: .remoteChatSessionsDidChange, object: nil, queue: .main) { [weak self] notification in
            guard notification.userInfo?["session"] as? ChatSessionRecord == nil else { return }
            Task { @MainActor [weak self] in
                self?.refreshPersistedActivities()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let remoteChatSessionsObserver {
                NotificationCenter.default.removeObserver(remoteChatSessionsObserver)
            }
        }
    }

    func state(
        for appState: AppState,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort
    ) -> ChatPanelState {
        let key = runtimeKey(for: appState)
        if let localKey = localHistoryKey(for: appState), let state = statesByKey[localKey] {
            statesByKey[key] = state
            remember(state, key: key, projectID: appState.selectedProjectID)
            return state
        }
        if let state = statesByKey[key] {
            if stateMatchesSelectedHistory(state, appState: appState) {
                remember(state, key: key, projectID: appState.selectedProjectID)
                return state
            }
            retainStateIfNeeded(state)
            statesByKey.removeValue(forKey: key)
        }
        if let historyID = appState.selectedCLIHistoryID,
           let state = stateByReverseLookup(historyID: historyID) {
            remember(state, key: key, projectID: appState.selectedProjectID)
            return state
        }
        if let historyID = appState.selectedCLIHistoryID,
           let state = lastKnownState,
           appState.selectedProjectID == lastKnownProjectID,
           state.currentSessionID?.uuidString == sessionUUIDComponent(in: historyID) {
            statesByKey[key] = state
            registerAliases(for: state, primaryHistoryID: historyID, runtimeKey: key)
            remember(state, key: key, projectID: appState.selectedProjectID)
            return state
        }

        let state = ChatPanelState()
        statesByKey[key] = state
        bind(state, primaryHistoryID: appState.selectedCLIHistoryID, appState: appState)
        state.loadFromAppState(appState, modelID: modelID, permissionMode: permissionMode, reasoningEffort: reasoningEffort)
        registerAliases(for: state, primaryHistoryID: appState.selectedCLIHistoryID, runtimeKey: key)
        remember(state, key: key, projectID: appState.selectedProjectID)
#if DEBUG
        print("[ChatRuntimeStore] Created fresh empty state for key=\(key) selectedCLIHistoryID=\(appState.selectedCLIHistoryID ?? "nil") cliHistoryCount=\(appState.cliHistory.count)")
#endif
        return state
    }

    func remoteDraftState(
        for project: ProjectItem,
        appState: AppState,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort
    ) -> ChatPanelState {
        let key = "remote-draft:\(project.id.uuidString):\(UUID().uuidString)"
        let state = ChatPanelState()
        statesByKey[key] = state
        bind(state, primaryHistoryID: nil, appState: appState)
        state.setRuntimeVisible(false)
        state.loadDraftDefaults(
            cli: project.defaultCLI.visibleValue,
            modelID: modelID,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
        return state
    }

    func remoteSessionState(
        for history: CLIHistorySession,
        appState: AppState,
        projectID: UUID?,
        modelID: String,
        permissionMode: ChatPermissionMode,
        reasoningEffort: ChatReasoningEffort
    ) -> ChatPanelState? {
        guard history.storageKey == ChatSessionStore.storageKey,
              let sessionID = UUID(uuidString: history.sessionId) else { return nil }
        if let state = controller(for: sessionID) {
            statesByKey["history:\(history.id)"] = state
            return state
        }
        let key = "remote-history:\(history.id)"
        let state = ChatPanelState()
        statesByKey[key] = state
        bind(state, primaryHistoryID: history.id, appState: appState)
        state.setRuntimeVisible(false)
        state.loadDraftDefaults(
            cli: history.cli.visibleValue,
            modelID: modelID,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
        state.loadPersistedSession(sessionID)
        registerAliases(for: state, primaryHistoryID: history.id, runtimeKey: key)
        return state
    }

    func activity(for session: CLIHistorySession) -> ChatSessionActivity? {
        activityBySessionID[session.id]
    }

    /// Per-session controller accessor used by the remote VNC server
    /// (`PanelStateBroadcaster` / `RemoteChatCommandRouter`).
    ///
    /// `nil` means "the most recently visible controller" — useful for the
    /// "currently focused" case before any explicit `focusSession` arrives.
    /// Resolution prefers exact-id match against `currentSessionID`, then
    /// falls back to the `local:<uuid>` alias, then to the last-known state.
    func controller(for sessionId: UUID?) -> ChatPanelController? {
        guard let sessionId else { return lastKnownState }
        if let state = statesByKey.values.first(where: { $0.currentSessionID == sessionId }) {
            return state
        }
        if let state = statesByKey["local:\(sessionId.uuidString)"] {
            return state
        }
        return nil
    }

    func allLiveControllers() -> [ChatPanelController] {
        var seen = Set<ObjectIdentifier>()
        var controllers: [ChatPanelController] = []
        for state in statesByKey.values {
            let identifier = ObjectIdentifier(state)
            guard seen.insert(identifier).inserted else { continue }
            controllers.append(state)
        }
        return controllers
    }

    func prepareForApplicationTermination() {
        for controller in allLiveControllers() {
            controller.prepareForApplicationTermination()
        }
    }

    func refreshPersistedActivities() {
        activityRefreshGeneration += 1
        let generation = activityRefreshGeneration
        Task { [weak self] in
            let persistedActivities = await Task.detached(priority: .utility) {
                var activities: [String: ChatSessionActivity] = [:]
                for session in ChatSessionStore.loadSessions() {
                    activities["\(session.cli.rawValue):\(session.id.uuidString)"] = ChatSessionActivity(
                        status: session.runStatus,
                        statusText: session.statusText,
                        queuedCount: 0,
                        lastCompletedAt: session.lastCompletedAt,
                        activeRunStartedAt: session.activeRunStartedAt
                    )
                }
                return activities
            }.value
            guard let self, self.activityRefreshGeneration == generation else { return }
            var activities = self.activityBySessionID
            for (sessionID, activity) in persistedActivities {
                if let current = activities[sessionID],
                   current.status.isRunning,
                   !activity.status.isRunning,
                   self.hasLiveRun(forHistoryID: sessionID) {
                    continue
                }
                activities[sessionID] = activity
            }
            if activities != self.activityBySessionID {
                self.activityBySessionID = activities
            }
        }
    }

    func removeRuntime(for session: CLIHistorySession, discardingState: Bool = false) {
        activityBySessionID.removeValue(forKey: session.id)
        let primaryKey = "history:\(session.id)"
        let localKey = session.storageKey == ChatSessionStore.storageKey ? "local:\(session.sessionId)" : nil
        let removedState = statesByKey[primaryKey]
            ?? localKey.flatMap { statesByKey[$0] }
            ?? stateByReverseLookup(historyID: session.id)
        statesByKey.removeValue(forKey: primaryKey)
        if let localKey {
            statesByKey.removeValue(forKey: localKey)
        }
        if let removedState {
            removedState.setRuntimeVisible(false)
            if discardingState {
                removedState.discardCurrentSessionWithoutPersisting()
            }
            statesByKey = statesByKey.filter { $0.value !== removedState }
            if lastKnownState === removedState {
                lastKnownState = nil
                lastKnownRuntimeKey = nil
                lastKnownProjectID = nil
            }
        }
    }

    private func bind(_ state: ChatPanelState, primaryHistoryID: String?, appState: AppState) {
        state.onActivityChanged = { [weak self, weak state] activity in
            guard let self, let state else { return }
            self.updateActivity(activity, for: state, primaryHistoryID: primaryHistoryID)
        }
        state.onRemoteSessionBegan = { [weak self, weak state, weak appState] session in
            guard let self, let state, let appState else { return }
            self.registerAliases(for: state, primaryHistoryID: self.historyID(for: session))
            appState.upsertPersistedChatSession(session)
        }
        state.onSessionPersisted = { [weak self, weak state, weak appState] in
            guard let self, let state else { return }
            self.registerAliases(for: state, primaryHistoryID: primaryHistoryID)
            guard let session = state.currentSessionSnapshot else { return }
            Task { @MainActor [weak self, weak state, weak appState] in
                guard let self, let state, let appState else { return }
                self.registerAliases(for: state, primaryHistoryID: primaryHistoryID)
                appState.upsertPersistedChatSession(session)
                let shouldAdoptSelection = self.isSelectedState(state, for: appState)
                if shouldAdoptSelection {
                    appState.adoptPersistedChatSession(session)
                }
            }
        }
    }

    private func updateActivity(_ activity: ChatSessionActivity?, for state: ChatPanelState, primaryHistoryID: String?) {
        guard let activity else { return }
        let previousActivities = activityBySessionID
        var activities = previousActivities
        let session = state.currentSessionSnapshot
        if let primaryHistoryID {
            activities[primaryHistoryID] = activity
        }
        if let session {
            activities[historyID(for: session)] = activity
        }
        if activities != activityBySessionID {
            activityBySessionID = activities
        }
        notifyTerminalActivityIfNeeded(
            activity,
            previousActivities: previousActivities,
            session: session,
            primaryHistoryID: primaryHistoryID
        )
    }

    private func notifyTerminalActivityIfNeeded(
        _ activity: ChatSessionActivity,
        previousActivities: [String: ChatSessionActivity],
        session: ChatSessionRecord?,
        primaryHistoryID: String?
    ) {
        guard let session,
              ConversationDesktopNotifier.notificationKind(for: activity) != nil else { return }
        let keys = [primaryHistoryID, historyID(for: session)].compactMap { $0 }
        guard keys.contains(where: { previousActivities[$0]?.status.isRunning == true }) else { return }
        ConversationDesktopNotifier.shared.deliverTerminalNotification(session: session, activity: activity)
    }

    private func remember(_ state: ChatPanelState, key: String, projectID: UUID?) {
        if lastKnownState !== state {
            lastKnownState?.setRuntimeVisible(false)
        }
        state.setRuntimeVisible(true)
        lastKnownState = state
        lastKnownRuntimeKey = key
        lastKnownProjectID = projectID
        touchLRU(state)
        evictIdleStatesIfNeeded()
    }

    private func touchLRU(_ state: ChatPanelState) {
        let identifier = ObjectIdentifier(state)
        lruOrder.removeAll { $0 == identifier }
        lruOrder.append(identifier)
    }

    /// Drop the oldest idle (non-running, non-visible) session states beyond the cap so memory
    /// doesn't grow unbounded as the user visits many conversations. Evicted states deallocate
    /// (all aliases removed) and reload from disk if re-selected. Never evicts a state with a
    /// live run / queued requests / mirroring, nor the currently visible one.
    private func evictIdleStatesIfNeeded() {
        var statesByIdentifier: [ObjectIdentifier: ChatPanelState] = [:]
        for state in statesByKey.values {
            statesByIdentifier[ObjectIdentifier(state)] = state
        }
        // Drop identifiers for states no longer held anywhere.
        lruOrder.removeAll { statesByIdentifier[$0] == nil }
        let visibleIdentifier = lastKnownState.map(ObjectIdentifier.init)
        let evictable = lruOrder.filter { identifier in
            guard let state = statesByIdentifier[identifier], identifier != visibleIdentifier else { return false }
            return !state.shouldRetainRuntime
        }
        let overflow = evictable.count - maxRetainedIdleStates
        guard overflow > 0 else { return }
        for identifier in evictable.prefix(overflow) {
            guard let state = statesByIdentifier[identifier] else { continue }
            state.setRuntimeVisible(false)
            statesByKey = statesByKey.filter { $0.value !== state }
            lruOrder.removeAll { $0 == identifier }
            if lastKnownState === state {
                lastKnownState = nil
                lastKnownRuntimeKey = nil
                lastKnownProjectID = nil
            }
        }
    }

    private func stateMatchesSelectedHistory(_ state: ChatPanelState, appState: AppState) -> Bool {
        guard let historyID = appState.selectedCLIHistoryID,
              let expectedUUID = sessionUUIDComponent(in: historyID),
              let currentUUID = state.currentSessionID?.uuidString else { return true }
        return currentUUID == expectedUUID
    }

    private func stateByReverseLookup(historyID: String) -> ChatPanelState? {
        guard let uuid = sessionUUIDComponent(in: historyID) else { return nil }
        if let state = statesByKey["local:\(uuid)"] {
            statesByKey["history:\(historyID)"] = state
            return state
        }
        guard let state = statesByKey.values.first(where: { $0.currentSessionID?.uuidString == uuid }) else { return nil }
        statesByKey["history:\(historyID)"] = state
        return state
    }

    private func hasLiveRun(forHistoryID historyID: String) -> Bool {
        guard let uuid = sessionUUIDComponent(in: historyID) else { return false }
        return statesByKey.values.contains { state in
            state.currentSessionID?.uuidString == uuid && state.hasLiveRun
        }
    }

    private func retainStateIfNeeded(_ state: ChatPanelState) {
        guard state.shouldRetainRuntime else { return }
        state.setRuntimeVisible(false)
        if let session = state.currentSessionSnapshot {
            registerAliases(for: state, primaryHistoryID: historyID(for: session))
        } else {
            statesByKey["retained:\(ObjectIdentifier(state).hashValue)"] = state
        }
    }

    private func sessionUUIDComponent(in historyID: String) -> String? {
        let parts = historyID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[1]) != nil else { return nil }
        return parts[1]
    }

    private func registerAliases(for state: ChatPanelState, primaryHistoryID: String?, runtimeKey: String? = nil) {
        guard let session = state.currentSessionSnapshot else {
            if let primaryHistoryID {
                statesByKey["history:\(primaryHistoryID)"] = state
            }
            if let runtimeKey {
                statesByKey[runtimeKey] = state
            }
            return
        }
        let localKey = "local:\(session.id.uuidString)"
        statesByKey[localKey] = state
        statesByKey["history:\(historyID(for: session))"] = state
        if let externalSessionID = session.externalSessionID?.nonEmptyTrimmed {
            statesByKey["history:\(session.cli.visibleValue.rawValue):\(externalSessionID)"] = state
        }
        if let primaryHistoryID {
            statesByKey["history:\(primaryHistoryID)"] = state
        }
    }

    private func isSelectedState(_ state: ChatPanelState, for appState: AppState?) -> Bool {
        guard let appState else { return false }
        if statesByKey[runtimeKey(for: appState)] === state {
            return true
        }
        if let localKey = localHistoryKey(for: appState), statesByKey[localKey] === state {
            return true
        }
        return false
    }

    private func runtimeKey(for appState: AppState) -> String {
        if let historyID = appState.selectedCLIHistoryID {
            return "history:\(historyID)"
        }
        let projectID = appState.selectedProjectID?.uuidString ?? "none"
        return "draft:\(projectID):\(appState.chatConversationSerial.uuidString)"
    }

    private func localHistoryKey(for appState: AppState) -> String? {
        guard let historyID = appState.selectedCLIHistoryID,
              let history = appState.cliHistory.first(where: { $0.id == historyID }),
              history.storageKey == ChatSessionStore.storageKey else { return nil }
        return "local:\(history.sessionId)"
    }

    private func historyID(for session: ChatSessionRecord) -> String {
        "\(session.cli.rawValue):\(session.id.uuidString)"
    }
}

private final class ConversationDesktopNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ConversationDesktopNotifier()

    private let center = UNUserNotificationCenter.current()
    private var isRequestingAuthorization = false

    private override init() {
        super.init()
        center.delegate = self
    }

    static func notificationKind(for activity: ChatSessionActivity) -> TerminalNotificationKind? {
        switch activity.status {
        case .completed where activity.statusText != "已停止": .completed
        case .failed, .unsupportedVersion: .failed
        default: nil
        }
    }

    func deliverTerminalNotification(session: ChatSessionRecord, activity: ChatSessionActivity) {
        guard let kind = Self.notificationKind(for: activity) else { return }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleNotification(kind: kind, session: session, activity: activity)
            case .notDetermined:
                self.requestAuthorization(kind: kind, session: session, activity: activity)
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func requestAuthorization(kind: TerminalNotificationKind, session: ChatSessionRecord, activity: ChatSessionActivity) {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self else { return }
            self.isRequestingAuthorization = false
            guard granted else { return }
            self.scheduleNotification(kind: kind, session: session, activity: activity)
        }
    }

    private func scheduleNotification(kind: TerminalNotificationKind, session: ChatSessionRecord, activity: ChatSessionActivity) {
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = body(for: session, activity: activity)
        content.sound = .default
        let identifier = "conversation.\(session.id.uuidString).\(kind.rawValue).\(Int(Date().timeIntervalSince1970 * 1000))"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func body(for session: ChatSessionRecord, activity: ChatSessionActivity) -> String {
        let title = session.title.nonEmptyTrimmed ?? "未命名对话"
        let project = session.projectName.nonEmptyTrimmed ?? session.projectPath.nonEmptyTrimmed ?? "未知项目"
        if activity.status == .completed {
            return "\(project) · \(title)"
        }
        return "\(project) · \(title) · \(activity.statusText)"
    }
}

private enum TerminalNotificationKind: String {
    case completed
    case failed

    var title: String {
        switch self {
        case .completed: "对话已完成"
        case .failed: "对话异常"
        }
    }
}
