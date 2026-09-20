import Foundation
import ChatCore

/// PanelStateMirror —— 服务端权威面板状态的镜像/合并器。
///
/// 设计目标：
/// 1. **In-place 合并**：`apply(patch:)` 仅替换 patch 中非 nil 的字段，复用其余引用，
///    避免每次 patch 都全量拷贝整个 snapshot，降低 CPU/内存压力。
/// 2. **revision 校验**：patch 仅在 `baseRevision == 当前 revision` 时可应用；不匹配
///    则丢弃并让 ChatViewModel 重新 `requestSnapshot`。
/// 3. **per-session 缓存**：同一个连接里 iOS 可能切换聚焦会话，每个 sessionId 维护一份。
@MainActor
final class PanelStateMirror {

    // MARK: - Per-session cached snapshots
    /// key: sessionId（nil 用 `Self.draftKey` 占位，表示 "未持久化的草稿会话"）。
    private var snapshots: [UUID: PanelStateSnapshot] = [:]
    private var streamingTextIndexBySessionKey: [UUID: [UUID: PanelStreamingTextDTO]] = [:]
    private var catalogProjects: [PanelProjectDTO] = []
    private var catalogSessions: [PanelSessionDTO] = []
    private var catalogModels: [PanelModelDTO] = []
    private static let draftKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Read

    func snapshot(for sessionId: UUID?) -> PanelStateSnapshot? {
        snapshots[Self.key(for: sessionId)]
    }

    func currentRevision(for sessionId: UUID?) -> Int? {
        snapshot(for: sessionId)?.revision
    }

    /// 该 mirror 所有缓存中的全部 sessions（catalog）。snapshot 都会带 sessions[]，
    /// 这里取最新拿到的那份做 sidebar 显示。
    var latestKnownSessions: [PanelSessionDTO] { catalogSessions }

    /// 同上 —— projects 列表来自最近一份 snapshot。
    var latestKnownProjects: [PanelProjectDTO] { catalogProjects }

    var latestKnownModels: [PanelModelDTO] { catalogModels }

    var latestKnownStreamingTexts: [PanelStreamingTextDTO] {
        snapshots.values
            .max(by: { $0.revision < $1.revision })?
            .streamingTexts ?? []
    }

    func streamingText(for messageID: UUID, sessionId: UUID?) -> PanelStreamingTextDTO? {
        streamingTextIndexBySessionKey[Self.key(for: sessionId)]?[messageID]
    }

    func latestKnownStreamingText(for messageID: UUID) -> PanelStreamingTextDTO? {
        let snapshot = snapshots.values.max(by: { $0.revision < $1.revision })
        return snapshot.flatMap { streamingText(for: messageID, sessionId: $0.sessionId) }
    }

    // MARK: - Write

    func updateCatalog(snapshot: PanelStateSnapshot) {
        catalogProjects = snapshot.projects
        catalogSessions = snapshot.sessions
        catalogModels = snapshot.models
    }

    func updateCatalog(patch: PanelStatePatch) {
        if let projects = patch.projects { catalogProjects = projects }
        if let sessions = patch.sessions { catalogSessions = sessions }
        if let models = patch.models { catalogModels = models }
    }

    func updateCatalog(
        projects: [PanelProjectDTO]? = nil,
        models: [PanelModelDTO]? = nil,
        sessions: [PanelSessionDTO]? = nil
    ) {
        if let projects { catalogProjects = projects }
        if let models { catalogModels = models }
        if let sessions { catalogSessions = sessions }
    }

    @discardableResult
    func apply(snapshot: PanelStateSnapshot) -> PanelStateSnapshot {
        updateCatalog(snapshot: snapshot)
        let key = Self.key(for: snapshot.sessionId)
        snapshots[key] = snapshot
        streamingTextIndexBySessionKey[key] = Self.streamingTextIndex(snapshot.streamingTexts)
        return snapshot
    }

    /// 应用 patch；返回应用后的新 snapshot，失败（revision 不匹配 / 无 base）返回 nil。
    /// 调用方在 nil 时应当请求一次 fresh snapshot。
    @discardableResult
    func apply(patch: PanelStatePatch) -> PanelStateSnapshot? {
        let key = Self.key(for: patch.sessionId)
        guard let base = snapshots[key] else { return nil }
        guard base.revision == patch.baseRevision else { return nil }

        updateCatalog(patch: patch)
        let merged = PanelStateSnapshot(
            revision: patch.revision,
            sessionId: base.sessionId,
            projects: patch.projects ?? base.projects,
            models: patch.models ?? base.models,
            sessions: patch.sessions ?? base.sessions,
            currentSessionId: patch.currentSessionId.map { $0.value } ?? base.currentSessionId,
            messages: patch.messages ?? base.messages,
            queuedRequests: patch.queuedRequests ?? base.queuedRequests,
            streamingTexts: patch.streamingTexts ?? base.streamingTexts,
            status: patch.status ?? base.status,
            statusText: patch.statusText ?? base.statusText,
            isAwaitingFirstModelOutput: patch.isAwaitingFirstModelOutput ?? base.isAwaitingFirstModelOutput,
            isLoadingHistory: patch.isLoadingHistory ?? base.isLoadingHistory,
            tokensUsed: patch.tokensUsed ?? base.tokensUsed,
            tokensTotal: patch.tokensTotal ?? base.tokensTotal,
            activeRunStartedAt: patch.activeRunStartedAt.map { $0.value } ?? base.activeRunStartedAt,
            // Phase C：iOS 端不再使用镜像标志做任何决策，所以无论 server 给什么，
            // 这里始终透传 false。spec §4.2 字段名保留（合规于 protocol-server 抄录），
            // 但被赋上一个稳定占位值，避免 iOS 逻辑层引用它。
            isMirroringRemoteSession: false,
            composer: patch.composer ?? base.composer,
            capabilities: patch.capabilities ?? base.capabilities
        )
        snapshots[key] = merged
        streamingTextIndexBySessionKey[key] = Self.streamingTextIndex(merged.streamingTexts)
        return merged
    }

    func clearAll() {
        snapshots.removeAll()
        streamingTextIndexBySessionKey.removeAll()
        catalogProjects = []
        catalogSessions = []
        catalogModels = []
    }

    func clear(sessionId: UUID?) {
        let key = Self.key(for: sessionId)
        snapshots.removeValue(forKey: key)
        streamingTextIndexBySessionKey.removeValue(forKey: key)
    }

    // MARK: - Helpers

    private static func key(for sessionId: UUID?) -> UUID {
        sessionId ?? draftKey
    }

    private static func streamingTextIndex(_ streamingTexts: [PanelStreamingTextDTO]) -> [UUID: PanelStreamingTextDTO] {
        streamingTexts.reduce(into: [:]) { index, item in
            index[item.messageId] = item
        }
    }
}
