import Foundation

/// Discovers Codevoke hosts on the local network by probing the Wi-Fi
/// subnet for `GET /health` on the remote-chat port（§4.2：https + proto:2）。
///
/// 扫到的主机如果证书指纹命中 EndpointStore（即已配对设备），顺手用
/// `/connect_info` 静默刷新它的 WAN 地址簿（§6）。
@MainActor
final class DeviceListViewModel: ObservableObject {
    @Published private(set) var hosts: [DiscoveredLanHost] = []
    @Published private(set) var pairedHosts: [PairedHost] = []
    @Published private(set) var isScanning = false
    @Published var message: String?

    let port = DeviceConnectViewModel.defaultPort
    private let store = EndpointStore.shared

    func scan(preferredHost: String? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        message = nil
        defer { isScanning = false }

        reloadPaired()
        hosts = await LanSubnetProbe.discoverHosts(port: port, preferredHost: preferredHost)
        // 静默刷新：发现已配对 host → GET /connect_info 更新 eps。
        for host in hosts where isPaired(host) {
            Task { await refreshConnectInfo(for: host) }
        }
        if hosts.isEmpty && pairedHosts.isEmpty {
            message = L10n.string("没有在本局域网找到运行 acode 的电脑，请确认电脑端已开启设备连接服务，或手动输入地址。")
        }
    }

    func reloadPaired() {
        pairedHosts = store.allRecords()
    }

    /// 这台扫描到的主机是否已配对（指纹即 hostId）。
    func isPaired(_ host: DiscoveredLanHost) -> Bool {
        guard let fp = host.peerFP else { return false }
        return store.record(forHostId: fp) != nil
    }

    func pairedHost(for host: DiscoveredLanHost) -> PairedHost? {
        guard let fp = host.peerFP else { return nil }
        return store.record(forHostId: fp)
    }

    /// 已配对设备列表里，这台机器当前是否同局域网在线。
    func isOnLAN(_ record: PairedHost) -> Bool {
        hosts.contains { $0.peerFP == record.hostId }
    }

    func unpair(_ hostId: String) {
        store.remove(hostId: hostId)
        reloadPaired()
    }

    /// §6 静默刷新：同 LAN 的已配对主机 → /connect_info 更新 eps/name。
    private func refreshConnectInfo(for host: DiscoveredLanHost) async {
        guard let fp = host.peerFP,
              let record = store.record(forHostId: fp) else { return }
        do {
            let info = try await RemotePairingClient.fetchConnectInfo(
                host: host.host, port: host.port,
                token: record.token, certFP: record.certFP, timeout: 3
            )
            store.applyConnectInfo(hostId: fp, name: info.name, eps: info.eps ?? [])
            reloadPaired()
        } catch {
            // 静默刷新失败不提示——下次扫描或连接时还会重试。
        }
    }
}
