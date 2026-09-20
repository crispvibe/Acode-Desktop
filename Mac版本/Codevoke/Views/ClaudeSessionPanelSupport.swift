import AppKit
import Combine
import ChatUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatTranscriptStructureKey: Equatable {
    struct MessageFingerprint: Equatable {
        let id: UUID
        let kind: ChatMessageKind
        let isStreaming: Bool
        let streamingTextLength: Int
        let title: String
        let subtitle: String
        let status: String
        let requestID: String?
        let attachmentsSignature: String
    }

    static let empty = ChatTranscriptStructureKey(projectKey: "", isLoading: false, messages: [])

    let projectKey: String
    let isLoading: Bool
    let messages: [MessageFingerprint]
}

enum ChatTranscriptItem: Identifiable, Equatable {
    case message(ChatMessage)
    case toolGroup(ToolInvocationGroup)
    case toolBatch(ToolBatchGroup)
    case loading

    var id: String {
        switch self {
        case .message(let message):
            "message-\(message.id.uuidString)"
        case .toolGroup(let group):
            group.id
        case .toolBatch(let batch):
            batch.id
        case .loading:
            "loading"
        }
    }

    var isStreaming: Bool {
        switch self {
        case .message(let message):
            message.isStreaming
        case .toolGroup(let group):
            group.primary.isStreaming || group.responses.contains(where: \.isStreaming)
        case .toolBatch(let batch):
            batch.isStreaming
        case .loading:
            true
        }
    }

    var lastMessageID: UUID? {
        switch self {
        case .message(let message):
            message.id
        case .toolGroup(let group):
            (group.responses.last ?? group.primary).id
        case .toolBatch(let batch):
            batch.groups.last.map { ($0.responses.last ?? $0.primary).id }
        case .loading:
            nil
        }
    }
}

struct EquatableTranscriptItemRow: View, Equatable {
    let item: ChatTranscriptItem
    let expandedMessageIDs: Set<UUID>
    let collapsedInlineToolIDs: Set<UUID>
    let expandedToolBatchIDs: Set<String>
    let isRunning: Bool
    let lastVisibleMessageID: UUID?
    let loadingText: String
    let content: (ChatTranscriptItem) -> AnyView

    var body: some View {
        content(item)
            .textSelection(.enabled)
    }

    static func == (lhs: EquatableTranscriptItemRow, rhs: EquatableTranscriptItemRow) -> Bool {
        // NOTE: deliberately NOT keyed on a global streaming counter. The streaming row updates
        // itself via its store-observing StreamingAssistantTextView, and a streaming tool/diff
        // row changes its own fingerprint (textLength). Keying on a global revision forced EVERY
        // visible row to re-render on EVERY delta — O(N) per token — which was the main streaming
        // stutter. Per-item fingerprints below capture the changes that actually matter.
        let lhsFingerprint = transcriptItemFingerprint(lhs.item)
        let rhsFingerprint = transcriptItemFingerprint(rhs.item)
        return lhs.lastVisibleMessageID == rhs.lastVisibleMessageID
            && lhs.isRunning == rhs.isRunning
            && (lhsFingerprint.kind != .loading || lhs.loadingText == rhs.loadingText)
            && lhs.expandedMessageIDs == rhs.expandedMessageIDs
            && lhs.collapsedInlineToolIDs == rhs.collapsedInlineToolIDs
            && lhs.expandedToolBatchIDs == rhs.expandedToolBatchIDs
            && lhsFingerprint == rhsFingerprint
    }
}

struct ChatTranscriptItemFingerprint: Equatable {
    let kind: Kind
    let primary: ChatMessageFingerprint
    let responses: [ChatMessageFingerprint]

    enum Kind: Equatable {
        case message
        case toolGroup
        case toolBatch
        case loading
    }
}

struct ChatMessageFingerprint: Equatable {
    let id: UUID
    let kind: ChatMessageKind
    let isStreaming: Bool
    let status: String
    let title: String
    let subtitle: String
    let textLength: Int
    let requestID: String?
    let interactiveStatus: ChatInteractiveStatus?
    let attachmentsSignature: String

    init(_ message: ChatMessage) {
        self.id = message.id
        self.kind = message.kind
        self.isStreaming = message.isStreaming
        self.status = message.status
        self.title = message.title
        self.subtitle = message.subtitle
        self.textLength = message.text.utf8.count
        self.requestID = message.requestID
        self.interactiveStatus = message.interactiveRequest?.status
        self.attachmentsSignature = chatAttachmentSignature(message.attachments)
    }
}

func chatAttachmentSignature(_ attachments: [ChatMessageAttachment]) -> String {
    attachments
        .map { "\($0.kind.rawValue):\($0.filename):\($0.path):\($0.thumbnailData?.count ?? 0)" }
        .joined(separator: "|")
}

func transcriptItemFingerprint(_ item: ChatTranscriptItem) -> ChatTranscriptItemFingerprint {
    switch item {
    case .message(let message):
        return ChatTranscriptItemFingerprint(kind: .message, primary: ChatMessageFingerprint(message), responses: [])
    case .toolGroup(let group):
        return ChatTranscriptItemFingerprint(
            kind: .toolGroup,
            primary: ChatMessageFingerprint(group.primary),
            responses: group.responses.map(ChatMessageFingerprint.init)
        )
    case .toolBatch(let batch):
        let all = batch.groups.flatMap { [$0.primary] + $0.responses }
        return ChatTranscriptItemFingerprint(
            kind: .toolBatch,
            primary: ChatMessageFingerprint(all.first ?? loadingPlaceholderMessage),
            responses: all.dropFirst().map(ChatMessageFingerprint.init)
        )
    case .loading:
        return ChatTranscriptItemFingerprint(kind: .loading, primary: ChatMessageFingerprint(loadingPlaceholderMessage), responses: [])
    }
}

let loadingPlaceholderMessage = ChatMessage(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000FEED") ?? UUID(),
    sessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000DEAD") ?? UUID(),
    kind: .system,
    text: "loading"
)

struct ToolInvocationGroup: Identifiable, Equatable {
    let primary: ChatMessage
    let responses: [ChatMessage]

    var id: String { "tool-group-\(primary.id.uuidString)" }

    var detailText: String {
        ([primary] + responses)
            .map { message in
                message.isTerminalTool ? message.terminalDetailText : message.toolDetailText
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct ToolBatchGroup: Identifiable, Equatable {
    let groups: [ToolInvocationGroup]

    var id: String { "tool-batch-\(groups.first?.primary.id.uuidString ?? "empty")" }

    var isStreaming: Bool {
        groups.contains { $0.primary.isStreaming || $0.responses.contains(where: \.isStreaming) }
    }
}

struct TranscriptContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ComposerChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DecisionOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranscriptScrollObserver: NSViewRepresentable {
    let onBottomStateChanged: (Bool) -> Void
    let onNearTop: () -> Void
    let onUserScroll: () -> Void
    let shouldFollowBottom: Bool
    let scrollToBottomToken: Int

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onBottomStateChanged = onBottomStateChanged
        view.onNearTop = onNearTop
        view.onUserScroll = onUserScroll
        view.shouldFollowBottom = shouldFollowBottom
        view.lastScrollToBottomToken = scrollToBottomToken
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onBottomStateChanged = onBottomStateChanged
        nsView.onNearTop = onNearTop
        nsView.onUserScroll = onUserScroll
        nsView.shouldFollowBottom = shouldFollowBottom
        nsView.attachIfNeeded()
        if nsView.lastScrollToBottomToken != scrollToBottomToken {
            nsView.lastScrollToBottomToken = scrollToBottomToken
            if shouldFollowBottom {
                nsView.scheduleScrollDocumentToBottom()
            } else {
                nsView.cancelScrollDocumentToBottom()
            }
        } else if !shouldFollowBottom {
            nsView.cancelScrollDocumentToBottom()
        }
    }

    final class ObserverView: NSView {
        var onBottomStateChanged: ((Bool) -> Void)?
        var onNearTop: (() -> Void)?
        var onUserScroll: (() -> Void)?
        var shouldFollowBottom = true
        var lastScrollToBottomToken: Int = 0
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var willStartLiveScrollObserver: NSObjectProtocol?
        private var didLiveScrollObserver: NSObjectProtocol?
        private var scrollWheelMonitor: Any?
        private var lastIsAtBottom: Bool?
        private var scrollToBottomRetryCount = 0
        private var pendingScrollToBottomWorkItem: DispatchWorkItem?
        private let bottomTolerance: CGFloat = 4
        private let topTolerance: CGFloat = 24
        private let userReviewDistanceThreshold: CGFloat = 96
        private let scrollToBottomMaxRetries = 6
        private let scrollToBottomRetryDelays: [TimeInterval] = [0.0, 0.05, 0.12, 0.24, 0.48, 0.8]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
            publishBottomState()
        }

        deinit {
            pendingScrollToBottomWorkItem?.cancel()
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let willStartLiveScrollObserver {
                NotificationCenter.default.removeObserver(willStartLiveScrollObserver)
            }
            if let didLiveScrollObserver {
                NotificationCenter.default.removeObserver(didLiveScrollObserver)
            }
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor)
            }
        }

        func scheduleScrollDocumentToBottom() {
            guard shouldFollowBottom else { return }
            pendingScrollToBottomWorkItem?.cancel()
            scrollToBottomRetryCount = 0
            scheduleScrollAttempt()
        }

        func cancelScrollDocumentToBottom() {
            pendingScrollToBottomWorkItem?.cancel()
            pendingScrollToBottomWorkItem = nil
            scrollToBottomRetryCount = 0
        }

        private func scheduleScrollAttempt() {
            guard shouldFollowBottom, scrollToBottomRetryCount < scrollToBottomMaxRetries else { return }
            let delay = scrollToBottomRetryDelays[min(scrollToBottomRetryCount, scrollToBottomRetryDelays.count - 1)]
            scrollToBottomRetryCount += 1
            let workItem = DispatchWorkItem { [weak self] in
                self?.performScrollDocumentToBottom()
            }
            pendingScrollToBottomWorkItem = workItem
            if delay <= 0 {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func performScrollDocumentToBottom() {
            guard shouldFollowBottom else {
                cancelScrollDocumentToBottom()
                return
            }
            guard let scrollView = observedScrollView ?? nearestScrollView() else {
                scheduleScrollAttempt()
                return
            }
            observedScrollView = scrollView
            guard let documentView = scrollView.documentView else {
                scheduleScrollAttempt()
                return
            }
            documentView.layoutSubtreeIfNeeded()
            let documentBounds = documentView.bounds
            let viewportHeight = scrollView.contentView.bounds.height
            guard documentBounds.height > 0, viewportHeight > 0 else {
                scheduleScrollAttempt()
                return
            }
            let targetY: CGFloat
            if documentView.isFlipped {
                targetY = max(0, documentBounds.maxY - viewportHeight)
            } else {
                targetY = max(0, documentBounds.minY)
            }
            let target = NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY)
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            publishBottomState()
            // Schedule a follow-up attempt because LazyVStack may still be materializing
            // additional rows; subsequent scrolls land on the new (taller) content.
            if scrollToBottomRetryCount < scrollToBottomMaxRetries {
                scheduleScrollAttempt()
            }
        }

        func attachIfNeeded() {
            guard observedScrollView == nil else { return }
            guard let scrollView = nearestScrollView() else { return }
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishBottomState()
            }
            willStartLiveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.publishUserScroll()
            }
            didLiveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.publishUserScroll()
            }
            scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scrollView] event in
                guard let self, let scrollView else { return event }
                if self.isEventInsideScrollView(event, scrollView: scrollView) {
                    self.publishUserScroll()
                }
                return event
            }
        }

        func publishBottomState() {
            guard let scrollView = observedScrollView ?? nearestScrollView() else { return }
            observedScrollView = scrollView
            guard let metrics = scrollMetrics(in: scrollView) else { return }
            let isAtBottom = metrics.contentFits || metrics.distanceFromBottom <= bottomTolerance
            guard lastIsAtBottom != isAtBottom else { return }
            lastIsAtBottom = isAtBottom
            onBottomStateChanged?(isAtBottom)
        }

        private func publishUserScroll() {
            if let scrollView = observedScrollView ?? nearestScrollView(),
               let metrics = scrollMetrics(in: scrollView),
               !metrics.contentFits {
                if metrics.distanceFromTop <= topTolerance {
                    onNearTop?()
                }
                if metrics.distanceFromBottom > userReviewDistanceThreshold {
                    cancelScrollDocumentToBottom()
                    onUserScroll?()
                }
            }
            publishBottomState()
        }

        private func scrollMetrics(in scrollView: NSScrollView) -> (distanceFromTop: CGFloat, distanceFromBottom: CGFloat, contentFits: Bool)? {
            guard let documentView = scrollView.documentView else { return nil }
            let visibleRect = documentView.visibleRect
            let documentBounds = documentView.bounds
            let distanceFromTop: CGFloat
            let distanceFromBottom: CGFloat
            if documentView.isFlipped {
                distanceFromTop = visibleRect.minY - documentBounds.minY
                distanceFromBottom = documentBounds.maxY - visibleRect.maxY
            } else {
                distanceFromTop = documentBounds.maxY - visibleRect.maxY
                distanceFromBottom = visibleRect.minY - documentBounds.minY
            }
            return (max(0, distanceFromTop), max(0, distanceFromBottom), documentBounds.height <= visibleRect.height + bottomTolerance)
        }

        private func isEventInsideScrollView(_ event: NSEvent, scrollView: NSScrollView) -> Bool {
            guard event.window === scrollView.window else { return false }
            let location = scrollView.convert(event.locationInWindow, from: nil)
            return scrollView.bounds.contains(location)
        }

        private func nearestScrollView() -> NSScrollView? {
            if let enclosingScrollView {
                return enclosingScrollView
            }
            var current = superview
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }
    }
}

struct ToolCodePreview {
    struct Line: Identifiable {
        let id = UUID()
        let marker: String
        let text: String
        let tint: Color
    }

    let title: String
    let path: String
    let stats: String
    let changeStats: ToolChangeStats
    let lines: [Line]
}

struct ToolChangeStats {
    let added: Int
    let removed: Int

    var hasChanges: Bool {
        added > 0 || removed > 0
    }
}

struct FileReference: Identifiable, Hashable {
    let raw: String
    let path: String
    let line: Int?
    let column: Int?

    init(raw: String? = nil, path: String, line: Int? = nil, column: Int? = nil) {
        self.raw = raw ?? path
        self.path = path
        self.line = line
        self.column = column
    }

    var id: String { "\(path):\(line ?? 0):\(column ?? 0)" }

    var displayName: String {
        let fileName = (path as NSString).lastPathComponent
        guard let line else { return fileName }
        if let column { return "\(fileName):\(line):\(column)" }
        return "\(fileName):\(line)"
    }

    var openURL: URL? {
        var components = URLComponents()
        components.scheme = "codevoke-file"
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
        components.queryItems = items
        return components.url
    }

    init?(openURL: URL) {
        guard openURL.scheme == "codevoke-file" else { return nil }
        let components = URLComponents(url: openURL, resolvingAgainstBaseURL: false)
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        let line = components?.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        let column = components?.queryItems?.first(where: { $0.name == "column" })?.value.flatMap(Int.init)
        self.init(path: path, line: line, column: column)
    }
}

struct FileLanguageStyle {
    let label: String
    let symbol: String
    let tint: Color

