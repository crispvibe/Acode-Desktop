import Combine
import Darwin
import Foundation
import Network
import ChatCore

private struct RemoteChatWebSocketControlEnvelope: Codable {
    let protocolVersion: Int?
    let commandId: UUID?
    let type: String
    let cursor: Int?
    let lastRevision: Int?
    let requestId: String?
    let clientConversationId: UUID?
    let sessionId: UUID?
}

/// Per-connection runtime state. Tracks legacy cursor bookkeeping and the new
/// VNC focus state side-by-side so we can dual-broadcast during Phase B.
private final class RemoteChatConnectionState {
    enum ProtocolMode {
        case undecided
        case legacy   // client resumed via `cursor`
        case vnc      // client resumed via `lastRevision`
    }
    var protocolMode: ProtocolMode = .undecided
    var focusedSessionID: UUID?
    var lastAckedCursor: Int = 0
    /// `revision` that the client most recently confirmed (per spec §4.7).
    var lastAckedRevision: Int?
    /// A `newDraftSession` command focuses a client on a draft UUID before
    /// the backing controller may start emitting a concrete session UUID.
    /// Allow one focused remap so strict fanout does not drop the new stream.
    var isResolvingDraftSession: Bool = false
}

private struct RemoteStreamEventCoalescer {
    private struct DeltaKey: Hashable {
        let requestId: String?
        let clientConversationId: UUID?
        let backendRequestId: String?
        let sessionId: UUID?
        let eventScopeId: UUID?
        let eventScopeKind: String?
        let kind: String?
        let title: String?
        let subtitle: String?
        let status: String?
    }

    private struct PendingDelta {
        var key: DeltaKey
        var event: RemoteChatStreamEvent
    }

    private var pendingDeltas: [DeltaKey: PendingDelta] = [:]
    private var deltaOrder: [DeltaKey] = []
    private var pendingDeltaCount = 0
    private var pendingUTF8Bytes = 0
    private var lastFlushAt = Date()

    private let flushInterval: TimeInterval
    private let maxPendingDeltas: Int
    private let maxPendingUTF8Bytes: Int

    init(flushInterval: TimeInterval = 0.09, maxPendingDeltas: Int = 48, maxPendingUTF8Bytes: Int = 8 * 1024) {
        self.flushInterval = flushInterval
        self.maxPendingDeltas = maxPendingDeltas
        self.maxPendingUTF8Bytes = maxPendingUTF8Bytes
    }

    var hasPendingEvents: Bool {
        !deltaOrder.isEmpty
    }

    mutating func push(_ event: RemoteChatStreamEvent) -> [RemoteChatStreamEvent] {
        guard event.type == "assistant_delta", let delta = event.delta, !delta.isEmpty else {
            return flush() + [event]
        }

        let key = DeltaKey(
            requestId: event.requestId,
            clientConversationId: event.clientConversationId,
            backendRequestId: event.backendRequestId,
            sessionId: event.sessionId,
            eventScopeId: event.eventScopeId,
            eventScopeKind: event.eventScopeKind,
            kind: event.kind,
            title: event.title,
            subtitle: event.subtitle,
            status: event.status
        )
        if pendingDeltas[key] == nil {
            deltaOrder.append(key)
            pendingDeltas[key] = PendingDelta(key: key, event: event)
        } else if var pending = pendingDeltas[key] {
            let existingDelta = pending.event.delta ?? ""
            pending.event.delta = existingDelta + delta
            pendingDeltas[key] = pending
        }
        pendingDeltaCount += 1
        pendingUTF8Bytes += delta.utf8.count
        return shouldFlush ? flush() : []
    }

    mutating func flush() -> [RemoteChatStreamEvent] {
        guard !deltaOrder.isEmpty else { return [] }
        let orderedEvents = deltaOrder.compactMap { pendingDeltas[$0]?.event }
        pendingDeltas.removeAll(keepingCapacity: true)
        deltaOrder.removeAll(keepingCapacity: true)
        pendingDeltaCount = 0
        pendingUTF8Bytes = 0
        lastFlushAt = Date()
        return orderedEvents
    }

    private var shouldFlush: Bool {
        pendingDeltaCount >= maxPendingDeltas
            || pendingUTF8Bytes >= maxPendingUTF8Bytes
            || Date().timeIntervalSince(lastFlushAt) >= flushInterval
    }
}

final class RemoteChatServer {
    private let configuration: RemoteChatServerConfiguration
    private let router: RemoteChatRouter
    private let identity: RemoteHostIdentity.Identity
    private let authService: RemoteAuthService
    private let pairingService: RemotePairingService
    private let endpointPublisher: WanEndpointPublisher
    private let queue = DispatchQueue(label: "com.codevoke.remote-chat-server", qos: .userInitiated)
    private var listener: NWListener?
    var onDiagnosticsChanged: ((RemoteChatServerDiagnostics) -> Void)?

