import Foundation

extension Notification.Name {
    static let remoteChatSessionsDidChange = Notification.Name("RemoteChatSessionsDidChange")
    static let remoteChatStreamEvent = Notification.Name("RemoteChatStreamEvent")
}

/// 内存事件总线：让 RemoteChatBridge（iOS 远程触发的 backend 跑动）把每一帧 backend
/// 事件实时镜像给 Mac 端对应 sessionID 的 ChatPanelState，实现两端 UI 同步。
///
/// 设计要点：
/// - Bridge 始终是数据源：持有 backend、写盘、回复 iOS。
/// - Mac 端 ChatPanelState 只是镜像：apply 事件以更新内存 UI，**不写盘**（避免双写）。
/// - 没有 Mac 订阅者时，Bridge 行为完全不变；新增逻辑 zero-cost。
/// - 同一 sessionID 允许多个订阅者（理论上 Mac 端不会出现，但接口保持通用）。
@MainActor
final class RemoteSessionMirrorBus {
    static let shared = RemoteSessionMirrorBus()

    enum Event {
        /// Mac 已经持久化接收 iOS 发来的请求，但它可能还在队列中等待执行。
        case queue(RemoteChatStreamEvent)
        /// 远程 turn 开始：iOS 触发了 send_message，Bridge 已 load/create 出 session
        /// 并构造了 user message。订阅者应该把 session 设为 currentSession（如必要）
        /// 并把 user message 加入 messages。
        case beginRun(session: ChatSessionRecord, userMessage: ChatMessage)
        /// backend 流式事件，直接转给 ChatPanelState.apply。
        case backend(ChatBackendEvent)
        /// turn 完整结束，订阅者可以做最后的状态同步（runStatus 等）。
        case endRun(session: ChatSessionRecord)
    }

    typealias Handler = (Event) -> Void

    private struct ActiveRunSnapshot {
        let session: ChatSessionRecord
        let userMessage: ChatMessage
    }

    private var handlers: [UUID: [UUID: Handler]] = [:]
    private var globalHandlers: [UUID: Handler] = [:]
    private var activeRunSnapshots: [UUID: ActiveRunSnapshot] = [:]

    private init() {}

    /// 订阅指定 sessionID 的事件流。返回的 token 用于取消订阅。
    @discardableResult
    func subscribe(sessionID: UUID, handler: @escaping Handler) -> UUID {
        let token = UUID()
        handlers[sessionID, default: [:]][token] = handler
        if let snapshot = activeRunSnapshots[sessionID] {
            handler(.beginRun(session: snapshot.session, userMessage: snapshot.userMessage))
        }
        return token
    }

    func unsubscribe(sessionID: UUID, token: UUID) {
        handlers[sessionID]?.removeValue(forKey: token)
        if handlers[sessionID]?.isEmpty == true {
            handlers.removeValue(forKey: sessionID)
        }
    }

    /// 订阅所有远程 beginRun 事件。Mac 当前没有打开对应 session 时，
    /// ChatPanelState 仍可收到 iOS 新建会话并切换到实时镜像。
    @discardableResult
    func subscribeToBegins(handler: @escaping Handler) -> UUID {
        let token = UUID()
        globalHandlers[token] = handler
        for snapshot in activeRunSnapshots.values {
            handler(.beginRun(session: snapshot.session, userMessage: snapshot.userMessage))
        }
        return token
    }

    func unsubscribeFromBegins(token: UUID) {
        globalHandlers.removeValue(forKey: token)
    }

    /// Bridge 调用：把事件投递给所有订阅了该 sessionID 的 handler。
    func publish(_ event: Event, to sessionID: UUID) {
        switch event {
        case .queue:
            break
        case .beginRun(let session, let userMessage):
            activeRunSnapshots[sessionID] = ActiveRunSnapshot(session: session, userMessage: userMessage)
        case .endRun:
            activeRunSnapshots.removeValue(forKey: sessionID)
        case .backend:
            break
        }
        let subscribers = Array((handlers[sessionID] ?? [:]).values)
        if isGlobalEvent(event), !globalHandlers.isEmpty {
            for handler in Array(globalHandlers.values) {
                handler(event)
            }
        }
        guard !subscribers.isEmpty else { return }
        // 拷贝一份避免 handler 在执行中订阅/退订导致字典遍历崩溃。
        for handler in subscribers {
            handler(event)
        }
    }

    /// 查询是否有 Mac 端订阅者。Bridge 暂时只用于 debug log，不影响功能。
    func hasSubscribers(for sessionID: UUID) -> Bool {
        !(handlers[sessionID]?.isEmpty ?? true)
    }

    private func isGlobalEvent(_ event: Event) -> Bool {
        switch event {
        case .queue, .beginRun:
            true
        case .backend, .endRun:
            false
        }
    }
}