    static func forPath(_ path: String) -> FileLanguageStyle {
        let key = languageKey(for: path)
        switch key {
        case "swift", "xib", "storyboard", "xcconfig", "entitlements", "xcprivacy", "pbxproj":
            return FileLanguageStyle(label: "Swift", symbol: "chevron.left.forwardslash.chevron.right", tint: .orange)
        case "js", "jsx", "mjs", "cjs":
            return FileLanguageStyle(label: "JS", symbol: "curlybraces", tint: .yellow)
        case "ts", "tsx":
            return FileLanguageStyle(label: "TS", symbol: "curlybraces", tint: .blue)
        case "py", "pyw", "ipynb":
            return FileLanguageStyle(label: "Python", symbol: "chevron.left.forwardslash.chevron.right", tint: .blue)
        case "go":
            return FileLanguageStyle(label: "Go", symbol: "network", tint: .cyan)
        case "rs":
            return FileLanguageStyle(label: "Rust", symbol: "gearshape.2", tint: .brown)
        case "java", "kt", "kts", "scala", "gradle":
            return FileLanguageStyle(label: "JVM", symbol: "cup.and.saucer", tint: .red)
        case "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "cs", "fs", "vb":
            return FileLanguageStyle(label: "Native", symbol: "hammer", tint: .indigo)
        case "rb":
            return FileLanguageStyle(label: "Ruby", symbol: "diamond", tint: .red)
        case "php":
            return FileLanguageStyle(label: "PHP", symbol: "globe", tint: .indigo)
        case "r":
            return FileLanguageStyle(label: "R", symbol: "chart.xyaxis.line", tint: .blue)
        case "lua":
            return FileLanguageStyle(label: "Lua", symbol: "moon", tint: .blue)
        case "dart":
            return FileLanguageStyle(label: "Dart", symbol: "paperplane", tint: .cyan)
        case "ex", "exs":
            return FileLanguageStyle(label: "Elixir", symbol: "hexagon", tint: .purple)
        case "erl", "hrl":
            return FileLanguageStyle(label: "Erlang", symbol: "antenna.radiowaves.left.and.right", tint: .red)
        case "clj", "cljs":
            return FileLanguageStyle(label: "Clojure", symbol: "leaf", tint: .green)
        case "zig":
            return FileLanguageStyle(label: "Zig", symbol: "bolt", tint: .orange)
        case "html", "htm", "css", "scss", "sass", "less", "vue", "svelte":
            return FileLanguageStyle(label: "Web", symbol: "safari", tint: .pink)
        case "json", "jsonc", "plist", "xml", "yaml", "yml", "toml", "properties", "ini", "conf", "config", "gitignore", "editorconfig":
            return FileLanguageStyle(label: "Config", symbol: "slider.horizontal.3", tint: .purple)
        case "md", "markdown", "txt", "rtf":
            return FileLanguageStyle(label: "Doc", symbol: "doc.richtext", tint: .blue)
        case "sh", "bash", "zsh", "fish", "ps1", "makefile", "dockerfile", "env":
            return FileLanguageStyle(label: "Shell", symbol: "terminal", tint: .green)
        case "sql", "graphql", "gql", "proto", "csv", "tsv":
            return FileLanguageStyle(label: "Data", symbol: "tablecells", tint: .mint)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf":
            return FileLanguageStyle(label: "Asset", symbol: "photo", tint: .teal)
        case "diff", "patch":
            return FileLanguageStyle(label: "Diff", symbol: "plus.forwardslash.minus", tint: .orange)
        case "lock", "log":
            return FileLanguageStyle(label: "Log", symbol: "doc.text.magnifyingglass", tint: .secondary)
        default:
            return FileLanguageStyle(label: "File", symbol: "doc.text", tint: .secondary)
        }
    }

    private static func languageKey(for path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
        if name == "makefile" || name.hasPrefix("makefile.") { return "makefile" }
        if name.hasPrefix(".env") { return "env" }
        return name
    }
}

struct FileReferenceText: View {
    let text: String
    let font: Font
    let baseColor: Color
    let lineSpacing: CGFloat
    let parseMarkdown: Bool
    var cacheID: String? = nil
    var highlightReferences = true
    let onOpenFile: (FileReference) -> Void

    var body: some View {
        Text(FileReferenceDetector.attributedString(from: text, cacheID: cacheID, parseMarkdown: parseMarkdown, baseColor: baseColor, highlightReferences: highlightReferences))
            .font(font)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if let reference = FileReference(openURL: url) {
                    onOpenFile(reference)
                    return .handled
                }
                if Self.isWebURL(url) {
                    NSWorkspace.shared.open(url)
                    return .handled
                }
                return .systemAction
            })
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

struct FileReferenceChips: View {
    let text: String
    var cacheID: String? = nil
    let onOpenFile: (FileReference) -> Void

    private var references: [FileReference] {
        FileReferenceDetector.references(in: text, cacheID: cacheID)
    }

    var body: some View {
        let visibleReferences = Array(references.prefix(8))
        if !visibleReferences.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(visibleReferences) { reference in
                    FileReferenceButton(reference: reference, onOpenFile: onOpenFile)
                }
                if references.count > visibleReferences.count {
                    Text("+\(references.count - visibleReferences.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AppTheme.toolMutedSurface)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

struct FileReferenceButton: View {
    let reference: FileReference
    let onOpenFile: (FileReference) -> Void

    private var style: FileLanguageStyle { .forPath(reference.path) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: style.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(reference.displayName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(style.tint.opacity(0.1))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            onOpenFile(reference)
        }
        .help(reference.path)
    }
}

final class FileReferenceListBox {
    let references: [FileReference]

    init(_ references: [FileReference]) {
        self.references = references
    }
}

final class AttributedStringBox {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}

enum FileReferenceDetector {
    private static let maxScanLength = 40_000
    private static let maxReferences = 24
    private static let referenceCache: NSCache<NSString, FileReferenceListBox> = {
        let cache = NSCache<NSString, FileReferenceListBox>()
        cache.countLimit = 400
        return cache
    }()
    private static let attributedCache: NSCache<NSString, AttributedStringBox> = {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.countLimit = 240
        return cache
    }()
    private static let pathPattern = #"(?:(?:file://)?/(?:[^\s`\"'<>|])+|(?:[A-Za-z0-9_@.+~%-]+/)+(?:[A-Za-z0-9_@.+~%-]+)|[A-Za-z0-9_@.+~%-]+\.[A-Za-z0-9]{1,12})(?::\d+){0,2}"#
    private static let webURLDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let knownKeys: Set<String> = [
        "swift", "xib", "storyboard", "xcconfig", "entitlements", "xcprivacy", "pbxproj",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "pyw", "ipynb", "go", "rs",
        "java", "kt", "kts", "scala", "gradle", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "cs", "fs", "vb",
        "rb", "php", "r", "lua", "dart", "ex", "exs", "erl", "hrl", "clj", "cljs", "zig",
        "html", "htm", "css", "scss", "sass", "less", "vue", "svelte",
        "json", "jsonc", "plist", "xml", "yaml", "yml", "toml", "properties", "ini", "conf", "config", "md", "markdown", "txt", "rtf",
        "sh", "bash", "zsh", "fish", "ps1", "makefile", "dockerfile", "env",
        "sql", "graphql", "gql", "proto", "csv", "tsv", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf",
        "diff", "patch", "lock", "log", "gitignore", "editorconfig"
    ]

    static func references(in text: String, cacheID: String? = nil) -> [FileReference] {
        let key = cacheID.map { cacheKey(prefix: "refs", cacheID: $0, text: text) }
        if let key, let cached = referenceCache.object(forKey: key) {
            return cached.references
        }
        let scanText = String(text.prefix(maxScanLength))
        guard let regex = try? NSRegularExpression(pattern: pathPattern) else { return [] }
        let range = NSRange(scanText.startIndex..<scanText.endIndex, in: scanText)
        var references: [FileReference] = []
        var seen: Set<String> = []

        for match in regex.matches(in: scanText, range: range) {
            guard references.count < maxReferences,
                  let swiftRange = Range(match.range, in: scanText),
                  let reference = reference(from: String(scanText[swiftRange])),
                  seen.insert(reference.id).inserted else { continue }
            references.append(reference)
        }
        if let key {
            referenceCache.setObject(FileReferenceListBox(references), forKey: key)
        }
        return references
    }

    static func attributedString(from text: String, cacheID: String? = nil, parseMarkdown: Bool, baseColor: Color, highlightReferences: Bool = true) -> AttributedString {
        var attributed = baseAttributedString(from: text, cacheID: cacheID, parseMarkdown: parseMarkdown)
        attributed.foregroundColor = baseColor
        applyWebLinks(in: text, to: &attributed)

        guard highlightReferences else { return attributed }
        for reference in references(in: text, cacheID: cacheID) {
            guard let url = reference.openURL, let range = attributed.range(of: reference.raw) else { continue }
            attributed[range].link = url
            attributed[range].foregroundColor = FileLanguageStyle.forPath(reference.path).tint
        }
        return attributed
    }

    private static func applyWebLinks(in text: String, to attributed: inout AttributedString) {
        guard let detector = webURLDetector else { return }
        let scanText = String(text.prefix(maxScanLength))
        let range = NSRange(scanText.startIndex..<scanText.endIndex, in: scanText)
        var seen: Set<String> = []

        for match in detector.matches(in: scanText, range: range) {
            guard let url = match.url,
                  isWebURL(url),
                  let swiftRange = Range(match.range, in: scanText) else { continue }
            let raw = String(scanText[swiftRange])
            guard seen.insert(raw).inserted,
                  let attributedRange = attributed.range(of: raw) else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].foregroundColor = .blue
            attributed[attributedRange].underlineStyle = .single
        }
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func baseAttributedString(from text: String, cacheID: String?, parseMarkdown: Bool) -> AttributedString {
        let key = cacheID.map { cacheKey(prefix: parseMarkdown ? "md" : "text", cacheID: $0, text: text) }
        if let key, let cached = attributedCache.object(forKey: key) {
            return cached.value
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = parseMarkdown
            ? ((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            : AttributedString(text)
        if let key {
            attributedCache.setObject(AttributedStringBox(attributed), forKey: key)
        }
        return attributed
    }

    private static func cacheKey(prefix: String, cacheID: String, text: String) -> NSString {
        "\(prefix):\(cacheID):\(text.renderCacheFingerprint)" as NSString
    }

    private static func reference(from rawValue: String) -> FileReference? {
        let raw = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]{}<>，。；；、,.;"))
        guard !raw.isEmpty else { return nil }
        if raw.contains("://"), !raw.hasPrefix("file://") { return nil }

        var parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var line: Int?
        var column: Int?
        if let last = parts.last, let value = Int(last) {
            column = value
            parts.removeLast()
        }
        if let last = parts.last, let value = Int(last) {
            line = value
            parts.removeLast()
        }
        if line == nil, let columnValue = column {
            line = columnValue
            column = nil
        }

        var path = parts.joined(separator: ":")
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path = String(path.dropFirst(2))
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]{}<>，。；；、,.;"))
        guard !path.isEmpty, path != "/dev/null", isKnownFilePath(path) else { return nil }
        return FileReference(raw: raw, path: path, line: line, column: column)
    }

    private static func isKnownFilePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return knownKeys.contains(ext) }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return true }
        if name == "makefile" || name.hasPrefix("makefile.") { return true }
        if name.hasPrefix(".env") { return true }
        return name == ".gitignore" || name == ".editorconfig"
    }
}

final class AssistantMessageBlockBox {
    let blocks: [AssistantMessageBlock]

    init(_ blocks: [AssistantMessageBlock]) {
        self.blocks = blocks
    }
}

struct IdentifiedAssistantMessageBlock: Identifiable {
    let id: String
    let block: AssistantMessageBlock
}

struct StreamingAssistantTextView: NSViewRepresentable {
    @ObservedObject var store: StreamingTextStore
    let messageID: UUID
    let fallbackText: String
    var textColor: NSColor = .labelColor

    private var displayText: String {
        let rawText = store.text(for: messageID) ?? fallbackText
        guard rawText.count > 18_000 else { return rawText }
        return String(rawText.prefix(18_000)) + "\n\n…输出过长，已暂停完整渲染；复制消息可获取完整内容。"
    }

    func makeNSView(context: Context) -> StreamingAssistantTextContainer {
        let view = StreamingAssistantTextContainer(textColor: textColor)
        view.setText(displayText)
        return view
    }

    func updateNSView(_ nsView: StreamingAssistantTextContainer, context: Context) {
        nsView.textColor = textColor
        nsView.setText(displayText)
    }
}

final class StreamingAssistantTextContainer: NSView {
    private let textView = NSTextView(frame: .zero)
    private var lastText = ""
    private var lastTextContainerWidth: CGFloat = 0
    private var isIntrinsicInvalidationScheduled = false
    var textColor: NSColor {
        didSet {
            rebuildAttributes()
            resetText(lastText)
        }
    }
    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    init(textColor: NSColor) {
        self.textColor = textColor
        super.init(frame: .zero)
        rebuildAttributes()
        setupTextView()
    }

    override init(frame frameRect: NSRect) {
        self.textColor = .labelColor
        super.init(frame: frameRect)
        rebuildAttributes()
        setupTextView()
    }

    required init?(coder: NSCoder) {
        self.textColor = .labelColor
        super.init(coder: coder)
        rebuildAttributes()
        setupTextView()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        updateTextContainerWidth(bounds.width)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(usedRect.height), 1))
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        let width = bounds.width
        guard abs(width - lastTextContainerWidth) > 0.5 else { return }
        lastTextContainerWidth = width
        updateTextContainerWidth(width)
        invalidateIntrinsicContentSize()
    }

    func setText(_ newText: String) {
        guard newText != lastText else { return }
        if !lastText.isEmpty, newText.hasPrefix(lastText) {
            let delta = String(newText.dropFirst(lastText.count))
            textView.textStorage?.append(NSAttributedString(string: delta, attributes: textAttributes))
        } else {
            resetText(newText)
        }
        lastText = newText
        needsLayout = true
        scheduleIntrinsicInvalidation()
    }

    private func resetText(_ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
    }

    private func scheduleIntrinsicInvalidation() {
        guard !isIntrinsicInvalidationScheduled else { return }
        isIntrinsicInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isIntrinsicInvalidationScheduled = false
            self.invalidateIntrinsicContentSize()
        }
    }

    private func rebuildAttributes() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        textAttributes = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func setupTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)
    }

    private func updateTextContainerWidth(_ width: CGFloat) {
        let safeWidth = max(width, 1)
        textView.textContainer?.containerSize = NSSize(width: safeWidth, height: .greatestFiniteMagnitude)
    }
}