    private var webSocketConnections: [UUID: NWConnection] = [:]
    private var connectionStates: [UUID: RemoteChatConnectionState] = [:]
    private let serverEpoch = UUID().uuidString
    private var nextStreamCursor = 0
    private var replayCache: [RemoteChatStreamEvent] = []
    private let replayCacheLimit = 2048
    private var legacyStreamEventCoalescer = RemoteStreamEventCoalescer()
    private var legacyStreamDeltaFlushItem: DispatchWorkItem?
    private var inboundTaskByConnection: [UUID: Task<Void, Never>] = [:]
    private var sessionsObserver: NSObjectProtocol?
    private var streamObserver: NSObjectProtocol?

    // MARK: - VNC pipeline

    /// Main-actor isolated. `broadcaster` and its observers must run on the
    /// main actor (controllers publish on `objectWillChange`). All `queue.async`
    /// callbacks bounce to `MainActor` before touching it.
    @MainActor
    private final class VNCPipeline {
        let broadcaster: PanelStateBroadcaster
        let router: RemoteChatCommandRouter
        private var envelopeSubscription: AnyCancellable?

        init(onEnvelope: @escaping (PanelStateEnvelope) -> Void) {
            broadcaster = PanelStateBroadcaster()
            router = RemoteChatCommandRouter(broadcaster: broadcaster)
            // The pipeline is built during `RemoteChatServer.init`, which runs
            // before `RemoteVNCWiring.install` (driven by `RootView.onAppear`).
            // Resolving the lookup lazily ensures the real runtime-store-backed
            // lookup is picked up once the App finishes wiring it — a one-time
            // `bindLookup` here would capture a transient stub forever.
            broadcaster.lookupResolver = { RemoteVNCWiring.lookup }
            envelopeSubscription = broadcaster.envelopePublisher
                .sink { envelope in
                    onEnvelope(envelope)
                }
        }
    }

    private var vncPipeline: VNCPipeline?

    private lazy var bridge = RemoteChatBridge { [weak self] event in
        self?.broadcastWebSocketEvent(event)
    }

