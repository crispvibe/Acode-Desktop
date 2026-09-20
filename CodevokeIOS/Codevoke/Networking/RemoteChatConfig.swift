import Foundation

/// LAN-direct connection target. There is no backend and no credential:
/// any device that can reach `macHost:port` can talk to the host's
/// HTTP + WebSocket server.
struct RemoteChatConfig: Equatable {
    var macHost: String
    var port: Int

    var isComplete: Bool {
        !macHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    var baseURL: URL? {
        guard isComplete else { return nil }
        return URL(string: "http://\(macHost):\(port)")
    }

    var webSocketURL: URL? {
        guard isComplete else { return nil }
        return URL(string: "ws://\(macHost):\(port)/chat")
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

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: L10n.string("请先连接远程设备。")
        case .invalidURL: L10n.string("连接地址无效。")
        case .badStatus(let code): L10n.format("服务器返回错误状态：%d。", code)
        case .serverMessage(let message, _): message
        case .emptyResponse: L10n.string("服务器返回为空。")
        case .webSocketMessageUnsupported: L10n.string("收到不支持的 WebSocket 消息。")
        case .remoteConnectionFailed: L10n.string("连接没有建立成功，请确认电脑端在线，并与手机处于同一 Wi‑Fi。")
        }
    }
}

struct RemoteServerErrorPayload: Decodable {
    let error: String?
    let message: String?
}