struct AssistantMessageContent: View {
    private static let blockCache: NSCache<NSString, AssistantMessageBlockBox> = {
        let cache = NSCache<NSString, AssistantMessageBlockBox>()
        cache.countLimit = 200
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    let text: String
    let isStreaming: Bool
    var messageID: UUID? = nil
    var streamingTextStore: StreamingTextStore? = nil
    let onOpenFile: (FileReference) -> Void

    private let lightweightThreshold = 12_000
    private let previewLimit = 20_000

    private var shouldUseLightweightRender: Bool {
        isStreaming || text.count > lightweightThreshold
    }

    private var previewText: String {
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit)) + "\n\n…输出过长，已暂停完整渲染；复制消息可获取完整内容。"
    }

    private var blocks: [AssistantMessageBlock] {
        guard !isStreaming else { return AssistantMessageBlock.parse(text) }
        guard let cacheID = messageID?.uuidString else { return AssistantMessageBlock.parse(text) }
        let key = "blocks:\(cacheID):\(text.renderCacheFingerprint)" as NSString
        if let cached = Self.blockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = AssistantMessageBlock.parse(text)
        Self.blockCache.setObject(AssistantMessageBlockBox(parsed), forKey: key, cost: text.utf8.count)
        return parsed
    }

    private var identifiedBlocks: [IdentifiedAssistantMessageBlock] {
        var occurrences: [String: Int] = [:]
        return blocks.map { block in
            let key = block.identityKey
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return IdentifiedAssistantMessageBlock(id: "\(key)#\(occurrence)", block: block)
        }
    }

    private func cacheID(for scope: String, text: String) -> String? {
        guard let messageID else { return nil }
        return "message:\(messageID.uuidString):\(scope):\(text.renderCacheFingerprint)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStreaming, let messageID, let streamingTextStore {
                StreamingAssistantTextView(store: streamingTextStore, messageID: messageID, fallbackText: text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if shouldUseLightweightRender {
                FileReferenceText(
                    text: previewText,
                    font: .system(size: 12),
                    baseColor: .primary,
                    lineSpacing: 3,
                    parseMarkdown: false,
                    cacheID: cacheID(for: "preview", text: previewText),
                    onOpenFile: onOpenFile
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(identifiedBlocks) { item in
                    blockView(item.block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMessageBlock) -> some View {
        switch block {
        case .text(let value):
            FileReferenceText(
                text: value,
                font: .system(size: 12),
                baseColor: .primary,
                lineSpacing: 3,
                parseMarkdown: true,
                cacheID: cacheID(for: "text", text: value),
                onOpenFile: onOpenFile
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code):
            AssistantCodeBlockView(language: language, code: code)
        case .table(let value):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(String(value.prefix(12_000)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.toolMutedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
        }
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
    }
}

struct AssistantCodeBlockView: View {
    let language: String
    let code: String

    private let previewLimit = 16_000

    private var previewCode: String {
        guard code.count > previewLimit else { return code }
        return String(code.prefix(previewLimit)) + "\n\n…代码过长，已暂停完整渲染；点击 copy 可复制完整代码。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                        Text("copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("复制代码")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AppTheme.toolMutedSurface)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(previewCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }
}

enum AssistantMessageBlock {
    case text(String)
    case code(language: String, code: String)
    case table(String)

    var identityKey: String {
        switch self {
        case .text(let value):
            return Self.identityKey(prefix: "text", value: value)
        case .code(let language, let code):
            return Self.identityKey(prefix: "code:\(language)", value: code)
        case .table(let value):
            return Self.identityKey(prefix: "table", value: value)
        }
    }

    static func parse(_ text: String) -> [AssistantMessageBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [AssistantMessageBlock] = []
        var textBuffer: [String] = []
        var codeBuffer: [String] = []
        var codeLanguage = ""
        var isInCodeBlock = false

        func flushText() {
            let value = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            textBuffer.removeAll()
            guard !value.isEmpty else { return }
            appendTextOrTable(value, to: &blocks)
        }

        for line in lines {
            if let language = fenceLanguage(from: line) {
                if isInCodeBlock {
                    blocks.append(.code(language: codeLanguage, code: codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    codeLanguage = ""
                    isInCodeBlock = false
                } else {
                    flushText()
                    codeLanguage = language
                    isInCodeBlock = true
                }
            } else if isInCodeBlock {
                codeBuffer.append(line)
            } else {
                textBuffer.append(line)
            }
        }

        if isInCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeBuffer.joined(separator: "\n")))
        }
        flushText()

        return blocks.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.text(text)] : blocks
    }

    private static func identityKey(prefix: String, value: String) -> String {
        let head = value.prefix(80)
        let tail = value.suffix(80)
        return "\(prefix):\(value.count):\(head):\(tail)"
    }

    private static func appendTextOrTable(_ value: String, to blocks: inout [AssistantMessageBlock]) {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var buffer: [String] = []
        var tableBuffer: [String] = []

        func flushBuffer() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            if !text.isEmpty { blocks.append(.text(text)) }
        }

        func flushTable() {
            let table = tableBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            tableBuffer.removeAll()
            if !table.isEmpty { blocks.append(.table(table)) }
        }

        var index = 0
        while index < lines.count {
            if let tableRange = tableRangeStart(in: lines, at: index) {
                flushBuffer()
                tableBuffer.append(contentsOf: lines[tableRange])
                flushTable()
                index = tableRange.upperBound
            } else {
                buffer.append(lines[index])
                index += 1
            }
        }
        flushTable()
        flushBuffer()
    }

    private static func fenceLanguage(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableRangeStart(in lines: [String], at index: Int) -> Range<Int>? {
        guard index + 1 < lines.count,
              isPotentialTableRow(lines[index]),
              isTableSeparator(lines[index + 1]) else { return nil }
        var end = index + 2
        while end < lines.count && isPotentialTableRow(lines[end]) {
            end += 1
        }
        return index..<end
    }

    private static func isPotentialTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        return trimmed.first == "|" || trimmed.last == "|" || trimmed.contains(" | ")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
            && trimmed.contains("---")
    }
}

struct WindowDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDraggableNSView {
        WindowDraggableNSView()
    }

    func updateNSView(_ nsView: WindowDraggableNSView, context: Context) {}
}

final class WindowDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct NonWindowDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonWindowDraggableNSView {
        NonWindowDraggableNSView()
    }

    func updateNSView(_ nsView: NonWindowDraggableNSView, context: Context) {}
}

final class NonWindowDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct QueuedRequestDragSource: NSViewRepresentable {
    let id: UUID
    let previewText: String

    func makeNSView(context: Context) -> QueuedRequestDragSourceView {
        QueuedRequestDragSourceView(id: id, previewText: previewText)
    }

    func updateNSView(_ nsView: QueuedRequestDragSourceView, context: Context) {
        nsView.id = id
        nsView.previewText = previewText
    }
}

final class QueuedRequestDragSourceView: NSView, NSDraggingSource {
    var id: UUID
    var previewText: String
    private var mouseDownEvent: NSEvent?

    init(id: UUID, previewText: String) {
        self.id = id
        self.previewText = previewText
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.id = UUID()
        self.previewText = ""
        super.init(coder: coder)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent else { return }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: queuedRequestPasteboardType)
        item.setString(previewText, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: self)
        self.mouseDownEvent = nil
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

enum ToolRunStatusKind: Equatable {
    case success
    case failed
    case running
    case warning
}

struct ToolStatusBadge: View, Equatable {
    let kind: ToolRunStatusKind
    let label: String

    init(message: ChatMessage) {
        self.kind = message.toolStatusKind
        self.label = message.toolStatusLabel
    }

    init(kind: ToolRunStatusKind, label: String) {
        self.kind = kind
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            if kind == .running {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 5, height: 5)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(AppTheme.toolMutedSurface)
        .clipShape(Capsule())
    }
}

struct ToolKeyValuePanel: View {
    let title: String
    let pairs: [(key: String, value: String)]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            if pairs.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 8) {
                        Text(pair.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 82, alignment: .leading)
                        Text(Self.inlineValue(pair.value))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.78))
                            .lineLimit(pair.value.contains("\n") ? 3 : 1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func inlineValue(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 180 else { return normalized }
        return String(normalized.prefix(180)) + "…"
    }
}

struct ToolCodePreviewView: View {
    let lines: [String]
    let firstLine: Int
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(firstLine + index)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 38, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.78))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: maxHeight)
        }
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

struct ToolMatchTable: View {
    let lines: [String]
    let onOpenFile: (FileReference) -> Void

    private static let maxVisibleLines = 300
    private var visibleLines: [String] { Array(lines.prefix(Self.maxVisibleLines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("file:line")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 190, alignment: .leading)
                Text("match")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                let split = Self.splitMatchLine(line)
                HStack(alignment: .top, spacing: 8) {
                    Text(split.location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onOpenFile(FileReference(raw: split.location, path: split.path, line: split.line, column: nil))
                        }
                    Text(split.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Divider().opacity(0.12)
            }

            if lines.count > visibleLines.count {
                Text("仅显示前 \(visibleLines.count) 条，结果过多已限制渲染")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
    }

    private static func splitMatchLine(_ line: String) -> (location: String, path: String, line: Int?, content: String) {
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let lineNumber = Int(parts[1]) else {
            return (line, line, nil, "")
        }
        return ("\(parts[0]):\(parts[1])", parts[0], lineNumber, parts[2])
    }
}

struct ToolFileGrid: View {
    let paths: [String]
    let onOpenFile: (FileReference) -> Void

    private static let maxVisiblePaths = 500
    private var visiblePaths: [String] { Array(paths.prefix(Self.maxVisiblePaths)) }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Array(visiblePaths.enumerated()), id: \.offset) { _, path in
                    HStack(spacing: 5) {
                        Image(systemName: "doc")
                            .font(.system(size: 9, weight: .medium))
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.toolMutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture {
                        onOpenFile(FileReference(path: path))
                    }
                }
            }
            if paths.count > visiblePaths.count {
                Text("仅显示前 \(visiblePaths.count) 个文件，结果过多已限制渲染")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}

struct TodoToolRow: View {
    let row: (content: String, status: String)

    private var isCompleted: Bool { row.status == "completed" }
    private var isInProgress: Bool { row.status == "in_progress" || row.status == "in progress" }
    private var isCancelled: Bool { row.status == "cancelled" || row.status == "canceled" }
    private var label: String {
        if isCompleted { return "已完成" }
        if isInProgress { return "进行中" }
        if isCancelled { return "已取消" }
        return "新增"
    }
    private var iconName: String {
        if isCompleted { return "checkmark.circle.fill" }
        if isInProgress { return "circle.lefthalf.filled" }
        return "circle"
    }
    private var iconColor: Color {
        if isCompleted { return .green.opacity(0.85) }
        if isInProgress { return .orange.opacity(0.85) }
        if isCancelled { return .secondary.opacity(0.45) }
        return .secondary.opacity(0.55)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 18)
            Text(row.content)
                .font(.system(size: 12))
                .foregroundStyle(isCancelled ? Color.secondary.opacity(0.55) : Color.primary.opacity(0.82))
                .strikethrough(isCancelled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.toolMutedSurface)
                .clipShape(Capsule())
        }
        .padding(.vertical, 7)
        .textSelection(.enabled)
        .accessibilityLabel("\(row.content)，\(label)")
    }
}

struct SubagentTimelineRow: View {
    let title: String
    let detail: String
    let tint: Color
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(AppTheme.hairline)
                        .frame(width: 1, height: 30)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}

struct StreamingTerminalOutputBlock: View {
    @ObservedObject var store: StreamingTextStore
    let message: ChatMessage
    let context: ChatMessage
    let command: String?
    let fallbackSections: [(label: String, text: String)]
    let exitCode: Int?
    let onOpenFile: (FileReference) -> Void

    var body: some View {
        TerminalOutputBlock(
            sections: liveSections,
            isStreaming: true,
            onOpenFile: onOpenFile
        )
    }

    private var liveSections: [(label: String, text: String)] {
        var liveMessage = message
        if let text = store.text(for: message.id) ?? store.text(for: context.id) {
            liveMessage.text = text
        }
        let sections = liveMessage.terminalVisualSections.isEmpty ? fallbackSections : liveMessage.terminalVisualSections
        return TerminalFlowBuilder.sections(command: command, sections: sections, exitCode: exitCode, isStreaming: true)
    }
}

enum TerminalFlowBuilder {
    static func sections(command: String?, sections: [(label: String, text: String)], exitCode: Int?, isStreaming: Bool) -> [(label: String, text: String)] {
        var flow: [(label: String, text: String)] = []
        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            flow.append(("command", "$ \(command)"))
        }
        flow.append(contentsOf: sections)
        if flow.isEmpty && isStreaming {
            flow.append(("status", "running..."))
        }
        if let exitCode, !isStreaming, exitCode != 0 {
            flow.append(("exit", "exit \(exitCode)"))
        }
        return flow
    }
}

final class TerminalOutputTextBox {
    let text: String
    let lineCount: Int

    init(text: String, lineCount: Int) {
        self.text = text
        self.lineCount = lineCount
    }
}

struct TerminalOutputBlock: View {
    private static let outputTextCache: NSCache<NSString, TerminalOutputTextBox> = {
        let cache = NSCache<NSString, TerminalOutputTextBox>()
        cache.countLimit = 200
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    let sections: [(label: String, text: String)]
    let isStreaming: Bool
    let onOpenFile: (FileReference) -> Void
    @State private var autoScroll = true
    @State private var expanded = false
    private let bottomID = "terminal-output-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasLongOutput {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Expand log") { expanded = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 4) {
                                if shouldShowLabel(section.label) {
                                    Text(section.label)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                FileReferenceText(
                                    text: outputText(section.text),
                                    font: .system(size: 11, design: .monospaced),
                                    baseColor: section.label == "stderr" || section.label == "exit" ? Color.secondary : Color.primary.opacity(0.78),
                                    lineSpacing: 2,
                                    parseMarkdown: false,
                                    cacheID: "terminal:\(section.label):\(section.text.renderCacheFingerprint):\(expanded)",
                                    highlightReferences: false,
                                    onOpenFile: onOpenFile
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: expanded ? 420 : 260, alignment: .leading)
                .onChange(of: totalTextLength) { _, _ in
                    guard isStreaming, autoScroll else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .background(Color.clear)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasLongOutput: Bool {
        sections.contains { outputInfo(for: $0.text).lineCount > 800 }
    }

    private var totalTextLength: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }

    private func shouldShowLabel(_ label: String) -> Bool {
        !["command", "stdout", "output", "status"].contains(label.lowercased())
    }

    private func outputText(_ text: String) -> String {
        outputInfo(for: text).text
    }

    private func outputInfo(for text: String) -> TerminalOutputTextBox {
        let key = "terminal-output:\(expanded):\(text.renderCacheFingerprint)" as NSString
        if let cached = Self.outputTextCache.object(forKey: key) {
            return cached
        }
        let lineCount = text.utf8.reduce(1) { count, byte in byte == 0x0A ? count + 1 : count }
        let output: String
        if expanded || lineCount <= 800 {
            output = text
        } else {
            output = (["... tail 600 lines ..."] + text.split(separator: "\n", omittingEmptySubsequences: false).suffix(600).map(String.init)).joined(separator: "\n")
        }
        let box = TerminalOutputTextBox(text: output, lineCount: lineCount)
        Self.outputTextCache.setObject(box, forKey: key, cost: output.utf8.count)
        return box
    }
}

struct ComposerSuggestedCommand: Equatable {
    let text: String
}

struct AppendRulePreview: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct AppendRulePreviewSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("追加规则")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider().opacity(0.25)

            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 520, height: 380)
        .background(AppTheme.toolSurface)
    }
}

struct ChatInteractiveRequestCard: View {
    let message: ChatMessage
    @ObservedObject var chatState: ChatPanelState
    @State private var selectedOptionIDs: Set<String> = []
    @State private var customText = ""

