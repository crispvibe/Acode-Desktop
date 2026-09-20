import Foundation
import Network

enum LanNetworkSelector {
    static func isOnWifi() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        var satisfied = false
        monitor.pathUpdateHandler = { path in
            satisfied = path.status == .satisfied
            semaphore.signal()
        }
        let queue = DispatchQueue(label: "com.codevoke.lan-path")
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1.0)
        monitor.cancel()
        return satisfied
    }

    static func localWifiIPv4() -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(cString: host)
            if isPrivateIPv4(ip) { return ip }
        }
        return nil
    }

    static func wifiSubnetPrefix() -> String? {
        guard let ip = localWifiIPv4() else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, let second) where (16...31).contains(second): return true
        case (192, 168): return true
        default: return false
        }
    }
}
