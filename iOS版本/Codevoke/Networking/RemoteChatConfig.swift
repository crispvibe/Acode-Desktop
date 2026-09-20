import Foundation

/// 直连连接目标。WAN 方案定稿后 host 统一 `wss://` + 鉴权（§4.1，LAN/WAN
/// 同一套，不再保留明文路径）：
/// - 已配对主机：`authToken`（Bearer）+ `certFP`（SPKI-SHA256 pin）必填；
///   `hostId` == `certFP`，是 EndpointStore 里的稳定身份。
/// - 未配对目标：`authToken`/`certFP` 为空，连接必然在鉴权前失败，
///   UI 层引导走扫码/连接串/6 位码配对。
struct RemoteChatConfig: Equatable {
    var macHost: String
    var port: Int
    var hostId: String?
    var hostName: String?
    var authToken: String?
    var certFP: String?

    init(macHost: String, port: Int, hostId: String? = nil, hostName: String? = nil,
         authToken: String? = nil, certFP: String? = nil) {
        self.macHost = macHost
        self.port = port
        self.hostId = hostId
        self.hostName = hostName
        self.authToken = authToken
        self.certFP = certFP
    }

    var isComplete: Bool {
        !macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    /// 有 Bearer + pin 才能过 §4.2 鉴权。
    var isPaired: Bool {
        guard let authToken, let certFP else { return false }
        return !authToken.isEmpty && !RemoteWanCredentials.normalizeFP(certFP).isEmpty
    }

    /// 当前点选的主目标（RemoteWanTransport 还会叠加 EndpointStore.eps）。
    var primaryEndpoint: RemoteEndpoint {
        RemoteEndpoint(a: macHost, p: port)
    }

    private var urlHost: String {
        RemotePairingClient.urlHost(macHost)
    }

    var baseURL: URL? {
        guard isComplete else { return nil }
        return URL(string: "https://\(urlHost):\(port)")
    }

    var webSocketURL: URL? {
        guard isComplete else { return nil }
        return URL(string: "wss://\(urlHost):\(port)/chat")
    }
}

enum RemoteChatError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case badStatus(Int)
    case serverMessage(String, statusCode: Int)
    case emptyResponse
    case webSocketMessageUnsupported
    case remoteConnectionFailed
    /// Bearer 被拒（401）——token 吊销/失效，需重新配对。
    case unauthorized
    /// 所有候选 endpoint 都不可达——地址可能已变化（§6 兜底提示）。
    case endpointsStale
    /// TLS 握手出示的证书与已配对 pin 不符——证书轮换/重装（§4.3）。
    case certificateMismatch

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: L10n.string("请先连接远程设备。")
        case .invalidURL: L10n.string("连接地址无效。")
        case .badStatus(let code): L10n.format("服务器返回错误状态：%d。", code)
        case .serverMessage(let message, _): message
        case .emptyResponse: L10n.string("服务器返回为空。")
        case .webSocketMessageUnsupported: L10n.string("收到不支持的 WebSocket 消息。")
        case .remoteConnectionFailed: L10n.string("连接没有建立成功，请确认电脑端在线，并与手机处于同一 Wi‑Fi。")
        case .unauthorized: L10n.string("鉴权失败，请检查电脑端设置面板里的连接配置是否正确。")
        case .endpointsStale: L10n.string("无法连上该设备已保存的地址，地址可能已变化。请重新扫码配对，或与电脑连回同一 Wi‑Fi 后重试。")
        case .certificateMismatch: L10n.string("电脑端证书已更换，请重新配对后再连接。")
        }
    }
}

struct RemoteServerErrorPayload: Decodable {
    let error: String?
    let message: String?
}
