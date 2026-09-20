import Foundation

/// 子网扫描发现的一台 acode host（§4.2 /health：proto:2 + pair + name）。
/// `peerFP` 是 TLS 握手出示的叶子证书 SPKI-SHA256——即主机身份（= EndpointStore
/// 的 hostId），用来判断"这台机器是不是已配对设备"并支撑静默刷新。
struct DiscoveredLanHost: Equatable, Identifiable {
    let host: String
    let port: Int
    let name: String?
    let peerFP: String?
    let pairCapable: Bool

    var id: String { host }
}

enum LanSubnetProbe {
    /// Scans the current /24 Wi-Fi subnet for hosts answering `GET /health`
    /// on `port`. WAN 定稿后 host 统一 TLS（§4.1），探测走 https +
    /// discovery session（接受任意证书、记录出示指纹）。Probes run
    /// concurrently (bounded) so a full sweep finishes in roughly the
    /// per-request timeout rather than 254 sequential seconds.
    static func discoverHosts(port: Int, preferredHost: String? = nil) async -> [DiscoveredLanHost] {
        let (session, delegate) = RemoteSecureSessionFactory.discoverySession()
        defer { session.invalidateAndCancel() }

        func probe(_ host: String) async -> DiscoveredLanHost? {
            guard let result = await RemotePairingClient.probeHealth(
                host: host, port: port, session: session, delegate: delegate, timeout: 1.2
            ), result.isAuthCapableHost else { return nil }
            return DiscoveredLanHost(
                host: host, port: port, name: result.health.name,
                peerFP: result.peerFP, pairCapable: result.pairCapable
            )
        }

        guard let prefix = LanNetworkSelector.wifiSubnetPrefix() else {
            if let preferredHost, !preferredHost.isEmpty, let found = await probe(preferredHost) {
                return [found]
            }
            return []
        }

        return await withTaskGroup(of: DiscoveredLanHost?.self) { group in
            var inFlight = 0
            var results: [DiscoveredLanHost] = []
            for host in 1...254 {
                let ip = "\(prefix).\(host)"
                if inFlight >= 32 {
                    if let found = await group.next(), let found {
                        results.append(found)
                    }
                    inFlight -= 1
                }
                group.addTask { await probe(ip) }
                inFlight += 1
            }
            for await found in group {
                if let found { results.append(found) }
            }
            if let preferredHost, !preferredHost.isEmpty,
               let index = results.firstIndex(where: { $0.host == preferredHost }) {
                let preferred = results.remove(at: index)
                results.insert(preferred, at: 0)
            }
            return results
        }
    }
}
