import Darwin
import Foundation
import Network
import SystemConfiguration
import os

private let wanPublisherLog = Logger(subsystem: "com.codevoke.mac", category: "WanEndpointPublisher")

/// Host-side "publish" module (spec §5): periodically produces the candidate
/// endpoint list (`eps`) plus per-candidate diagnostics for the settings page.
///
/// - Global IPv6 is enumerated with `getifaddrs` (link-local fe80::/10 and ULA
///   fc00::/7 excluded, `2000::/3` kept; temporary/deprecated addresses only
///   used when no stable address exists).
/// - IPv4 reachability goes through `DNSServiceNATPortMappingCreate`, which on
///   macOS covers NAT-PMP, PCP and UPnP/IGD in one shot and renews the mapping
///   automatically while the ref is alive.
/// - The external IPv4 reported by the gateway is checked against shared/CGNAT
///   ranges (100.64/10, 10/8, 172.16/12, 192.168/16): a hit means upstream NAT
///   and the IPv4 candidate is not usable.
final class WanEndpointPublisher {
    enum EndpointKind: String, Equatable {
        case ipv6Global = "ipv6"
        case ipv4Mapped = "ipv4"
    }

    struct PublishedEndpoint: Equatable {
        let address: String
        let port: UInt16
        let kind: EndpointKind
    }

    enum DiagnosticState: Equatable {
        case usable       // 直连可用
        case checking     // 检测中
        case cgnat        // 上游还有 NAT（运营商 CGNAT / 多重 NAT）
        case unsupported  // 路由器不支持自动映射，需手动端口转发
        case unavailable  // 无可用候选
    }

