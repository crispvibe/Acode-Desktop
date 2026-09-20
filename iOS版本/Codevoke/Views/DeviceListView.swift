import SwiftUI

/// Entry screen（§6）：
/// - 局域网自动发现 proto:2 host——已配对直接连，未配对输 6 位码走 /pair；
/// - 「已配对设备」随时可点（WAN 候选地址由 RemoteWanTransport 竞速）；
/// - 扫码配对 / 输入连接串导入 `acode://pair?d=…` 载荷，不依赖同局域网。
struct DeviceListView: View {
    @StateObject private var listViewModel = DeviceListViewModel()
    @StateObject private var connectViewModel = DeviceConnectViewModel()
    @State private var chatConfig: RemoteChatConfig?
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pendingPairing: DeviceConnectViewModel.PendingPairing?
    @State private var showScanner = false
    @State private var showConnectionString = false

    var body: some View {
        Group {
            if let chatConfig {
                RootView(initialConfig: chatConfig)
            } else {
                NavigationStack {
                    ZStack {
                        WhiteGlassBackground()
                            .ignoresSafeArea()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                header
                                pairingSection
                                pairedSection
                                discoveredSection
                                manualSection
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 22)
                        }
                    }
                    .navigationTitle(L10n.key("远程设备"))
                    .toolbar {
                        ToolbarItem(placement: .codevokeTopBarTrailing) {
                            Button {
                                Task { await rescan() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.codevokeInk)
                                    .frame(width: 44, height: 44)
                                    .codevokeCircleGlass()
                                    .overlay(Circle().stroke(Color.codevokeGlassStroke, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 7)
                            }
                            .buttonStyle(.codevokePress)
                            .disabled(listViewModel.isScanning)
                        }
                    }
                    .task {
                        await rescan()
                    }
                }
            }
        }
        .sheet(item: $pendingPairing) { pending in
            PairCodeSheet(pending: pending, isWorking: connectViewModel.isConnecting, errorMessage: connectViewModel.message) { code in
                submitPairCode(code)
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                importConnectionString(code)
            }
        }
        .sheet(isPresented: $showConnectionString) {
            ConnectionStringSheet(isWorking: connectViewModel.isConnecting, errorMessage: connectViewModel.message) { text in
                importConnectionString(text)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.key("选择电脑"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.codevokeInk)
            Text(L10n.key("同一 Wi‑Fi 下自动发现运行 acode 的电脑；扫码或输入连接串可跨网直连。"))
                .font(.system(size: 14))
                .foregroundStyle(Color.codevokeMuted)
        }
    }

    // MARK: - 配对入口（§6）

    private var pairingSection: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCardTitle("跨网配对", subtitle: "与电脑端建立加密直连，之后不在同一 Wi‑Fi 也能连")
                HStack(spacing: 10) {
                    pairingButton(title: "扫码配对", subtitle: "扫电脑端二维码", icon: "qrcode.viewfinder") {
                        showScanner = true
                    }
                    pairingButton(title: "输入连接串", subtitle: "粘贴 acode:// 串", icon: "link") {
                        showConnectionString = true
                    }
                }
            }
            .padding(16)
        }
    }

    private func pairingButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                    .frame(width: 38, height: 38)
                    .background(Color.codevokeSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(L10n.key(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Text(L10n.key(subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codevokeMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.045), lineWidth: 1))
        }
        .buttonStyle(.codevokePress)
    }

    // MARK: - 已配对设备

    @ViewBuilder
    private var pairedSection: some View {
        if !listViewModel.pairedHosts.isEmpty {
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCardTitle("已配对设备", subtitle: "跨网直连，长按可解除配对")
                    ForEach(listViewModel.pairedHosts, id: \.hostId) { record in
                        pairedRow(record)
                    }
                }
                .padding(16)
            }
        }
    }

    private func pairedRow(_ record: PairedHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name.isEmpty ? (record.lastGood?.displayText ?? L10n.string("未命名设备")) : record.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Text(L10n.key(listViewModel.isOnLAN(record) ? "局域网在线" : "跨网直连"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codevokeMuted)
            }
            Spacer()
            Button(L10n.string(connectViewModel.isConnecting ? "连接中…" : "连接")) {
                connect(paired: record)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.codevokePress)
            .disabled(connectViewModel.isConnecting)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button(role: .destructive) {
                listViewModel.unpair(record.hostId)
            } label: {
                Label(L10n.key("解除配对"), systemImage: "trash")
            }
        }
    }

    // MARK: - 局域网发现

    private var discoveredSection: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCardTitle("局域网设备", subtitle: "自动扫描当前 Wi‑Fi 网段")
                if listViewModel.isScanning && listViewModel.hosts.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.black)
                        Text(L10n.key("正在扫描局域网…"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.codevokeMuted)
                    }
                } else if listViewModel.hosts.isEmpty {
                    Text(L10n.key("没有发现设备。请确认电脑端已开启「设备连接服务」。"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.codevokeMuted)
                } else {
                    ForEach(listViewModel.hosts) { host in
                        hostRow(host)
                    }
                }
                if let message = listViewModel.message ?? connectViewModel.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.codevokeMuted)
                }
            }
            .padding(16)
        }
    }

    private func hostRow(_ host: DiscoveredLanHost) -> some View {
        let paired = listViewModel.isPaired(host)
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text(host.name?.isEmpty == false ? host.name! : host.host)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                }
                Text(L10n.key(paired ? "已配对 · 局域网可连接" : "局域网可连接 · 未配对"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codevokeMuted)
            }
            Spacer()
            Button(L10n.string(connectViewModel.isConnecting ? "连接中…" : (paired ? "连接" : "配对"))) {
                Task { await connect(host: host.host, port: host.port) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.codevokePress)
            .disabled(connectViewModel.isConnecting)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 手动地址

    private var manualSection: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCardTitle("手动连接", subtitle: "输入电脑的局域网地址")
                SettingsTextField("地址", text: $manualHost, placeholder: "192.168.1.10")
                SettingsTextField("端口", text: $manualPort, placeholder: "\(DeviceConnectViewModel.defaultPort)")
                Button {
                    Task { await connect(host: manualHost, port: resolvedManualPort) }
                } label: {
                    Text(L10n.key(connectViewModel.isConnecting ? "连接中…" : "连接"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.codevokePress)
                .disabled(connectViewModel.isConnecting || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
    }

    private var resolvedManualPort: Int {
        let trimmed = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? DeviceConnectViewModel.defaultPort
    }

    // MARK: - Actions

    private func rescan() async {
        let lastHost = chatConfig?.macHost
            ?? UserDefaults.standard.string(forKey: "remote.macHost")
        await listViewModel.scan(preferredHost: lastHost)
    }

    private func connect(host: String, port: Int) async {
        guard let outcome = await connectViewModel.connect(host: host, port: port) else { return }
        switch outcome {
        case .connected(let config):
            chatConfig = config
        case .needsPairing(let pending):
            pendingPairing = pending
        }
    }

    private func connect(paired record: PairedHost) {
        if let config = connectViewModel.config(for: record) {
            chatConfig = config
        }
    }

    private func submitPairCode(_ code: String) {
        guard let pending = pendingPairing else { return }
        Task {
            if let config = await connectViewModel.pair(pending, code: code) {
                pendingPairing = nil
                listViewModel.reloadPaired()
                chatConfig = config
            }
        }
    }

    private func importConnectionString(_ raw: String) {
        if let config = connectViewModel.connect(connectionString: raw) {
            showConnectionString = false
            listViewModel.reloadPaired()
            chatConfig = config
        }
    }
}
