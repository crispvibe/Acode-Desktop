import SwiftUI

/// Entry screen: scans the local network for Codevoke hosts and connects
/// directly — no account, pairing, or approval step.
struct DeviceListView: View {
    @StateObject private var listViewModel = DeviceListViewModel()
    @StateObject private var connectViewModel = DeviceConnectViewModel()
    @State private var chatConfig: RemoteChatConfig?
    @State private var manualHost = ""
    @State private var manualPort = ""

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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.key("选择电脑"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.codevokeInk)
            Text(L10n.key("同一 Wi‑Fi 下自动发现运行 acode 的电脑，点击即连。"))
                .font(.system(size: 14))
                .foregroundStyle(Color.codevokeMuted)
        }
    }

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
                    ForEach(listViewModel.hosts, id: \.self) { host in
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

    private func hostRow(_ host: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text(host)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                }
                Text(L10n.key("局域网可连接"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codevokeMuted)
            }
            Spacer()
            Button(L10n.string(connectViewModel.isConnecting ? "连接中…" : "连接")) {
                Task { await connect(host: host, port: listViewModel.port) }
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

    private func rescan() async {
        let lastHost = chatConfig?.macHost
            ?? UserDefaults.standard.string(forKey: "remote.macHost")
        await listViewModel.scan(preferredHost: lastHost)
    }

    private func connect(host: String, port: Int) async {
        if let config = await connectViewModel.connect(host: host, port: port) {
            chatConfig = config
        }
    }
}
