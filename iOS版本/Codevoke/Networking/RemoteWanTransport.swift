import Foundation
import ChatCore

/// 已配对主机的传输实现（文档 §6 RemoteWanTransport）。
///
/// LAN/WAN 同一条路径（§4.1 host 统一 wss+鉴权，不再有明文路径），差别只在
/// 候选地址集合：
/// - 候选 = `config.primaryEndpoint`（用户点选/上次使用的目标）+ EndpointStore
///   里该主机的 `eps`（lastGood 先行，其余并行，去重）；
/// - 每条候选先用 `GET /connect_info`（pinned session + Bearer）探测——3s 内
///   拿不到 200 即换下一条；这一步同时完成 pin+token+可达性校验与 eps 静默刷新；
/// - 首个探测成功的地址胜出 → 在其上建立 `URLSessionWebSocketTask`（同一
///   pinned session + Bearer upgrade 头）→ 写回 lastGood；
/// - 全部失败按归因上报：`unauthorized`（token 被拒，重新配对）/
///   `certificateMismatch`（证书轮换，重新配对）/ `endpointsStale`
///   （地址可能已变化，引导重配对或回局域网）。
@MainActor
final class RemoteWanTransport: RemoteTransport {
    private let config: RemoteChatConfig
    private let store: EndpointStore

    private var winner: RemoteWebSocketClient?
    private var session: URLSession?
    private var pinDelegate: PinnedTrustDelegate?
    private var connectTask: Task<Void, Never>?
    private var intentionallyClosed = false
    /// 连接代际：connect()/disconnect() 每次自增。上一轮被取消的
    /// raceEndpoints 在探测回调恢复执行时必须先比代际 —— disconnect→connect
    /// 快速连续调用时 `intentionallyClosed` 已被新一轮复位，单看布尔拦不住
    /// 旧 race 复活后 adopt() 覆盖新一轮的 winner/session（双 WS + session 泄漏）。
    private var connectGeneration = 0

    /// 胜出地址通知（ChatViewModel 用它把 config.macHost/port 对齐到实际
    /// 可用地址，让 /files、/attachments 等 HTTP 跟随同一 endpoint）。
    var onEndpointSelected: ((RemoteEndpoint) -> Void)?

    var isConnected: Bool { winner?.isConnected == true }
    var canSendFrames: Bool { !intentionallyClosed && winner?.canSendFrames == true }

    var onConnect: (() -> Void)?
    var onEnvelope: ((PanelStateEnvelope) -> Void)?
    var onAck: ((CommandAck) -> Void)?
    var onRecoveryResponse: ((RemoteRecoveryResponse) -> Void)?
    var onDecodeFailure: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(config: RemoteChatConfig, store: EndpointStore = .shared) {
        self.config = config
        self.store = store
    }

    // MARK: - RemoteTransport

    func connect() throws {
        guard config.isComplete, let token = config.authToken, !token.isEmpty,
              let fp = config.certFP, !RemoteWanCredentials.normalizeFP(fp).isEmpty else {
            throw RemoteChatError.missingConfiguration
        }
        disconnect(notify: false)
        intentionallyClosed = false
        connectGeneration &+= 1
        let generation = connectGeneration
        connectTask = Task { @MainActor [weak self] in
            await self?.raceEndpoints(generation: generation)
        }
    }

    func disconnect() {
        disconnect(notify: false)
    }

    func sendResume(sessionId: UUID?, lastRevision: Int?) async throws {
        guard let winner else { throw RemoteChatError.missingConfiguration }
        try await winner.sendResume(sessionId: sessionId, lastRevision: lastRevision)
    }

    func sendCommand(_ command: Command) async throws {
        guard let winner, canSendFrames else { throw RemoteChatError.missingConfiguration }
        try await winner.sendCommand(command)
    }

    func sendRecoveryRequest(_ request: RemoteRecoveryRequest) async throws {
        guard let winner, canSendFrames else { throw RemoteChatError.missingConfiguration }
        try await winner.sendRecoveryRequest(request)
    }

    // MARK: - Endpoint race

    private enum ProbeOutcome {
        case success(RemoteConnectInfo)
        case unauthorized
        case unreachable
    }

    private func candidates() -> [RemoteEndpoint] {
        let preferred = config.primaryEndpoint
        if let hostId = config.hostId ?? config.certFP.map(RemoteWanCredentials.normalizeFP),
           let record = store.record(forHostId: hostId) {
            return record.candidateEndpoints(preferred: preferred)
        }
        return preferred.isValid ? [preferred] : []
    }

    /// 本代是否仍是当前连接代。disconnect()（intentionallyClosed）与新一轮
    /// connect()（generation 自增）都会让旧代立刻失效。
    private func isCurrent(_ generation: Int) -> Bool {
        !intentionallyClosed && connectGeneration == generation
    }