    init(
        configuration: RemoteChatServerConfiguration,
        identity: RemoteHostIdentity.Identity,
        authService: RemoteAuthService = .shared,
        pairingService: RemotePairingService = .shared,
        endpointPublisher: WanEndpointPublisher
    ) {
        self.configuration = configuration
        self.identity = identity
        self.authService = authService
        self.pairingService = pairingService
        self.endpointPublisher = endpointPublisher
        router = RemoteChatRouter(configuration: configuration)
        sessionsObserver = NotificationCenter.default.addObserver(forName: .remoteChatSessionsDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.broadcastWebSocketEvent(RemoteChatStreamEvent(type: "sessions_changed", status: "changed"))
        }
        streamObserver = NotificationCenter.default.addObserver(forName: .remoteChatStreamEvent, object: nil, queue: nil) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? RemoteChatStreamEvent else { return }
            self?.broadcastWebSocketEvent(event)
        }
        // VNC pipeline must be built on the main actor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pipeline = VNCPipeline { [weak self] envelope in
                self?.broadcastVNCEnvelope(envelope)
            }
            self.queue.async {
                self.vncPipeline = pipeline
            }
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
        if let streamObserver {
            NotificationCenter.default.removeObserver(streamObserver)
        }
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RemoteChatServerError.invalidPort
        }

        // Wire contract §4.1/§4.3: every connection — LAN included — is TLS
        // (wss) with the self-signed Keychain identity. Clients pin SPKI-SHA256.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity.secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tlsOptions)
        if !configuration.bindLAN {
            // requiredLocalEndpoint 在 NWListener 上的实际效果不稳定（不同 macOS 行为不一），
            // 因此只把它当作"尽量绑 loopback"的提示，真正的拦截在 newConnectionHandler 里做。
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        }

        let listener = try NWListener(using: parameters, on: port)
        let bindLAN = configuration.bindLAN
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            // 防御性校验：当用户选择"仅本机"时，无论 NWListener 是否真的只绑了 loopback，
            // 都要在这里拒绝来自非回环地址的连接，确保设置开关一定生效。
            if !bindLAN, !Self.isLoopbackEndpoint(connection.endpoint) {
                connection.cancel()
                return
            }
            self.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("RemoteChatServer failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            if address == .loopback { return true }
            // ::ffff:127.0.0.1 这类 IPv4-mapped IPv6 也算回环
            if address.isIPv4Mapped, let v4 = address.asIPv4 {
                return v4 == .loopback
            }
            return false
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for connection in webSocketConnections.values {
                connection.cancel()
            }
            webSocketConnections.removeAll()
            connectionStates.removeAll()
            notifyDiagnosticsChangedLocked()
        }
        bridge.stop()
    }

    func diagnosticsSnapshot() -> RemoteChatServerDiagnostics {
        queue.sync {
            diagnosticsSnapshotLocked()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, accumulated: Data(), startedAt: Date(), peerAddress: Self.peerAddressString(for: connection))
    }

    /// Peer IP string for auth bookkeeping (`/pair` source check, rate
    /// limiting). Zone suffixes (`%en0`) are stripped.
    private static func peerAddressString(for connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: raw = ""
        }
        return String(raw.split(separator: "%").first.map(String.init) ?? raw)
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data, startedAt: Date, peerAddress: String) {
        // Audit A-P1: enforce a read deadline. Without this a slow client
        // could pin a socket indefinitely while drip-feeding `Content-Length`
        // bytes; the server would happily accumulate up to `maxRequestBytes`.
        if Date().timeIntervalSince(startedAt) > RemoteChatHTTPCodec.requestReadDeadline {
            self.send(.error("request_timeout", message: "请求等待时间过长，请重试。", statusCode: 408, reasonPhrase: "Request Timeout"), on: connection)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: RemoteChatHTTPCodec.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }

            if requestData.count > RemoteChatHTTPCodec.maxRequestBytes {
                self.send(.error("request_too_large", message: "请求内容太大，请减少内容后重试。", statusCode: 413, reasonPhrase: "Payload Too Large"), on: connection)
                return
            }

            guard RemoteChatHTTPCodec.containsHeaderTerminator(requestData),
                  let expectedLength = RemoteChatHTTPCodec.expectedRequestLength(for: requestData),
                  requestData.count >= expectedLength else {
                self.receiveRequest(from: connection, accumulated: requestData, startedAt: startedAt, peerAddress: peerAddress)
                return
            }

            do {
                let request = try RemoteChatHTTPCodec.parseRequest(from: requestData)
                self.dispatch(request, on: connection, peerAddress: peerAddress)
            } catch {
                self.send(.error("bad_request", message: "请求内容格式不正确，请重试。", statusCode: 400, reasonPhrase: "Bad Request"), on: connection)
            }
        }
    }

    /// Wire contract §4.2 dispatch: `/health` and `/pair` are public (pair is
    /// further restricted to private-network sources); everything else —
    /// including the `/chat` WebSocket upgrade — requires `Bearer <token>`.
    private func dispatch(_ request: RemoteChatHTTPRequest, on connection: NWConnection, peerAddress: String) {
        if authService.isBanned(ip: peerAddress) {
            send(.error("rate_limited", message: "尝试次数过多，请稍后再试。", statusCode: 429, reasonPhrase: "Too Many Requests"), on: connection)
            return
        }

        switch request.path {
        case "/health":
            send(router.route(request), on: connection)
            return
        case "/pair":
            send(pairResponse(request: request, peerAddress: peerAddress), on: connection)
            return
        default:
            break
        }

        guard authenticate(request) != nil else {
            authService.recordAuthFailure(ip: peerAddress)
            // Contract §4.2 allows at most 5 failures per connection; this
            // server closes the connection after every HTTP response anyway
            // (one request per connection), so the first failure already
            // ends it — strictly stronger than the 5-failure ceiling.
            send(.error("unauthorized", message: "连接凭证无效，请重新连接。", statusCode: 401, reasonPhrase: "Unauthorized"), on: connection)
            return
        }

        if request.path == "/chat", RemoteChatWebSocket.isUpgradeRequest(request) {
            handleWebSocket(request, on: connection)
            return
        }
        if request.path == "/connect_info" {
            send(connectInfoResponse(request: request), on: connection)
            return
        }
        if request.path == "/events" {
            send(eventsResponse(request: request), on: connection)
            return
        }
        send(router.route(request), on: connection)
    }

    private func authenticate(_ request: RemoteChatHTTPRequest) -> RemotePairedDevice? {
        guard let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst(7))
        guard !token.isEmpty else { return nil }
        return authService.authenticate(token: token)
    }

    /// `POST /pair` — private/loopback sources only; WAN sources get 403.
    private func pairResponse(request: RemoteChatHTTPRequest, peerAddress: String) -> RemoteChatHTTPResponse {
        guard Self.isPrivatePeerAddress(peerAddress) else {
            return .error("pair_forbidden", message: "配对仅允许局域网来源。", statusCode: 403, reasonPhrase: "Forbidden")
        }
        guard request.method == "POST" else {
            return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
        }
        guard let body = try? RemoteChatHTTPCodec.jsonDecoder.decode(RemotePairRequestDTO.self, from: request.body) else {
            return .error("bad_request", message: "请求内容格式不正确，请重试。", statusCode: 400, reasonPhrase: "Bad Request")
        }
        switch pairingService.redeem(code: body.code, deviceName: body.deviceName, peerIP: peerAddress) {
        case .success(let credential):
            return .json(RemotePairResponseDTO(
                token: credential.token,
                fp: identity.spkiSHA256Hex,
                name: RemoteHostInfo.displayName,
                eps: endpointDTOs()
            ))
        case .failure(.rateLimited):
            return .error("rate_limited", message: "尝试次数过多，请稍后再试。", statusCode: 429, reasonPhrase: "Too Many Requests")
        case .failure(.invalidCode):
            return .error("invalid_pairing_code", message: "配对码错误或已过期。", statusCode: 403, reasonPhrase: "Forbidden")
        }
    }

    /// `GET /connect_info` — Bearer-authed; returns the current endpoint list
    /// so a paired client can silently refresh addresses while on the same LAN.
    private func connectInfoResponse(request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        guard request.method == "GET" else {
            return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
        }
        return .json(RemoteConnectInfoDTO(name: RemoteHostInfo.displayName, eps: endpointDTOs()))
    }

    private func endpointDTOs() -> [RemoteEndpointDTO] {
        endpointPublisher.currentSnapshot().endpoints.map { RemoteEndpointDTO(a: $0.address, p: $0.port) }
    }

    /// `/pair` source gate (spec §4.2): RFC1918 + link-local + loopback for
    /// both families, including IPv4-mapped IPv6. Anything else is WAN → 403.
    static func isPrivatePeerAddress(_ address: String) -> Bool {
        if let v4 = ipv4Bytes(address) {
            switch v4[0] {
            case 10, 127: return true
            case 169: return v4[1] == 254
            case 172: return (16...31).contains(v4[1])
            case 192: return v4[1] == 168
            default: return false
            }
        }
        if let v6 = ipv6Bytes(address) {
            // ::1
            if v6.dropLast().allSatisfy({ $0 == 0 }), v6.last == 1 { return true }
            // IPv4-mapped ::ffff:a.b.c.d
            if v6.prefix(10).allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
                return isPrivatePeerAddress(v6.suffix(4).map(String.init).joined(separator: "."))
            }
            // fe80::/10 link-local, fc00::/7 unique-local
            if v6[0] == 0xFE, (v6[1] & 0xC0) == 0x80 { return true }
            if (v6[0] & 0xFE) == 0xFC { return true }
            return false
        }
        return false
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        var storage = in_addr()
        guard inet_pton(AF_INET, address, &storage) == 1 else { return nil }
        return withUnsafeBytes(of: storage, Array.init)
    }

    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        var storage = in6_addr()
        guard inet_pton(AF_INET6, address, &storage) == 1 else { return nil }
        return withUnsafeBytes(of: storage, Array.init)
    }

    private func handleWebSocket(_ request: RemoteChatHTTPRequest, on connection: NWConnection) {
        guard request.method == "GET" else {
            send(.error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed"), on: connection)
            return
        }
        guard let response = RemoteChatWebSocket.handshakeResponse(for: request) else {
            send(.error("bad_websocket_upgrade", message: "实时连接启动失败，请重新进入对话。", statusCode: 400, reasonPhrase: "Bad Request"), on: connection)
            return
        }

        let connectionID = UUID()

        connection.send(content: response.data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                connection.cancel()
                return
            }
            self?.webSocketConnections[connectionID] = connection
            self?.connectionStates[connectionID] = RemoteChatConnectionState()
            guard let self else { return }
            print("RemoteChatServer accepted ws_id=\(connectionID.uuidString)")
            self.notifyDiagnosticsChangedLocked()
            self.sendWebSocketEvent(self.makeSystemEvent(type: "hello", status: "connected"), on: connection)
            self.receiveWebSocketFrames(from: connection, connectionID: connectionID, buffer: Data())
        })
    }

    private func receiveWebSocketFrames(from connection: NWConnection, connectionID: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.removeWebSocketConnection(connectionID)
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            do {
                let frames = try RemoteChatWebSocket.decodeFrames(from: &nextBuffer)
                var shouldClose = false
                for frame in frames {
                    switch frame.opcode {
                    case .text:
                        guard let text = String(data: frame.payload, encoding: .utf8) else {
                            self.sendWebSocketError("invalid_payload", message: "实时消息格式不正确，请重新进入对话。", on: connection)
                            shouldClose = true
                            continue
                        }
                        if self.handleRecoveryRequest(text: text, reply: { responseText in
                            self.sendWebSocketData(RemoteChatWebSocket.encodeText(responseText), on: connection)
                        }) {
                            continue
                        }
                        // New VNC commands take priority — fast-path decode.
                        if self.handleVNCCommand(text: text, connectionID: connectionID, connection: connection) {
                            continue
                        }
                        if self.handleWebSocketControl(text: text, connectionID: connectionID, connection: connection) {
                            continue
                        }
                        let previousTask = self.inboundTaskByConnection[connectionID]
                        let task = Task {
                            await previousTask?.value
                            await self.bridge.handle(text: text)
                        }
                        self.inboundTaskByConnection[connectionID] = task
                    case .ping:
                        self.sendWebSocketData(RemoteChatWebSocket.encodePong(payload: frame.payload), on: connection)
                    case .close:
                        self.removeWebSocketConnection(connectionID)
                        self.sendWebSocketData(RemoteChatWebSocket.encodeClose(), on: connection) {
                            connection.cancel()
                        }
                        shouldClose = true
                    case .continuation, .pong:
                        break
                    }
                }

                if !shouldClose {
                    self.receiveWebSocketFrames(from: connection, connectionID: connectionID, buffer: nextBuffer)
                }
            } catch {
                // Audit A-P1: previously sent a plain close frame which iOS
                // surfaced as a silent disconnect. Forward the typed error
                // when we can identify it (currently only `payloadTooLarge`)
                // with the RFC 6455 status code so the client knows why.
                let closeFrame: Data
                if let wsError = error as? RemoteChatWebSocketError, case .payloadTooLarge = wsError {
                    self.sendWebSocketError("websocket_payload_too_large", message: "单条消息太大，请减少内容后重试。", on: connection)
                    closeFrame = RemoteChatWebSocket.encodeClose(code: 1009, reason: "message too big")
                } else {
                    self.sendWebSocketError("websocket_decode_failed", message: "实时消息格式不正确，请重新进入对话。", on: connection)
                    closeFrame = RemoteChatWebSocket.encodeClose(code: 1002, reason: "protocol error")
                }
                self.sendWebSocketData(closeFrame, on: connection) {
                    self.removeWebSocketConnection(connectionID)
                    connection.cancel()
                }
            }
        }
    }

    private func send(_ response: RemoteChatHTTPResponse, on connection: NWConnection) {
        // isComplete + finalMessage lets the TLS layer emit close_notify and
        // a clean FIN; a bare cancel() after send races it and surfaces on
        // the client as RST (curl reports 000 despite the body arriving).
        connection.send(
            content: response.data,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func eventsResponse(request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        let sessionID = request.queryItems["sessionId"].flatMap(UUID.init(uuidString:))
        let afterCursor = request.queryItems["afterCursor"].flatMap(Int.init) ?? 0
        let limit = request.queryItems["limit"].flatMap(Int.init).map { min(max($0, 1), 500) } ?? 200
        if let firstCursor = replayCache.first?.cursor, afterCursor > 0, afterCursor < firstCursor - 1 {
            var truncated = makeSystemEvent(
                type: "replay_truncated",
                status: "snapshot_required",
                message: "消息记录已刷新，请重新加载当前对话。"
            )
            truncated.cursor = firstCursor - 1
            truncated.snapshotCursor = firstCursor - 1
            return .json(RemoteStreamEventPageDTO(events: [truncated], nextCursor: truncated.cursor, hasMore: true))
        }
        let events = replayCache.filter { event in
            guard (event.cursor ?? 0) > afterCursor else { return false }
            guard let sessionID else { return true }
            return event.sessionId == sessionID
        }
        let limited = Array(events.prefix(limit))
        let nextCursor = limited.last?.cursor
        let hasMore = events.count > limited.count
        return .json(RemoteStreamEventPageDTO(events: limited, nextCursor: nextCursor, hasMore: hasMore))
    }

    private func sendWebSocketEvent(_ event: RemoteChatStreamEvent, on connection: NWConnection) {
        do {
            let data = try RemoteChatHTTPCodec.jsonEncoder.encode(event)
            guard let text = String(data: data, encoding: .utf8) else { return }
            sendWebSocketData(RemoteChatWebSocket.encodeText(text), on: connection)
        } catch {
            sendWebSocketError("encoding_failed", message: "消息发送失败，请稍后重试。", on: connection)
        }
    }

    private func broadcastWebSocketEvent(_ event: RemoteChatStreamEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            let events = self.enqueueLegacyStreamEvent(event)
            for event in events {
                self.emitWebSocketEvent(event)
            }
        }
    }

    private func enqueueLegacyStreamEvent(_ event: RemoteChatStreamEvent) -> [RemoteChatStreamEvent] {
        let events = legacyStreamEventCoalescer.push(event)
        if legacyStreamEventCoalescer.hasPendingEvents {
            scheduleLegacyStreamDeltaFlushIfNeeded()
        } else {
            legacyStreamDeltaFlushItem?.cancel()
            legacyStreamDeltaFlushItem = nil
        }
        return events
    }

    private func scheduleLegacyStreamDeltaFlushIfNeeded() {
        guard legacyStreamDeltaFlushItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let events = self.legacyStreamEventCoalescer.flush()
            self.legacyStreamDeltaFlushItem = nil
            for event in events {
                self.emitWebSocketEvent(event)
            }
        }
        legacyStreamDeltaFlushItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(90), execute: item)
    }

    private func emitWebSocketEvent(_ incomingEvent: RemoteChatStreamEvent) {
        var event = incomingEvent
        if event.protocolVersion == nil {
            event.protocolVersion = 2
        }
        if event.eventId == nil {
            event.eventId = UUID()
        }
        if event.envelopeKind == nil {
            event.envelopeKind = "event"
        }
        if event.serverEpoch == nil {
            event.serverEpoch = self.serverEpoch
        }
        if event.eventScopeId == nil {
            event.eventScopeId = event.sessionId ?? event.clientConversationId
            event.eventScopeKind = event.sessionId != nil ? "session" : (event.clientConversationId != nil ? "client_conversation" : nil)
        }
        self.nextStreamCursor += 1
        event.cursor = self.nextStreamCursor
        event.snapshotCursor = self.nextStreamCursor
        self.replayCache.append(event)
        if self.replayCache.count > self.replayCacheLimit {
            self.replayCache.removeFirst(self.replayCache.count - self.replayCacheLimit)
        }
        // Phase B: legacy connections (or undecided, which we treat as legacy
        // until the first resume frame) get the legacy event. VNC connections
        // ignore legacy events.
        for (connectionID, connection) in self.webSocketConnections {
            let mode = self.connectionStates[connectionID]?.protocolMode ?? .undecided
            if mode == .vnc { continue }
            self.sendWebSocketEvent(event, on: connection)
        }
    }

    /// Fan a `PanelStateEnvelope` produced by the broadcaster only to
    /// connections focused on the same session. Draft creation gets one alias
    /// remap from the optimistic draft UUID to the concrete controller UUID.
    private func broadcastVNCEnvelope(_ envelope: PanelStateEnvelope) {
        queue.async { [weak self] in
            guard let self else { return }
            for (connectionID, connection) in self.webSocketConnections {
                guard let state = self.connectionStates[connectionID] else { continue }
                if state.protocolMode == .legacy { continue }
                guard self.shouldSendVNCEnvelope(envelope, to: state) else { continue }
                self.sendVNCEnvelope(envelope, on: connection)
            }
        }
    }

    private func shouldSendVNCEnvelope(_ envelope: PanelStateEnvelope, to state: RemoteChatConnectionState) -> Bool {
        guard let focusedSessionID = state.focusedSessionID else {
            return envelope.sessionId == nil
        }
        guard let envelopeSessionID = envelope.sessionId else {
            return true
        }
        if envelopeSessionID == focusedSessionID {
            state.isResolvingDraftSession = false
            return true
        }
        if state.isResolvingDraftSession {
            state.focusedSessionID = envelopeSessionID
            state.isResolvingDraftSession = false
            return true
        }
        return false
    }

    private func sendVNCEnvelope(_ envelope: PanelStateEnvelope, on connection: NWConnection) {
        do {
            let data = try RemoteChatHTTPCodec.jsonEncoder.encode(envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            sendWebSocketData(RemoteChatWebSocket.encodeText(text), on: connection)
        } catch {
            sendWebSocketError("encoding_failed", message: "界面状态发送失败，请稍后重试。", on: connection)
        }
    }

    private func sendVNCAck(_ ack: CommandAck, on connection: NWConnection) {
        do {
            let data = try RemoteChatHTTPCodec.jsonEncoder.encode(ack)
            guard let text = String(data: data, encoding: .utf8) else { return }
            sendWebSocketData(RemoteChatWebSocket.encodeText(text), on: connection)
        } catch {
            sendWebSocketError("encoding_failed", message: "操作结果发送失败，请稍后重试。", on: connection)
        }
    }

    private func handleRecoveryRequest(text: String, reply: @escaping (String) -> Void) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct TypeTag: Decodable { let type: String? }
        guard let tag = try? decoder.decode(TypeTag.self, from: data),
              tag.type == RemoteVNCFrameType.recoveryRequest else {
            return false
        }
        guard let request = try? decoder.decode(RemoteRecoveryRequest.self, from: data) else {
            replyEncoded(RemoteRecoveryResponse.error(requestId: Self.recoveryRequestId(from: data) ?? UUID(), message: "恢复请求格式不正确，请重试。"), reply: reply)
            return true
        }
        let response = router.recoveryResponse(for: request)
        replyEncoded(response, reply: reply)
        return true
    }

    private static func recoveryRequestId(from data: Data) -> UUID? {
        struct RequestIdEnvelope: Decodable { let requestId: UUID? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(RequestIdEnvelope.self, from: data) else { return nil }
        return envelope.requestId
    }

    private static func commandId(from data: Data) -> UUID? {
        struct CommandIdEnvelope: Decodable { let commandId: UUID? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(CommandIdEnvelope.self, from: data) else { return nil }
        return envelope.commandId
    }

    private func replyEncoded<T: Encodable>(_ value: T, reply: @escaping (String) -> Void) {
        guard let text = encodedJSONText(value) else { return }
        reply(text)
    }

    private func encodedJSONText<T: Encodable>(_ value: T) -> String? {
        guard let data = try? RemoteChatHTTPCodec.jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns `true` if the text was a VNC `command` frame and was handled.
    /// Other frame types (cursor_ack/resume legacy, send_message, control envelopes)
    /// fall through to the legacy handlers.
    private func handleVNCCommand(text: String, connectionID: UUID, connection: NWConnection) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Cheap type-tag peek.
        struct TypeTag: Decodable { let type: String? }
        guard let tag = try? decoder.decode(TypeTag.self, from: data),
              tag.type == RemoteVNCFrameType.command else {
            return false
        }
        guard let command = try? decoder.decode(Command.self, from: data) else {
            // Audit A-P1: previously emitted a legacy `assistant_error` frame
            // which the VNC iOS client drops silently. Recover the
            // commandId from a partial decode if possible so the iOS pending
            // queue can settle; otherwise stamp a synthetic UUID.
            let probedId = Self.commandId(from: data) ?? UUID()
            let ack = CommandAck(
                commandId: probedId,
                status: .error,
                message: "操作内容格式不正确，请重试。",
                sessionId: nil
            )
            sendVNCAck(ack, on: connection)
            return true
        }
        // Mark the connection as VNC-mode if not already.
        if let state = connectionStates[connectionID], state.protocolMode != .vnc {
            state.protocolMode = .vnc
        }
        let isDraftCommand = command.op == .newDraftSession
        let previousTask = inboundTaskByConnection[connectionID]
        let task = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            await self.processVNCCommand(
                command,
                connectionID: connectionID,
                connection: connection,
                isDraftCommand: isDraftCommand
            )
        }
        inboundTaskByConnection[connectionID] = task
        return true
    }

    private func processVNCCommand(
        _ command: Command,
        connectionID: UUID,
        connection: NWConnection,
        isDraftCommand: Bool
    ) async {
        let focusedSessionID = queue.sync { connectionStates[connectionID]?.focusedSessionID }
        let dispatch = await MainActor.run { () -> RemoteChatCommandRouter.Dispatch? in
            guard let pipeline = vncPipeline else { return nil }
            return pipeline.router.route(command, focusedSessionID: focusedSessionID)
        }
        guard let dispatch else {
            let ack = CommandAck(
                commandId: command.commandId,
                status: .error,
                message: "remote panel is not ready",
                sessionId: command.sessionId
            )
            queue.sync {
                sendVNCAck(ack, on: connection)
            }
            return
        }
        queue.sync {
            sendVNCAck(dispatch.ack, on: connection)
            if dispatch.shouldUpdateFocusedSessionID {
                connectionStates[connectionID]?.focusedSessionID = dispatch.newFocusedSessionID
                connectionStates[connectionID]?.isResolvingDraftSession = isDraftCommand
            }
        }
        if dispatch.shouldPushSnapshotForFocus {
            pushFocusedSnapshot(connectionID: connectionID, connection: connection)
        }
    }

    private func pushFocusedSnapshot(connectionID: UUID, connection: NWConnection) {
        let focusedSessionID = queue.sync { connectionStates[connectionID]?.focusedSessionID }
        Task { @MainActor [weak self] in
            guard let self, let pipeline = self.vncPipeline else { return }
            if let snapshot = pipeline.broadcaster.snapshot(for: focusedSessionID) {
                let envelope = PanelStateEnvelope(snapshot: snapshot)
                self.queue.async {
                    self.sendVNCEnvelope(envelope, on: connection)
                }
            }
        }
    }

    private func handleWebSocketControl(text: String, connectionID: UUID, connection: NWConnection) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let control = try? decoder.decode(RemoteChatWebSocketControlEnvelope.self, from: data) else {
            return false
        }
        switch control.type {
        case "cursor_ack":
            if let cursor = control.cursor {
                connectionStates[connectionID]?.lastAckedCursor = cursor
            }
            sendWebSocketEvent(makeAckEvent(control: control, status: "applied"), on: connection)
            return true
        case "resume":
            // Decide protocol mode by the legacy-only `cursor` field. A VNC
            // client's first `resume` carries no revision yet (`lastRevision`
            // is nil until it has received a snapshot), so keying off
            // `lastRevision` would misroute every fresh VNC connection into
            // the legacy replay path and never deliver a `panel_state` frame.
            let isVNC = control.cursor == nil
            if let state = connectionStates[connectionID] {
                state.protocolMode = isVNC ? .vnc : .legacy
                state.lastAckedRevision = control.lastRevision
            }
            if isVNC {
                // The VNC client's "resume accepted" signal is the
                // `panel_state` envelope itself. Emitting a legacy
                // `command_ack` event here would fail `CommandAck` decoding
                // on the client (no `commandId`) and pollute its ack queue.
                handleVNCResume(control: control, connectionID: connectionID, connection: connection)
            } else {
                handleLegacyResume(control: control, connection: connection)
                sendWebSocketEvent(makeAckEvent(control: control, status: "accepted"), on: connection)
            }
            return true
        default:
            return false
        }
    }

    private func handleLegacyResume(control: RemoteChatWebSocketControlEnvelope, connection: NWConnection) {
        let cursor = control.cursor ?? 0
        let sessionID = control.sessionId
        let clientConversationID = control.clientConversationId
        queue.async { [weak self] in
            guard let self else { return }
            if let firstCursor = self.replayCache.first?.cursor, cursor > 0, cursor < firstCursor - 1 {
                var truncated = self.makeSystemEvent(
                    type: "replay_truncated",
                    status: "snapshot_required",
                    message: "消息记录已刷新，请重新加载当前对话。"
                )
                truncated.cursor = firstCursor - 1
                truncated.snapshotCursor = firstCursor - 1
                self.sendWebSocketEvent(truncated, on: connection)
                return
            }
            let replayEvents = self.replayCache.filter { event in
                guard (event.cursor ?? 0) > cursor else { return false }
                if let sessionID {
                    return event.sessionId == sessionID
                }
                if let clientConversationID {
                    return event.clientConversationId == clientConversationID || event.sessionId == clientConversationID
                }
                return true
            }
            for var event in replayEvents {
                event.replay = true
                self.sendWebSocketEvent(event, on: connection)
            }
        }
    }

    private func handleVNCResume(control: RemoteChatWebSocketControlEnvelope, connectionID: UUID, connection: NWConnection) {
        let sessionID = control.sessionId
        let lastRevision = control.lastRevision
        // VNC resume binds the connection's focus to the requested session.
        if let sessionID {
            connectionStates[connectionID]?.focusedSessionID = sessionID
        }
        Task { @MainActor [weak self] in
            guard let self, let pipeline = self.vncPipeline else { return }
            let payload = pipeline.broadcaster.replayPayload(sessionId: sessionID, lastRevision: lastRevision)
            // 当 client `lastRevision == server.currentRevision` 时 replayPayload 返回
            // `.empty`(client 已经追上了,没有新 patch 要发)。但 VNC client 端把
            // 接收到任意 envelope 当作连接 OK 的信号,如果服务端在 resume 时一个字节
            // 都不回,iOS 端就会出现"WS 握手成功但永远 stuck 在'连接中'"的诡异状态,
            // pending command 也不会重放。这里兜底,empty 时也回一份当前 snapshot。
            let fallbackSnapshot: PanelStateSnapshot?
            if case .empty = payload {
                fallbackSnapshot = pipeline.broadcaster.snapshot(for: sessionID)
                    ?? pipeline.broadcaster.snapshot(for: nil)
            } else {
                fallbackSnapshot = nil
            }
            self.queue.async {
                switch payload {
                case .snapshot(let snapshot):
                    self.sendVNCEnvelope(PanelStateEnvelope(snapshot: snapshot), on: connection)
                case .patches(let patches):
                    for patch in patches {
                        self.sendVNCEnvelope(PanelStateEnvelope(patch: patch), on: connection)
                    }
                case .empty:
                    if let fallbackSnapshot {
                        self.sendVNCEnvelope(PanelStateEnvelope(snapshot: fallbackSnapshot), on: connection)
                    }
                }
            }
        }
    }

    private func makeAckEvent(control: RemoteChatWebSocketControlEnvelope, status: String) -> RemoteChatStreamEvent {
        makeSystemEvent(
            type: "command_ack",
            requestId: control.requestId,
            clientConversationId: control.clientConversationId,
            sessionId: control.sessionId,
            status: status,
            message: control.commandId?.uuidString ?? control.type
        )
    }

    private func makeSystemEvent(
        type: String,
        requestId: String? = nil,
        clientConversationId: UUID? = nil,
        sessionId: UUID? = nil,
        status: String? = nil,
        message: String? = nil
    ) -> RemoteChatStreamEvent {
        RemoteChatStreamEvent(
            type: type,
            requestId: requestId,
            clientConversationId: clientConversationId,
            eventScopeId: sessionId ?? clientConversationId,
            eventScopeKind: sessionId != nil ? "session" : (clientConversationId != nil ? "client_conversation" : "global"),
            sessionId: sessionId,
            status: status,
            message: message,
            protocolVersion: 2,
            eventId: UUID(),
            envelopeKind: "event",
            serverEpoch: serverEpoch
        )
    }

    private func diagnosticsSnapshotLocked() -> RemoteChatServerDiagnostics {
        RemoteChatServerDiagnostics(
            activeWebSocketCount: webSocketConnections.count,
            localWebSocketIDs: webSocketConnections.keys.map(\.uuidString).sorted()
        )
    }

    private func notifyDiagnosticsChangedLocked() {
        onDiagnosticsChanged?(diagnosticsSnapshotLocked())
    }

    private func removeWebSocketConnection(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.webSocketConnections.removeValue(forKey: id)
            self.connectionStates.removeValue(forKey: id)
            self.inboundTaskByConnection[id]?.cancel()
            self.inboundTaskByConnection.removeValue(forKey: id)
            print("RemoteChatServer closed ws_id=\(id.uuidString)")
            self.notifyDiagnosticsChangedLocked()
        }
    }

    private func sendWebSocketError(_ error: String, message: String, on connection: NWConnection) {
        let event = RemoteChatStreamEvent(type: "assistant_error", requestId: nil, sessionId: nil, messageId: nil, seq: nil, kind: nil, title: nil, subtitle: nil, delta: nil, text: nil, status: "failed", externalSessionId: nil, message: message)
        do {
            let data = try RemoteChatHTTPCodec.jsonEncoder.encode(event)
            guard let text = String(data: data, encoding: .utf8) else { return }
            sendWebSocketData(RemoteChatWebSocket.encodeText(text), on: connection)
        } catch {
            let fallback = "{\"type\":\"assistant_error\",\"status\":\"failed\",\"message\":\"\(error)\"}"
            sendWebSocketData(RemoteChatWebSocket.encodeText(fallback), on: connection)
        }
    }

    private func sendWebSocketData(_ data: Data, on connection: NWConnection, completion: (() -> Void)? = nil) {
        queue.async {
            connection.send(content: data, completion: .contentProcessed { _ in
                completion?()
            })
        }
    }
}

enum RemoteChatServerError: Error {
    case invalidPort
}
