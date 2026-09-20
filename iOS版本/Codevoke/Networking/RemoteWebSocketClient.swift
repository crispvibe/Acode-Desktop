import Foundation
import ChatCore

private struct RemoteWebSocketClosedError: LocalizedError {
    let underlying: Error
    let closeCode: URLSessionWebSocketTask.CloseCode
    let closeReason: String?

    var errorDescription: String? {
        var parts = [RemoteUserFacingText.apiError(underlying.localizedDescription, fallback: "远程连接已断开。")]
        if closeCode != .invalid {
            parts.append(L10n.format("关闭码：%d", closeCode.rawValue))
        }
        if let closeReason, !closeReason.isEmpty {
            let reason = RemoteUserFacingText.reason(closeReason) ?? closeReason
            parts.append(L10n.format("原因：%@", reason))
        }
        return parts.joined(separator: " ")
    }
}

/// iOS 端 VNC 协议 WebSocket 客户端。
///
/// 收到的帧只关心三类：
/// - `panel_state` envelope（snapshot 或 patch）
/// - `command_ack`
/// - 任何其他（含旧协议）—— 直接 drop。
///
/// 发送的帧只有两类：
/// - `resume`（连接建立后第一帧）
/// - `command`（用户操作）
final class RemoteWebSocketClient: RemoteTransport {
    private let config: RemoteChatConfig
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let codec: RemoteTransportFrameCodec

