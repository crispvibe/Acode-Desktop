import SwiftUI
import UIKit

private struct SettingsHomeSnapshot: Equatable {
    var connectionStatus: String
    var selectedCLI: String

    @MainActor
    init(chatViewModel: ChatViewModel) {
        connectionStatus = chatViewModel.effectiveConnectionStatus
        selectedCLI = chatViewModel.selectedCLI
    }
}

private enum SettingsRoute: Hashable {
    case connection
    case cli
}

struct SettingsView: View {
    let chatViewModel: ChatViewModel
    let close: () -> Void
    @State private var navigationPath: [SettingsRoute] = []
    @State private var homeSnapshot: SettingsHomeSnapshot
    @ObservedObject private var updateChecker = AppUpdateChecker.shared

    init(chatViewModel: ChatViewModel, close: @escaping () -> Void) {
        self.chatViewModel = chatViewModel
        self.close = close
        _homeSnapshot = State(initialValue: SettingsHomeSnapshot(chatViewModel: chatViewModel))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                WhiteGlassBackground()
                    .ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        SettingsSectionCard {
                            VStack(spacing: 0) {
                                NavigationLink(value: SettingsRoute.connection) {
                                    SettingsMenuRow(title: "远程设备", subtitle: homeSnapshot.connectionStatus, icon: "desktopcomputer")
                                }
                                SettingsDivider()
                                NavigationLink(value: SettingsRoute.cli) {
                                    SettingsMenuRow(title: "CLI", subtitle: cliDisplayName(homeSnapshot.selectedCLI), icon: "terminal")
                                }
                            }
                        }

                        SettingsSectionCard {
                            VStack(spacing: 0) {
                                if let update = updateChecker.availableUpdate {
                                    updateBanner(update)
                                    SettingsDivider()
                                }
                                Button {
                                    Task { await updateChecker.check(manual: true) }
                                } label: {
                                    SettingsMenuRow(title: "检查更新", subtitle: updateCheckSubtitle, icon: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.codevokePress)
                                .disabled(updateChecker.isChecking)
                                SettingsDivider()
                                SettingsMenuRow(title: "关于 acode", subtitle: appVersionText, icon: "info.circle", showsChevron: false)
                                SettingsDivider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("© 2026 crispvibe · 仅限个人非商业使用，禁止商用")
                                    Text("许可：PolyForm Noncommercial 1.0.0")
                                    Text("QQ 群：1076321843（Code 开源技术交流群）")
                                    Text("仓库：github.com/crispvibe/Acode-Desktop")
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 13)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(L10n.key("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshHomeSnapshot)
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
            }
            .toolbar {
                ToolbarItem(placement: .codevokeTopBarLeading) {
                    Button {
                        close()
                    } label: {
                        SettingsCloseButtonLabel()
                    }
                    .buttonStyle(.codevokePress)
                    .accessibilityLabel(L10n.string("关闭设置"))
                }
            }
        }
    }

    private func refreshHomeSnapshot() {
        let snapshot = SettingsHomeSnapshot(chatViewModel: chatViewModel)
        if homeSnapshot != snapshot {
            homeSnapshot = snapshot
        }
    }

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .connection:
            SettingsConnectionPage(viewModel: chatViewModel, close: close)
        case .cli:
            SettingsCLIPage(viewModel: chatViewModel)
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return L10n.format("版本 %@ (%@)", version, build)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// 「检查更新」行副标题：检查中 > 有新版 > 上次手动检查结果 > 当前版本。
    private var updateCheckSubtitle: String {
        if updateChecker.isChecking { return L10n.string("正在检查更新…") }
        if let update = updateChecker.availableUpdate {
            return L10n.format("发现新版本 v%@", update.version)
        }
        if let status = updateChecker.statusText, !status.isEmpty { return status }
        return L10n.format("当前版本 %@", appVersion)
    }

    /// 「有新版本」横幅：iOS 未签名 IPA 无法应用内安装，点击用 Safari 打开 release 页。
    private func updateBanner(_ update: AppUpdateInfo) -> some View {
        Button {
            UIApplication.shared.open(update.releasePageURL)
        } label: {
            HStack(spacing: 12) {
                SettingsPlainIcon(
                    systemName: "arrow.up.circle.fill",
                    tint: Color(red: 0.18, green: 0.49, blue: 0.20)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.key("发现新版本"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                    Text(L10n.format("v%@ · 点按前往下载", update.version))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.codevokeMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(L10n.key("前往下载"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.codevokePress)
        .accessibilityLabel(L10n.string("发现新版本，点按前往下载"))
    }
}

private struct SettingsCloseButtonLabel: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        } else {
            Image(systemName: "chevron.backward")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
                .frame(width: 44, height: 44)
                .codevokeCircleGlass()
                .overlay(Circle().stroke(Color.codevokeGlassStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 7)
        }
    }
}

private struct SettingsConnectionPage: View {
    @ObservedObject var viewModel: ChatViewModel
    let close: () -> Void
    @StateObject private var listViewModel = DeviceListViewModel()
    @StateObject private var connectViewModel = DeviceConnectViewModel()
    @State private var hostInput = ""
    @State private var portInput = ""
    @State private var pendingPairing: DeviceConnectViewModel.PendingPairing?

    var body: some View {
        SettingsPageContainer(title: "远程设备") {
            connectionHeader
            manualCard
            discoveredCard
            statusCard
        }
        .onAppear {
            hostInput = viewModel.config.macHost
            portInput = String(viewModel.config.port)
        }
        .task {
            await listViewModel.scan(preferredHost: viewModel.config.macHost)
        }
        .sheet(item: $pendingPairing) { pending in
            PairCodeSheet(pending: pending, isWorking: connectViewModel.isConnecting, errorMessage: connectViewModel.message) { code in
                submitPairCode(code)
            }
        }
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.key("连接电脑"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.codevokeInk)
            Text(L10n.key("同一 Wi‑Fi 下的局域网直连，无需账号。"))
                .font(.system(size: 13))
                .foregroundStyle(Color.codevokeMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var manualCard: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCardTitle("连接地址", subtitle: "电脑的局域网 IP 与端口")
                SettingsTextField("地址", text: $hostInput, placeholder: "192.168.1.10")
                SettingsTextField("端口", text: $portInput, placeholder: "\(DeviceConnectViewModel.defaultPort)")
                Button {
                    Task { await apply(host: hostInput, port: resolvedPort) }
                } label: {
                    Text(L10n.key(connectViewModel.isConnecting ? "连接中…" : "保存并连接"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.codevokePress)
                .disabled(connectViewModel.isConnecting || hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
    }

    private var discoveredCard: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SettingsCardTitle("局域网设备", subtitle: "自动扫描当前 Wi‑Fi 网段")
                    Spacer(minLength: 0)
                    Button(L10n.string(listViewModel.isScanning ? "扫描中…" : "重新扫描")) {
                        Task { await listViewModel.scan(preferredHost: viewModel.config.macHost) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
                    .buttonStyle(.codevokePress)
                    .disabled(listViewModel.isScanning)
                }

                if listViewModel.isScanning && listViewModel.hosts.isEmpty {
                    SettingsEmptyRow(icon: "desktopcomputer", text: "正在扫描局域网…")
                } else if listViewModel.hosts.isEmpty {
                    SettingsEmptyRow(icon: "desktopcomputer", text: "没有发现设备，请确认电脑端已开启设备连接服务。")
                } else {
                    VStack(spacing: 10) {
                        ForEach(listViewModel.hosts) { host in
                            lanHostRow(host)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func lanHostRow(_ host: DiscoveredLanHost) -> some View {
        let paired = listViewModel.isPaired(host)
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
                .frame(width: 38, height: 38)
                .background(Color.codevokeSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text(host.name?.isEmpty == false ? host.name! : host.host)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                }
                Text(L10n.key(paired ? "已配对 · 局域网可连接" : "局域网可连接 · 未配对"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codevokeMuted)
            }
            Spacer(minLength: 0)
            Button(L10n.string(connectViewModel.isConnecting ? "连接中…" : (paired ? "连接" : "配对"))) {
                Task { await apply(host: host.host, port: host.port) }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.045), lineWidth: 1))
    }

    @ViewBuilder
    private var statusCard: some View {
        if let message = connectViewModel.message ?? listViewModel.message {
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(message.contains("失败") || message.contains("超时") || message.contains("没有") ? .red.opacity(0.85) : Color.codevokeMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private var resolvedPort: Int {
        Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? DeviceConnectViewModel.defaultPort
    }

    private func apply(host: String, port: Int) async {
        guard let outcome = await connectViewModel.connect(host: host, port: port) else { return }
        switch outcome {
        case .connected(let config):
            viewModel.config = config
            viewModel.saveConnectionConfig()
            close()
        case .needsPairing(let pending):
            pendingPairing = pending
        }
    }

    private func submitPairCode(_ code: String) {
        guard let pending = pendingPairing else { return }
        Task {
            if let config = await connectViewModel.pair(pending, code: code) {
                pendingPairing = nil
                viewModel.config = config
                viewModel.saveConnectionConfig()
                close()
            }
        }
    }
}


private struct CLICatalogEntry {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
}

/// host 端 `cli` 字段是 String 透传；这里放已知 CLI 的展示元数据。
/// 新 CLI 在 host 加完后这里补一行即可。
private let cliCatalog: [CLICatalogEntry] = [
    CLICatalogEntry(id: "claude", title: "Claude Code", subtitle: "Anthropic Claude CLI", icon: "sparkles"),
    CLICatalogEntry(id: "codex", title: "Codex", subtitle: "OpenAI Codex CLI", icon: "circle.hexagongrid.fill"),
    CLICatalogEntry(id: "cursor", title: "Cursor Agent", subtitle: "Cursor 编辑器内置 Agent CLI", icon: "cursorarrow.rays"),
    CLICatalogEntry(id: "gemini", title: "Gemini", subtitle: "Google Gemini CLI", icon: "star.fill"),
    CLICatalogEntry(id: "qwen", title: "Qwen Code", subtitle: "阿里通义 Qwen Code CLI", icon: "cloud.fill"),
    CLICatalogEntry(id: "copilot", title: "Copilot", subtitle: "GitHub Copilot CLI", icon: "airplane"),
    CLICatalogEntry(id: "kimi", title: "Kimi", subtitle: "Moonshot Kimi CLI", icon: "moon.fill"),
    CLICatalogEntry(id: "agy", title: "Antigravity", subtitle: "Google Antigravity CLI", icon: "arrow.up.circle.fill"),
    CLICatalogEntry(id: "kiro", title: "Kiro", subtitle: "AWS Kiro CLI", icon: "bolt.circle.fill"),
    CLICatalogEntry(id: "dsh", title: "DeepSeek Harness", subtitle: "DeepSeek 官方 Harness，ACP 协议", icon: "water.waves"),
]

/// CLI id → 展示名；host 新增未收录的 cli 时兜底为首字母大写的原始值，避免空白。
private func cliDisplayName(_ cli: String) -> String {
    let trimmed = cli.trimmingCharacters(in: .whitespacesAndNewlines)
    if let entry = cliCatalog.first(where: { $0.id == trimmed }) {
        return entry.title
    }
    guard let first = trimmed.first else { return cli }
    return first.uppercased() + trimmed.dropFirst()
}

private struct SettingsCLIPage: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        SettingsPageContainer(title: "CLI") {
            // Audit C-05: surface ack errors from CLI / model / permission /
            // reasoning switches so the user sees feedback in the page they
            // actually clicked in (instead of silently logging to lastError).
            if let err = viewModel.lastError, !err.isEmpty {
                SettingsSectionCard {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Button(L10n.string("收起")) { viewModel.lastError = nil }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.codevokeInk)
                    }
                    .padding(12)
                }
            }
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsCardTitle("命令行后端", subtitle: "选择消息使用的 CLI")
                    ForEach(cliCatalog, id: \.id) { option in
                        // Audit C-03: surface capability.errorMessage and
                        // disable the row when the CLI is unavailable.
                        let cap = viewModel.capability(forCLI: option.id)
                        let unavailable = cap?.executableAvailable == false
                        let errorMessage = cap?.errorMessage
                        SettingsOptionRow(
                            title: option.title,
                            subtitle: unavailable
                                ? (errorMessage ?? L10n.format("%@ 不可用", option.title)) : option.subtitle,
                            icon: option.icon,
                            selected: viewModel.selectedCLI == option.id
                        ) {
                            guard !unavailable else { return }
                            viewModel.selectCLI(option.id)
                        }
                        .opacity(unavailable ? 0.5 : 1)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct SettingsPageContainer<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            WhiteGlassBackground()
                .ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 16) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(L10n.key(title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsSectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .codevokeGlass(cornerRadius: 26)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.codevokeHairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.055), radius: 16, x: 0, y: 8)
    }
}

private struct SettingsPlainIcon: View {
    let systemName: String
    var tint: Color = Color.codevokeInk.opacity(0.58)
    var size: CGFloat = 16
    var weight: Font.Weight = .semibold
    var frame: CGFloat = 31

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
            .frame(width: frame, height: frame)
    }
}

private struct SettingsMenuRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsPlainIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key(title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.codevokeInk)
                Text(L10n.key(subtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codevokeMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codevokeMuted.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = Color.codevokeInk

    var body: some View {
        HStack(spacing: 12) {
            SettingsPlainIcon(
                systemName: icon,
                tint: tint.opacity(0.72)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key(title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(L10n.key(subtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codevokeMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

struct SettingsCardTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.key(title))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.codevokeInk)
            Text(L10n.key(subtitle))
                .font(.system(size: 11))
                .foregroundStyle(Color.codevokeMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    init(_ title: String, text: Binding<String>, placeholder: String) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.key(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.codevokeMuted)
            TextField(L10n.string(placeholder), text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .padding(11)
                .codevokeGlass(cornerRadius: 16)
                .background(.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.codevokeGlassStroke, lineWidth: 1))
        }
    }
}

private struct SettingsSecureField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    init(_ title: String, text: Binding<String>, placeholder: String) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.key(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.codevokeMuted)
            SecureField(L10n.string(placeholder), text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .padding(11)
                .codevokeGlass(cornerRadius: 16)
                .background(.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.codevokeGlassStroke, lineWidth: 1))
        }
    }
}

private struct SettingsOptionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsPlainIcon(
                    systemName: icon,
                    tint: Color.codevokeInk.opacity(selected ? 0.78 : 0.5),
                    size: 13,
                    frame: 24
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.key(title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                        .lineLimit(1)
                    Text(L10n.key(subtitle))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codevokeMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.codevokeInk)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Color.white.opacity(0.85) : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.black.opacity(0.18) : .white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.codevokePress)
    }
}

private struct SettingsEmptyRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.codevokeMuted)
            Text(L10n.key(text))
                .font(.system(size: 12))
                .foregroundStyle(Color.codevokeMuted)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

private struct SettingsStatusDot: View {
    let status: String

    var body: some View {
        let color: Color = switch status {
        case "已连接": .green
        case "正在连接": .orange
        default: .red.opacity(0.7)
        }
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 57)
            .opacity(0.32)
    }
}

private struct SettingsMessageView: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(message.contains("成功") || message.contains("已") ? Color.codevokeMuted : .red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
    }
}
