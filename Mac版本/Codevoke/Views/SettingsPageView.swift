import AppKit
import CoreImage
import SwiftUI

struct SettingsPageView: View {
    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case general
        case claude
        case codex
        case remoteChat
        case appendRules
        case globalRules
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .remoteChat: "设备连接"
            case .appendRules: "追加规则"
            case .globalRules: "全局规则"
            case .about: "关于与版本"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .claude: "terminal"
            case .codex: "cpu"
            case .remoteChat: "display"
            case .appendRules: "text.badge.checkmark"
            case .globalRules: "doc.text"
            case .about: "info.circle"
            }
        }
    }

    private enum CodexAuthMode: String, Identifiable, Hashable, Sendable {
        case apiKey

        var id: String { rawValue }
        var title: String { "API Key / 中转站" }
    }

    private enum GlobalRuleKind: String, CaseIterable, Identifiable, Hashable, Sendable {
        case claude
        case codex
        case cursor
        case gemini
        case qwen
        case copilot
        case kimi
        case agy
        case kiro
        case dsh

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor Agent"
            case .gemini: "Gemini"
            case .qwen: "Qwen Code"
            case .copilot: "Copilot"
            case .kimi: "Kimi"
            case .agy: "Antigravity"
            case .kiro: "Kiro"
            case .dsh: "DeepSeek Harness"
            }
        }

        /// 各家 CLI 的全局指令文件（相对真实用户目录）。
        /// - claude：~/.claude/CLAUDE.md（官方 memory 机制）
        /// - codex：~/.codex/AGENTS.md
        /// - cursor：~/.cursor/rules/ 目录下的 .mdc 用户规则文件（Cursor 无单一全局 AGENTS.md）
        /// - gemini：~/.gemini/GEMINI.md
        /// - qwen：~/.qwen/QWEN.md（官方 Global Memory）
        /// - copilot：~/.copilot/copilot-instructions.md（官方 user-level instructions）
        /// - kimi：~/.kimi-code/AGENTS.md（Kimi Code CLI 的 $KIMI_CODE_HOME 全局指令文件）
        /// - agy：~/.gemini/GEMINI.md（Antigravity 官方全局规则文件，与 Gemini CLI 共用）
        /// - kiro：~/.kiro/steering/AGENTS.md（全局 steering，AGENTS.md 始终注入会话）
        /// - dsh：~/.dsh/AGENTS.md（dsh-agent-instructions 的 USER_GLOBAL_FILE，
        ///   作为全局 baseline 注入每个会话）
        var relativePath: String {
            switch self {
            case .claude: ".claude/CLAUDE.md"
            case .codex: ".codex/AGENTS.md"
            case .cursor: ".cursor/rules/acode.mdc"
            case .gemini: ".gemini/GEMINI.md"
            case .qwen: ".qwen/QWEN.md"
            case .copilot: ".copilot/copilot-instructions.md"
            case .kimi: ".kimi-code/AGENTS.md"
            case .agy: ".gemini/GEMINI.md"
            case .kiro: ".kiro/steering/AGENTS.md"
            case .dsh: ".dsh/AGENTS.md"
            }
        }

        /// 该 CLI 全局规则机制的补充说明；nil 表示无需额外提示。
        var note: String? {
            switch self {
            case .cursor:
                "Cursor 的全局规则保存在 ~/.cursor/rules/ 目录的 .mdc 文件中，这里编辑其中的 acode.mdc（自动补 alwaysApply 头部，对本机所有项目生效）。"
            case .kimi:
                "适用于 Kimi Code CLI；旧版 kimi-cli（~/.kimi）没有全局指令文件机制。"
            case .agy:
                "Antigravity 与 Gemini CLI 共用同一个全局规则文件，改动对两者同时生效。"
            case .kiro:
                "Kiro 的全局规则保存在 ~/.kiro/steering/ 目录的 Markdown 文件中，这里编辑其中的 AGENTS.md，每个会话都会自动注入。"
            case .claude, .codex, .gemini, .qwen, .copilot, .dsh:
                nil
            }
        }
    }

    private enum ModelFetchOutcome: Sendable {
        case success([String])
        case failure(String)
    }

    private struct ClaudeSettingsSnapshot: Sendable {
        var baseURL = ""
        var authToken = ""
        var model = ""
        var haikuModel = ""
        var sonnetModel = ""
        var opusModel = ""
        var httpProxy = ""
        var httpsProxy = ""
    }

    private struct CodexSettingsSnapshot: Sendable {
        var model = ""
        var baseURL = ""
        var apiKey = ""
        var wireApi = "responses"
        var authMode: CodexAuthMode = .apiKey
    }

    private struct GlobalRuleSnapshot: Sendable {
        var text: String
        var status: String
        var isTooLarge: Bool
    }

    private struct SettingsDiskSnapshot: Sendable {
        var claude: ClaudeSettingsSnapshot
        var codex: CodexSettingsSnapshot
        var profiles: ConfigProfileCollection
        var globalRule: GlobalRuleSnapshot
    }

    private struct ModelMenuItems {
        var items: [String]
        var hiddenCount: Int
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var modelService: ChatModelService
    @ObservedObject private var updateService = UpdateService.shared
    private let showsBackButton: Bool

    init(showsBackButton: Bool = true) {
        self.showsBackButton = showsBackButton
    }

    @State private var selectedCategory: SettingsCategory = .general
    @State private var defaultCLI: CLIType = .claude
    @State private var defaultTerminal: TerminalType = .terminal
    @State private var showCommandPreview = true
    @State private var appendRuleEnabled = false
    @State private var appendRuleText = ""
    @State private var ignoredFoldersText = ""

    // 中转站配置（直接读写 ~/.claude/settings.json）
    @State private var anthropicBaseURL = ""
    @State private var anthropicAuthToken = ""
    @State private var anthropicModel = ""
    @State private var anthropicHaikuModel = ""
    @State private var anthropicSonnetModel = ""
    @State private var anthropicOpusModel = ""
    @State private var httpProxy = ""
    @State private var httpsProxy = ""
    @State private var relaySaveStatus = ""
    @State private var claudeModelList: [String] = []
    @State private var isFetchingClaudeModels = false
    @State private var configProfiles: ConfigProfileCollection = .empty
    @State private var selectedClaudeProfileID: UUID?
    @State private var newClaudeProfileName = ""
    @State private var editingClaudeProfile: ClaudeRelayProfile?

    // Codex 配置（读写 ~/.codex/config.toml + auth.json）
    @State private var codexModel = ""
    @State private var codexBaseURL = ""
    @State private var codexApiKey = ""
    @State private var codexWireApi = "responses"
    @State private var codexAuthMode: CodexAuthMode = .apiKey
    @State private var codexSaveStatus = ""
    @State private var codexModelList: [String] = []
    @State private var isFetchingCodexModels = false
    @State private var selectedCodexProfileID: UUID?
    @State private var newCodexProfileName = ""
    @State private var editingCodexProfile: CodexConfigProfile?

    @State private var remoteChatEnabled = true
    @State private var remoteChatBindLAN = true
    @State private var remoteChatStatus = ""
    @State private var pairingPresentation: RemotePairingPresentation?
    @State private var pairedDevices: [RemotePairedDevice] = []
    @State private var wanSnapshot = WanEndpointPublisher.Snapshot()

    @State private var selectedGlobalRuleKind: GlobalRuleKind = .claude
    @State private var globalRuleText = ""
    @State private var globalRuleStatus = ""
    @State private var isGlobalRuleTooLarge = false
    @State private var settingsLoadTask: Task<Void, Never>?
    @State private var codexSettingsLoadTask: Task<Void, Never>?
    @State private var globalRuleLoadTask: Task<Void, Never>?
    @State private var claudeModelFetchTask: Task<Void, Never>?
    @State private var codexModelFetchTask: Task<Void, Never>?
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    nonisolated private static let realHomeDir: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    nonisolated private static let claudeSettingsURL: URL = {
        realHomeDir.appendingPathComponent(".claude/settings.json")
    }()

    nonisolated private static let codexConfigURL: URL = {
        realHomeDir.appendingPathComponent(".codex/config.toml")
    }()

    nonisolated private static let codexAuthURL: URL = {
        realHomeDir.appendingPathComponent(".codex/auth.json")
    }()

    nonisolated private static let maxEditableGlobalRuleBytes = 1_000_000
    nonisolated private static let modelMenuLimit = 300

    private var codexAvailableModels: [String] {
        codexAvailableModels(including: codexModel)
    }

    private func codexAvailableModels(including currentModel: String) -> [String] {
        var models = ChatModelCatalog.options(for: .codex).map(\.id)
        models.append(contentsOf: codexModelList)
        if !currentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            models.insert(currentModel, at: 0)
        }
        return uniqueStrings(models)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            settingsSidebar

            ScrollView {
                selectedSettingsContent
                    .padding(.vertical, 24)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.editorSurface.opacity(0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: AppTheme.softShadow, radius: 16, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadSettings()
            loadSettingsSnapshot()
        }
        .onDisappear {
            cancelSettingsTasks()
        }
        .onChange(of: selectedGlobalRuleKind) { _, _ in
            loadGlobalRuleText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .acodeShowUpdateSettings)) { _ in
            withAnimation(.easeOut(duration: 0.14)) {
                selectedCategory = .about
            }
        }
        .sheet(item: $editingClaudeProfile) { profile in
            claudeProfileEditorSheet(profile)
        }
        .sheet(item: $editingCodexProfile) { profile in
            codexProfileEditorSheet(profile)
        }
    }

    private var settingsSidebar: some View {
        GlassPanel {
            VStack(spacing: 0) {
                HStack {
                    Text("设置")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

                Divider().opacity(0.24)
                    .padding(.horizontal, 14)

                categoryTabs
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)

                Divider().opacity(0.24)
                    .padding(.horizontal, 14)

                if showsBackButton {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            appState.showSettings = false
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text("返回")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(SettingsSidebarReturnButtonStyle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 228)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedCategory {
        case .general:
            generalSection
        case .claude:
            relaySection
        case .codex:
            codexSection
        case .remoteChat:
            remoteChatSection
        case .appendRules:
            appendRulesSection
        case .globalRules:
            globalRulesSection
        case .about:
            aboutSection
        }
    }

    private var categoryTabs: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selectedCategory = category
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16)
                            .foregroundStyle(selectedCategory == category ? Color.accentColor : .secondary)
                        Text(category.title)
                            .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 11)
                    .padding(.trailing, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(selectedCategory == category ? .primary : .secondary)
                    .background(selectedCategory == category ? AppTheme.selectedSurface : AppTheme.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        settingsCard(title: "通用") {
            settingsGrid {
                optionSelector(
                    title: "默认 CLI",
                    selection: $defaultCLI,
                    options: CLIType.visibleCases.map { ($0, $0.displayName) }
                )

                optionSelector(
                    title: "默认终端",
                    selection: $defaultTerminal,
                    options: TerminalType.allCases.map { ($0, $0.displayName) }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("忽略目录")
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: $ignoredFoldersText)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 132)
                    .background(AppTheme.inputSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                Text("每行一个目录名")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            authorizedFoldersSection

            HStack {
                Button("恢复默认") {
                    ignoredFoldersText = FileTreeScanner.defaultIgnoredNames.sorted().joined(separator: "\n")
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                Spacer()
                Button("保存") { saveAppSettings() }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var authorizedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("授权文件夹")
                        .font(.system(size: 13, weight: .semibold))
                    Text("启动提示和这里添加的目录都会通过系统面板授权；添加桌面、下载或常用工作目录后，打开其中的外部文件会优先复用目录授权。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("添加文件夹") {
                    appState.addAuthorizedFolder()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
            }

            if appState.settings.authorizedFolders.isEmpty {
                Text("尚未添加授权文件夹")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 34, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.secondaryCardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(appState.settings.authorizedFolders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(folder.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("移除") {
                                appState.removeAuthorizedFolder(folder)
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.secondaryCardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private func settingsFormHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsInlineMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(message.contains("失败") || message.contains("失效") ? Color.red.opacity(0.88) : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Device Connection

    private var remoteChatSection: some View {
        VStack(spacing: 18) {
            settingsCard(title: "设备连接") {
                deviceConnectionOverview
                remoteChatControlPanel
            }
            settingsCard(title: "跨网直连与配对") {
                wanPairingPanel
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePairingStateDidChange)) { _ in
            refreshPairingState()
        }
        .onAppear {
            refreshPairingState()
        }
    }

    private var deviceConnectionOverview: some View {
        let diagnostics = RemoteChatServerController.shared.currentDiagnostics()
        let isServerReady = remoteChatEnabled && RemoteChatServerController.shared.isRunning
        let connectionCount = diagnostics.activeWebSocketCount

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("手机、Mac、项目会话")
                        .font(.system(size: 16, weight: .semibold))
                    Text("局域网和跨网都通过加密通道（wss）直连这台 Mac，配对码/二维码完成鉴权，无需账号或云端中转。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                connectionStatusBadge(title: isServerReady ? "服务已开启" : "服务未开启", isGood: isServerReady)
            }

            HStack(alignment: .center, spacing: 16) {
                connectionNode(
                    title: "iPhone",
                    subtitle: "同局域网设备",
                    systemImage: "iphone",
                    isActive: isServerReady
                )
                connectionRail(isActive: isServerReady)
                connectionNode(
                    title: "acode (Mac)",
                    subtitle: "本机设备",
                    systemImage: "desktopcomputer",
                    isActive: isServerReady
                )
                connectionRail(isActive: connectionCount > 0)
                connectionNode(
                    title: "项目会话",
                    subtitle: connectionCount > 0 ? "\(connectionCount) 个连接" : "等待连接",
                    systemImage: "bubble.left.and.text.bubble.right",
                    isActive: connectionCount > 0
                )
            }

            HStack(spacing: 10) {
                metricChip(title: "连接方式", value: "局域网直连 + 跨网直连")
                metricChip(title: "本机端口", value: "\(RemoteChatServerController.defaultPort)")
                metricChip(title: "WebSocket", value: diagnostics.activeWebSocketCount > 0 ? "\(diagnostics.activeWebSocketCount) 个在线" : "空闲")
            }
        }
        .padding(18)
        .background(AppTheme.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private var remoteChatControlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            remoteSettingToggle(
                title: "设备连接服务",
                subtitle: remoteChatEnabled ? "允许同一 Wi-Fi 下的设备连接这台 Mac" : "关闭后其他设备不能连接这台 Mac",
                isOn: $remoteChatEnabled
            )
            if remoteChatEnabled {
                remoteSettingToggle(
                    title: "允许局域网直连",
                    subtitle: "手机与 Mac 在同一 Wi‑Fi 时，走局域网 TCP 直连",
                    isOn: $remoteChatBindLAN
                )
            }

            HStack(alignment: .center, spacing: 12) {
                if !remoteChatStatus.isEmpty {
                    Text(remoteChatStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button("保存") { saveRemoteChatSettings() }
                    .buttonStyle(SettingsPrimaryButtonStyle())
            }
        }
    }

    // MARK: - WAN pairing panel

    private var wanPairingPanel: some View {
        let controller = RemoteChatServerController.shared

        return VStack(alignment: .leading, spacing: 16) {
            if !remoteChatEnabled {
                wanHint("设备连接服务已关闭。开启后才能配对新设备。")
            } else if !remoteChatBindLAN {
                wanHint("当前仅监听本机回环（loopback），其他设备无法连接。开启「允许局域网直连」后可配对。")
            } else if !controller.isRunning {
                wanHint(controller.lastError.map { "服务未运行：\($0)" } ?? "保存上方设置后服务才会启动。")
            } else {
                pairingControls
                wanEndpointList
                pairedDeviceList
                Text("二维码和配对码只在出示期间有效：码 5 分钟过期、一次性；扫码连接串含配对凭证。吊销设备后对应 token 立即失效。若提示 CGNAT 或「需手动端口转发」，请在路由器上把 TCP \(RemoteChatServerController.defaultPort) 转发到这台 Mac，或改用 IPv6 直连（需在路由器防火墙放通该端口）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(pairingPresentation == nil ? "生成配对二维码与连接串" : "重新生成") {
                    pairingPresentation = RemoteChatServerController.shared.makePairingPresentation()
                }
                .buttonStyle(SettingsPrimaryButtonStyle(compact: true))
                if pairingPresentation != nil {
                    Button("清除") {
                        pairingPresentation = nil
                        RemoteChatServerController.shared.pairingService.cancelPairing()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                }
            }

            if let presentation = pairingPresentation {
                HStack(alignment: .top, spacing: 18) {
                    if let image = Self.qrImage(for: presentation.connectionString) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("局域网 6 位配对码")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(presentation.pairingCode)
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Text("手机与 Mac 在同一 Wi‑Fi 时输入；\(codeExpiryText(presentation.codeExpiresAt))后失效。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Button("复制连接串") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(presentation.connectionString, forType: .string)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                        Text("连接串含配对凭证，仅发送给可信设备。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var wanEndpointList: some View {
        let snapshot = wanSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("跨网可达性")
                .font(.system(size: 13, weight: .semibold))
            if snapshot.diagnostics.isEmpty {
                wanHint("正在检测网络环境…")
            } else {
                ForEach(snapshot.diagnostics) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(wanStateColor(item.state))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(item.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if snapshot.endpoints.isEmpty {
                    wanHint("当前网络无法跨网直连：既无可用全球 IPv6，也未获得公网 IPv4 映射。可手动在路由器上做端口转发后用手机扫码配对。")
                }
            }
        }
        .padding(14)
        .background(AppTheme.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private var pairedDeviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已配对设备")
                .font(.system(size: 13, weight: .semibold))
            if pairedDevices.isEmpty {
                wanHint("还没有已配对设备。")
            } else {
                ForEach(pairedDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.deviceName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(device.lastSeen.map { "最近连接 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "配对于 \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("吊销") {
                            RemoteChatServerController.shared.revokeDevice(device.id)
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                    }
                }
            }
        }
        .padding(14)
        .background(AppTheme.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private func wanHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func wanStateColor(_ state: WanEndpointPublisher.DiagnosticState) -> Color {
        switch state {
        case .usable: return .green
        case .checking: return .orange
        case .cgnat, .unavailable: return .secondary.opacity(0.6)
        case .unsupported: return .red.opacity(0.85)
        }
    }

    private func codeExpiryText(_ expiresAt: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSinceNow))
        return remaining > 0 ? "\(remaining / 60) 分 \(remaining % 60) 秒" : "已过期"
    }

    private func refreshPairingState() {
        let controller = RemoteChatServerController.shared
        pairedDevices = controller.pairedDevices()
        wanSnapshot = controller.wanSnapshot()
    }

    private static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 600 / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func remoteSettingToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private func connectionNode(title: String, subtitle: String, systemImage: String, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: 44, height: 44)
                .background(isActive ? AppTheme.secondaryCardSurface : AppTheme.toolMutedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? relayProfileCardBackground(isActive: true) : AppTheme.secondaryCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    private func connectionRail(isActive: Bool) -> some View {
        Capsule()
            .fill(isActive ? Color.primary.opacity(0.22) : Color.secondary.opacity(0.12))
            .frame(width: 52, height: 5)
    }

    private func connectionStatusBadge(title: String, isGood: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isGood ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isGood ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(AppTheme.buttonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 50, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.secondaryCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    // MARK: - Append Rules

    private var appendRulesSection: some View {
        settingsCard(title: "追加规则") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发送时追加到实际 prompt")
                        .font(.system(size: 13, weight: .semibold))
                    Text("聊天气泡仍显示原始输入，追加内容会随请求一起发送给当前 CLI。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("启用", isOn: $appendRuleEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
            }

            TextEditor(text: $appendRuleText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(AppTheme.inputSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))

            HStack {
                Button("清空") {
                    appendRuleText = ""
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                Spacer()
                Button("保存") { saveAppSettings() }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Relay / Proxy

    private var relaySection: some View {
        settingsCard(title: "中转站（Claude Code）") {
            claudeRelayProfileList

            Text("列表只展示名称、API 地址和模型摘要；密钥、模型和代理配置在编辑弹窗里维护。“设为当前”才会写入 ~/.claude/settings.json 并影响新启动的 Claude Code 会话。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Update

    private var codexSection: some View {
        settingsCard(title: "Codex") {
            codexConfigProfileList

            Text("Codex 中转站同样按列表管理；编辑弹窗维护 base_url、OPENAI_API_KEY、wire_api 和模型。设为当前后才写入 ~/.codex/config.toml 与 auth.json。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var globalRulesSection: some View {
        settingsCard(title: "全局规则") {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(GlobalRuleKind.allCases) { kind in
                        Button(kind.title) { selectedGlobalRuleKind = kind }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedGlobalRuleKind.title)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(AppTheme.inputSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                VStack(alignment: .leading, spacing: 5) {
                    Text("文件路径")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(globalRuleURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let note = selectedGlobalRuleKind.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                if isGlobalRuleTooLarge {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.zipper")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("规则文件过大，已跳过载入编辑器。")
                            .font(.system(size: 13, weight: .medium))
                        Text("请使用外部编辑器修改这个文件。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    TextEditor(text: $globalRuleText)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 260)
                }
            }
            .background(AppTheme.inputSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))

            HStack {
                if !globalRuleStatus.isEmpty {
                    Text(globalRuleStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(globalRuleStatus.contains("失败") ? .red : .secondary)
                }
                Spacer()
                Button("重新读取") { loadGlobalRuleText() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                Button("保存") { saveGlobalRuleText() }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(isGlobalRuleTooLarge || globalRuleStatus.hasPrefix("读取失败"))
            }

            Text("保存后需要重启 acode 或开启新的 CLI 会话后生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var claudeRelayProfileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code 中转站列表")
                        .font(.system(size: 13, weight: .semibold))
                    Text("一行一个配置，点击编辑再维护完整字段。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增中转站") { openNewClaudeProfile() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }

            if configProfiles.claudeRelayProfiles.isEmpty {
                emptyProfileText("还没有中转站配置，点击“新增中转站”创建一个空白配置。")
            } else {
                profileListHeader
                ForEach(configProfiles.claudeRelayProfiles) { profile in
                    claudeRelayProfileRow(profile)
                }
            }

            if !relaySaveStatus.isEmpty {
                Text(relaySaveStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(relaySaveStatusColor)
            }
        }
    }

    private func claudeRelayProfileRow(_ profile: ClaudeRelayProfile) -> some View {
        profileListRow(
            isActive: selectedClaudeProfileID == profile.id,
            name: profile.name,
            subtitle: profile.httpProxy.isEmpty && profile.httpsProxy.isEmpty ? "未配置代理" : "已配置代理",
            apiAddress: profile.baseURL,
            modelSummary: claudeModelSummary(profile),
            edit: { editingClaudeProfile = profile },
            activate: { activateClaudeProfile(profile) },
            delete: { deleteClaudeProfile(profile) }
        )
    }

    private var codexConfigProfileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 中转站列表")
                        .font(.system(size: 13, weight: .semibold))
                    Text("一行一个配置，编辑弹窗维护 API Key 和 wire_api。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增中转站") { openNewCodexProfile() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }

            if configProfiles.codexProfiles.isEmpty {
                emptyProfileText("还没有 Codex 配置，点击“新增中转站”创建一个空白配置。")
            } else {
                profileListHeader
                ForEach(configProfiles.codexProfiles) { profile in
                    codexConfigProfileRow(profile)
                }
            }

            if !codexSaveStatus.isEmpty {
                Text(codexSaveStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(codexSaveStatusColor)
            }
        }
    }

    private func codexConfigProfileRow(_ profile: CodexConfigProfile) -> some View {
        profileListRow(
            isActive: selectedCodexProfileID == profile.id,
            name: profile.name,
            subtitle: profile.wireApi.isEmpty ? "responses" : profile.wireApi,
            apiAddress: profile.baseURL,
            modelSummary: profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未设置模型" : profile.model,
            edit: { editingCodexProfile = profile },
            activate: { activateCodexProfile(profile) },
            delete: { deleteCodexProfile(profile) }
        )
    }

    private var profileListHeader: some View {
        HStack(spacing: 14) {
            Text("状态").frame(width: 74, alignment: .leading)
            Text("名称").frame(width: 220, alignment: .leading)
            Text("API 地址").frame(maxWidth: .infinity, alignment: .leading)
            Text("模型").frame(width: 140, alignment: .leading)
            Text("操作").frame(width: 246, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(AppTheme.secondaryCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func profileListRow(
        isActive: Bool,
        name: String,
        subtitle: String,
        apiAddress: String,
        modelSummary: String,
        edit: @escaping () -> Void,
        activate: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            profileStatusBadge(isActive: isActive)
                .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名中转站" : name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)

            Text(apiAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写 API 地址" : apiAddress)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(apiAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(modelSummary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 8) {
                Button("编辑", action: edit)
                    .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                Button("设为当前", action: activate)
                    .buttonStyle(SettingsPrimaryButtonStyle(compact: true))
                    .disabled(isActive)
                Button("删除", role: .destructive, action: delete)
                    .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
            }
            .frame(width: 246, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 74)
        .background(relayProfileCardBackground(isActive: isActive))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(isActive ? AppTheme.hairline : AppTheme.weakHairline, lineWidth: 1))
    }

    private func claudeModelSummary(_ profile: ClaudeRelayProfile) -> String {
        let values = [profile.model, profile.haikuModel, profile.sonnetModel, profile.opusModel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if values.isEmpty { return "未设置模型" }
        return values.count == 1 ? values[0] : "\(values.count) 个模型"
    }

    private func claudeProfileEditorSheet(_ profile: ClaudeRelayProfile) -> some View {
        let draft = Binding<ClaudeRelayProfile>(
            get: { editingClaudeProfile ?? profile },
            set: { editingClaudeProfile = $0 }
        )
        return profileEditorShell(
            title: "编辑 Claude 中转站",
            subtitle: "配置名称、API 地址、密钥、模型和代理都在这里维护。"
        ) {
            settingsGrid {
                envField(label: "配置名称", placeholder: "主力 Claude 中转站", text: draft.name)
                envField(label: "ANTHROPIC_BASE_URL", placeholder: "https://api.anthropic.com", text: draft.baseURL)
                envField(label: "ANTHROPIC_API_KEY", placeholder: "sk-...", text: draft.authToken, secure: true)
            }

            editorSectionHeader("模型配置") {
                fetchClaudeModels(for: draft.wrappedValue)
            } isFetching: {
                isFetchingClaudeModels
            } disabled: {
                draft.wrappedValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingClaudeModels
            }

            if !claudeModelList.isEmpty {
                settingsGrid {
                    modelPicker(label: "ANTHROPIC_MODEL", selection: draft.model, models: claudeModelList)
                    modelPicker(label: "ANTHROPIC_DEFAULT_HAIKU_MODEL", selection: draft.haikuModel, models: claudeModelList)
                    modelPicker(label: "ANTHROPIC_DEFAULT_SONNET_MODEL", selection: draft.sonnetModel, models: claudeModelList)
                    modelPicker(label: "ANTHROPIC_DEFAULT_OPUS_MODEL", selection: draft.opusModel, models: claudeModelList)
                }
            } else {
                settingsGrid {
                    envField(label: "ANTHROPIC_MODEL", placeholder: "claude-sonnet-4-6", text: draft.model)
                    envField(label: "ANTHROPIC_DEFAULT_HAIKU_MODEL", placeholder: "claude-haiku-4-5-20251001", text: draft.haikuModel)
                    envField(label: "ANTHROPIC_DEFAULT_SONNET_MODEL", placeholder: "claude-sonnet-4-6", text: draft.sonnetModel)
                    envField(label: "ANTHROPIC_DEFAULT_OPUS_MODEL", placeholder: "claude-opus-4-7", text: draft.opusModel)
                }
            }

            editorSectionHeader("代理") {} isFetching: { false } disabled: { true }

            settingsGrid {
                envField(label: "HTTP_PROXY", placeholder: "http://127.0.0.1:7890", text: draft.httpProxy)
                envField(label: "HTTPS_PROXY", placeholder: "http://127.0.0.1:7890", text: draft.httpsProxy)
            }

            profileEditorFooter(
                save: {
                    if let editingClaudeProfile {
                        saveClaudeProfileDraft(editingClaudeProfile)
                    }
                    editingClaudeProfile = nil
                },
                saveAndActivate: {
                    if let editingClaudeProfile, let saved = saveClaudeProfileDraft(editingClaudeProfile) {
                        activateClaudeProfile(saved)
                    }
                    editingClaudeProfile = nil
                },
                cancel: { editingClaudeProfile = nil }
            )
        }
    }

    private func codexProfileEditorSheet(_ profile: CodexConfigProfile) -> some View {
        let draft = Binding<CodexConfigProfile>(
            get: { editingCodexProfile ?? profile },
            set: { editingCodexProfile = $0 }
        )
        let availableModels = codexAvailableModels(including: draft.wrappedValue.model)
        return profileEditorShell(
            title: "编辑 Codex 中转站",
            subtitle: "配置 OpenAI 兼容接口、API Key、模型和 wire_api。"
        ) {
            settingsGrid {
                envField(label: "配置名称", placeholder: "Codex 配置", text: draft.name)
                envField(label: "base_url", placeholder: "https://api.openai.com/v1", text: draft.baseURL)
                envField(label: "OPENAI_API_KEY", placeholder: "sk-...", text: draft.apiKey, secure: true)
            }

            editorSectionHeader("模型与协议") {
                fetchCodexModels(for: draft.wrappedValue)
            } isFetching: {
                isFetchingCodexModels
            } disabled: {
                draft.wrappedValue.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingCodexModels
            }

            settingsGrid {
                if !availableModels.isEmpty {
                    modelPicker(label: "model", selection: draft.model, models: availableModels)
                } else {
                    envField(label: "model", placeholder: "gpt-5.5", text: draft.model)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("wire_api")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    inlineSegmentedPicker(
                        selection: draft.wireApi,
                        options: [("responses", "responses"), ("chat", "chat")]
                    )
                }
            }

            profileEditorFooter(
                save: {
                    if let editingCodexProfile {
                        saveCodexProfileDraft(editingCodexProfile)
                    }
                    editingCodexProfile = nil
                },
                saveAndActivate: {
                    if let editingCodexProfile, let saved = saveCodexProfileDraft(editingCodexProfile) {
                        activateCodexProfile(saved)
                    }
                    editingCodexProfile = nil
                },
                cancel: { editingCodexProfile = nil }
            )
        }
    }

    private func profileEditorShell<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .padding(26)
        }
        .frame(width: 760)
        .frame(minHeight: 520)
        .background(AppTheme.cardSurface)
    }

    private func editorSectionHeader(
        _ title: String,
        fetch: @escaping () -> Void,
        isFetching: @escaping () -> Bool,
        disabled: @escaping () -> Bool
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !disabled() || isFetching() {
                Button(action: fetch) {
                    fetchModelsButtonLabel(isFetching: isFetching())
                }
                .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                .disabled(disabled())
            }
        }
    }

    private func profileEditorFooter(save: @escaping () -> Void, saveAndActivate: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button("取消", action: cancel)
                .buttonStyle(SettingsSecondaryButtonStyle())
            Spacer()
            Button("保存", action: save)
                .buttonStyle(SettingsSecondaryButtonStyle())
            Button("保存并设为当前", action: saveAndActivate)
                .buttonStyle(SettingsPrimaryButtonStyle())
        }
        .padding(.top, 4)
    }

    private func relayProfileCardBackground(isActive: Bool) -> Color {
        guard isActive else { return AppTheme.inputSurface }
        return AppTheme.relayActiveGlassSurface
    }

    private func profileStatusBadge(isActive: Bool) -> some View {
        Text(isActive ? "当前" : "未启用")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isActive ? Color.green : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(AppTheme.buttonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    private func fetchModelsButtonLabel(isFetching: Bool) -> some View {
        HStack(spacing: 4) {
            if isFetching {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            Text("拉取模型")
                .font(.system(size: 12))
        }
    }

    private var relaySaveStatusColor: Color {
        if relaySaveStatus.contains("成功") || relaySaveStatus.contains("已") { return .green }
        if relaySaveStatus.contains("请") { return .orange }
        return .red
    }

    private var codexSaveStatusColor: Color {
        if codexSaveStatus.contains("成功") || codexSaveStatus.contains("已") { return .green }
        if codexSaveStatus.contains("请") { return .orange }
        return .red
    }

    private var updateSection: some View {
        settingsCard(title: "版本更新") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前版本：\(appVersion)（\(buildNumber)）")
                        .font(.system(size: 13))
                    if let lastCheckedAt = updateService.lastCheckedAt {
                        Text("上次检查：\(lastCheckedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if updateService.checkState == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("检查更新") { updateService.checkManually() }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }

            updateStateContent
        }
    }

    @ViewBuilder
    private var updateStateContent: some View {
        switch updateService.checkState {
        case .idle:
            EmptyView()
        case .checking:
            Text("正在检查更新…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .upToDate:
            VStack(alignment: .leading, spacing: 4) {
                settingsInlineMessage("已是最新版本。")
                if let release = updateService.latestRelease {
                    Text("最新发布：\(release.tagName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        case .updateAvailable:
            if let release = updateService.latestRelease {
                updateAvailableContent(release)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.red.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updateAvailableContent(_ release: UpdateService.ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现新版本：\(release.tagName)")
                    .font(.system(size: 13, weight: .semibold))
                if release.assetSize > 0 {
                    Text("安装包：\(release.assetName)（\(ByteCountFormatter.string(fromByteCount: release.assetSize, countStyle: .file))）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(AppTheme.inputSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
            }

            updateInstallContent(release)
        }
    }

    @ViewBuilder
    private func updateInstallContent(_ release: UpdateService.ReleaseInfo) -> some View {
        switch updateService.installState {
        case .idle:
            HStack(spacing: 10) {
                Button("下载并安装") { updateService.downloadAndInstall() }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                Button("查看发布页") { updateService.openReleasePage() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("正在下载更新…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    ProgressView(value: progress, total: 1)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(step)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .finished:
            settingsInlineMessage("安装完成，正在重启…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button("重试") { updateService.downloadAndInstall() }
                        .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                    if updateService.downloadedDMGURL != nil {
                        Button("手动打开 DMG") { updateService.openDownloadedDMG() }
                            .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                    }
                    Button("查看发布页") { updateService.openReleasePage() }
                        .buttonStyle(SettingsSecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "关于") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("acode")
                        .font(.system(size: 15, weight: .semibold))
                    Text("一个轻量级的 Claude Code / Codex 桌面客户端")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("© 2026 crispvibe · 仅限个人非商业使用，禁止商用")
                        Text("许可：PolyForm Noncommercial 1.0.0")
                        Text("QQ 群：1076321843（Code 开源技术交流群）")
                        Text("仓库：github.com/crispvibe/Acode-Desktop")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            updateSection
        }
    }

    // MARK: - UI Helpers

    @ViewBuilder
    private func envField(label: String, placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .settingsTextFieldChrome()
        }
    }

    private func multilineField(label: String, placeholder: String, text: Binding<String>, minHeight: CGFloat = 82) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .background(AppTheme.inputSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func settingsGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .topLeading)
            ],
            alignment: .leading,
            spacing: 16
        ) {
            content()
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppTheme.cardSurface)
            }
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func optionSelector<Value: Hashable>(title: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            inlineSegmentedPicker(selection: selection, options: options)
        }
    }

    private func inlineSegmentedPicker<Value: Hashable>(selection: Binding<Value>, options: [(Value, String)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection.wrappedValue == option.0
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection.wrappedValue = option.0
                    }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(isSelected ? AppTheme.selectedSurface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        // Without an explicit contentShape the unselected segments only
                        // hit-test the underlying Text, because their background is
                        // Color.clear. Force the entire pill to be tappable.
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AppTheme.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private func emptyProfileText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppTheme.inputSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func profileChips<Profile: Identifiable>(
        profiles: [Profile],
        selectedID: UUID?,
        title: KeyPath<Profile, String>,
        select: @escaping (Profile) -> Void,
        delete: @escaping (Profile) -> Void
    ) -> some View where Profile.ID == UUID {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(profiles) { profile in
                    let isSelected = selectedID == profile.id
                    HStack(spacing: 0) {
                        Button {
                            select(profile)
                        } label: {
                            Text(profile[keyPath: title])
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .padding(.leading, 12)
                                .padding(.trailing, 6)
                                .padding(.vertical, 8)
                                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            delete(profile)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(CircularIconButtonStyle(size: 24))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                    }
                    .background(isSelected ? AppTheme.selectedSurface : AppTheme.buttonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(isSelected ? AppTheme.hairline : AppTheme.weakHairline, lineWidth: 1))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func addProfileRow(placeholder: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: text)
                .settingsTextFieldChrome()
            Button("添加当前配置") { action() }
                .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    private func loadSettingsSnapshot() {
        settingsLoadTask?.cancel()
        let ruleKind = selectedGlobalRuleKind
        settingsLoadTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                SettingsDiskSnapshot(
                    claude: Self.readClaudeSettingsSnapshot(),
                    codex: Self.readCodexSettingsSnapshot(),
                    profiles: ProjectStore.loadConfigProfiles(),
                    globalRule: Self.readGlobalRuleSnapshot(kind: ruleKind)
                )
            }.value
            guard !Task.isCancelled else { return }
            applyClaudeSettings(snapshot.claude)
            applyCodexSettings(snapshot.codex)
            applyConfigProfiles(snapshot.profiles)
            if selectedGlobalRuleKind == ruleKind {
                applyGlobalRuleSnapshot(snapshot.globalRule)
            }
        }
    }

    private func loadCodexSettingsSnapshot() {
        codexSettingsLoadTask?.cancel()
        codexSettingsLoadTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                Self.readCodexSettingsSnapshot()
            }.value
            guard !Task.isCancelled else { return }
            applyCodexSettings(snapshot)
        }
    }

    private func cancelSettingsTasks() {
        settingsLoadTask?.cancel()
        codexSettingsLoadTask?.cancel()
        globalRuleLoadTask?.cancel()
        claudeModelFetchTask?.cancel()
        codexModelFetchTask?.cancel()
        isFetchingClaudeModels = false
        isFetchingCodexModels = false
    }

    private func applyClaudeSettings(_ snapshot: ClaudeSettingsSnapshot) {
        anthropicBaseURL = snapshot.baseURL
        anthropicAuthToken = snapshot.authToken
        anthropicModel = snapshot.model
        anthropicHaikuModel = snapshot.haikuModel
        anthropicSonnetModel = snapshot.sonnetModel
        anthropicOpusModel = snapshot.opusModel
        httpProxy = snapshot.httpProxy
        httpsProxy = snapshot.httpsProxy
    }

    private func applyCodexSettings(_ snapshot: CodexSettingsSnapshot) {
        codexApiKey = snapshot.apiKey
        codexModel = snapshot.model
        codexBaseURL = snapshot.baseURL
        codexWireApi = snapshot.wireApi
        codexAuthMode = snapshot.authMode
    }

    private func applyConfigProfiles(_ profiles: ConfigProfileCollection) {
        configProfiles = profiles
        selectedClaudeProfileID = profiles.activeClaudeRelayProfileID
        selectedCodexProfileID = profiles.activeCodexProfileID

        if let id = selectedClaudeProfileID,
           let profile = profiles.claudeRelayProfiles.first(where: { $0.id == id }) {
            applyClaudeProfile(profile)
        }
        if let id = selectedCodexProfileID,
           let profile = profiles.codexProfiles.first(where: { $0.id == id }) {
            applyCodexProfile(profile)
        }
    }

    private func applyGlobalRuleSnapshot(_ snapshot: GlobalRuleSnapshot) {
        globalRuleText = snapshot.text
        globalRuleStatus = snapshot.status
        isGlobalRuleTooLarge = snapshot.isTooLarge
    }

    private nonisolated static func readClaudeSettingsSnapshot() -> ClaudeSettingsSnapshot {
        var snapshot = ClaudeSettingsSnapshot()
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else { return snapshot }
        snapshot.baseURL = env["ANTHROPIC_BASE_URL"] as? String ?? ""
        snapshot.authToken = env["ANTHROPIC_API_KEY"] as? String ?? env["ANTHROPIC_AUTH_TOKEN"] as? String ?? ""
        snapshot.model = env["ANTHROPIC_MODEL"] as? String ?? ""
        snapshot.haikuModel = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String ?? ""
        snapshot.sonnetModel = env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String ?? ""
        snapshot.opusModel = env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String ?? ""
        snapshot.httpProxy = env["HTTP_PROXY"] as? String ?? ""
        snapshot.httpsProxy = env["HTTPS_PROXY"] as? String ?? ""
        return snapshot
    }

    private nonisolated static func readCodexSettingsSnapshot() -> CodexSettingsSnapshot {
        var snapshot = CodexSettingsSnapshot()
        var configuredProvider = ""

        if let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) {
            snapshot.model = tomlValue(in: text, key: "model") ?? ""
            configuredProvider = tomlValue(in: text, key: "model_provider") ?? ""

            let providerSection = configuredProvider.isEmpty ? "codevoke_custom" : configuredProvider
            if let customSection = tomlSection(in: text, section: "model_providers.\(providerSection)") {
                snapshot.baseURL = tomlValue(in: customSection, key: "base_url") ?? ""
                snapshot.wireApi = tomlValue(in: customSection, key: "wire_api") ?? "responses"
            }
        }

        if let data = try? Data(contentsOf: codexAuthURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            snapshot.apiKey = json["OPENAI_API_KEY"] as? String ?? ""
        }

        snapshot.authMode = .apiKey
        return snapshot
    }

    private nonisolated static func settingsError(_ message: String) -> NSError {
        NSError(domain: "CodevokeSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func tomlRawValue(in text: String, key: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard isTomlAssignment(line, key: key) else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            return parts[1]
        }
        return nil
    }

    private nonisolated static func splitTomlCommaValues(_ text: String) -> [String] {
        var values: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                current.append(character)
                isQuoted.toggle()
                continue
            }
            if character == ",", !isQuoted {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(current)
        }
        return values
    }

    private nonisolated static func tomlUnquoted(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed.isEmpty ? nil : trimmed }
        var result = ""
        var isEscaped = false
        for character in trimmed.dropFirst().dropLast() {
            if isEscaped {
                switch character {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private nonisolated static func stripTomlComment(_ line: String) -> String {
        var result = ""
        var isQuoted = false
        var isEscaped = false
        for character in line {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                result.append(character)
                isQuoted.toggle()
                continue
            }
            if character == "#", !isQuoted {
                break
            }
            result.append(character)
        }
        return result
    }

    private nonisolated static func readGlobalRuleSnapshot(kind: GlobalRuleKind) -> GlobalRuleSnapshot {
        let url = globalRuleURL(for: kind)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return GlobalRuleSnapshot(text: "", status: "文件不存在，保存时会创建", isTooLarge: false)
        }
        do {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > maxEditableGlobalRuleBytes {
                let sizeText = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
                return GlobalRuleSnapshot(text: "", status: "文件大小为 \(sizeText)，已跳过载入以避免卡顿", isTooLarge: true)
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            return GlobalRuleSnapshot(text: text, status: "已读取", isTooLarge: false)
        } catch {
            return GlobalRuleSnapshot(text: "", status: "读取失败：\(error.localizedDescription)", isTooLarge: false)
        }
    }

    private nonisolated static func globalRuleURL(for kind: GlobalRuleKind) -> URL {
        realHomeDir.appendingPathComponent(kind.relativePath)
    }

    private nonisolated static func tomlValue(in text: String, key: String) -> String? {
        guard let rawValue = tomlRawValue(in: text, key: key) else { return nil }
        return tomlUnquoted(rawValue)
    }

    private nonisolated static func tomlSection(in text: String, section: String) -> String? {
        var lines: [String] = []
        var isInsideSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if isInsideSection { break }
                isInsideSection = trimmed.dropFirst().dropLast() == section
                continue
            }
            if isInsideSection {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - App Settings

    private func loadSettings() {
        let s = appState.settings
        defaultCLI = s.defaultCLI.visibleValue
        defaultTerminal = s.defaultTerminal
        showCommandPreview = s.showCommandPreview
        appendRuleEnabled = s.appendRuleEnabled
        appendRuleText = s.appendRuleText
        ignoredFoldersText = s.ignoredFolders.joined(separator: "\n")
        loadRemoteChatSettings()
    }

    private func loadRemoteChatSettings() {
        let s = appState.settings
        remoteChatEnabled = s.remoteChatServerEnabled
        remoteChatBindLAN = s.remoteChatServerBindLAN
    }

    private func saveRemoteChatSettings() {
        var settings = appState.settings
        settings.remoteChatServerEnabled = remoteChatEnabled
        settings.remoteChatServerPort = Int(RemoteChatServerController.defaultPort)
        settings.remoteChatServerBindLAN = remoteChatBindLAN
        do {
            try ProjectStore.saveSettings(settings)
            appState.settings = settings
        } catch {
            remoteChatStatus = "保存失败：\(error.localizedDescription)"
            return
        }
        RemoteChatServerController.shared.restart()
        remoteChatStatus = remoteChatEnabled ? "已保存，设备连接服务已更新。" : "已保存，设备连接服务已关闭。"
    }

    private func saveAppSettings() {
        appState.saveSettings(
            defaultCLI: defaultCLI,
            defaultTerminal: defaultTerminal,
            showCommandPreview: showCommandPreview,
            appendRuleEnabled: appendRuleEnabled,
            appendRuleText: appendRuleText,
            ignoredFolders: ignoredFoldersText
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private var globalRuleURL: URL {
        Self.globalRuleURL(for: selectedGlobalRuleKind)
    }

    private func loadGlobalRuleText() {
        globalRuleLoadTask?.cancel()
        let kind = selectedGlobalRuleKind
        globalRuleLoadTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                Self.readGlobalRuleSnapshot(kind: kind)
            }.value
            guard !Task.isCancelled, selectedGlobalRuleKind == kind else { return }
            applyGlobalRuleSnapshot(snapshot)
        }
    }

    private func saveGlobalRuleText() {
        guard !isGlobalRuleTooLarge else {
            globalRuleStatus = "文件过大，未载入编辑内容，已取消保存"
            return
        }
        guard !globalRuleStatus.hasPrefix("读取失败") else {
            globalRuleStatus = "读取失败，未载入内容，已取消保存"
            return
        }
        do {
            try FileManager.default.createDirectory(at: globalRuleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = globalRuleText
            if selectedGlobalRuleKind == .cursor, !text.hasPrefix("---") {
                text = "---\nalwaysApply: true\n---\n\n" + text
            }
            try text.write(to: globalRuleURL, atomically: true, encoding: .utf8)
            globalRuleStatus = "已保存，重启 acode 或开启新 CLI 会话后生效"
        } catch {
            globalRuleStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Config Profiles

    private func loadConfigProfiles() {
        configProfiles = ProjectStore.loadConfigProfiles()
        selectedClaudeProfileID = configProfiles.activeClaudeRelayProfileID
        selectedCodexProfileID = configProfiles.activeCodexProfileID

        if let id = selectedClaudeProfileID,
           let profile = configProfiles.claudeRelayProfiles.first(where: { $0.id == id }) {
            applyClaudeProfile(profile)
        }
        if let id = selectedCodexProfileID,
           let profile = configProfiles.codexProfiles.first(where: { $0.id == id }) {
            applyCodexProfile(profile)
        }
    }

    private func persistConfigProfiles() throws {
        try ProjectStore.saveConfigProfiles(configProfiles)
    }

    private func openNewClaudeProfile() {
        editingClaudeProfile = emptyClaudeProfile(
            named: nextProfileName(newClaudeProfileName, fallback: "Claude 中转站", count: configProfiles.claudeRelayProfiles.count)
        )
        newClaudeProfileName = ""
    }

    private func openNewCodexProfile() {
        editingCodexProfile = emptyCodexProfile(
            named: nextProfileName(newCodexProfileName, fallback: "Codex 配置", count: configProfiles.codexProfiles.count)
        )
        newCodexProfileName = ""
    }

    @discardableResult
    private func saveClaudeProfileDraft(_ profile: ClaudeRelayProfile) -> ClaudeRelayProfile? {
        do {
            let saved: ClaudeRelayProfile
            if configProfiles.claudeRelayProfiles.contains(where: { $0.id == profile.id }) {
                saved = try persistedClaudeProfile(profile)
            } else {
                saved = try insertedClaudeProfile(profile)
            }
            if selectedClaudeProfileID == saved.id {
                applyClaudeProfile(saved)
                try writeClaudeSettings(updateSelectedProfile: false)
            }
            relaySaveStatus = selectedClaudeProfileID == saved.id ? "已保存并更新当前配置" : "已保存配置：\(saved.name)"
            return saved
        } catch {
            relaySaveStatus = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    private func saveCodexProfileDraft(_ profile: CodexConfigProfile) -> CodexConfigProfile? {
        do {
            let saved: CodexConfigProfile
            if configProfiles.codexProfiles.contains(where: { $0.id == profile.id }) {
                saved = try persistedCodexProfile(profile)
            } else {
                saved = try insertedCodexProfile(profile)
            }
            if selectedCodexProfileID == saved.id {
                applyCodexProfile(saved)
                try writeCodexSettings(updateSelectedProfile: false)
            }
            codexSaveStatus = selectedCodexProfileID == saved.id ? "已保存并更新当前配置" : "已保存配置：\(saved.name)"
            return saved
        } catch {
            codexSaveStatus = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func addClaudeProfile() {
        let profile = emptyClaudeProfile(named: nextProfileName(newClaudeProfileName, fallback: "Claude 中转站", count: configProfiles.claudeRelayProfiles.count))
        configProfiles.claudeRelayProfiles.insert(profile, at: 0)
        newClaudeProfileName = ""
        do {
            try persistConfigProfiles()
            relaySaveStatus = "已新增中转站，请填写后保存或设为当前"
        } catch {
            relaySaveStatus = "新增失败：\(error.localizedDescription)"
        }
    }

    private func saveClaudeProfile(_ profile: ClaudeRelayProfile) {
        do {
            let saved = try persistedClaudeProfile(profile)
            if selectedClaudeProfileID == saved.id {
                applyClaudeProfile(saved)
                try writeClaudeSettings(updateSelectedProfile: false)
            }
            relaySaveStatus = selectedClaudeProfileID == saved.id ? "已保存并更新当前配置" : "已保存配置：\(saved.name)"
        } catch {
            relaySaveStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func activateClaudeProfile(_ profile: ClaudeRelayProfile) {
        do {
            let saved = try persistedClaudeProfile(profile)
            selectedClaudeProfileID = saved.id
            configProfiles.activeClaudeRelayProfileID = saved.id
            try persistConfigProfiles()
            applyClaudeProfile(saved)
            try writeClaudeSettings(updateSelectedProfile: false)
            relaySaveStatus = "已设为当前：\(saved.name)"
        } catch {
            relaySaveStatus = "切换失败：\(error.localizedDescription)"
        }
    }

    private func deleteClaudeProfile(_ profile: ClaudeRelayProfile) {
        let wasSelected = selectedClaudeProfileID == profile.id
        configProfiles.claudeRelayProfiles.removeAll { $0.id == profile.id }
        if wasSelected {
            selectedClaudeProfileID = configProfiles.claudeRelayProfiles.first?.id
            configProfiles.activeClaudeRelayProfileID = selectedClaudeProfileID
        }
        do {
            try persistConfigProfiles()
            if wasSelected,
               let selectedClaudeProfileID,
               let next = configProfiles.claudeRelayProfiles.first(where: { $0.id == selectedClaudeProfileID }) {
                applyClaudeProfile(next)
                try writeClaudeSettings(updateSelectedProfile: false)
            }
            relaySaveStatus = "已删除配置"
        } catch {
            relaySaveStatus = "删除失败：\(error.localizedDescription)"
        }
    }

    private func addCodexProfile() {
        let profile = emptyCodexProfile(named: nextProfileName(newCodexProfileName, fallback: "Codex 配置", count: configProfiles.codexProfiles.count))
        configProfiles.codexProfiles.insert(profile, at: 0)
        newCodexProfileName = ""
        do {
            try persistConfigProfiles()
            codexSaveStatus = "已新增中转站，请填写后保存或设为当前"
        } catch {
            codexSaveStatus = "新增失败：\(error.localizedDescription)"
        }
    }

    private func saveCodexProfile(_ profile: CodexConfigProfile) {
        do {
            let saved = try persistedCodexProfile(profile)
            if selectedCodexProfileID == saved.id {
                applyCodexProfile(saved)
                try writeCodexSettings(updateSelectedProfile: false)
            }
            codexSaveStatus = selectedCodexProfileID == saved.id ? "已保存并更新当前配置" : "已保存配置：\(saved.name)"
        } catch {
            codexSaveStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func activateCodexProfile(_ profile: CodexConfigProfile) {
        do {
            let saved = try persistedCodexProfile(profile)
            selectedCodexProfileID = saved.id
            configProfiles.activeCodexProfileID = saved.id
            try persistConfigProfiles()
            applyCodexProfile(saved)
            try writeCodexSettings(updateSelectedProfile: false)
            codexSaveStatus = "已设为当前：\(saved.name)"
        } catch {
            codexSaveStatus = "切换失败：\(error.localizedDescription)"
        }
    }

    private func deleteCodexProfile(_ profile: CodexConfigProfile) {
        let wasSelected = selectedCodexProfileID == profile.id
        configProfiles.codexProfiles.removeAll { $0.id == profile.id }
        if wasSelected {
            selectedCodexProfileID = configProfiles.codexProfiles.first?.id
            configProfiles.activeCodexProfileID = selectedCodexProfileID
        }
        do {
            try persistConfigProfiles()
            if wasSelected,
               let selectedCodexProfileID,
               let next = configProfiles.codexProfiles.first(where: { $0.id == selectedCodexProfileID }) {
                applyCodexProfile(next)
                try writeCodexSettings(updateSelectedProfile: false)
            }
            codexSaveStatus = "已删除配置"
        } catch {
            codexSaveStatus = "删除失败：\(error.localizedDescription)"
        }
    }

    private func emptyClaudeProfile(named name: String) -> ClaudeRelayProfile {
        let now = Date()
        return ClaudeRelayProfile(
            id: UUID(),
            name: name,
            baseURL: "",
            authToken: "",
            model: "",
            haikuModel: "",
            sonnetModel: "",
            opusModel: "",
            httpProxy: "",
            httpsProxy: "",
            createdAt: now,
            updatedAt: now
        )
    }

    private func emptyCodexProfile(named name: String) -> CodexConfigProfile {
        let now = Date()
        return CodexConfigProfile(
            id: UUID(),
            name: name,
            authMode: CodexAuthMode.apiKey.rawValue,
            model: "",
            baseURL: "",
            apiKey: "",
            wireApi: "responses",
            createdAt: now,
            updatedAt: now
        )
    }

    private func persistedClaudeProfile(_ profile: ClaudeRelayProfile) throws -> ClaudeRelayProfile {
        guard let index = configProfiles.claudeRelayProfiles.firstIndex(where: { $0.id == profile.id }) else {
            throw Self.settingsError("配置不存在")
        }
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Self.settingsError("配置名称不能为空")
        }
        var saved = profile
        saved.name = trimmedName
        saved.createdAt = configProfiles.claudeRelayProfiles[index].createdAt
        saved.updatedAt = Date()
        configProfiles.claudeRelayProfiles[index] = saved
        try persistConfigProfiles()
        return saved
    }

    private func insertedClaudeProfile(_ profile: ClaudeRelayProfile) throws -> ClaudeRelayProfile {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Self.settingsError("配置名称不能为空")
        }
        var saved = profile
        let now = Date()
        saved.name = trimmedName
        saved.createdAt = now
        saved.updatedAt = now
        configProfiles.claudeRelayProfiles.insert(saved, at: 0)
        try persistConfigProfiles()
        return saved
    }

    private func persistedCodexProfile(_ profile: CodexConfigProfile) throws -> CodexConfigProfile {
        guard let index = configProfiles.codexProfiles.firstIndex(where: { $0.id == profile.id }) else {
            throw Self.settingsError("配置不存在")
        }
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Self.settingsError("配置名称不能为空")
        }
        var saved = profile
        saved.name = trimmedName
        saved.authMode = CodexAuthMode.apiKey.rawValue
        saved.wireApi = saved.wireApi.isEmpty ? "responses" : saved.wireApi
        saved.createdAt = configProfiles.codexProfiles[index].createdAt
        saved.updatedAt = Date()
        configProfiles.codexProfiles[index] = saved
        try persistConfigProfiles()
        return saved
    }

    private func insertedCodexProfile(_ profile: CodexConfigProfile) throws -> CodexConfigProfile {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Self.settingsError("配置名称不能为空")
        }
        var saved = profile
        let now = Date()
        saved.name = trimmedName
        saved.authMode = CodexAuthMode.apiKey.rawValue
        saved.wireApi = saved.wireApi.isEmpty ? "responses" : saved.wireApi
        saved.createdAt = now
        saved.updatedAt = now
        configProfiles.codexProfiles.insert(saved, at: 0)
        try persistConfigProfiles()
        return saved
    }

    private func applyClaudeProfile(_ profile: ClaudeRelayProfile) {
        anthropicBaseURL = profile.baseURL
        anthropicAuthToken = profile.authToken
        anthropicModel = profile.model
        anthropicHaikuModel = profile.haikuModel
        anthropicSonnetModel = profile.sonnetModel
        anthropicOpusModel = profile.opusModel
        httpProxy = profile.httpProxy
        httpsProxy = profile.httpsProxy
    }

    private func applyCodexProfile(_ profile: CodexConfigProfile) {
        codexAuthMode = .apiKey
        codexModel = profile.model
        codexBaseURL = profile.baseURL
        codexApiKey = profile.apiKey
        codexWireApi = profile.wireApi.isEmpty ? "responses" : profile.wireApi
    }

    private func currentClaudeProfile(named name: String, id: UUID = UUID()) -> ClaudeRelayProfile {
        let now = Date()
        return ClaudeRelayProfile(
            id: id,
            name: name,
            baseURL: anthropicBaseURL,
            authToken: anthropicAuthToken,
            model: anthropicModel,
            haikuModel: anthropicHaikuModel,
            sonnetModel: anthropicSonnetModel,
            opusModel: anthropicOpusModel,
            httpProxy: httpProxy,
            httpsProxy: httpsProxy,
            createdAt: now,
            updatedAt: now
        )
    }

    private func currentCodexProfile(named name: String, id: UUID = UUID()) -> CodexConfigProfile {
        let now = Date()
        return CodexConfigProfile(
            id: id,
            name: name,
            authMode: CodexAuthMode.apiKey.rawValue,
            model: codexModel,
            baseURL: codexBaseURL,
            apiKey: codexApiKey,
            wireApi: codexWireApi,
            createdAt: now,
            updatedAt: now
        )
    }

    private func updateSelectedClaudeProfile() throws {
        guard let selectedClaudeProfileID,
              let index = configProfiles.claudeRelayProfiles.firstIndex(where: { $0.id == selectedClaudeProfileID }) else { return }
        var updated = currentClaudeProfile(named: configProfiles.claudeRelayProfiles[index].name, id: selectedClaudeProfileID)
        updated.createdAt = configProfiles.claudeRelayProfiles[index].createdAt
        updated.updatedAt = Date()
        configProfiles.claudeRelayProfiles[index] = updated
        configProfiles.activeClaudeRelayProfileID = selectedClaudeProfileID
        try persistConfigProfiles()
    }

    private func updateSelectedCodexProfile() throws {
        guard let selectedCodexProfileID,
              let index = configProfiles.codexProfiles.firstIndex(where: { $0.id == selectedCodexProfileID }) else { return }
        var updated = currentCodexProfile(named: configProfiles.codexProfiles[index].name, id: selectedCodexProfileID)
        updated.createdAt = configProfiles.codexProfiles[index].createdAt
        updated.updatedAt = Date()
        configProfiles.codexProfiles[index] = updated
        configProfiles.activeCodexProfileID = selectedCodexProfileID
        try persistConfigProfiles()
    }

    private func nextProfileName(_ rawName: String, fallback: String, count: Int) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "\(fallback) \(count + 1)" : name
    }

    // MARK: - Claude Settings (relay)

    private func loadClaudeSettings() {
        guard let data = try? Data(contentsOf: Self.claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any] else { return }

        anthropicBaseURL = env["ANTHROPIC_BASE_URL"] as? String ?? ""
        anthropicAuthToken = env["ANTHROPIC_API_KEY"] as? String ?? env["ANTHROPIC_AUTH_TOKEN"] as? String ?? ""
        anthropicModel = env["ANTHROPIC_MODEL"] as? String ?? ""
        anthropicHaikuModel = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String ?? ""
        anthropicSonnetModel = env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String ?? ""
        anthropicOpusModel = env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String ?? ""
        httpProxy = env["HTTP_PROXY"] as? String ?? ""
        httpsProxy = env["HTTPS_PROXY"] as? String ?? ""
    }

    private func saveClaudeSettings() {
        relaySaveStatus = ""

        do {
            try writeClaudeSettings(updateSelectedProfile: true)
            relaySaveStatus = "保存成功"
        } catch {
            relaySaveStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func writeClaudeSettings(updateSelectedProfile: Bool) throws {
        let claudeDir = Self.claudeSettingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.claudeSettingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var env = (json["env"] as? [String: Any]) ?? [:]

        let fields: [(String, String)] = [
            ("ANTHROPIC_BASE_URL", anthropicBaseURL),
            ("ANTHROPIC_API_KEY", anthropicAuthToken),
            ("ANTHROPIC_MODEL", anthropicModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", anthropicHaikuModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", anthropicSonnetModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", anthropicOpusModel),
            ("HTTP_PROXY", httpProxy),
            ("HTTPS_PROXY", httpsProxy),
        ]

        for (key, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                env.removeValue(forKey: key)
            } else {
                env[key] = trimmed
            }
        }
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")

        json["env"] = env

        let outputData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try outputData.write(to: Self.claudeSettingsURL, options: .atomic)
        if updateSelectedProfile {
            try updateSelectedClaudeProfile()
        }
        modelService.reloadConfiguredModels()
        modelService.fetchClaudeModels(baseURL: anthropicBaseURL, apiKey: anthropicAuthToken)
    }

    // MARK: - Codex Settings

    private func loadCodexSettings() {
        codexApiKey = ""
        var configuredProvider = ""

        // 读取 config.toml
        if let text = try? String(contentsOf: Self.codexConfigURL, encoding: .utf8) {
            codexModel = parseTomlValue(text, key: "model") ?? ""
            configuredProvider = parseTomlValue(text, key: "model_provider") ?? ""

            let providerSection = configuredProvider.isEmpty ? "codevoke_custom" : configuredProvider
            if let customSection = extractTomlSection(text, section: "model_providers.\(providerSection)") {
                codexBaseURL = parseTomlValue(customSection, key: "base_url") ?? ""
                codexWireApi = parseTomlValue(customSection, key: "wire_api") ?? "responses"
            }
        }

        // 读取 auth.json
        if let data = try? Data(contentsOf: Self.codexAuthURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = json["OPENAI_API_KEY"] as? String {
            codexApiKey = key
        }

        codexAuthMode = .apiKey
    }

    private func saveCodexSettings() {
        codexSaveStatus = ""

        do {
            try writeCodexSettings(updateSelectedProfile: true)
            codexSaveStatus = "保存成功（中转站）"
        } catch {
            codexSaveStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func writeCodexSettings(updateSelectedProfile: Bool) throws {
        let codexDir = Self.codexConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let previousConfigData = try? Data(contentsOf: Self.codexConfigURL)
        let previousAuthData = try? Data(contentsOf: Self.codexAuthURL)

        do {
            let providerID = "codevoke_custom"
            codexAuthMode = .apiKey
            var configText = (try? String(contentsOf: Self.codexConfigURL, encoding: .utf8)) ?? ""
            configText = updateTomlValue(configText, key: "model", value: codexModel.isEmpty ? "gpt-5.5" : codexModel)
            configText = updateTomlValue(configText, key: "model_provider", value: providerID)
            configText = updateTomlSectionValue(configText, section: "model_providers.\(providerID)", key: "name", value: providerID)
            configText = updateTomlSectionValue(configText, section: "model_providers.\(providerID)", key: "base_url", value: codexBaseURL)
            configText = updateTomlSectionValue(configText, section: "model_providers.\(providerID)", key: "wire_api", value: codexWireApi)
            configText = updateTomlSectionRawValue(configText, section: "model_providers.\(providerID)", key: "requires_openai_auth", value: "true")

            var authJson: [String: Any] = [:]
            if let data = try? Data(contentsOf: Self.codexAuthURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                authJson = existing
            }

            let trimmedKey = codexApiKey.trimmingCharacters(in: .whitespaces)
            if trimmedKey.isEmpty {
                authJson.removeValue(forKey: "OPENAI_API_KEY")
            } else {
                authJson["OPENAI_API_KEY"] = trimmedKey
            }
            let authDataToWrite = try JSONSerialization.data(withJSONObject: authJson, options: [.prettyPrinted, .sortedKeys])

            try configText.write(to: Self.codexConfigURL, atomically: true, encoding: .utf8)
            try authDataToWrite.write(to: Self.codexAuthURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.codexAuthURL.path)

            if updateSelectedProfile {
                try updateSelectedCodexProfile()
            }
            modelService.reloadConfiguredModels()
            modelService.fetchCodexModels(baseURL: codexBaseURL, apiKey: codexApiKey)
        } catch {
            restoreFile(at: Self.codexConfigURL, data: previousConfigData)
            restoreFile(at: Self.codexAuthURL, data: previousAuthData)
            throw error
        }
    }

    // MARK: - TOML Helpers

    private func parseTomlValue(_ text: String, key: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var isInsideSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                isInsideSection = true
                continue
            }
            guard !isInsideSection else { continue }
            guard Self.isTomlAssignment(trimmed, key: key) else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            if rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"") {
                return String(rawValue.dropFirst().dropLast())
            }
            return rawValue
        }
        return nil
    }

    private func extractTomlSection(_ text: String, section: String) -> String? {
        let header = "[\(section)]"
        let lines = text.components(separatedBy: .newlines)
        var inSection = false
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header {
                inSection = true
                continue
            }
            if inSection {
                if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                    break
                }
                result.append(line)
            }
        }

        return inSection ? result.joined(separator: "\n") : nil
    }

    private func updateTomlValue(_ text: String, key: String, value: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var found = false
        var isInsideSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                isInsideSection = true
                result.append(line)
                continue
            }

            if !isInsideSection && Self.isTomlAssignment(trimmed, key: key) {
                result.append(tomlAssignment(key: key, value: value))
                found = true
            } else {
                result.append(line)
            }
        }

        if !found {
            let insertIndex = result.firstIndex { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            } ?? result.count
            result.insert(tomlAssignment(key: key, value: value), at: insertIndex)
        }

        return result.joined(separator: "\n")
    }

    private func updateTomlSectionValue(_ text: String, section: String, key: String, value: String) -> String {
        updateTomlSectionRawValue(text, section: section, key: key, value: Self.tomlQuoted(value))
    }

    private func updateTomlSectionRawValue(_ text: String, section: String, key: String, value: String) -> String {
        let header = "[\(section)]"
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var inSection = false
        var found = false
        var didFindSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header {
                inSection = true
                didFindSection = true
                result.append(line)
                continue
            }
            if inSection {
                if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                    // Leaving section — insert if not found
                    if !found && !value.isEmpty {
                        result.append("\(key) = \(value)")
                    }
                    inSection = false
                    result.append(line)
                    continue
                }
                if Self.isTomlAssignment(trimmed, key: key) {
                    if !value.isEmpty {
                        result.append("\(key) = \(value)")
                    }
                    found = true
                    continue
                }
            }
            result.append(line)
        }

        // If still in section at end of file
        if inSection && !found && !value.isEmpty {
            result.append("\(key) = \(value)")
        }

        if !didFindSection && !value.isEmpty {
            if !result.isEmpty && result.last?.isEmpty == false {
                result.append("")
            }
            result.append(header)
            result.append("\(key) = \(value)")
        }

        return result.joined(separator: "\n")
    }

    private func restoreFile(at url: URL, data: Data?) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func isTomlAssignment(_ line: String, key: String) -> Bool {
        line == key || line.hasPrefix("\(key) ") || line.hasPrefix("\(key)=")
    }

    private func tomlAssignment(key: String, value: String) -> String {
        "\(key) = \(Self.tomlQuoted(value))"
    }

    private nonisolated static func tomlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func modelMenuItems(models: [String], selectedModel: String) -> ModelMenuItems {
        var values = models
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            values.insert(selected, at: 0)
        }
        let uniqueModels = uniqueStrings(values)
        guard uniqueModels.count > Self.modelMenuLimit else {
            return ModelMenuItems(items: uniqueModels, hiddenCount: 0)
        }
        return ModelMenuItems(
            items: Array(uniqueModels.prefix(Self.modelMenuLimit)),
            hiddenCount: uniqueModels.count - Self.modelMenuLimit
        )
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Model Picker UI

    private func modelPicker(label: String, selection: Binding<String>, models: [String]) -> some View {
        let menuItems = modelMenuItems(models: models, selectedModel: selection.wrappedValue)
        return VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            HStack(spacing: 10) {
                TextField("模型 ID", text: selection)
                    .settingsTextFieldChrome()
                    .frame(maxWidth: .infinity)

                Menu {
                    Button("不设置") { selection.wrappedValue = "" }
                    Divider()
                    ForEach(menuItems.items, id: \.self) { model in
                        Button(model) { selection.wrappedValue = model }
                    }
                    if menuItems.hiddenCount > 0 {
                        Divider()
                        Text("已隐藏 \(menuItems.hiddenCount) 个模型，可直接输入模型 ID")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selection.wrappedValue.isEmpty ? "选择" : "切换")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(AppTheme.inputSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - Fetch Models

    private func fetchClaudeModels() {
        fetchClaudeModels(baseURL: anthropicBaseURL, authToken: anthropicAuthToken)
    }

    private func fetchClaudeModels(for profile: ClaudeRelayProfile) {
        fetchClaudeModels(baseURL: profile.baseURL, authToken: profile.authToken)
    }

    private func fetchClaudeModels(baseURL rawBaseURL: String, authToken rawAuthToken: String) {
        let baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return }

        isFetchingClaudeModels = true
        claudeModelList = []
        relaySaveStatus = "正在拉取模型…"

        let candidates = [
            baseURL.hasSuffix("/") ? baseURL + "v1/models" : baseURL + "/v1/models",
            baseURL.hasSuffix("/") ? baseURL + "models" : baseURL + "/models",
        ]
        let token = rawAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)

        claudeModelFetchTask?.cancel()
        claudeModelFetchTask = Task {
            let result = await fetchModelIDs(from: candidates, token: token, sendsAPIKeyHeader: true)
            guard !Task.isCancelled else { return }
            isFetchingClaudeModels = false
            switch result {
            case .success(let models):
                claudeModelList = models.sorted()
                relaySaveStatus = "已拉取 \(models.count) 个模型"
            case .failure(let message):
                relaySaveStatus = "拉取模型失败：\(message)"
            }
        }
    }

    private func fetchCodexModels() {
        fetchCodexModels(baseURL: codexBaseURL, apiKey: codexApiKey)
    }

    private func fetchCodexModels(for profile: CodexConfigProfile) {
        fetchCodexModels(baseURL: profile.baseURL, apiKey: profile.apiKey)
    }

    private func fetchCodexModels(baseURL rawBaseURL: String, apiKey rawAPIKey: String) {
        let baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return }

        isFetchingCodexModels = true
        codexModelList = []
        codexSaveStatus = "正在拉取模型…"

        let candidates = [
            baseURL.hasSuffix("/") ? baseURL + "models" : baseURL + "/models",
        ]
        let token = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        codexModelFetchTask?.cancel()
        codexModelFetchTask = Task {
            let result = await fetchModelIDs(from: candidates, token: token, sendsAPIKeyHeader: false)
            guard !Task.isCancelled else { return }
            isFetchingCodexModels = false
            switch result {
            case .success(let models):
                codexModelList = models.sorted()
                codexSaveStatus = "已拉取 \(models.count) 个模型"
            case .failure(let message):
                codexSaveStatus = "拉取模型失败：\(message)"
            }
        }
    }

    private func fetchModelIDs(from candidates: [String], token: String, sendsAPIKeyHeader: Bool) async -> ModelFetchOutcome {
        var failures: [String] = []
        for urlString in candidates {
            if Task.isCancelled { return .failure("") }
            guard let url = validModelURL(urlString) else {
                failures.append("URL 无效：\(urlString)")
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if sendsAPIKeyHeader {
                    request.setValue(token, forHTTPHeaderField: "x-api-key")
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse else {
                    failures.append("响应格式不支持")
                    continue
                }
                guard httpResp.statusCode == 200 else {
                    failures.append("HTTP \(httpResp.statusCode)")
                    continue
                }
                guard let models = parseModelListResponse(data) else {
                    failures.append("响应格式不支持")
                    continue
                }
                return .success(models.removingDuplicateValues())
            } catch {
                if Task.isCancelled { return .failure("") }
                failures.append(networkErrorDescription(error))
            }
        }
        return .failure(failures.removingDuplicateValues().joined(separator: "；"))
    }

    private func validModelURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private func networkErrorDescription(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet:
            return "网络不可用"
        case .timedOut:
            return "网络超时"
        case .cannotFindHost, .cannotConnectToHost:
            return "无法连接服务器"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "TLS 连接失败"
        case .appTransportSecurityRequiresSecureConnection:
            return "HTTP 请求被系统安全策略拦截，请重新构建应用后重试"
        case .unsupportedURL, .badURL:
            return "URL 无效"
        default:
            return urlError.localizedDescription
        }
    }

    private func parseModelListResponse(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = json as? [String: Any], let dataArray = object["data"] as? [[String: Any]] {
            let ids = dataArray.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : ids
        }
        if let arr = json as? [[String: Any]] {
            let ids = arr.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : ids
        }
        return nil
    }
}

private extension Array where Element == String {
    func removingDuplicateValues() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(count)
        for value in self where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

private extension View {
    func settingsTextFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(AppTheme.inputSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }
}

private struct SettingsSidebarReturnButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(configuration.isPressed ? AppTheme.buttonPressedSurface : AppTheme.controlSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SettingsPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, compact ? 11 : 16)
            .frame(height: compact ? 32 : 40)
            .background(configuration.isPressed ? AppTheme.buttonPressedSurface : AppTheme.buttonSurface)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SettingsSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 30 : 38)
            .background(configuration.isPressed ? AppTheme.buttonPressedSurface : AppTheme.secondaryCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SettingsDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background {
                if isEnabled {
                    configuration.isPressed ? Color.red.opacity(0.78) : Color.red.opacity(0.92)
                } else {
                    AppTheme.buttonSurface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.hairline, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