    private var request: ChatInteractiveRequest? { message.interactiveRequest }
    private var isWaiting: Bool { request?.status == .waiting || message.status == ChatInteractiveStatus.waiting.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(request?.title.nonEmptyTrimmed ?? message.title.nonEmptyTrimmed ?? "需要选择")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(request?.prompt.nonEmptyTrimmed ?? message.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let request, isWaiting {
                switch request.mode {
                case .singleChoice:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(request.options) { option in
                            Button {
                                submit(selectedIDs: [option.id], customText: nil)
                            } label: {
                                optionRow(option, selected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .multipleChoice:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(request.options) { option in
                            Button {
                                if selectedOptionIDs.contains(option.id) {
                                    selectedOptionIDs.remove(option.id)
                                } else {
                                    selectedOptionIDs.insert(option.id)
                                }
                            } label: {
                                optionRow(option, selected: selectedOptionIDs.contains(option.id))
                            }
                            .buttonStyle(.plain)
                        }
                        interactiveActionButton("提交选择", disabled: selectedOptionIDs.isEmpty) {
                            submit(selectedIDs: Array(selectedOptionIDs), customText: nil)
                        }
                    }
                case .text:
                    textInput(request)
                }

                if request.allowCustomInput && request.mode != .text {
                    textInput(request)
                }
            }
        }
        .padding(10)
        .background(AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(_ option: ChatInteractiveOption, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.45))
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(0.88))
                if !option.detail.isEmpty {
                    Text(option.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? AppTheme.secondaryCardSurface : AppTheme.toolMutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
    }

    private func textInput(_ request: ChatInteractiveRequest) -> some View {
        HStack(spacing: 6) {
            TextField(request.placeholder.isEmpty ? "输入回复" : request.placeholder, text: $customText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(AppTheme.secondaryCardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
            interactiveActionButton("发送", disabled: customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                submit(selectedIDs: [], customText: customText)
            }
        }
    }

    private func interactiveActionButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(disabled ? AppTheme.toolMutedSurface.opacity(0.55) : AppTheme.secondaryCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.weakHairline, lineWidth: 1))
            .disabled(disabled)
    }

    private func submit(selectedIDs: [String], customText: String?) {
        guard let request else { return }
        chatState.respondToInteractiveRequest(ChatInteractiveResponse(
            requestID: request.id,
            selectedOptionIDs: selectedIDs,
            customText: customText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyTrimmed
        ))
    }
}

struct SubagentDetailRequest: Identifiable, Equatable {
    let agentID: String?
    let agentType: String
    let description: String
    let projectPath: String?

    var id: String { agentID ?? "pending-\(agentType)-\(description)" }
}

@MainActor
final class SubagentTranscriptSheetModel: ObservableObject {
    @Published private(set) var transcript: SubagentTranscript?
    @Published var isPaused = false

    private let request: SubagentDetailRequest
    private var timer: DispatchSourceTimer?
    private var refreshGeneration = 0
    private var isLoading = false

    init(request: SubagentDetailRequest) {
        self.request = request
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.schedule(deadline: .now() + 2.5, repeating: 2.5)
            source.setEventHandler { [weak self] in
                guard let self, !self.isPaused else { return }
                self.refresh()
            }
            timer = source
            source.resume()
        }
        refresh()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshotRequest = request
        Task { [weak self] in
            let next = await Task.detached(priority: .utility) { () -> SubagentTranscript? in
                if let agentID = snapshotRequest.agentID {
                    return SubagentTranscriptStore.load(agentID: agentID, projectPath: snapshotRequest.projectPath)
                }
                return SubagentTranscriptStore.find(
                    agentType: snapshotRequest.agentType,
                    description: snapshotRequest.description,
                    projectPath: snapshotRequest.projectPath
                )
            }.value
            guard let self else { return }
            self.isLoading = false
            guard self.refreshGeneration == generation else { return }
            if self.transcript != next {
                self.transcript = next
            }
        }
    }
}

struct SubagentTranscriptSheet: View {
    let request: SubagentDetailRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SubagentTranscriptSheetModel

    init(request: SubagentDetailRequest) {
        self.request = request
        _model = StateObject(wrappedValue: SubagentTranscriptSheetModel(request: request))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent process")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(headerSubtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(model.isPaused ? "resume" : "pause") {
                    model.isPaused.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                Button("refresh") { model.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider().opacity(0.28)

            if let transcript = model.transcript, !transcript.messages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(transcript.messages) { message in
                            SubagentTranscriptMessageRow(message: message)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("waiting for agent transcript")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("日志写入后会自动刷新；这里只读展示，不会影响后台运行。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var headerSubtitle: String {
        let transcriptType = model.transcript?.agentType.nonEmptyTrimmed
        let type = transcriptType ?? request.agentType
        let description = model.transcript?.description.nonEmptyTrimmed ?? request.description
        let idText = request.agentID.map { "agent-\($0.prefix(8))" } ?? "pending"
        return "\(type) · \(description) · \(idText)"
    }
}

struct SubagentTranscriptMessageRow: View {
    let message: SubagentTranscriptMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(AppTheme.toolMutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        case .assistant:
            AssistantMessageContent(text: message.text, isStreaming: false, onOpenFile: { _ in })
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            SubagentSmallCard(message: message)
        case .toolCall:
            SubagentSmallCard(message: message)
        case .toolResult:
            SubagentSmallCard(message: message)
        case .raw:
            SubagentSmallCard(message: message)
        }
    }
}

struct SubagentSmallCard: View {
    let message: SubagentTranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(message.title.isEmpty ? message.kind.rawValue : message.title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !message.subtitle.isEmpty {
                    Text(message.subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if !message.text.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(previewText)
                        .font(.system(size: 10, design: message.kind == .toolCall || message.kind == .toolResult ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 12)
        .textSelection(.enabled)
    }

    private var previewText: String {
        guard message.text.count > 18_000 else { return message.text }
        return String(message.text.prefix(18_000)) + "\n\n…内容过长，已暂停完整渲染。"
    }

    private var statusText: String {
        message.status == "failed" ? "失败" : "完成"
    }
}

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var hasMarkedText: Bool
    @Binding var suggestedCommand: ComposerSuggestedCommand?
    @Binding var measuredHeight: CGFloat
    let focusRequest: Int
    let onSubmit: () -> Void
    let onFilesDropped: ([String]) -> Void
    let onFilesPasted: ([String]) -> Bool
    let onQueuedRequestDropped: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            hasMarkedText: $hasMarkedText,
            suggestedCommand: $suggestedCommand,
            measuredHeight: $measuredHeight,
            onSubmit: onSubmit,
            onFilesDropped: onFilesDropped,
            onFilesPasted: onFilesPasted
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onFilesDropped = onFilesDropped
        textView.onFilesPasted = onFilesPasted
        textView.onQueuedRequestDropped = onQueuedRequestDropped
        textView.onMarkedTextChanged = { context.coordinator.hasMarkedText = $0 }
        textView.onSuggestedCommandCleared = { context.coordinator.suggestedCommand = nil }
        textView.suggestedCommand = suggestedCommand
        textView.string = text
        textView.font = .systemFont(ofSize: 12)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([queuedRequestPasteboardType, .fileURL, .URL, .string])

        scrollView.documentView = textView
        context.coordinator.updateMeasuredHeight(for: textView)
        context.coordinator.updateMeasuredHeightAfterLayout(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onFilesDropped = onFilesDropped
        textView.onFilesPasted = onFilesPasted
        textView.onQueuedRequestDropped = onQueuedRequestDropped
        textView.onMarkedTextChanged = { context.coordinator.hasMarkedText = $0 }
        textView.onSuggestedCommandCleared = { context.coordinator.suggestedCommand = nil }
        textView.isEditable = true
        textView.isSelectable = true
        if textView.hasMarkedText() {
            context.coordinator.hasMarkedText = true
            return
        }
        textView.suggestedCommand = suggestedCommand
        let didUpdateText = textView.string != text
        if didUpdateText {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        textView.refreshSuggestedCommandHighlight()
        context.coordinator.updateMeasuredHeight(for: textView)
        if didUpdateText {
            context.coordinator.updateMeasuredHeightAfterLayout(for: textView)
        }
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async { [weak scrollView, weak textView] in
                guard let scrollView, let textView, let window = scrollView.window else { return }
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var hasMarkedText: Bool
        @Binding var suggestedCommand: ComposerSuggestedCommand?
        @Binding var measuredHeight: CGFloat
        var handledFocusRequest = 0
        let onSubmit: () -> Void
        let onFilesDropped: ([String]) -> Void
        let onFilesPasted: ([String]) -> Bool

        init(
            text: Binding<String>,
            hasMarkedText: Binding<Bool>,
            suggestedCommand: Binding<ComposerSuggestedCommand?>,
            measuredHeight: Binding<CGFloat>,
            onSubmit: @escaping () -> Void,
            onFilesDropped: @escaping ([String]) -> Void,
            onFilesPasted: @escaping ([String]) -> Bool
        ) {
            _text = text
            _hasMarkedText = hasMarkedText
            _suggestedCommand = suggestedCommand
            _measuredHeight = measuredHeight
            self.onSubmit = onSubmit
            self.onFilesDropped = onFilesDropped
            self.onFilesPasted = onFilesPasted
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SubmitTextView else { return }
            let isComposing = textView.hasMarkedText()
            hasMarkedText = isComposing
            guard !isComposing else { return }
            text = textView.string
            if let suggestedCommand, textView.string != suggestedCommand.text {
                self.suggestedCommand = nil
                textView.suggestedCommand = nil
            }
            textView.refreshSuggestedCommandHighlight()
            updateMeasuredHeight(for: textView)
        }

        func updateMeasuredHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            let scrollWidth = textView.enclosingScrollView?.contentView.bounds.width ?? 0
            let availableWidth = max(max(scrollWidth, textView.bounds.width), 1)
            textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            let nextHeight = min(160, max(42, contentHeight + 10))
            guard abs(measuredHeight - nextHeight) >= 0.5 else { return }
            measuredHeight = nextHeight
        }

        func updateMeasuredHeightAfterLayout(for textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                updateMeasuredHeight(for: textView)
            }
        }
    }

    final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFilesDropped: (([String]) -> Void)?
        var onFilesPasted: (([String]) -> Bool)?
        var onQueuedRequestDropped: ((UUID) -> Void)?
        var onMarkedTextChanged: ((Bool) -> Void)?
        var onSuggestedCommandCleared: (() -> Void)?
        var suggestedCommand: ComposerSuggestedCommand?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if queuedRequestID(from: sender.draggingPasteboard) != nil { return .move }
            return filePaths(from: sender.draggingPasteboard).isEmpty ? [] : .copy
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            queuedRequestID(from: sender.draggingPasteboard) != nil || !filePaths(from: sender.draggingPasteboard).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let id = queuedRequestID(from: sender.draggingPasteboard) {
                onQueuedRequestDropped?(id)
                return true
            }
            let paths = filePaths(from: sender.draggingPasteboard)
            guard !paths.isEmpty else { return false }
            onFilesDropped?(paths)
            return true
        }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            let paths = pastePathCandidates(from: pasteboard)
            if !paths.isEmpty, onFilesPasted?(paths) == true {
                return
            }
            super.paste(sender)
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let isBackspace = event.keyCode == 51
            let isForwardDelete = event.keyCode == 117
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasSubmitModifier = flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) || flags.contains(.command)
            if isReturn, hasMarkedText() {
                super.keyDown(with: event)
                onMarkedTextChanged?(hasMarkedText())
                return
            }
            if isReturn && !hasSubmitModifier {
                onSubmit?()
                return
            }
            if !hasMarkedText(), isSuggestedCommandDeletion(backspace: isBackspace, forwardDelete: isForwardDelete), deleteSuggestedCommand(backspace: isBackspace) {
                return
            }
            super.keyDown(with: event)
        }

        func refreshSuggestedCommandHighlight() {
            guard !hasMarkedText() else { return }
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            layoutManager?.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
            guard let suggestedCommand, string == suggestedCommand.text, fullRange.length > 0 else { return }
            layoutManager?.addTemporaryAttributes([
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ], forCharacterRange: fullRange)
        }

        private func isSuggestedCommandDeletion(backspace: Bool, forwardDelete: Bool) -> Bool {
            backspace || forwardDelete
        }

        private func deleteSuggestedCommand(backspace: Bool) -> Bool {
            guard let suggestedCommand, string == suggestedCommand.text else { return false }
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            guard fullRange.length > 0 else { return false }
            let selection = selectedRange()
            let shouldDelete: Bool
            if selection.length > 0 {
                shouldDelete = NSIntersectionRange(selection, fullRange).length > 0
            } else if backspace {
                shouldDelete = selection.location > 0 && selection.location <= NSMaxRange(fullRange)
            } else {
                shouldDelete = selection.location >= fullRange.location && selection.location < NSMaxRange(fullRange)
            }
            guard shouldDelete, shouldChangeText(in: fullRange, replacementString: "") else { return false }
            textStorage?.replaceCharacters(in: fullRange, with: "")
            didChangeText()
            self.suggestedCommand = nil
            onSuggestedCommandCleared?()
            refreshSuggestedCommandHighlight()
            return true
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            publishMarkedTextState()
        }

        override func unmarkText() {
            super.unmarkText()
            publishMarkedTextState()
        }

        private func publishMarkedTextState() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onMarkedTextChanged?(self.hasMarkedText())
            }
        }

        private func queuedRequestID(from pasteboard: NSPasteboard) -> UUID? {
            if let raw = pasteboard.string(forType: queuedRequestPasteboardType)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return UUID(uuidString: raw)
            }
            if let data = pasteboard.data(forType: queuedRequestPasteboardType),
               let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return UUID(uuidString: raw)
            }
            return nil
        }

        private func filePaths(from pasteboard: NSPasteboard) -> [String] {
            existingPaths(from: pathCandidates(from: pasteboard, includeImage: false))
        }

        private func pastePathCandidates(from pasteboard: NSPasteboard) -> [String] {
            pathCandidates(from: pasteboard, includeImage: true)
        }

        private func pathCandidates(from pasteboard: NSPasteboard, includeImage: Bool) -> [String] {
            var paths: [String] = []
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] {
                paths.append(contentsOf: urls.map(\.path))
            }
            if includeImage, paths.isEmpty, let imagePath = pastedImagePath(from: pasteboard) {
                paths.append(imagePath)
            }
            return paths
        }

        private func existingPaths(from paths: [String]) -> [String] {
            var seen = Set<String>()
            return paths.compactMap { path in
                let standardized = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
                guard !standardized.isEmpty,
                      FileManager.default.fileExists(atPath: standardized),
                      seen.insert(standardized).inserted else { return nil }
                return standardized
            }
        }



        private func pastedImagePath(from pasteboard: NSPasteboard) -> String? {
            guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodevokePastedImages", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("pasted-image-\(UUID().uuidString).png")
                if pasteboard.data(forType: .png) != nil {
                    try data.write(to: destination, options: .atomic)
                } else if let image = NSImage(data: data),
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: destination, options: .atomic)
                } else {
                    return nil
                }
                return destination.path
            } catch {
                return nil
            }
        }
    }
}

struct ToolInvocationSummary {
    let primaryTitle: String
    let plainSummary: String?
    let filePath: String?
    let isAgentTool: Bool
}

final class ToolInvocationSummaryBox {
    let value: ToolInvocationSummary

    init(_ value: ToolInvocationSummary) {
        self.value = value
    }
}

enum ToolInvocationSummaryCache {
    private static let cache: NSCache<NSString, ToolInvocationSummaryBox> = {
        let cache = NSCache<NSString, ToolInvocationSummaryBox>()
        cache.countLimit = 800
        return cache
    }()