    // intentionallyClosed 被 URLSession 回调线程和 main actor 双向读写，用 NSLock 包装。
    /// `taskEpoch` 用来识别"当前活跃的 task 代"。每次 `connect()` 都会自增；
    /// 老 task 的 receive 完成回调进入 `handle/fail` 前先比对自己捕获的 epoch
    /// 与当前 epoch，不一致直接丢弃 —— 避免老 task 的 cancel 回调把新 task 干掉
    /// （iOS 上观察到的 "WS connect ... 然后立刻 disconnect → auto reconnect" 死循环）。
    private let stateLock = NSLock()
    private nonisolated(unsafe) var _intentionallyClosed = false
    private nonisolated(unsafe) var _taskEpoch: UInt64 = 0
    private nonisolated var intentionallyClosed: Bool {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return _intentionallyClosed
        }
        set {
            stateLock.lock(); defer { stateLock.unlock() }
            _intentionallyClosed = newValue
        }
    }
    private nonisolated var currentEpoch: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _taskEpoch
    }
    private nonisolated func bumpEpoch() -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        _taskEpoch &+= 1
        return _taskEpoch
    }

    private(set) var isConnected = false

    var canSendFrames: Bool {
        task != nil && !intentionallyClosed
    }

    /// 心跳间隔，让半死连接快速暴露。
    private static let pingInterval: UInt64 = 20_000_000_000  // 20 s
    private var pingTask: Task<Void, Never>?
    /// 上一次 ping 的 pong 仍未收到。URLSession 的 sendPing completion 只在
    /// 拿到 pong 或出错时回调 —— 网络切换造成的 TCP 黑洞会让回调永远不来，
    /// socket 保持"看似存在"且发送持续排队。到下一次 tick 仍未归位即判死，
    /// 走 fail → 上层自动重连。仅 MainActor 访问。
    private var pongPending = false

    // 上层回调（仅瘦客户端关心的三类事件）
    var onConnect: (() -> Void)?
    var onEnvelope: ((PanelStateEnvelope) -> Void)?
    var onAck: ((CommandAck) -> Void)?
    var onRecoveryResponse: ((RemoteRecoveryResponse) -> Void)?
    var onDecodeFailure: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(config: RemoteChatConfig, session: URLSession = .shared, codec: RemoteTransportFrameCodec = RemoteTransportFrameCodec()) {
        self.config = config
        self.session = session
        self.codec = codec
    }

    // MARK: - Lifecycle

    func connect() throws {
        guard let url = config.webSocketURL else { throw RemoteChatError.invalidURL }
        disconnect(notify: false)
        intentionallyClosed = false
        let epoch = bumpEpoch()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // §4.2：/chat upgrade 携带 Bearer；缺失/错误时服务端在 101 前回 401。
        if let token = config.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext(epoch: epoch)
        startPingLoop(epoch: epoch)
    }

    func disconnect() {
        disconnect(notify: false)
    }

    // MARK: - Send

    func sendResume(sessionId: UUID?, lastRevision: Int?) async throws {
        try await sendText(codec.encodeResume(sessionId: sessionId, lastRevision: lastRevision))
    }

    func sendCommand(_ command: Command) async throws {
        try await sendText(codec.encodeCommand(command))
    }

    func sendRecoveryRequest(_ request: RemoteRecoveryRequest) async throws {
        try await sendText(codec.encodeRecoveryRequest(request))
    }

    private func sendText(_ text: String) async throws {
        guard let task, canSendFrames else { throw RemoteChatError.missingConfiguration }
        let data = Data(text.utf8)
        guard data.count <= RemoteRecoveryLimits.maximumTextFrameUTF8Bytes else {
            throw RemoteChatError.serverMessage(L10n.string("附件不能超过 10MB。"), statusCode: 413)
        }
        try await task.send(.string(text))
    }

    // MARK: - Internals

    private func disconnect(notify: Bool) {
        intentionallyClosed = true
        isConnected = false
        pongPending = false
        stopPingLoop()
        _ = bumpEpoch()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if notify {
            onDisconnect?(nil)
        }
    }

    private func startPingLoop(epoch: UInt64) {
        stopPingLoop()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingInterval)
                guard let self, !Task.isCancelled, !self.intentionallyClosed, self.currentEpoch == epoch else { return }
                self.sendPing(epoch: epoch)
            }
        }
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func sendPing(epoch: UInt64) {
        guard let task, currentEpoch == epoch else { return }
        // 上一次 ping 的 pong 还没回来 → 连接已半死，主动判死触发重连。
        if pongPending {
            fail(URLError(.networkConnectionLost), epoch: epoch)
            return
        }
        pongPending = true
        task.sendPing { [weak self] error in
            // pong 回调在 URLSession delegate 队列上派发，回 MainActor 再动状态。
            Task { @MainActor [weak self] in
                guard let self, !self.intentionallyClosed, self.currentEpoch == epoch else { return }
                self.pongPending = false
                if let error {
                    self.fail(error, epoch: epoch)
                }
            }
        }
    }

    /// 帧解码结果 —— decode 在 URLSession delegate 队列上完成（非主线程），
    /// 只有派发回到主线程做回调。流式期间 host 每 ~30ms 推一个 panel_state
    /// patch，若 JSON 解码也在主线程，会叠加 @Published 发布/行重建一起卡 UI。
    private enum DecodedReceive {
        case frame(RemoteTransportFrameCodec.DecodedFrame)
        case decodeFailure(String)
    }

    private func receiveNext(epoch: UInt64) {
        guard let task, currentEpoch == epoch else { return }
        // codec 是不可变 struct，按值捕获后即可在 delegate 队列安全使用。
        // （类本身因 RemoteTransport 协议是 @MainActor —— 若不把 codec 拿出来，
        //  decode 会被推断回主线程，失去离主线程解码的意义。）
        let codec = self.codec
        task.receive { [weak self] result in
            guard let self, !self.intentionallyClosed, self.currentEpoch == epoch else { return }
            switch result {
            case .success(let message):
                // URLSessionWebSocketTask.receive 回调在 session 的 delegate 队列
                // 上串行派发 —— 在这里做 JSON 解码，解码完只把已解析帧抛回主线程。
                let decoded = Self.decode(message, codec: codec)
                Task { @MainActor in
                    guard !self.intentionallyClosed, self.currentEpoch == epoch else { return }
                    self.handle(decoded: decoded)
                    self.receiveNext(epoch: epoch)
                }
            case .failure(let error):
                Task { @MainActor in
                    guard !self.intentionallyClosed, self.currentEpoch == epoch else { return }
                    self.fail(error, epoch: epoch)
                }
            }
        }
    }

    nonisolated private static func decode(_ message: URLSessionWebSocketTask.Message, codec: RemoteTransportFrameCodec) -> DecodedReceive {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                return .decodeFailure("<binary frame>")
            }
            text = value
        @unknown default:
            return .decodeFailure("<unknown frame>")
        }

        do {
            return .frame(try codec.decode(text: text))
        } catch {
            return .decodeFailure("\(error.localizedDescription): \(String(text.prefix(200)))")
        }
    }

    private func handle(decoded: DecodedReceive) {
        switch decoded {
        case .frame(.panelState(let envelope)):
            if !isConnected {
                isConnected = true
                onConnect?()
            }
            onEnvelope?(envelope)
        case .frame(.commandAck(let ack)):
            // Ack 是"服务端往这条连接回了帧"的最硬证据。如果 hello/panel_state
            // 因为任何原因没到(比如 .empty 的 resume payload),靠 ack 也能把
            // isConnected 翻起来,让 onConnect 走起来,replayPendingCommands
            // 不会卡死在 pending 里。
            if !isConnected {
                isConnected = true
                onConnect?()
            }
            onAck?(ack)
        case .frame(.recoveryResponse(let response)):
            if !isConnected {
                isConnected = true
                onConnect?()
            }
            onRecoveryResponse?(response)
        case .frame(.hello):
            // Server 老路径可能还会发 hello。仅当作连接 OK 的信号即可，状态走 panel_state。
            if !isConnected {
                isConnected = true
                onConnect?()
            }
        case .frame(.ignored):
            // 旧协议事件统一忽略（Phase B 兼容）。
            break
        case .decodeFailure(let preview):
            onDecodeFailure?(preview)
        }
    }

    private func fail(_ error: Error, epoch: UInt64) {
        guard !intentionallyClosed, currentEpoch == epoch else { return }
        let reportedError = annotatedDisconnectError(error)
        // 主动 bump epoch:这次 fail 一过去,后续同 epoch 的 receive/ping 回调
        // 全部会被 currentEpoch == epoch 卡掉,避免一次连接断开重复触发
        // 多次 onDisconnect → ChatViewModel 排好几个并发 reconnect Task。
        _ = bumpEpoch()
        isConnected = false
        pongPending = false
        stopPingLoop()
        // 合成失败路径（如 pong 超时）里 socket 可能还半开着，主动收掉，
        // 否则系统侧残留 dead socket + 未完成的 ping/receive 回调。
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onDisconnect?(reportedError)
    }

    private func annotatedDisconnectError(_ error: Error) -> Error {
        // upgrade 被服务端拒绝（如 token 失效的 401）时拿不到 closeCode，
        // 但 task.response 里保留 HTTP 响应——翻成 .unauthorized 供上层提示重新配对。
        if let http = task?.response as? HTTPURLResponse, http.statusCode == 401 {
            return RemoteChatError.unauthorized
        }
        guard let task, task.closeCode != .invalid else { return error }
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        return RemoteWebSocketClosedError(underlying: error, closeCode: task.closeCode, closeReason: reason)
    }
}