    private func raceEndpoints(generation: Int) async {
        guard let token = config.authToken, let certFP = config.certFP else { return }
        let (session, pinDelegate) = RemoteSecureSessionFactory.pinnedSession(certFP: certFP)
        // disconnect()/新 connect() 可能在竞速期间先到 —— self.session 槽位
        // 已经属于更新的一代（或被清空），本代只收掉自己创建的局部 session，
        // 绝不能再写回 self.*，否则会覆盖新一代的连接状态。
        guard isCurrent(generation) else {
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.pinDelegate = pinDelegate

        let endpoints = candidates()
        guard !endpoints.isEmpty else {
            finishAllFailed(generation: generation)
            return
        }

        // §6：lastGood（=排序后的第一条候选）先行探测；只有"不可达"才继续，
        // 401/pin 不匹配在所有 endpoint 上必然同样失败，直接短路。
        var sawUnauthorized = false
        switch await probe(endpoints[0], token: token, session: session, generation: generation) {
        case .success(let info):
            adopt(endpoints[0], info: info, session: session, generation: generation)
            return
        case .unauthorized:
            sawUnauthorized = true
        case .unreachable:
            break
        }
        // 探测挂起期间可能发生了 disconnect→connect：旧代到此为止。
        guard isCurrent(generation) else {
            session.invalidateAndCancel()
            return
        }
        if sawUnauthorized || pinDelegate.sawPinMismatch {
            finishAllFailed(unauthorized: sawUnauthorized, generation: generation)
            return
        }

        // 其余候选并行竞速，首个 200 胜出。
        let rest = Array(endpoints.dropFirst())
        if !rest.isEmpty {
            let winner = await withTaskGroup(of: (RemoteEndpoint, ProbeOutcome).self) { group -> (RemoteEndpoint, RemoteConnectInfo)? in
                for endpoint in rest {
                    group.addTask { [weak self] in
                        guard let self else { return (endpoint, .unreachable) }
                        return (endpoint, await self.probe(endpoint, token: token, session: session, generation: generation))
                    }
                }
                var winning: (RemoteEndpoint, RemoteConnectInfo)?
                var groupSawUnauthorized = false
                for await (endpoint, outcome) in group {
                    switch outcome {
                    case .success(let info):
                        winning = (endpoint, info)
                        group.cancelAll()
                    case .unauthorized:
                        groupSawUnauthorized = true
                    case .unreachable:
                        break
                    }
                    if winning != nil { break }
                }
                sawUnauthorized = sawUnauthorized || groupSawUnauthorized
                return winning
            }
            if let winner, isCurrent(generation) {
                adopt(winner.0, info: winner.1, session: session, generation: generation)
                return
            }
        }

        guard isCurrent(generation) else {
            session.invalidateAndCancel()
            return
        }
        finishAllFailed(unauthorized: sawUnauthorized, generation: generation)
    }

    /// 单条候选探测：`GET /connect_info`，3s 未拿到 200 即换下一条（§6）。
    private func probe(_ endpoint: RemoteEndpoint, token: String, session: URLSession, generation: Int) async -> ProbeOutcome {
        guard isCurrent(generation) else { return .unreachable }
        do {
            let info = try await RemotePairingClient.fetchConnectInfo(
                host: endpoint.a, port: endpoint.p, token: token,
                session: session, timeout: 3
            )
            return .success(info)
        } catch {
            if let remoteError = error as? RemoteChatError, case .unauthorized = remoteError {
                return .unauthorized
            }
            return .unreachable
        }
    }

    /// 胜出 endpoint：先静默刷新 eps + 写回 lastGood，再建真实 WS。
    private func adopt(_ endpoint: RemoteEndpoint, info: RemoteConnectInfo, session: URLSession, generation: Int) {
        // 代际失效时 session 参数是本代自己的局部对象（self.session 可能已是
        // 新一代的），直接收掉它即可，不要碰 self.*。
        guard isCurrent(generation) else {
            session.invalidateAndCancel()
            return
        }
        let hostId = config.hostId ?? RemoteWanCredentials.normalizeFP(config.certFP ?? "")
        if !hostId.isEmpty {
            store.applyConnectInfo(hostId: hostId, name: info.name, eps: info.eps ?? [])
            store.updateLastGood(hostId: hostId, endpoint: endpoint)
        }

        var wsConfig = config
        wsConfig.macHost = endpoint.a
        wsConfig.port = endpoint.p
        let client = RemoteWebSocketClient(config: wsConfig, session: session)
        winner = client
        onEndpointSelected?(endpoint)

        // 回调全部 weak client —— client.onX 强持闭包，闭包再强持 client
        // 会形成自循环泄漏。
        client.onConnect = { [weak self, weak client] in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.onConnect?()
        }
        client.onEnvelope = { [weak self, weak client] envelope in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.onEnvelope?(envelope)
        }
        client.onAck = { [weak self, weak client] ack in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.onAck?(ack)
        }
        client.onRecoveryResponse = { [weak self, weak client] response in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.onRecoveryResponse?(response)
        }
        client.onDecodeFailure = { [weak self, weak client] preview in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.onDecodeFailure?(preview)
        }
        client.onDisconnect = { [weak self, weak client] error in
            guard let self, let client, !self.intentionallyClosed, self.winner === client else { return }
            self.winner = nil
            self.onDisconnect?(error)
        }

        do {
            try client.connect()
        } catch {
            // WS 没建起来，pinned session 已无主——立即收掉避免泄漏。
            winner = nil
            session.invalidateAndCancel()
            self.session = nil
            self.pinDelegate = nil
            if !intentionallyClosed {
                onDisconnect?(error)
            }
        }
    }

    private func finishAllFailed(unauthorized: Bool = false, generation: Int) {
        guard isCurrent(generation) else { return }
        let pinMismatch = pinDelegate?.sawPinMismatch == true
        // 竞速阶段全部失败 = 不会再有 WS 接走 session，这里收掉。
        session?.invalidateAndCancel()
        session = nil
        pinDelegate = nil
        let error: RemoteChatError
        if unauthorized {
            error = .unauthorized
        } else if pinMismatch {
            error = .certificateMismatch
        } else {
            error = .endpointsStale
        }
        onDisconnect?(error)
    }

    private func disconnect(notify: Bool) {
        intentionallyClosed = true
        connectGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        winner?.disconnect()
        winner = nil
        session?.invalidateAndCancel()
        session = nil
        pinDelegate = nil
        if notify {
            onDisconnect?(nil)
        }
    }
}