    static func summary(for message: ChatMessage) -> ToolInvocationSummary {
        let key = "\(message.id.uuidString):\(message.status):\(message.isStreaming):\(message.text.count)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let toolKey = message.toolKindKey
        let summary = ToolInvocationSummary(
            primaryTitle: message.toolPrimaryTitle,
            plainSummary: message.cheapToolHeaderSummary(toolKey: toolKey),
            filePath: message.toolFilePath,
            isAgentTool: toolKey == "agent"
        )
        cache.setObject(ToolInvocationSummaryBox(summary), forKey: key)
        return summary
    }
}

struct ToolBusinessField: Equatable {
    let key: String
    let value: String
}

struct ReadPayload {
    let path: String?
    let lines: [String]
    let startLine: Int
    let copyText: String
    let fields: [ToolBusinessField]
}

struct GrepPayload {
    let pattern: String?
    let matches: [String]
    let fields: [ToolBusinessField]
}

struct GlobPayload {
    let pattern: String?
    let files: [String]
    let fields: [ToolBusinessField]
}

struct DiffPayload {
    let path: String?
    let stats: String?
    let copyText: String
    let fields: [ToolBusinessField]
}

struct BashPayload {
    let command: String?
    let sections: [(label: String, text: String)]
    let exitCode: Int?
    let fields: [ToolBusinessField]
}

struct TodoPayload {
    let rows: [(content: String, status: String)]
    let fields: [ToolBusinessField]
}

struct AgentPayload {
    let title: String
    let agentID: String?
    let prompt: String?
    let resultSummary: String?
    let fields: [ToolBusinessField]
}

struct McpPayload {
    let title: String
    let fields: [ToolBusinessField]
    let resultPreview: String
    let rawText: String
    let isParseFallback: Bool
}

enum ToolPayload {
    case read(ReadPayload)
    case grep(GrepPayload)
    case glob(GlobPayload)
    case diff(DiffPayload)
    case terminal(BashPayload)
    case todo(TodoPayload)
    case agent(AgentPayload)
    case mcp(McpPayload)
    case plain(McpPayload)

    var businessFields: [ToolBusinessField] {
        switch self {
        case .read(let payload): payload.fields
        case .grep(let payload): payload.fields
        case .glob(let payload): payload.fields
        case .diff(let payload): payload.fields
        case .terminal(let payload): payload.fields
        case .todo(let payload): payload.fields
        case .agent(let payload): payload.fields
        case .mcp(let payload), .plain(let payload): payload.fields
        }
    }

    var plainPreview: String {
        switch self {
        case .read(let payload): payload.lines.prefix(3).joined(separator: "\n")
        case .grep(let payload): payload.matches.prefix(3).joined(separator: "\n")
        case .glob(let payload): payload.files.prefix(3).joined(separator: "\n")
        case .diff(let payload): payload.stats ?? payload.path ?? ""
        case .terminal(let payload): payload.sections.map { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .todo(let payload): payload.rows.prefix(3).map { $0.content }.joined(separator: "\n")
        case .agent(let payload): payload.resultSummary ?? payload.prompt ?? ""
        case .mcp(let payload), .plain(let payload): payload.resultPreview
        }
    }

    var semanticFallback: McpPayload {
        switch self {
        case .mcp(let payload), .plain(let payload):
            payload
        default:
            McpPayload(title: "工具调用", fields: businessFields, resultPreview: plainPreview, rawText: plainPreview, isParseFallback: false)
        }
    }

    func semanticDiffPayload(message: ChatMessage, context: ChatMessage) -> DiffPayload {
        if case .diff(let payload) = self { return payload }
        return DiffPayload(path: context.toolFilePath ?? message.toolFilePath, stats: message.diffStatsSummary ?? context.diffStatsSummary, copyText: message.toolDetailText.nonEmptyTrimmed ?? context.toolDetailText, fields: businessFields)
    }

    func semanticReadPayload(message: ChatMessage, path: String?) -> ReadPayload {
        if case .read(let payload) = self { return payload }
        return ReadPayload(path: path ?? message.toolFilePath, lines: message.toolContentLines, startLine: message.toolStartLine ?? 1, copyText: message.toolDetailText, fields: businessFields)
    }

    func semanticGrepPayload(message: ChatMessage) -> GrepPayload {
        if case .grep(let payload) = self { return payload }
        return GrepPayload(pattern: message.toolSearchPattern, matches: message.toolContentLines, fields: businessFields)
    }

    func semanticGlobPayload(message: ChatMessage) -> GlobPayload {
        if case .glob(let payload) = self { return payload }
        return GlobPayload(pattern: message.toolSearchPattern, files: message.toolContentLines, fields: businessFields)
    }

    func semanticTodoPayload(message: ChatMessage, context: ChatMessage) -> TodoPayload {
        if case .todo(let payload) = self { return payload }
        return TodoPayload(rows: context.todoTaskRows.isEmpty ? message.todoTaskRows : context.todoTaskRows, fields: businessFields)
    }

    func semanticAgentPayload(message: ChatMessage, context: ChatMessage) -> AgentPayload {
        if case .agent(let payload) = self { return payload }
        return AgentPayload(title: context.subagentDisplayTitle, agentID: context.subagentID ?? message.subagentID, prompt: context.subagentPrompt ?? message.subagentPrompt, resultSummary: message.subagentResultSummary, fields: businessFields)
    }

    func semanticBashPayload(message: ChatMessage, context: ChatMessage) -> BashPayload {
        if case .terminal(let payload) = self { return payload }
        let sections = message.terminalVisualSections.isEmpty ? context.terminalVisualSections : message.terminalVisualSections
        return BashPayload(command: context.toolExecutedCommand ?? message.toolExecutedCommand, sections: sections, exitCode: message.terminalExitCode ?? context.terminalExitCode, fields: businessFields)
    }
}

final class ToolPayloadBox {
    let value: ToolPayload

    init(_ value: ToolPayload) {
        self.value = value
    }
}

enum ToolPayloadCache {
    private static let cache: NSCache<NSString, ToolPayloadBox> = {
        let cache = NSCache<NSString, ToolPayloadBox>()
        cache.countLimit = 800
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func payload(for message: ChatMessage, context: ChatMessage?) -> ToolPayload {
        let primary = context ?? message
        guard !message.isStreaming, !primary.isStreaming else {
            return ToolPayloadParser.payload(for: message, context: primary)
        }
        let key = [
            message.id.uuidString,
            primary.id.uuidString,
            message.status,
            primary.status,
            message.text.renderCacheFingerprint,
            primary.text.renderCacheFingerprint
        ].joined(separator: ":") as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let payload = ToolPayloadParser.payload(for: message, context: primary)
        let cost = message.text.utf8.count + primary.text.utf8.count
        cache.setObject(ToolPayloadBox(payload), forKey: key, cost: cost)
        return payload
    }
}

enum ToolPayloadParser {
    private static let protocolKeys = Set([
        "tool_use_id", "tooluseid", "call_id", "callid", "item_id", "itemid", "command_id", "commandid",
        "request_id", "requestid", "is_error", "iserror", "cache_control", "cachecontrol", "type", "name", "role",
        "parent_tool_use_id", "parenttooluseid", "server_name", "servername", "mcp_server", "mcpserver", "partial_json", "partialjson", "id"
    ])
    private static let businessKeys = Set([
        "path", "file", "filepath", "file_path", "filename", "notebook_path", "pattern", "query", "regex", "glob",
        "command", "cmd", "shell_command", "shellcommand", "url", "sql", "repo", "repository", "branch", "limit", "offset",
        "encoding", "cwd", "description", "prompt", "instruction", "instructions", "subagent_type", "subagenttype"
    ])
    private static let resultKeys = Set(["stdout", "stderr", "output", "result", "error", "message", "text", "content", "summary"])

    static func payload(for message: ChatMessage, context: ChatMessage) -> ToolPayload {
        let toolKey = context.toolKindKey.isEmpty ? message.toolKindKey : context.toolKindKey
        let fields = sanitizedFields(from: [context.text, message.text])
        if context.kind == .diff || message.kind == .diff || ["edit", "write", "multi_edit", "multiedit"].contains(toolKey) {
            return .diff(DiffPayload(path: context.toolFilePath ?? message.toolFilePath, stats: message.diffStatsSummary ?? context.diffStatsSummary, copyText: message.toolDetailText.nonEmptyTrimmed ?? context.toolDetailText, fields: fields))
        }
        if context.isTerminalTool || message.isTerminalTool {
            let sections = message.terminalVisualSections.isEmpty ? context.terminalVisualSections : message.terminalVisualSections
            return .terminal(BashPayload(command: context.toolExecutedCommand ?? message.toolExecutedCommand, sections: sections, exitCode: message.terminalExitCode ?? context.terminalExitCode, fields: fields))
        }
        if context.isAgentTool || message.isAgentTool {
            return .agent(AgentPayload(title: context.subagentDisplayTitle, agentID: context.subagentID ?? message.subagentID, prompt: context.subagentPrompt ?? message.subagentPrompt, resultSummary: message.subagentResultSummary, fields: fields))
        }
        if toolKey == "todowrite" {
            let rows = context.todoTaskRows.isEmpty ? message.todoTaskRows : context.todoTaskRows
            return .todo(TodoPayload(rows: rows, fields: fields))
        }
        if toolKey == "read" {
            return .read(ReadPayload(path: context.toolFilePath ?? message.toolFilePath, lines: message.toolContentLines, startLine: message.toolStartLine ?? context.toolStartLine ?? 1, copyText: message.toolDetailText, fields: fields))
        }
        if toolKey == "grep" {
            return .grep(GrepPayload(pattern: context.toolSearchPattern ?? message.toolSearchPattern, matches: message.toolContentLines, fields: fields))
        }
        if toolKey == "glob" {
            return .glob(GlobPayload(pattern: context.toolSearchPattern ?? message.toolSearchPattern, files: message.toolContentLines, fields: fields))
        }
        let result = resultPreview(from: message.text).nonEmptyTrimmed ?? resultPreview(from: context.text)
        let rawText = fullToolText(message: message, context: context)
        let parsed = jsonObject(from: message.text) != nil || jsonObject(from: context.text) != nil
        let title = context.toolPrimaryTitle == "tool" ? (message.toolPrimaryTitle == "tool" ? "工具调用" : message.toolPrimaryTitle) : context.toolPrimaryTitle
        let payload = McpPayload(title: title, fields: fields, resultPreview: result, rawText: rawText, isParseFallback: !parsed)
        return parsed ? .mcp(payload) : .plain(payload)
    }

    private static func sanitizedFields(from texts: [String]) -> [ToolBusinessField] {
        var fields: [ToolBusinessField] = []
        var seen: Set<String> = []
        for text in texts {
            if let object = jsonObject(from: text) {
                collectFields(in: object, into: &fields, seen: &seen)
            } else {
                collectLooseFields(in: text, into: &fields, seen: &seen)
            }
            if fields.count >= 12 { break }
        }
        return Array(fields.prefix(12))
    }

    private static func collectFields(in object: Any, into fields: inout [ToolBusinessField], seen: inout Set<String>) {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalized = normalizedKey(key)
                guard !protocolKeys.contains(normalized) else { continue }
                if businessKeys.contains(normalized), let text = fieldValue(value), !text.isEmpty, seen.insert(normalized).inserted {
                    fields.append(ToolBusinessField(key: displayKey(key), value: text))
                }
                collectFields(in: value, into: &fields, seen: &seen)
                if fields.count >= 12 { return }
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectFields(in: value, into: &fields, seen: &seen)
                if fields.count >= 12 { return }
            }
        } else if let string = object as? String, let nested = jsonObject(from: string) {
            collectFields(in: nested, into: &fields, seen: &seen)
        }
    }

    private static func collectLooseFields(in text: String, into fields: inout [ToolBusinessField], seen: inout Set<String>) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedKey(key)
            guard businessKeys.contains(normalized), !protocolKeys.contains(normalized), seen.insert(normalized).inserted else { continue }
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                fields.append(ToolBusinessField(key: displayKey(key), value: plainPreview(value, limit: 220)))
            }
            if fields.count >= 12 { return }
        }
    }

    private static func resultPreview(from text: String) -> String {
        if let object = jsonObject(from: text) {
            return firstResultString(in: object).map { plainPreview($0, limit: 2_000) } ?? ""
        }
        return plainPreview(text, limit: 2_000)
    }

    private static func fullToolText(message: ChatMessage, context: ChatMessage) -> String {
        var parts: [String] = []
        let contextText = fullToolText(from: context.text)
        let messageText = fullToolText(from: message.text)
        if !contextText.isEmpty {
            parts.append(context.kind == .toolCall || context.kind == .command ? "调用参数\n\(contextText)" : contextText)
        }
        if message.id != context.id, !messageText.isEmpty {
            parts.append(message.kind == .toolResult || message.kind == .commandOutput ? "回调内容\n\(messageText)" : messageText)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func fullToolText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let object = jsonObject(from: trimmed), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let value = String(data: data, encoding: .utf8) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isInternalToolNoiseLine }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstResultString(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalized = normalizedKey(key)
                guard !protocolKeys.contains(normalized) else { continue }
                if resultKeys.contains(normalized), let text = fieldValue(value), !text.isEmpty {
                    return text
                }
            }
            for (key, value) in dictionary where !protocolKeys.contains(normalizedKey(key)) {
                if let text = firstResultString(in: value) { return text }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let text = firstResultString(in: value) { return text }
            }
        }
        if let string = object as? String, let nested = jsonObject(from: string) {
            return firstResultString(in: nested) ?? string
        }
        return nil
    }

    private static func fieldValue(_ value: Any) -> String? {
        if let string = value as? String {
            if let nested = jsonObject(from: string), let nestedText = firstResultString(in: nested) {
                return plainPreview(nestedText, limit: 600)
            }
            return plainPreview(string, limit: 600)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any] {
            let values = array.compactMap(fieldValue)
            return values.isEmpty ? nil : plainPreview(values.joined(separator: ", "), limit: 600)
        }
        return nil
    }

    private static func jsonObject(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").lowercased()
    }

    private static func displayKey(_ key: String) -> String {
        switch normalizedKey(key) {
        case "filepath", "file_path": return "path"
        case "shellcommand", "shell_command", "cmd": return "command"
        case "subagenttype", "subagent_type": return "agent"
        default: return key
        }
    }

    private static func plainPreview(_ text: String, limit: Int) -> String {
        let filtered = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isInternalToolNoiseLine }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard filtered.count > limit else { return filtered }
        return String(filtered.prefix(limit)) + "…"
    }
}

extension ChatMessageKind {
    var isToolDetailMonospaced: Bool {
        switch self {
        case .toolCall, .toolResult, .command, .commandOutput:
            true
        case .user, .assistant, .reasoning, .permissionRequest, .interactiveRequest, .diff, .error, .system, .result, .rawOutput:
            false
        }
    }

    var isVisibleInTranscript: Bool {
        switch self {
        case .system:
            false
        case .user, .assistant, .reasoning, .toolCall, .toolResult, .command, .commandOutput, .permissionRequest, .interactiveRequest, .diff, .error, .result, .rawOutput:
            true
        }
    }
}

final class OptionalStringBox {
    let value: String?

    init(_ value: String?) {
        self.value = value
    }
}

final class StringArrayBox {
    let value: [String]

    init(_ value: [String]) {
        self.value = value
    }
}

