import Foundation

/// Discovers Codevoke hosts on the local network by probing the Wi-Fi
/// subnet for `GET /health` on the remote-chat port.
@MainActor
final class DeviceListViewModel: ObservableObject {
    @Published private(set) var hosts: [String] = []
    @Published private(set) var isScanning = false
    @Published var message: String?

    let port = DeviceConnectViewModel.defaultPort

    func scan(preferredHost: String? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        defer { isScanning = false }

        hosts = await LanSubnetProbe.discoverHealthHosts(port: port, preferredHost: preferredHost)
        if hosts.isEmpty {
            message = L10n.string("没有在本局域网找到运行 Codevoke 的电脑，请确认电脑端已开启设备连接服务，或手动输入地址。")
        }
    }
}
