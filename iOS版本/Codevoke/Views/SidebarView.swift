import SwiftUI
import UIKit
import ChatCore

struct ChatSidebarState: Equatable {
    var connectionStatus: String
    var projects: [PanelProjectDTO]
    var models: [PanelModelDTO]
    var selectedCLI: String
    var selectedModelID: String
    var selectedModelTitle: String
    var sessions: [PanelSessionDTO]
    var selectedProjectID: UUID?
    var selectedSessionID: UUID?
    var currentFilePath: String
    var parentFilePath: String?
    var fileEntries: [RemoteProjectFileEntry]
    var fileError: String?
    var isRefreshing: Bool
    var isLoadingMessages: Bool
    var isLoadingFiles: Bool
    var hasSelectedProject: Bool

    var emptySessionTitle: String {
        hasSelectedProject ? L10n.string("暂无聊天") : L10n.string("选择项目后查看聊天记录")
    }
}

struct SidebarView: View, Equatable {
    let state: ChatSidebarState
    let startNewChat: () -> Void
    let refresh: () -> Void
    let selectProject: (PanelProjectDTO) -> Void
    let selectModel: (PanelModelDTO) -> Void
    let selectSession: (PanelSessionDTO) -> Void
    let openParentDirectory: () -> Void
    let openFileEntry: (RemoteProjectFileEntry) -> Void
    let copyFilePath: (RemoteProjectFileEntry) -> Void

    @State private var safeAreaInsets: EdgeInsets = .init()
    @State private var windowSize: CGSize = .zero
    @State private var isModelPickerPresented = false

    static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        GlassCard(cornerRadius: 30) {
            VStack(alignment: .leading, spacing: 18) {
                scrollableSections
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.top, sidebarTopPadding)
        .padding(.bottom, sidebarBottomPadding)
        .background {
            WindowSafeAreaReader(insets: $safeAreaInsets, size: $windowSize)
                .frame(width: 0, height: 0)
        }
    }

    private var sidebarTopPadding: CGFloat {
        let statusBarHeight = UIApplication.shared.codevokeStatusBarHeight
        let observedTopInset = max(safeAreaInsets.top, statusBarHeight)
        let fallback = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(56) : CGFloat(0)
        let measuredPadding = max(0, (observedTopInset > 0 ? observedTopInset : fallback) - 6) + 12
        let minimumPadding = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(104) : CGFloat(32)
        return max(measuredPadding, minimumPadding)
    }

    private var sidebarBottomPadding: CGFloat {
        let fallback = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(34) : CGFloat(0)
        let measuredPadding = max(safeAreaInsets.bottom, fallback) + 12
        let minimumPadding = UIDevice.current.userInterfaceIdiom == .phone ? CGFloat(112) : CGFloat(32)
        return max(measuredPadding, minimumPadding)
    }

    private var scrollableSections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                projectSection
                modelSection
                sessionSection
                fileSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button(action: startNewChat) {
                quickActionLabel("新对话", icon: "plus")
            }
            .buttonStyle(.codevokePress)