enum ChatToolHotPathCache {
    static let stringValues: NSCache<NSString, OptionalStringBox> = {
        let cache = NSCache<NSString, OptionalStringBox>()
        cache.countLimit = 1_600
        return cache
    }()

    static let contentLines: NSCache<NSString, StringArrayBox> = {
        let cache = NSCache<NSString, StringArrayBox>()
        cache.countLimit = 800
        return cache
    }()

    static let toolNames: NSCache<NSString, OptionalStringBox> = {
        let cache = NSCache<NSString, OptionalStringBox>()
        cache.countLimit = 1_200
        return cache
    }()

    static let agentIDs: NSCache<NSString, OptionalStringBox> = {
        let cache = NSCache<NSString, OptionalStringBox>()
        cache.countLimit = 800
        return cache
    }()

    static let blockedToolNames = Set([
        "tool use", "tool result", "input json delta", "json delta", "content block", "content block delta",
        "item started", "item completed", "message start", "message stop", "raw", "done"
    ])

    static let agentIDRegexes: [NSRegularExpression] = [
        #"agentId:\s*([A-Za-z0-9_-]+)"#,
        #"agent_id:\s*([A-Za-z0-9_-]+)"#,
        #"\"agentId\"\s*:\s*\"([^\"]+)\""#,
        #"\"agent_id\"\s*:\s*\"([^\"]+)\""#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

extension ChatMessage {
    private static let maxToolCodePreviewLines = 300

    var isToolInvocationStart: Bool {
        kind == .toolCall || kind == .command
    }

    var isToolInvocationBoundary: Bool {
        switch kind {
        case .user, .assistant, .reasoning, .permissionRequest, .interactiveRequest, .error, .result, .rawOutput:
            true
        case .toolCall, .command:
            true
        case .toolResult, .commandOutput, .diff, .system:
            false
        }
    }

    func isToolInvocationFeedback(for primary: ChatMessage) -> Bool {
        switch (primary.kind, kind) {
        case (.command, .commandOutput), (.toolCall, .toolResult):
            if let primaryID = primary.toolCorrelationID, let feedbackID = toolCorrelationID {
                return primaryID == feedbackID
            }
            return primary.requestID == nil && requestID == nil
        default:
            return false
        }
    }

    var isNoisyRawTranscriptEvent: Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind == .result {
            return normalizedTitle == "result" && normalizedSubtitle == "success"
        }
        guard kind == .rawOutput else { return false }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return true }
        if ["content_block_delta", "content_block_start", "content_block_stop", "input_json_delta", "message_delta", "message_start", "message_stop", "ping", "signature_delta", "stream_event", "user"].contains(normalizedTitle) {
            return true
        }
        return normalizedTitle == "raw" && normalizedSubtitle == "claude code" && normalizedText.isClaudeProtocolRawLine
    }

    var toolCorrelationID: String? {
        if let requestID = requestID?.nonEmptyTrimmed { return requestID }
        if kind == .toolResult,
           let resultID = firstToolStringValue(keys: ["tool_use_id", "toolUseId"], in: text) {
            return resultID
        }
        return firstToolStringValue(keys: ["call_id", "callId", "item_id", "itemId", "command_id", "commandId", "id"], in: text)
    }

    var toolDisplayTitle: String {
        toolPrimaryTitle
    }

    var toolPrimaryTitle: String {
        let name = toolName
        if !name.isEmpty {
            return displayToolName(name)
        }
        switch kind {
        case .toolCall, .toolResult:
            return "tool"
        case .command:
            return "command"
        case .commandOutput:
            return "output"
        case .diff:
            return "diff"
        default:
            return "tool"
        }
    }

    var toolDetailLabel: String {
        if kind == .diff { return "diff" }
        if isTerminalTool { return "terminal" }
        return "details"
    }

    var toolActionSummary: String {
        switch toolName.lowercased() {
        case "read": return "读取文件内容"
        case "grep": return "搜索代码匹配"
        case "glob": return "匹配文件列表"
        case "edit": return "修改已有文件"
        case "write": return "写入文件内容"
        case "bash": return "执行终端命令"
        case "todowrite": return "更新任务列表"
        case "agent": return "启动子代理"
        default:
            if kind == .diff { return "代码变更预览" }
            if isTerminalTool { return "执行终端任务" }
            if kind == .toolResult { return "工具返回结果" }
            return "调用工具"
        }
    }

    var toolSystemImage: String {
        switch toolName.lowercased() {
        case "read": return "doc.text.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "glob": return "folder"
        case "edit": return "pencil.line"
        case "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "todowrite": return "checklist"
        case "agent": return "person.crop.circle.badge.gearshape"
        default:
            if kind == .diff { return "plus.forwardslash.minus" }
            if isTerminalTool { return "terminal" }
            if kind == .toolResult { return "checkmark.seal" }
            return "hammer"
        }
    }

    var toolTint: Color {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus.contains("fail") || normalizedStatus.contains("error") { return .red }
        if normalizedStatus == "stopped" { return .secondary }
        switch toolName.lowercased() {
        case "read", "grep", "glob": return .blue
        case "edit": return .orange
        case "write": return .green
        case "bash": return .purple
        case "todowrite", "agent": return .secondary
        default:
            if kind == .diff { return .orange }
            if kind == .toolResult { return .green }
            return .secondary
        }
    }

    var toolStatusLabel: String {
        if isStreaming { return "Running" }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fail") || normalized.contains("error") { return "Failed" }
        if normalized == "stopped" { return "Warning" }
        if normalized == "done" || normalized == "success" || normalized == "completed" { return "Success" }
        return normalized.isEmpty ? "Success" : status
    }

    var toolStatusKind: ToolRunStatusKind {
        if isStreaming { return .running }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fail") || normalized.contains("error") { return .failed }
        if normalized == "stopped" || normalized.contains("warn") { return .warning }
        return .success
    }

