import Foundation

enum LanSubnetProbe {
    static func discoverHealthHost(port: Int, preferredHost: String? = nil, session: URLSession = .shared) async -> String? {
        await discoverHealthHosts(port: port, preferredHost: preferredHost, session: session).first
    }

    /// Scans the current /24 Wi-Fi subnet for hosts answering `GET /health`
    /// on `port`. Probes run concurrently (bounded) so a full sweep finishes
    /// in roughly the per-request timeout rather than 254 sequential seconds.
    static func discoverHealthHosts(port: Int, preferredHost: String? = nil, session: URLSession = .shared) async -> [String] {
        guard let prefix = LanNetworkSelector.wifiSubnetPrefix() else {
            if let preferredHost, !preferredHost.isEmpty,
               await healthOK(host: preferredHost, port: port, session: session) {
                return [preferredHost]
            }
            return []
        }

        return await withTaskGroup(of: String?.self) { group in
            var inFlight = 0
            var results: [String] = []
            for host in 1...254 {
                let ip = "\(prefix).\(host)"
                if inFlight >= 32 {
                    if let found = await group.next(), let found {
                        results.append(found)
                    }
                    inFlight -= 1
                }
                group.addTask {
                    await healthOK(host: ip, port: port, session: session) ? ip : nil
                }
                inFlight += 1
            }
            for await found in group {
                if let found { results.append(found) }
            }
            if let preferredHost, !preferredHost.isEmpty {
                results.removeAll { $0 == preferredHost }
                results.insert(preferredHost, at: 0)
            }
            return results
        }
    }

    private static func healthOK(host: String, port: Int, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
