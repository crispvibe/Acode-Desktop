import Foundation

/// §4.2 配对与发现 HTTP 端点。
///
/// - `/health`：无鉴权，供子网扫描与"点选主机后判断配对状态"用。
///   此时还没有 pin，走 `DiscoveryTrustDelegate`（接受任意证书 + 记录出示指纹）。
/// - `POST /pair`：6 位码鉴权，仅局域网可达时调用；返回 fp 与 TLS 实际出示
///   指纹比对，不一致即中间人，拒绝落库。
/// - `GET /connect_info`：Bearer + pinned session，静默刷新 eps。
enum RemotePairingClient {

    /// 一次 /health 探测的结果。`peerFP` 是 TLS 握手实际出示的叶子证书
    /// SPKI-SHA256——即主机身份（hostId），不是响应 JSON 里的字段。
    struct HealthProbe {
        let host: String
        let port: Int
        let health: RemoteHealth
        let peerFP: String?

        /// `proto:2` = 鉴权版服务端（§4.2）。旧版明文 host 直接无法完成
        /// TLS 握手，到不了这里；这里防的是非 acode 的 TLS 服务。
        var isAuthCapableHost: Bool { health.proto == 2 }
        var pairCapable: Bool { health.pair == true }
    }

    /// 指定 session 调 /health。扫描与单点探测共用这一条路径，
    /// session 由调用方持有（扫描器复用同一个 discovery session）。
    static func probeHealth(host: String, port: Int, session: URLSession, delegate: DiscoveryTrustDelegate,
                            timeout: TimeInterval = 4) async -> HealthProbe? {
        guard let url = URL(string: "https://\(urlHost(host)):\(port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let health = try JSONDecoder().decode(RemoteHealth.self, from: data)
            return HealthProbe(host: host, port: port, health: health,
                               peerFP: delegate.fingerprint(host: host, port: port))
        } catch {
            return nil
        }
    }

    /// `POST /pair {code, deviceName}` → `{token, fp, name, eps}`。
    /// 返回前强制比对响应 fp 与握手实际出示的叶子证书指纹，不一致 = 中间人。
    /// deviceName 由调用方传（UIDevice.current 是 MainActor 隔离）。
    static func pair(host: String, port: Int, code: String, deviceName: String) async throws -> PairedHost {
        let (session, delegate) = RemoteSecureSessionFactory.discoverySession()
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(urlHost(host)):\(port)/pair") else {
            throw RemoteChatError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemotePairRequest(code: code, deviceName: deviceName))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteChatError.emptyResponse }
        guard 200..<300 ~= http.statusCode else {
            throw pairError(statusCode: http.statusCode, data: data)
        }
        let pairResponse = try JSONDecoder().decode(RemotePairResponse.self, from: data)
        let responseFP = RemoteWanCredentials.normalizeFP(pairResponse.fp)
        guard !responseFP.isEmpty else {
            throw RemoteChatError.serverMessage(L10n.string("电脑端返回的证书指纹无效。"), statusCode: 200)
        }
        // TOFU 校验：payload 里的 fp 必须等于这次 TLS 握手实际出示的证书指纹，
        // 否则说明 LAN 上有人替换了证书——不落库、不连接。
        if let presented = delegate.fingerprint(host: host, port: port), presented != responseFP {
            throw RemoteChatError.serverMessage(L10n.string("证书指纹校验不一致，网络可能被劫持，请检查网络后重试。"), statusCode: 200)
        }
        return PairedHost(
            hostId: responseFP,
            name: pairResponse.name ?? host,
            token: pairResponse.token,
            certFP: responseFP,
            eps: (pairResponse.eps ?? []).filter { $0.isValid },
            lastGood: nil,
            updatedAt: Date()
        )
    }

    /// `GET /connect_info`（Bearer + pin）→ `{name, eps}`。供静默刷新与
    /// WAN 竞速探测复用；返回 nil 之外用 throws 区分 401 / pin 拒绝。
    static func fetchConnectInfo(host: String, port: Int, token: String, certFP: String,
                                 timeout: TimeInterval = 8) async throws -> RemoteConnectInfo {
        let (session, delegate) = RemoteSecureSessionFactory.pinnedSession(certFP: certFP)
        defer { session.invalidateAndCancel() }
        do {
            return try await fetchConnectInfo(host: host, port: port, token: token,
                                              session: session, timeout: timeout)
        } catch {
            if delegate.sawPinMismatch { throw RemoteChatError.certificateMismatch }
            throw error
        }
    }

    /// 共享 session 版本——RemoteWanTransport 竞速时复用同一 pinned session。
    static func fetchConnectInfo(host: String, port: Int, token: String,
                                 session: URLSession, timeout: TimeInterval) async throws -> RemoteConnectInfo {
        guard let url = URL(string: "https://\(urlHost(host)):\(port)/connect_info") else {
            throw RemoteChatError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteChatError.emptyResponse }
        guard 200..<300 ~= http.statusCode else {
            throw http.statusCode == 401 ? RemoteChatError.unauthorized : RemoteChatError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(RemoteConnectInfo.self, from: data)
    }

    private static func pairError(statusCode: Int, data: Data) -> Error {
        if let payload = try? JSONDecoder().decode(RemoteServerErrorPayload.self, from: data),
           let message = payload.message, !message.isEmpty {
            return RemoteChatError.serverMessage(message, statusCode: statusCode)
        }
        switch statusCode {
        case 400, 401:
            return RemoteChatError.serverMessage(L10n.string("配对码错误或已过期，请核对电脑端显示的 6 位码后重试。"), statusCode: statusCode)
        case 403:
            return RemoteChatError.serverMessage(L10n.string("配对只允许在同一局域网下进行。"), statusCode: statusCode)
        case 429:
            return RemoteChatError.serverMessage(L10n.string("尝试次数过多，请稍后再试。"), statusCode: statusCode)
        default:
            return RemoteChatError.badStatus(statusCode)
        }
    }

    /// IPv6 字面量进 URL 需要方括号。
    static func urlHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { return trimmed }
        return trimmed.contains(":") ? "[\(trimmed)]" : trimmed
    }
}