    var toolDurationText: String? {
        firstToolStringValue(keys: ["duration", "duration_ms", "durationMs", "elapsed", "elapsed_ms", "elapsedMs"], in: text).map { value in
            if let number = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " mssec"))) {
                return number >= 1000 ? String(format: "%.1fs", number / 1000.0) : "\(Int(number))ms"
            }
            return value
        }
    }

    var toolSearchPattern: String? {
        firstToolStringValue(keys: ["pattern", "query", "regex", "glob"], in: text)
    }

    var toolStartLine: Int? {
        firstToolStringValue(keys: ["start_line", "startLine", "line", "offset"], in: text).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var terminalExitCode: Int? {
        firstToolStringValue(keys: ["exit_code", "exitCode", "code", "status_code", "statusCode"], in: text).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var toolContentLines: [String] {
        let key = toolCacheKey(prefix: "content-lines")
        if let cached = ChatToolHotPathCache.contentLines.object(forKey: key) {
            return cached.value
        }
        let lines = toolDetailText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty, !line.isInternalToolNoiseLine else { return false }
                let lowercased = line.lowercased()
                return !["tool:", "path:", "file:", "input:", "args:", "arguments:", "params:", "result:", "output:", "text:", "message:"].contains(lowercased)
            }
        ChatToolHotPathCache.contentLines.setObject(StringArrayBox(lines), forKey: key)
        return lines
    }

    var toolLineRangeSummary: String? {
        let count = toolContentLines.count
        guard count > 0 else { return nil }
        if let start = toolStartLine {
            return "lines \(start)-\(start + count - 1) (\(count) lines)"
        }
        return "\(count) lines"
    }

    var toolKindKey: String {
        toolName.lowercased()
    }

    var isAgentTool: Bool {
        // ONLY the actual sub-agent–spawning tool (Agent/Task). Previously this also returned
        // true for any message whose text merely contained an agentId/agent_id field — which
        // includes a running sub-agent's INNER tool calls (Grep/Read), so the floating pill
        // counted every inner tool as a separate "running agent" (the bogus "N 个 Agent 运行中").
        let key = toolName.lowercased()
        return key == "agent" || key == "task"
    }

    var isExitPlanModeCall: Bool {
        guard kind == .toolCall else { return false }
        let normalized = toolName.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        return normalized == "exitplanmode"
    }

    var exitPlanModePlan: String {
        if let plan = firstToolStringValue(keys: ["plan", "summary", "content"], in: text)?.nonEmptyTrimmed {
            return plan
        }
        if exitPlanModeAllowedPromptsSummary(from: text) != nil {
            return ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object) {
            return ""
        }
        return trimmed
    }

    private func exitPlanModeAllowedPromptsSummary(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return exitPlanModeAllowedPromptsSummary(from: object)
    }

    private func exitPlanModeAllowedPromptsSummary(from object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where key.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").lowercased() == "allowedprompts" {
                if let summary = exitPlanModeAllowedPromptsSummary(fromAllowedPrompts: value) {
                    return summary
                }
            }
            for value in dictionary.values {
                if let summary = exitPlanModeAllowedPromptsSummary(from: value) {
                    return summary
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let summary = exitPlanModeAllowedPromptsSummary(from: value) {
                    return summary
                }
            }
        } else if let string = object as? String,
                  let data = string.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let nested = try? JSONSerialization.jsonObject(with: data) {
            return exitPlanModeAllowedPromptsSummary(from: nested)
        }
        return nil
    }

    private func exitPlanModeAllowedPromptsSummary(fromAllowedPrompts value: Any) -> String? {
        let items: [String]
        if let array = value as? [Any] {
            items = array.enumerated().compactMap { exitPlanModeAllowedPromptLine(from: $0.element, index: $0.offset) }
        } else if let dictionary = value as? [String: Any] {
            items = exitPlanModeAllowedPromptLine(from: dictionary, index: 0).map { [$0] } ?? []
        } else if let string = value as? String {
            let trimmed = Self.previewSnippet(string, limit: 96)
            items = trimmed.isEmpty ? [] : [trimmed]
        } else {
            items = []
        }
        guard !items.isEmpty else { return nil }
        let visibleItems = Array(items.prefix(4))
        var lines = ["允许的提示"]
        lines.append(contentsOf: visibleItems.map { "- \($0)" })
        if items.count > visibleItems.count {
            lines.append("- 还有 \(items.count - visibleItems.count) 项")
        }
        return lines.joined(separator: "\n")
    }

    private func exitPlanModeAllowedPromptLine(from item: Any, index: Int) -> String? {
        if let string = item as? String {
            let trimmed = Self.previewSnippet(string, limit: 96)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dictionary = item as? [String: Any] {
            let tool = firstToolStringValue(in: dictionary, keySet: Set(["tool", "tool_name", "toolname", "name"]))?.nonEmptyTrimmed
            let prompt = firstToolStringValue(in: dictionary, keySet: Set(["prompt", "summary", "content", "text", "description"]))?.nonEmptyTrimmed
            switch (tool, prompt) {
            case let (tool?, prompt?):
                return "\(displayToolName(tool))：\(Self.previewSnippet(prompt, limit: 96))"
            case let (tool?, nil):
                return displayToolName(tool)
            case let (nil, prompt?):
                return Self.previewSnippet(prompt, limit: 96)
            default:
                if let title = firstToolStringValue(in: dictionary, keySet: Set(["title", "label", "header"]))?.nonEmptyTrimmed {
                    return Self.previewSnippet(title, limit: 96)
                }
                return nil
            }
        }
        if let array = item as? [Any] {
            return array.enumerated().compactMap { exitPlanModeAllowedPromptLine(from: $0.element, index: $0.offset) }.first
        }
        return nil
    }

    var subagentID: String? {
        if let value = firstToolStringValue(keys: ["agentId", "agent_id", "task_id", "taskId"], in: text) {
            return Self.normalizedAgentID(value)
        }
        return Self.agentID(from: text)
    }

    var taskStartedToolUseID: String? {
        firstToolStringValue(keys: ["tool_use_id", "toolUseId", "parent_tool_use_id", "parentToolUseId"], in: text)
    }

    var subagentTaskID: String? {
        firstToolStringValue(keys: ["task_id", "taskId", "agentId", "agent_id"], in: text).flatMap(Self.normalizedAgentID)
    }

    var subagentDisplayTitle: String {
        let type = subagentType ?? "Agent"
        if let description = subagentDescription {
            return "\(type) · \(description)"
        }
        return type
    }

    var subagentPrompt: String? {
        firstToolStringValue(keys: ["prompt", "instruction", "instructions"], in: text).map { Self.previewSnippet($0, limit: 420) }
    }

    var subagentResultSummary: String? {
        Self.firstUsefulLine(toolDetailText).map { Self.previewSnippet($0, limit: 420) }
    }

    func subagentDetailRequest(projectPath: String?) -> SubagentDetailRequest? {
        guard isAgentTool else { return nil }
        return SubagentDetailRequest(
            agentID: subagentID,
            agentType: subagentType ?? "Agent",
            description: subagentDescription ?? subagentResultSummary ?? "子代理",
            projectPath: projectPath
        )
    }

    private var subagentType: String? {
        firstToolStringValue(keys: ["subagent_type", "subagentType", "agentType", "agent_type"], in: text)
    }

    private var subagentDescription: String? {
        firstToolStringValue(keys: ["description", "summary", "title"], in: text)
    }

    func cheapToolHeaderSummary(toolKey: String) -> String? {
        if toolKey == "todowrite" { return "任务列表" }
        if toolKey == "agent" { return "Agent" }
        let primaryTitle = toolPrimaryTitle.lowercased()
        for value in [subtitle, title] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("{"),
                  !trimmed.contains("}"),
                  !trimmed.contains("\n"),
                  trimmed.lowercased() != primaryTitle else { continue }
            return Self.previewSnippet(trimmed, limit: 72)
        }
        return nil
    }

    var toolPlainSummary: String? {
        switch toolName.lowercased() {
        case "read", "edit", "write", "multi_edit", "multiedit":
            return toolFilePath.map(Self.displayFileName)
        case "grep":
            if let path = toolFilePath { return Self.displayFileName(path) }
            return firstToolStringValue(keys: ["pattern", "query", "regex"], in: text).map { Self.previewSnippet($0, limit: 56) }
        case "glob":
            return firstToolStringValue(keys: ["pattern", "glob", "path"], in: text).map { Self.previewSnippet($0, limit: 56) }
        case "bash":
            return toolExecutedCommand.map { Self.previewSnippet($0, limit: 72) }
        case "todowrite":
            return "任务列表"
        case "agent":
            return subagentDisplayTitle
        default:
            if toolKindKey == "agent" { return subagentDisplayTitle }
            if kind == .diff { return toolFilePath.map(Self.displayFileName) }
            if let path = toolFilePath { return Self.displayFileName(path) }
            if let command = toolExecutedCommand { return Self.previewSnippet(command, limit: 72) }
            return Self.firstUsefulLine(toolDetailText).map { Self.previewSnippet($0, limit: 72) }
        }
    }

    var toolExecutionSummary: String? {
        switch toolName.lowercased() {
        case "read":
            if let path = toolFilePath { return "读取 \(Self.displayFileName(path))" }
            return "读取文件内容"
        case "grep":
            if let pattern = firstToolStringValue(keys: ["pattern", "query", "regex"], in: text) {
                return "搜索 \(Self.previewSnippet(pattern))"
            }
            return "搜索代码匹配"
        case "glob":
            if let pattern = firstToolStringValue(keys: ["pattern", "glob", "path"], in: text) {
                return "匹配 \(Self.previewSnippet(pattern))"
            }
            return "匹配文件列表"
        case "edit", "multi_edit", "multiedit":
            if let path = toolFilePath { return "编辑 \(Self.displayFileName(path))" }
            if let replacement = firstToolStringValue(keys: ["new_string", "newString", "replacement"], in: text) {
                return "替换为 \(Self.previewSnippet(replacement))"
            }
            return "编辑文件"
        case "write":
            if let path = toolFilePath { return "写入 \(Self.displayFileName(path))" }
            return "写入文件"
        case "bash":
            if let command = toolExecutedCommand { return "$ \(Self.previewSnippet(command, limit: 86))" }
            return "执行终端命令"
        case "todowrite":
            return "更新任务列表"
        case "agent":
            return subagentDisplayTitle
        default:
            if kind == .diff, let path = toolFilePath { return "变更 \(Self.displayFileName(path))" }
            if let command = toolExecutedCommand { return "$ \(Self.previewSnippet(command, limit: 86))" }
            if let path = toolFilePath { return Self.displayFileName(path) }
            return Self.firstUsefulLine(toolDetailText).map { Self.previewSnippet($0) }
        }
    }

    var toolExecutionSystemImage: String {
        switch toolName.lowercased() {
        case "read": return "doc.text.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "glob": return "folder.badge.gearshape"
        case "edit", "multi_edit", "multiedit": return "text.cursor"
        case "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "todowrite": return "checklist"
        case "agent": return "person.crop.circle.badge.gearshape"
        default:
            if kind == .diff { return "plus.forwardslash.minus" }
            if isTerminalTool { return "terminal" }
            return "info.circle"
        }
    }

    var todoTaskRows: [(content: String, status: String)] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return Self.todoTaskRows(fromPlainText: toolDetailText)
        }
        let rows = Self.todoTaskRows(in: object)
        return rows.isEmpty ? Self.todoTaskRows(fromPlainText: toolDetailText) : rows
    }

    private static func todoTaskRows(in object: Any) -> [(content: String, status: String)] {
        if let dictionary = object as? [String: Any] {
            if let todos = caseInsensitiveValue("todos", in: dictionary) as? [Any] {
                let rows = todos.compactMap(todoTaskRow(from:))
                if !rows.isEmpty { return rows }
            }
            for key in ["input", "args", "arguments", "params", "data", "message", "content"] {
                guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
            for value in dictionary.values {
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
        }
        if let array = object as? [Any] {
            let rows = array.compactMap(todoTaskRow(from:))
            if !rows.isEmpty { return rows }
            for value in array {
                let rows = todoTaskRows(in: value)
                if !rows.isEmpty { return rows }
            }
        }
        if let string = object as? String,
           let data = string.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) {
            return todoTaskRows(in: nested)
        }
        return []
    }

    private static func todoTaskRow(from object: Any) -> (content: String, status: String)? {
        guard let dictionary = object as? [String: Any],
              let content = todoStringValue(for: ["content", "title", "task", "demand"], in: dictionary) else { return nil }
        let status = todoStringValue(for: ["status"], in: dictionary)?.lowercased() ?? ""
        return (content, status)
    }

    private static func todoTaskRows(fromPlainText value: String) -> [(content: String, status: String)] {
        for fragment in todoJSONFragments(in: value) {
            guard let data = fragment.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let rows = todoTaskRows(in: object)
            if !rows.isEmpty { return rows }
        }

        let objectRows = todoObjectRows(fromPlainText: value)
        if !objectRows.isEmpty { return objectRows }

        return todoContentRows(fromPlainText: value)
    }

    private static func todoJSONFragments(in value: String) -> [String] {
        var fragments: [String] = []
        var startIndex: String.Index?
        var stack: [Character] = []
        var isInsideString = false
        var isEscaped = false
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" || character == "[" {
                if stack.isEmpty { startIndex = index }
                stack.append(character)
            } else if character == "}" || character == "]" {
                if let last = stack.last, (last == "{" && character == "}" || last == "[" && character == "]") {
                    stack.removeLast()
                    if stack.isEmpty, let fragmentStartIndex = startIndex {
                        fragments.append(String(value[fragmentStartIndex...index]))
                        startIndex = nil
                    }
                } else {
                    stack.removeAll()
                    startIndex = nil
                }
            }
            index = value.index(after: index)
        }

        return fragments
    }

    private static func todoObjectRows(fromPlainText value: String) -> [(content: String, status: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"\{[^{}]*"content"\s*:\s*"(?:\\.|[^"\\])*"[^{}]*\}"#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value),
                  let data = String(value[matchRange]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return todoTaskRow(from: object)
        }
    }

    private static func todoContentRows(fromPlainText value: String) -> [(content: String, status: String)] {
        guard let regex = try? NSRegularExpression(pattern: #""content"\s*:\s*"((?:\\.|[^"\\])*)""#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: value) else { return nil }
            let content = unescapedJSONString(String(value[contentRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : (content, "")
        }
    }

    private static func unescapedJSONString(_ value: String) -> String {
        guard let data = "\"\(value)\"".data(using: .utf8),
              let string = try? JSONSerialization.jsonObject(with: data) as? String else { return value }
        return string
    }

    private static func todoStringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = caseInsensitiveValue(key, in: dictionary) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func caseInsensitiveValue(_ key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    var diffStatsSummary: String? {
        let added = diffLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = diffLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        guard added > 0 || removed > 0 else { return nil }
        return "+\(added) / -\(removed)"
    }

    var toolCodePreview: ToolCodePreview? {
        if kind == .diff {
            return diffCodePreview
        }
        switch toolName.lowercased() {
        case "multi_edit", "multiedit":
            return multiEditCodePreview ?? editCodePreview
        case "edit":
            return editCodePreview
        case "write", "create", "create_file", "new_file":
            return writeCodePreview
        default:
            return nil
        }
    }

    private var diffCodePreview: ToolCodePreview? {
        let path = toolFilePath ?? "changes.diff"
        let changeStats = ToolChangeStats(
            added: diffLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count,
            removed: diffLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        )
        let lines = diffLines.lazy
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("+++") && !$0.hasPrefix("---") && !$0.hasPrefix("@@") }
            .prefix(Self.maxToolCodePreviewLines)
            .map(Self.previewLine(from:))
        guard !lines.isEmpty else { return nil }
        return ToolCodePreview(title: Self.displayFileName(path), path: path, stats: diffStatsSummary ?? "代码变更", changeStats: changeStats, lines: Array(lines))
    }

    private var editCodePreview: ToolCodePreview? {
        guard let path = toolFilePath else { return nil }
        var lines: [ToolCodePreview.Line] = []
        var added = 0
        var removed = 0
        if let oldValue = firstToolStringValue(keys: ["old_string", "oldString", "old", "before"], in: text) {
            removed = oldValue.split(separator: "\n", omittingEmptySubsequences: false).count
            lines.append(contentsOf: Self.previewContentLines(oldValue, marker: "-", tint: .red, limit: Self.maxToolCodePreviewLines / 2))
        }
        if let newValue = firstToolStringValue(keys: ["new_string", "newString", "replacement", "after"], in: text) {
            added = newValue.split(separator: "\n", omittingEmptySubsequences: false).count
            lines.append(contentsOf: Self.previewContentLines(newValue, marker: "+", tint: .green, limit: Self.maxToolCodePreviewLines / 2))
        }
        guard !lines.isEmpty else { return nil }
        let stats = diffStatsSummary ?? "+\(added) / -\(removed)"
        return ToolCodePreview(title: Self.displayFileName(path), path: path, stats: stats, changeStats: ToolChangeStats(added: added, removed: removed), lines: lines)
    }

    private var writeCodePreview: ToolCodePreview? {
        guard let path = toolFilePath,
              let content = firstToolStringValue(keys: ["content", "text", "source", "new_string", "newString"], in: text) else { return nil }
        let lines = Self.previewContentLines(content, marker: "+", tint: .green, limit: Self.maxToolCodePreviewLines)
        guard !lines.isEmpty else { return nil }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return ToolCodePreview(title: Self.displayFileName(path), path: path, stats: "写入 \(lineCount) 行", changeStats: ToolChangeStats(added: lineCount, removed: 0), lines: lines)
    }

    /// Completed MultiEdit preview: iterate EVERY edit in the `edits` array (the single-pair
    /// `editCodePreview`/`firstToolStringValue` path only ever surfaces the first edit).
    private var multiEditCodePreview: ToolCodePreview? {
        guard let path = toolFilePath,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let edits = Self.firstEditsArray(in: object), !edits.isEmpty else { return nil }
        var lines: [ToolCodePreview.Line] = []
        var added = 0
        var removed = 0
        let perEditLimit = max(2, Self.maxToolCodePreviewLines / max(1, min(edits.count, 8)))
        for edit in edits {
            if lines.count >= Self.maxToolCodePreviewLines { break }
            if let oldValue = (edit["old_string"] as? String) ?? (edit["oldString"] as? String), !oldValue.isEmpty {
                removed += oldValue.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append(contentsOf: Self.previewContentLines(oldValue, marker: "-", tint: .red, limit: perEditLimit))
            }
            if let newValue = (edit["new_string"] as? String) ?? (edit["newString"] as? String), !newValue.isEmpty {
                added += newValue.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append(contentsOf: Self.previewContentLines(newValue, marker: "+", tint: .green, limit: perEditLimit))
            }
        }
        guard !lines.isEmpty else { return nil }
        return ToolCodePreview(
            title: Self.displayFileName(path),
            path: path,
            stats: "+\(added) / -\(removed)",
            changeStats: ToolChangeStats(added: added, removed: removed),
            lines: Array(lines.prefix(Self.maxToolCodePreviewLines))
        )
    }

    private static func firstEditsArray(in object: Any) -> [[String: Any]]? {
        if let dictionary = object as? [String: Any] {
            if let edits = dictionary["edits"] as? [[String: Any]] { return edits }
            for value in dictionary.values {
                if let found = firstEditsArray(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = firstEditsArray(in: value) { return found }
            }
        }
        return nil
    }

    var isTerminalTool: Bool {
        if kind == .command || kind == .commandOutput { return true }
        let values = [title, subtitle, toolPrimaryTitle].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return values.contains { value in
            value == "bash" || value == "shell" || value == "command" || value == "exec" || value.contains("commandexecution")
        }
    }

    var toolExecutedCommand: String? {
        guard !isBackendLaunchCommand else { return nil }
        if let value = firstToolStringValue(keys: ["command", "cmd", "shell_command", "shellCommand"], in: text) {
            return value
        }
        return textCommandValue(from: text)
    }

    var terminalOutputText: String {
        if let value = firstToolStringValue(keys: ["stderr", "stdout", "output", "result", "error"], in: text),
           let cleaned = cleanedTerminalOutput(value) {
            return cleaned
        }
        guard kind == .commandOutput || kind == .toolResult else { return "" }
        return cleanedTerminalOutput(text) ?? ""
    }

    var terminalVisualSections: [(label: String, text: String)] {
        terminalOutputSections
    }

    private var terminalOutputSections: [(label: String, text: String)] {
        let stdout = cleanedTerminalOutput(firstToolStringValue(keys: ["stdout"], in: text))
        let stderr = cleanedTerminalOutput(firstToolStringValue(keys: ["stderr"], in: text))
        var sections: [(String, String)] = []
        if let stdout, !stdout.isEmpty {
            sections.append(("stdout", stdout))
        }
        if let stderr, !stderr.isEmpty {
            sections.append(("stderr", stderr))
        }
        if !sections.isEmpty { return sections }
        if let output = cleanedTerminalOutput(firstToolStringValue(keys: ["output", "result", "error"], in: text)) {
            return [("output", output)]
        }
        let fallback = terminalOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [] : [("output", fallback)]
    }

    private func cleanedTerminalOutput(_ value: String?) -> String? {
        guard let value else { return nil }
        return cleanedTerminalOutput(value)
    }

    private func cleanedTerminalOutput(_ value: String) -> String? {
        let lines = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !Self.isTerminalWrapperLine($0) }
        let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static func isTerminalWrapperLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("to=") || lowercased.hasPrefix("recipient=") || lowercased.hasPrefix("tool_use_id") || lowercased.hasPrefix("call_id") {
            return true
        }
        if lowercased == "tool:" || lowercased == "input:" || lowercased == "args:" || lowercased == "arguments:" || lowercased == "params:" || lowercased == "result:" || lowercased == "message:" || lowercased == "text:" {
            return true
        }
        if lowercased.hasPrefix("type: ") || lowercased.hasPrefix("name: ") || lowercased.hasPrefix("role: ") || lowercased.hasPrefix("is_error: ") {
            return true
        }
        return false
    }

    var terminalDetailText: String {
        var parts: [String] = []
        let commandText = toolExecutedCommand
        if let commandText {
            parts.append("$ \(commandText)")
        }
        for section in terminalOutputSections {
            if let commandText, section.text == commandText { continue }
            let needsLabel = terminalOutputSections.count > 1 || section.label == "stderr"
            parts.append(needsLabel ? "[\(section.label)]\n\(section.text)" : section.text)
        }
        return parts.joined(separator: "\n\n")
    }

    var terminalDetailPreviewText: String {
        let detail = terminalDetailText
        guard detail.count > 16_000 else { return detail }
        return String(detail.prefix(16_000)) + "\n\n…终端输出过长，已暂停完整渲染；复制详情可获取完整内容。"
    }

    var toolDetailText: String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        if let visual = visualFormattedJSONObject(body) {
            return visual
        }
        let filtered = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isInternalToolNoiseLine }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered
    }

    var toolDetailPreviewText: String {
        let detail = toolDetailText
        guard detail.count > 16_000 else { return detail }
        return String(detail.prefix(16_000)) + "\n\n…详情过长，已暂停完整渲染；复制详情可获取完整内容。"
    }

    var toolHeaderFileIsOpenable: Bool {
        if kind == .diff { return true }
        let toolKey = toolKindKey
        return toolKey == "read"
            || ["edit", "write", "create", "create_file", "new_file", "multi_edit", "multiedit"].contains(toolKey)
    }

    var toolFilePath: String? {        if let path = jsonToolFilePath(from: text) {
            return path
        }
        if let loosePath = firstToolStringValue(keys: ["file_path", "filePath", "filepath", "path", "filename", "notebook_path"], in: text),
           let path = normalizedToolPath(loosePath) {
            return path
        }
        for value in [title, subtitle, text] {
            if let path = textToolFilePath(from: value) {
                return path
            }
        }
        return nil
    }

    var isBackendLaunchCommand: Bool {
        guard kind == .command else { return false }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedTitle == "claude" || normalizedTitle == "codex" else { return false }
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedStatus == "start"
            || body.contains(" --output-format stream-json")
            || body.contains(" app-server")
    }

    private var toolName: String {
        let key = toolCacheKey(prefix: "tool-name", includesBody: false)
        if let cached = ChatToolHotPathCache.toolNames.object(forKey: key) {
            return cached.value ?? ""
        }
        let value = (Self.normalizedToolName(title) ?? Self.normalizedToolName(subtitle)) ?? ""
        ChatToolHotPathCache.toolNames.setObject(OptionalStringBox(value.isEmpty ? nil : value), forKey: key)
        return value
    }

    private static func normalizedToolName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("{"), !value.contains("}") else { return nil }
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
        guard !ChatToolHotPathCache.blockedToolNames.contains(normalized), !normalized.contains("json delta") else { return nil }
        if value.contains("/") && value.lowercased().contains("item/") { return nil }
        return value
    }

    private func displayToolName(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bash": return "Bash"
        case "read": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "edit": return "Edit"
        case "multi_edit", "multiedit": return "MultiEdit"
        case "write": return "Write"
        case "todowrite": return "任务列表"
        case "agent": return "Agent"
        default: return value
        }
    }

    private func firstToolStringValue(keys: [String], in body: String) -> String? {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = toolStringValueCacheKey(keys: keys, body: body)
        if let cached = ChatToolHotPathCache.stringValues.object(forKey: key) {
            return cached.value
        }
        let value: String?
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let jsonValue = firstToolStringValue(in: object, keySet: Set(keys.map { $0.lowercased() })) {
            value = jsonValue
        } else {
            value = looseToolStringValue(keys: keys, in: body)
        }
        ChatToolHotPathCache.stringValues.setObject(OptionalStringBox(value), forKey: key)
        return value
    }

    private func firstToolStringValue(in object: Any, keySet: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keySet.contains(key.lowercased()) {
                if let text = readableToolValue(value) {
                    return text
                }
            }
            for value in dictionary.values {
                if let text = firstToolStringValue(in: value, keySet: keySet) {
                    return text
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let text = firstToolStringValue(in: value, keySet: keySet) {
                    return text
                }
            }
        }
        return nil
    }

    private func looseToolStringValue(keys: [String], in body: String) -> String? {
        for key in keys {
            let quotedMarkers = ["\"\(key)\":\"", "\"\(key)\": \""]
            for marker in quotedMarkers {
                guard let range = body.range(of: marker) else { continue }
                let tail = body[range.upperBound...]
                var value = ""
                var isEscaped = false
                for character in tail {
                    if isEscaped {
                        value.append(character)
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                        break
                    } else {
                        value.append(character)
                    }
                }
            }
        }
        return nil
    }

    /// Like `looseToolStringValue` but returns the in-progress value of a JSON string field
    /// even when the closing quote hasn't streamed yet, and unescapes JSON escapes correctly
    /// (`\n`, `\t`, `\"`, `\\`, `\uXXXX`, …). Used to stream Write/Edit content into the card
    /// as the model types it, before the tool input JSON is complete.
    func streamingToolStringValue(keys: [String], in body: String) -> String? {
        // The card preview only renders the first ~300 lines, so cap how much of the (possibly
        // huge, still-growing) value we scan/copy per render. Without this, a large file write
        // re-scans the whole content on every delta — O(n²) over the stream.
        let maxValueChars = 20_000
        for key in keys {
            for marker in ["\"\(key)\":\"", "\"\(key)\": \""] {
                guard let range = body.range(of: marker) else { continue }
                let chars = Array(body[range.upperBound...].prefix(maxValueChars * 2))
                var result = ""
                result.reserveCapacity(min(chars.count, maxValueChars))
                var index = 0
                var closed = false
                loop: while index < chars.count {
                    if result.count >= maxValueChars { break loop }
                    let character = chars[index]
                    if character == "\"" {
                        closed = true
                        break loop
                    }
                    if character != "\\" {
                        result.append(character)
                        index += 1
                        continue
                    }
                    // Escape sequence — need at least the escaped char; if it hasn't streamed
                    // yet, stop and return what we have so far.
                    guard index + 1 < chars.count else { break loop }
                    let next = chars[index + 1]
                    switch next {
                    case "n": result.append("\n"); index += 2
                    case "t": result.append("\t"); index += 2
                    case "r": result.append("\r"); index += 2
                    case "b": result.append("\u{08}"); index += 2
                    case "f": result.append("\u{0C}"); index += 2
                    case "\"": result.append("\""); index += 2
                    case "\\": result.append("\\"); index += 2
                    case "/": result.append("/"); index += 2
                    case "u":
                        guard index + 5 < chars.count else { break loop }
                        if let code = UInt32(String(chars[(index + 2)...(index + 5)]), radix: 16),
                           let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        }
                        index += 6
                    default:
                        result.append(next); index += 2
                    }
                }
                if closed || !result.isEmpty { return result }
            }
        }
        return nil
    }

    /// A live, partial preview for a streaming Write/Edit tool call so the card renders
    /// immediately and fills in as content streams. Nil unless the message is mid-stream.
    var streamingToolCodePreview: ToolCodePreview? {
        guard isStreaming else { return nil }
        let displayPath = toolFilePath ?? "正在写入…"
        switch toolName.lowercased() {
        case "write", "create", "create_file", "new_file":
            let content = streamingToolStringValue(keys: ["content", "text", "source", "new_string", "newString"], in: text) ?? ""
            let lines = Self.previewContentLines(content, marker: "+", tint: .green, limit: Self.maxToolCodePreviewLines)
            let lineCount = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            return ToolCodePreview(
                title: Self.displayFileName(displayPath),
                path: displayPath,
                stats: content.isEmpty ? "写入中…" : "写入 \(lineCount) 行…",
                changeStats: ToolChangeStats(added: lineCount, removed: 0),
                lines: lines
            )
        case "edit", "multi_edit", "multiedit":
            var lines: [ToolCodePreview.Line] = []
            var added = 0
            var removed = 0
            if let oldValue = streamingToolStringValue(keys: ["old_string", "oldString", "old", "before"], in: text), !oldValue.isEmpty {
                removed = oldValue.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append(contentsOf: Self.previewContentLines(oldValue, marker: "-", tint: .red, limit: Self.maxToolCodePreviewLines / 2))
            }
            if let newValue = streamingToolStringValue(keys: ["new_string", "newString", "replacement", "after"], in: text), !newValue.isEmpty {
                added = newValue.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append(contentsOf: Self.previewContentLines(newValue, marker: "+", tint: .green, limit: Self.maxToolCodePreviewLines / 2))
            }
            return ToolCodePreview(
                title: Self.displayFileName(displayPath),
                path: displayPath,
                stats: lines.isEmpty ? "编辑中…" : "+\(added) / -\(removed)",
                changeStats: ToolChangeStats(added: added, removed: removed),
                lines: lines
            )
        default:
            return nil
        }
    }

    private func textCommandValue(from value: String) -> String? {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("$ ") {
                let command = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { return command }
            }
            let prefixes = ["command:", "cmd:"]
            for prefix in prefixes where trimmed.lowercased().hasPrefix(prefix) {
                let command = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { return command }
            }
        }
        return nil
    }

    private func jsonToolFilePath(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstToolPath(in: object)
    }

    private func firstToolPath(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            let keys = ["filePath", "file_path", "filepath", "path", "filename", "file"]
            for key in keys {
                if let value = dictionary[key] {
                    if let string = value as? String, let path = normalizedToolPath(string) {
                        return path
                    }
                    if let nested = firstToolPath(in: value) {
                        return nested
                    }
                }
            }
            for value in dictionary.values {
                if let path = firstToolPath(in: value) {
                    return path
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let path = firstToolPath(in: value) {
                    return path
                }
            }
        }
        return nil
    }

    private func textToolFilePath(from value: String) -> String? {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("diff --git a/"), let range = trimmed.range(of: " b/") {
                let path = String(trimmed[range.upperBound...])
                if let normalized = normalizedToolPath(path) { return normalized }
            }
            if trimmed.hasPrefix("+++ ") || trimmed.hasPrefix("--- ") {
                let path = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                if let normalized = normalizedToolPath(path) { return normalized }
            }
            let prefixes = ["path:", "file:", "filePath:", "file_path:"]
            for prefix in prefixes where trimmed.hasPrefix(prefix) {
                let path = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if let normalized = normalizedToolPath(String(path)) { return normalized }
            }
        }
        return nil
    }

    private func normalizedToolPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path = String(path.dropFirst(2))
        }
        guard !path.isEmpty, path != "/dev/null", !path.contains("\n") else { return nil }
        guard path.contains("/") || path.contains(".") else { return nil }
        return path
    }

    private func visualFormattedJSONObject(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let pairs = visibleToolPairs(from: object)
        guard !pairs.isEmpty else { return "" }
        return pairs
            .map { "\($0.key):\n\($0.value)" }
            .joined(separator: "\n\n")
    }

    private func visibleToolPairs(from object: Any) -> [(key: String, value: String)] {
        if let dictionary = object as? [String: Any] {
            return visibleToolPairs(from: dictionary)
        }
        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                visibleToolPairs(from: value).map { ("item \(index + 1) · \($0.key)", $0.value) }
            }
        }
        return []
    }

    private func visibleToolPairs(from dictionary: [String: Any]) -> [(key: String, value: String)] {
        let priorityKeys = [
            "tool",
            "command", "cmd", "cwd", "path", "file", "filePath", "file_path",
            "input", "args", "arguments", "params",
            "stdout", "stderr", "output", "result", "error", "message", "text", "diff", "patch"
        ]
        var pairs: [(key: String, value: String)] = []
        for key in priorityKeys {
            guard let value = dictionary[key],
                  let text = readableToolValue(value),
                  !text.isEmpty else { continue }
            pairs.append((displayToolKey(key), text))
        }
        if !pairs.isEmpty { return pairs.removingDuplicateKeys() }

        let envelopeKeys = ["message", "content", "event", "delta", "item", "params", "data"]
        for key in envelopeKeys {
            guard let value = dictionary[key] else { continue }
            pairs.append(contentsOf: visibleToolPairs(from: value))
        }
        return pairs.removingDuplicateKeys()
    }

    private func readableToolValue(_ value: Any) -> String? {
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            let filtered = string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isInternalToolNoiseLine }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return filtered.isEmpty ? nil : filtered
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        let filtered = string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isInternalToolNoiseLine }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? nil : filtered
    }

    private func displayToolKey(_ key: String) -> String {
        switch key {
        case "toolName", "tool_name": return "tool"
        case "filePath", "file_path": return "path"
        default: return key
        }
    }

    private static func displayFileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func firstUsefulLine(_ value: String) -> String? {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.isInternalToolNoiseLine }
    }

    private static func normalizedAgentID(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "agent-", with: "")
        let id = trimmed.prefix { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
        return id.isEmpty ? nil : String(id)
    }

    private static func agentID(from body: String) -> String? {
        let key = textSignatureCacheKey(prefix: "agent-id", body: body)
        if let cached = ChatToolHotPathCache.agentIDs.object(forKey: key) {
            return cached.value
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for regex in ChatToolHotPathCache.agentIDRegexes {
            guard let match = regex.firstMatch(in: body, range: range), match.numberOfRanges > 1 else { continue }
            guard let valueRange = Range(match.range(at: 1), in: body) else { continue }
            if let id = normalizedAgentID(String(body[valueRange])) {
                ChatToolHotPathCache.agentIDs.setObject(OptionalStringBox(id), forKey: key)
                return id
            }
        }
        ChatToolHotPathCache.agentIDs.setObject(OptionalStringBox(nil), forKey: key)
        return nil
    }

    private func toolCacheKey(prefix: String, includesBody: Bool = true) -> NSString {
        let bodySignature = includesBody ? Self.textSignature(text) : ""
        return [
            prefix,
            id.uuidString,
            "\(kind)",
            status,
            String(isStreaming),
            title,
            subtitle,
            requestID ?? "",
            bodySignature
        ].joined(separator: "|") as NSString
    }

    private func toolStringValueCacheKey(keys: [String], body: String) -> NSString {
        [
            "string-value",
            id.uuidString,
            "\(kind)",
            status,
            String(isStreaming),
            requestID ?? "",
            keys.joined(separator: ","),
            Self.textSignature(body)
        ].joined(separator: "|") as NSString
    }

    private static func textSignatureCacheKey(prefix: String, body: String) -> NSString {
        [prefix, textSignature(body)].joined(separator: "|") as NSString
    }

    private static func textSignature(_ body: String) -> String {
        let prefix = body.prefix(96)
        let suffix = body.suffix(96)
        return "\(body.count):\(prefix):\(suffix)"
    }

    private static func previewSnippet(_ value: String, limit: Int = 72) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private static func previewContentLines(_ value: String, marker: String, tint: Color, limit: Int) -> [ToolCodePreview.Line] {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .prefix(limit)
            .map(String.init)
            .map { line in
                ToolCodePreview.Line(marker: marker, text: line.isEmpty ? " " : line, tint: tint)
            }
    }

    private static func previewLine(from rawLine: String) -> ToolCodePreview.Line {
        if rawLine.hasPrefix("+") {
            return ToolCodePreview.Line(marker: "+", text: String(rawLine.dropFirst()), tint: .green)
        }
        if rawLine.hasPrefix("-") {
            return ToolCodePreview.Line(marker: "-", text: String(rawLine.dropFirst()), tint: .red)
        }
        let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
        return ToolCodePreview.Line(marker: " ", text: text.isEmpty ? " " : text, tint: .secondary)
    }
}

