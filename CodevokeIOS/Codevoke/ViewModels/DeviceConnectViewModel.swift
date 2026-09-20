import Foundation

/// LAN-direct connect flow. No accounts, device codes, or approvals:
/// a host is reachable if `GET /health` on `port` answers 200, and a
/// successful probe returns a ready `RemoteChatConfig` for ChatViewModel.
@MainActor
final class DeviceConnectViewModel: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var latestTransport: String?
    @Published var message: String?

    static let defaultPort = 18765

    func connect(host: String, port: Int) async -> RemoteChatConfig? {
        guard !isConnecting else { return nil }
        isConnecting = true
        message = nil
        defer { isConnecting = false }

        let config = RemoteChatConfig(
            macHost: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port
        )
        guard config.isComplete else {
            message = L10n.string("请输入有效的地址和端口。")
            return nil
        }

        do {
            _ = try await RemoteHTTPClient(config: config).fetchHealth()
            latestTransport = "lan"
            return config
        } catch {
            message = RemoteUserFacingText.apiError(
                error.localizedDescription,
                fallback: "连接失败，请确认电脑端已开启设备连接服务，且手机与电脑在同一 Wi‑Fi 下。"
            )
            return nil
        }
    }
}