    struct EndpointDiagnostic: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let state: DiagnosticState
    }

    struct Snapshot: Equatable {
        var endpoints: [PublishedEndpoint] = []
        var diagnostics: [EndpointDiagnostic] = []
        var refreshedAt = Date()
    }

    /// Called on the publisher queue whenever the snapshot changes.
    var onSnapshot: ((Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.codevoke.wan-endpoint-publisher", qos: .utility)
    private var pathMonitor: NWPathMonitor?
    private var reenumerateTimer: DispatchSourceTimer?
    private var natMappingRef: DNSServiceRef?

    private var port: UInt16 = 0
    private var running = false

    private var ipv6Addresses: [IPv6AddressInfo] = []
    private var natMapping: NATMappingState = .idle

    private var snapshot = Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            onSnapshot?(snapshot)
        }
    }

    private enum NATMappingState: Equatable {
        case idle
        case probing
        case mapped(externalAddress: String, externalPort: UInt16)
        case cgnat(externalAddress: String, externalPort: UInt16)
        case unsupported
        case unavailable
    }

    private struct IPv6AddressInfo: Equatable {
        let address: String
        let interfaceName: String
        let isTemporary: Bool
        let isEUI64: Bool
    }

    // MARK: - Lifecycle

    func start(port: UInt16) {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.port = port
            self.natMapping = .probing
            self.refresh()

            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                self?.queue.async { self?.refresh() }
            }
            monitor.start(queue: self.queue)
            self.pathMonitor = monitor

            // Slow periodic re-enumeration: prefix rotation / address flag
            // changes do not always surface as NWPathMonitor updates.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.reenumerateTimer = timer
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.reenumerateTimer?.cancel()
            self.reenumerateTimer = nil
            self.teardownNATMapping()
            self.ipv6Addresses = []
            self.natMapping = .idle
            self.snapshot = Snapshot()
        }
    }

    func currentSnapshot() -> Snapshot {
        queue.sync { snapshot }
    }

    // MARK: - Refresh

    private func refresh() {
        ipv6Addresses = Self.enumerateGlobalIPv6Addresses()
        if natMappingRef == nil {
            startNATMapping()
        }
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        var endpoints: [PublishedEndpoint] = []
        var diagnostics: [EndpointDiagnostic] = []

        // --- IPv6 candidates: stable first (EUI-64 IID first), temporary as
        // last resort (spec §5.1 prefers stable). ---
        let stable = ipv6Addresses.filter { !$0.isTemporary }
        let fallback = ipv6Addresses.filter { $0.isTemporary }
        let preferred = (stable.isEmpty ? fallback : stable)
            .sorted { ($0.isEUI64 && !$1.isEUI64) || ($0.isEUI64 == $1.isEUI64 && $0.address < $1.address) }

        if preferred.isEmpty {
            diagnostics.append(EndpointDiagnostic(
                title: "IPv6",
                detail: ipv6Addresses.isEmpty ? "无全球IPv6" : "仅检测到临时 IPv6 地址，已跳过",
                state: .unavailable
            ))
        } else {
            for info in preferred {
                endpoints.append(PublishedEndpoint(address: info.address, port: port, kind: .ipv6Global))
                diagnostics.append(EndpointDiagnostic(
                    title: "IPv6 · \(info.address)",
                    detail: info.isTemporary ? "直连可用（临时地址，前缀变化后需重新配对）" : "直连可用",
                    state: .usable
                ))
            }
        }

        // --- IPv4 via NAT mapping (NAT-PMP / PCP / UPnP handled by configd). ---
        switch natMapping {
        case .idle:
            break
        case .probing:
            diagnostics.append(EndpointDiagnostic(
                title: "IPv4 · 路由器端口映射",
                detail: "检测中（NAT-PMP / UPnP）…",
                state: .checking
            ))
        case .mapped(let address, let externalPort):
            endpoints.append(PublishedEndpoint(address: address, port: externalPort, kind: .ipv4Mapped))
            diagnostics.append(EndpointDiagnostic(
                title: "IPv4 · \(address):\(externalPort)",
                detail: "直连可用（路由器自动映射）",
                state: .usable
            ))
        case .cgnat(let address, let externalPort):
            diagnostics.append(EndpointDiagnostic(
                title: "IPv4 · \(address):\(externalPort)",
                detail: "CGNAT：上游还有一层 NAT，该候选不可用",
                state: .cgnat
            ))
        case .unsupported:
            diagnostics.append(EndpointDiagnostic(
                title: "IPv4 · 路由器端口映射",
                detail: "路由器不支持自动映射，需手动端口转发",
                state: .unsupported
            ))
        case .unavailable:
            diagnostics.append(EndpointDiagnostic(
                title: "IPv4 · 路由器端口映射",
                detail: "未获得公网 IPv4 映射（可能无 IPv4 网络或网关未响应）",
                state: .unavailable
            ))
        }

        snapshot = Snapshot(endpoints: endpoints, diagnostics: diagnostics, refreshedAt: Date())
    }

    // MARK: - NAT port mapping (NAT-PMP / PCP / UPnP via configd)

    private func startNATMapping() {
        guard port != 0 else { return }
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceNATPortMappingCreate(
            &ref,
            0,                      // flags
            0,                      // interfaceIndex: primary
            DNSServiceProtocol(kDNSServiceProtocol_TCP),
            port.bigEndian,         // internalPort, network byte order
            0,                      // externalPort: let the gateway choose
            3600,                   // ttl seconds; configd renews at ttl/2
            WanEndpointPublisher.natMappingCallback,
            context
        )
        guard error == kDNSServiceErr_NoError, let ref else {
            wanPublisherLog.error("DNSServiceNATPortMappingCreate failed: \(error)")
            natMapping = .unsupported
            rebuildSnapshot()
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        natMappingRef = ref
    }

    private static let natMappingCallback: DNSServiceNATPortMappingReply = {
        _, _, _, errorCode, externalAddress, _, _, externalPort, _, context in
        guard let context else { return }
        let publisher = Unmanaged<WanEndpointPublisher>.fromOpaque(context).takeUnretainedValue()
        // Callback arrives on the dispatch queue set above.
        publisher.handleNATMappingResult(
            errorCode: errorCode,
            externalAddress: externalAddress,
            externalPort: externalPort
        )
    }

    private func handleNATMappingResult(errorCode: DNSServiceErrorType, externalAddress: UInt32, externalPort: UInt16) {
        let port = UInt16(bigEndian: externalPort)
        let dotted = Self.dottedIPv4(externalAddress)

        switch Int(errorCode) {
        case kDNSServiceErr_NoError:
            if externalAddress == 0 || port == 0 {
                natMapping = .unavailable
            } else if Self.isSharedOrPrivateIPv4(externalAddress) {
                natMapping = .cgnat(externalAddress: dotted, externalPort: port)
            } else {
                natMapping = .mapped(externalAddress: dotted, externalPort: port)
            }
        case kDNSServiceErr_DoubleNAT:
            // Upstream NAT: mapping exists but is not publicly reachable.
            natMapping = .cgnat(externalAddress: dotted, externalPort: port)
        case kDNSServiceErr_NATPortMappingUnsupported, kDNSServiceErr_NATTraversal:
            natMapping = .unsupported
        default:
            natMapping = .unavailable
        }
        rebuildSnapshot()
    }

    private func teardownNATMapping() {
        if let ref = natMappingRef {
            DNSServiceRefDeallocate(ref)
            natMappingRef = nil
        }
    }

    // MARK: - IPv6 enumeration

    /// All global-unicast (`2000::/3`) IPv6 addresses, tagged with the
    /// interface name and the kernel `ifru_flags6` so temporary/deprecated
    /// addresses can be deprioritized (spec §5.1).
    private static func enumerateGlobalIPv6Addresses() -> [IPv6AddressInfo] {
        var result: [IPv6AddressInfo] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        let storeFlags = temporaryIPv6Flags()
        var seen: Set<String> = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
            guard bytes.count == 16 else { continue }
            // 2000::/3 = global unicast. This drops link-local (fe80::/10),
            // ULA (fc00::/7), loopback and multicast in one test.
            guard (bytes[0] & 0xE0) == 0x20 else { continue }

            let interfaceName = String(cString: ifa.pointee.ifa_name)
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var mutableAddr = sin6.sin6_addr
            let rendered = inet_ntop(AF_INET6, &mutableAddr, &buffer, socklen_t(INET6_ADDRSTRLEN))
            guard rendered != nil else { continue }
            let address = String(cString: buffer)
            let key = "\(interfaceName)|\(address)"
            guard seen.insert(key).inserted else { continue }

            let flags = storeFlags[address] ?? 0
            result.append(IPv6AddressInfo(
                address: address,
                interfaceName: interfaceName,
                isTemporary: (flags & Self.IN6_IFF_TEMPORARY_FLAG) != 0,
                isEUI64: bytes[11] == 0xFF && bytes[12] == 0xFE
            ))
        }
        return result
    }

    // Kernel flags (netinet6/in6_var.h — not exported to Swift). Verified
    // against `ifconfig` output: the 0x0080 bit is set exactly on the
    // addresses ifconfig labels `temporary`.
    private static let IN6_IFF_TEMPORARY_FLAG: Int32 = 0x0080

    /// `SIOCGIFAFLAG_IN6` cannot be called from Swift (`ioctl` is variadic,
    /// and on Apple silicon variadic arguments are stack-passed, so a
    /// `dlsym` trampoline does not work either). The dynamic store publishes
    /// the same IN6_IFF flags per address at
    /// `State:/Network/Interface/<ifname>/IPv6`, where `Addresses[i]` pairs
    /// with `Flags[i]` — verified against `ifconfig` (`secured` = 0x0400,
    /// `temporary` = 0x0080).
    private static func temporaryIPv6Flags() -> [String: Int32] {
        var result: [String: Int32] = [:]
        guard let store = SCDynamicStoreCreate(nil, "com.codevoke.wan-endpoint-publisher" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/.*/IPv6" as CFString) as? [String]
        else { return result }

        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let addresses = value["Addresses"] as? [String],
                  let flags = value["Flags"] as? [Int]
            else { continue }
            for (index, address) in addresses.enumerated() where index < flags.count {
                result[address.lowercased()] = Int32(flags[index])
            }
        }
        return result
    }

    // MARK: - IPv4 helpers

    /// `externalAddress` arrives as a uint32 in network byte order — i.e. the
    /// first octet of the dotted quad is the low byte of the value.
    private static func dottedIPv4(_ networkOrder: UInt32) -> String {
        "\(networkOrder & 0xFF).\((networkOrder >> 8) & 0xFF).\((networkOrder >> 16) & 0xFF).\((networkOrder >> 24) & 0xFF)"
    }

    /// CGNAT self-check (spec §5.2): the gateway's external address landing in
    /// shared/private space means upstream NAT — the IPv4 candidate is unusable.
    static func isSharedOrPrivateIPv4(_ networkOrder: UInt32) -> Bool {
        let b0 = networkOrder & 0xFF
        let b1 = (networkOrder >> 8) & 0xFF
        switch b0 {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(b1)     // 100.64.0.0/10 CGNAT
        case 169: return b1 == 254                   // link-local
        case 172: return (16...31).contains(b1)      // 172.16.0.0/12
        case 192: return b1 == 168                   // 192.168.0.0/16
        default: return false
        }
    }
}