extension ChatRunStatus {
    var statusTint: Color {
        switch self {
        case .idle, .completed: .secondary
        case .starting, .streaming: Color.accentColor
        case .waitingPermission, .waitingInput, .stopping: .orange
        case .failed, .unsupportedVersion: .red
        }
    }
}

extension ChatPermissionMode {
    var systemImage: String {
        switch self {
        case .ask: "hand.raised"
        case .autoEdit: "pencil.and.scribble"
        case .fullAccess: "shield.lefthalf.filled.badge.checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .ask: .secondary
        case .autoEdit: Color.accentColor
        case .fullAccess: .orange
        }
    }
}

extension Array where Element == (key: String, value: String) {
    func removingDuplicateKeys() -> [(key: String, value: String)] {
        var seen = Set<String>()
        var result: [(key: String, value: String)] = []
        for item in self where !seen.contains(item.key) {
            seen.insert(item.key)
            result.append(item)
        }
        return result
    }
}

extension String {
    var diffTint: Color {
        if hasPrefix("+") { return .green }
        if hasPrefix("-") { return .red }
        return .secondary
    }

    var displayToolPairKey: String {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        switch normalized {
        case "file path", "filepath", "path", "filename": return "path"
        case "old string", "old", "before": return "old string"
        case "new string", "replacement", "after": return "new string"
        case "stdout": return "stdout"
        case "stderr": return "stderr"
        case "command", "cmd": return "command"
        case "pattern", "query", "regex": return "pattern"
        case "glob": return "glob"
        case "content", "source", "text": return "content"
        case "output", "result", "message": return "output"
        default: return normalized.isEmpty ? self : normalized
        }
    }

    var isClaudeProtocolRawLine: Bool {
        let compact = trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace }
        guard compact.hasPrefix("{") else { return false }
        return [
            "\"type\":\"stream_event\"",
            "\"type\":\"message_start\"",
            "\"type\":\"message_delta\"",
            "\"type\":\"message_stop\"",
            "\"type\":\"content_block_start\"",
            "\"type\":\"content_block_delta\"",
            "\"type\":\"content_block_stop\"",
            "\"type\":\"input_json_delta\"",
            "\"type\":\"signature_delta\"",
            "\"type\":\"ping\""
        ].contains { compact.contains($0) }
    }

    var isInternalToolNoiseLine: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "done" || normalized == "null" { return true }
        let noisyPrefixes = [
            "\"id\"", "\"type\"", "\"role\"", "\"index\"", "\"model\"",
            "\"usage\"", "\"session_id\"", "\"request_id\"", "\"parent_id\"",
            "\"message_start\"", "\"message_stop\"", "\"stop_reason\"",
            "\"created_at\"", "\"timestamp\"", "\"uuid\""
        ]
        return noisyPrefixes.contains { normalized.hasPrefix($0) }
    }
}

enum ChatPicker {
    case cli
    case permission
    case model
    case reasoning
}
