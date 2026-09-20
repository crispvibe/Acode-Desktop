import AppKit
import Darwin
import SwiftUI

@main
struct CodevokeApp: App {
    @NSApplicationDelegateAdaptor(RemoteChatAppDelegate.self) private var remoteChatAppDelegate
    @StateObject private var appState = AppState()
    @StateObject private var modelService = ChatModelService()
    @StateObject private var chatRuntimeStore = ChatRuntimeStore()

    init() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        _ = signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(modelService)
                .environmentObject(chatRuntimeStore)
                .background(WindowConfigurator())
                .onAppear {
                    RemoteVNCWiring.install(runtimeStore: chatRuntimeStore, appState: appState, modelService: modelService)
                    triggerModelFetch()
                    appState.showFolderPermissionOnboardingIfNeeded()
                }
                .onChange(of: appState.settings.apiBaseURL) { _, _ in triggerModelFetch() }
                .onChange(of: appState.settings.apiKey) { _, _ in triggerModelFetch() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    chatRuntimeStore.prepareForApplicationTermination()
                    ProjectStore.flushPendingFileTreeState()
                    ChatSessionStore.flushPendingDrafts()
                }
        }
        .defaultSize(width: 1380, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Codevoke") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }

            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("设置…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    appState.saveSelectedTab()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState.selectedTab?.isDirty != true)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(modelService)
                .environmentObject(chatRuntimeStore)
        }
    }

    private func triggerModelFetch() {
        let settings = appState.settings
        modelService.reloadConfiguredModels()
        modelService.fetchClaudeModels(baseURL: settings.apiBaseURL, apiKey: settings.apiKey)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.isRestorable = false
        localizeMenuBar()
    }

    private func localizeMenuBar() {
        guard let mainMenu = NSApp.mainMenu else { return }
        localize(menu: mainMenu)
    }

    private func localize(menu: NSMenu) {
        for item in menu.items {
            item.title = localizedMenuTitle(item.title)
            if let submenu = item.submenu {
                submenu.title = localizedMenuTitle(submenu.title)
                localize(menu: submenu)
            }
        }
    }

    private func localizedMenuTitle(_ title: String) -> String {
        let appName = "Codevoke"
        let replacements = [
            "File": "文件",
            "Edit": "编辑",
            "View": "显示",
            "Window": "窗口",
            "Help": "帮助",
            "Services": "服务",
            "Settings…": "设置…",
            "Preferences…": "设置…",
            "Hide Others": "隐藏其他",
            "Show All": "全部显示",
            "Close": "关闭",
            "Close Window": "关闭窗口",
            "Save": "保存",
            "Save As…": "另存为…",
            "Revert To": "复原到",
            "Page Setup…": "页面设置…",
            "Print…": "打印…",
            "Undo": "撤销",
            "Redo": "重做",
            "Cut": "剪切",
            "Copy": "复制",
            "Paste": "粘贴",
            "Paste and Match Style": "粘贴并匹配样式",
            "Delete": "删除",
            "Select All": "全选",
            "Find": "查找",
            "Find…": "查找…",
            "Find and Replace…": "查找和替换…",
            "Find Next": "查找下一个",
            "Find Previous": "查找上一个",
            "Use Selection for Find": "用所选内容查找",
            "Jump to Selection": "跳到所选内容",
            "Spelling and Grammar": "拼写和语法",
            "Show Spelling and Grammar": "显示拼写和语法",
            "Check Document Now": "立即检查文稿",
            "Check Spelling While Typing": "键入时检查拼写",
            "Check Grammar With Spelling": "随拼写检查语法",
            "Correct Spelling Automatically": "自动更正拼写",
            "Substitutions": "替换",
            "Show Substitutions": "显示替换",
            "Smart Copy/Paste": "智能复制/粘贴",
            "Smart Quotes": "智能引号",
            "Smart Dashes": "智能破折号",
            "Smart Links": "智能链接",
            "Data Detectors": "数据检测器",
            "Text Replacement": "文本替换",
            "Transformations": "转换",
            "Make Upper Case": "转为大写",
            "Make Lower Case": "转为小写",
            "Capitalize": "首字母大写",
            "Speech": "语音",
            "Start Speaking": "开始朗读",
            "Stop Speaking": "停止朗读",
            "Start Dictation…": "开始听写…",
            "Emoji & Symbols": "表情与符号",
            "Show Toolbar": "显示工具栏",
            "Customize Toolbar…": "自定义工具栏…",
            "Enter Full Screen": "进入全屏幕",
            "Exit Full Screen": "退出全屏幕",
            "Minimize": "最小化",
            "Zoom": "缩放",
            "Bring All to Front": "全部移到最前",
            "Show Previous Tab": "显示上一个标签页",
            "Show Next Tab": "显示下一个标签页",
            "Move Tab to New Window": "将标签页移到新窗口",
            "Merge All Windows": "合并所有窗口"
        ]
        if title == "About \(appName)" { return "关于 \(appName)" }
        if title == "Hide \(appName)" { return "隐藏 \(appName)" }
        if title == "Quit \(appName)" { return "退出 \(appName)" }
        if title == "\(appName) Help" { return "\(appName) 帮助" }
        return replacements[title] ?? title
    }
}
