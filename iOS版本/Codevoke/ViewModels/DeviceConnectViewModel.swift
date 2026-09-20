import Foundation
import UIKit

/// 连接编排（§6）：点选目标 → /health 探测（https，记录出示的证书指纹）
/// → 指纹命中 EndpointStore 即已配对、直出带凭据的 config；未配对 → 回
/// needsPairing，由 UI 引导输 6 位码走 POST /pair，或扫码/连接串导入。
@MainActor
final class DeviceConnectViewModel: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var latestTransport: String?
    @Published var message: String?

    static let defaultPort = 18765
    private let store = EndpointStore.shared

    enum ConnectOutcome {
        case connected(RemoteChatConfig)
        case needsPairing(PendingPairing)
    }

    /// 待配对的一台主机：UI 拿它弹 6 位码输入框。
    struct PendingPairing: Equatable, Identifiable {
        let host: String
        let port: Int
        let name: String?
        /// /health 探测时主机出示的证书指纹；为空表示握手没取到（兜底也可配对，
        /// /pair 内部已做"响应 fp == 出示 fp"校验）。
        let presentedFP: String?

        var id: String { "\(host):\(port)" }
        var displayName: String {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? host : trimmed
        }
    }

    // MARK: - 点选地址连接（发现列表/手动输入共用）

    func connect(host: String, port: Int) async -> ConnectOutcome? {
        guard !isConnecting else { return nil }
        isConnecting = true
        message = nil
        defer { isConnecting = false }

        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, (1...65535).contains(port) else {
            message = L10n.string("请输入有效的地址和端口。")
            return nil
        }

        let (session, delegate) = RemoteSecureSessionFactory.discoverySession()
        defer { session.invalidateAndCancel() }
        guard let probe = await RemotePairingClient.probeHealth(
            host: cleanHost, port: port, session: session, delegate: delegate, timeout: 4
        ) else {
            message = L10n.string("连接失败，请确认电脑端已开启设备连接服务，且手机与电脑在同一 Wi‑Fi 下。")
            return nil
        }
        guard probe.isAuthCapableHost else {
            message = L10n.string("电脑端版本过旧，请升级电脑端 acode 后重试。")
            return nil
        }

        if let fp = probe.peerFP, let record = store.record(forHostId: fp) {
            latestTransport = "paired"
            let endpoint = RemoteEndpoint(a: cleanHost, p: port)
            Task { await refreshConnectInfo(record: record, endpoint: endpoint) }
            return .connected(makeConfig(record: record, preferred: endpoint))
        }

        guard probe.pairCapable else {
            message = L10n.string("该设备尚未配对，且电脑端未开启配对。")
            return nil
        }
        return .needsPairing(PendingPairing(
            host: cleanHost, port: port,
            name: probe.health.name, presentedFP: probe.peerFP
        ))
    }

    // MARK: - 6 位码配对（LAN）

    func pair(_ pending: PendingPairing, code: String) async -> RemoteChatConfig? {
        guard !isConnecting else { return nil }
        isConnecting = true
        message = nil
        defer { isConnecting = false }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            message = L10n.string("请输入电脑端显示的 6 位数字配对码。")
            return nil
        }

        do {
            let record = try await RemotePairingClient.pair(host: pending.host, port: pending.port, code: trimmed, deviceName: UIDevice.current.name)
            // /pair 内部已校验响应 fp == 握手出示 fp；这里再叠一层与
            // /health 探测到的指纹交叉验证，双保险防中间人。
            if let presented = pending.presentedFP, presented != record.certFP {
                message = L10n.string("证书指纹校验不一致，网络可能被劫持，请检查网络后重试。")
                return nil
            }
            guard store.upsert(record) else {
                message = L10n.string("钥匙串读写失败。")
                return nil
            }
            latestTransport = "paired"
            return makeConfig(record: record, preferred: RemoteEndpoint(a: pending.host, p: pending.port))
        } catch {
            message = RemoteUserFacingText.apiError(
                error.localizedDescription,
                fallback: "配对失败，请核对配对码并重试。"
            )
            return nil
        }
    }

    // MARK: - 扫码/连接串导入（§4.4 载荷直建记录）

    func connect(connectionString raw: String) -> RemoteChatConfig? {
        let payload: PairingPayload
        do {
            payload = try PairingPayload.parse(raw)
        } catch {
            message = error.localizedDescription
            return nil
        }
        let record = PairedHost(
            hostId: payload.certFP,
            name: payload.name,
            token: payload.token,
            certFP: payload.certFP,
            eps: payload.endpoints,
            lastGood: nil,
            updatedAt: Date()
        )
        guard store.upsert(record) else {
            message = L10n.string("钥匙串读写失败。")
            return nil
        }
        guard let preferred = record.eps.first else {
            // 记录已落库：回到同一局域网扫描后仍可经 LAN 直连。
            message = L10n.string("配对信息已保存，但该电脑暂未发布可直连地址，请连回同一 Wi‑Fi 后重试。")
            return nil
        }
        latestTransport = "wan"
        return makeConfig(record: record, preferred: preferred)
    }

    // MARK: - 已配对设备直点（WAN 竞速由 RemoteWanTransport 负责）

    func config(for record: PairedHost) -> RemoteChatConfig? {
        guard let preferred = record.lastGood ?? record.eps.first else {
            message = L10n.string("该设备暂未发布可直连地址，请连回同一 Wi‑Fi 刷新后重试。")
            return nil
        }
        latestTransport = record.lastGood == nil ? "wan" : "paired"
        return makeConfig(record: record, preferred: preferred)
    }

    // MARK: - Internals

    private func makeConfig(record: PairedHost, preferred: RemoteEndpoint) -> RemoteChatConfig {
        RemoteChatConfig(
            macHost: preferred.a,
            port: preferred.p,
            hostId: record.hostId,
            hostName: record.name,
            authToken: record.token,
            certFP: record.certFP
        )
    }

    /// 同 LAN 静默刷新 eps（§6）；失败不打扰用户。
    private func refreshConnectInfo(record: PairedHost, endpoint: RemoteEndpoint) async {
        do {
            let info = try await RemotePairingClient.fetchConnectInfo(
                host: endpoint.a, port: endpoint.p,
                token: record.token, certFP: record.certFP, timeout: 4
            )
            store.applyConnectInfo(hostId: record.hostId, name: info.name, eps: info.eps ?? [])
        } catch {
            // 静默失败：连接本身不依赖这次刷新。
        }
    }
}