            Button(action: refresh) {
                quickActionLabel(state.isRefreshing ? "刷新中" : "刷新", icon: "arrow.clockwise")
            }
            .buttonStyle(.codevokePress)
            .disabled(state.isRefreshing)
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("项目")
            if state.projects.isEmpty {
                placeholderRow("暂无项目", icon: "folder")
            } else {
                ForEach(Array(state.projects.prefix(5)), id: \.id) { project in
                    Button {
                        guard project.id != state.selectedProjectID || !state.isLoadingMessages else { return }
                        selectProject(project)
                    } label: {
                        sidebarRow(
                            title: project.name.isEmpty ? "未命名项目" : project.name,
                            subtitle: project.path.isEmpty ? "—" : project.path,
                            icon: "folder.fill",
                            selected: project.id == state.selectedProjectID
                        )
                    }
                    .buttonStyle(.codevokePress)
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("模型")
            if state.models.isEmpty {
                placeholderRow("暂无模型", icon: "cpu")
            } else {
                Button {
                    isModelPickerPresented.toggle()
                } label: {
                    sidebarRow(
                        title: state.selectedModelTitle.isEmpty ? "默认模型" : state.selectedModelTitle,
                        subtitle: state.selectedModelID.isEmpty ? "点击选择模型" : state.selectedModelID,
                        icon: "cpu.fill",
                        selected: false
                    )
                }
                .buttonStyle(.codevokePress)

                if isModelPickerPresented {
                    VStack(spacing: 6) {
                        ForEach(state.models, id: \.id) { model in
                            Button {
                                selectModel(model)
                                isModelPickerPresented = false
                            } label: {
                                modelPickerRow(model)
                            }
                            .buttonStyle(.codevokePress)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.codevokeGlassStroke, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("聊天记录")
                Spacer()
                if state.isLoadingMessages {
                    ProgressView()
                        .controlSize(.mini)
                }
                Button(action: startNewChat) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codevokeInk)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.codevokePress)
                .accessibilityLabel(L10n.string("新对话"))
            }
            .frame(maxWidth: .infinity)
            if state.sessions.isEmpty {
                placeholderRow(state.emptySessionTitle, icon: "text.bubble")
            } else {
                ForEach(Array(state.sessions.prefix(8)), id: \.id) { session in
                    Button {
                        guard !state.isLoadingMessages || session.id != state.selectedSessionID else { return }
                        selectSession(session)
                    } label: {
                        sidebarRow(
                            title: session.title.isEmpty ? "未命名会话" : session.title,
                            subtitle: state.isLoadingMessages && session.id == state.selectedSessionID ? "加载中..." : (session.statusText.isEmpty ? "—" : session.statusText),
                            icon: "bubble.left.and.bubble.right.fill",
                            selected: session.id == state.selectedSessionID
                        )
                    }
                    .buttonStyle(.codevokePress)
                }
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(state.currentFilePath.isEmpty ? "文件" : state.currentFilePath)
                    .lineLimit(1)
                Spacer()
                if state.isLoadingFiles {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                fileRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var fileRows: some View {
        if !state.hasSelectedProject {
            placeholderRow("先选择项目", icon: "folder", subtitle: "选好项目后会显示文件")
        } else if let fileError = state.fileError {
            sidebarRow(title: "文件读取失败", subtitle: fileError, icon: "exclamationmark.triangle", selected: false)
                .opacity(0.72)
        } else if state.isLoadingFiles && state.fileEntries.isEmpty {
            sidebarRow(title: "正在读取文件", subtitle: "请稍等", icon: "hourglass", selected: false)
                .opacity(0.72)
        } else {
            if state.parentFilePath != nil {
                Button(action: openParentDirectory) {
                    sidebarRow(title: "..", subtitle: "上一级", icon: "arrow.up", selected: false)
                }
                .buttonStyle(.codevokePress)
            }
            if state.fileEntries.isEmpty && !state.isLoadingFiles {
                placeholderRow("空文件夹", icon: "folder", subtitle: "此目录没有可显示的内容")
            } else {
                ForEach(state.fileEntries) { entry in
                    Button {
                        if entry.isDirectory {
                            openFileEntry(entry)
                        } else {
                            copyFilePath(entry)
                        }
                    } label: {
                        sidebarRow(
                            title: entry.name,
                            subtitle: entry.isDirectory ? "文件夹" : "文件",
                            icon: entry.isDirectory ? "folder.fill" : "doc.text",
                            selected: false
                        )
                    }
                    .buttonStyle(.codevokePress)
                    .contextMenu {
                        if entry.isDirectory {
                            Button {
                                openFileEntry(entry)
                            } label: {
                                Label(L10n.string("打开文件夹"), systemImage: "folder")
                            }
                        }
                        Button {
                            copyFilePath(entry)
                        } label: {
                            Label(L10n.string("复制绝对路径"), systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.key(title))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.codevokeMuted)
    }

    private func quickActionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(L10n.key(title))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.codevokeInk)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func placeholderRow(_ title: String, icon: String, subtitle: String = "—") -> some View {
        sidebarRow(title: title, subtitle: subtitle, icon: icon, selected: false)
            .opacity(0.72)
    }

    private func sidebarRow(title: String, subtitle: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(selected ? Color.white : Color.codevokeMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key(title))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(L10n.key(subtitle))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .opacity(0.65)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.codevokeInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(selected ? Color.black : Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: selected ? 20 : 18, style: .continuous))
    }

    private func modelPickerRow(_ model: PanelModelDTO) -> some View {
        let selected = model.id == state.selectedModelID && model.cli == state.selectedCLI
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.codevokeMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? model.id : model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(model.id)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .opacity(0.68)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.codevokeInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(selected ? Color.black : Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
