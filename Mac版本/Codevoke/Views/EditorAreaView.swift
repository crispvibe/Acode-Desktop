import AppKit
import ImageIO
import PDFKit
import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let tab = appState.selectedTab {
                editorContent(for: tab)
                    .id(tab.id)
                    .background(AppTheme.editorBackground)
            } else {
                emptyEditor
            }

            Divider().opacity(0.24)
            statusBar
        }
        .background(AppTheme.editorBackground)
        .clipShape(EditorSurfaceShape(radius: 18))
        .overlay(
            EditorSurfaceBorderShape(radius: 18)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func editorContent(for tab: EditorTab) -> some View {
        if tab.isLoadingContent {
            EditorLoadingView(title: tab.title)
        } else if let message = tab.loadErrorMessage {
            EditorLoadFailedView(title: tab.title, message: message)
        } else if let preview = tab.preview {
            PreviewContentView(preview: preview, title: tab.title)
        } else {
            TextEditorRepresentable(
                text: appState.bindingForTabText(tab.id),
                fileName: tab.title,
                jumpRequest: appState.editorJumpRequest?.tabID == tab.id ? appState.editorJumpRequest : nil,
                onTextChange: { _ in },
                onCursorChange: { line, column in
                    appState.cursorLine = line
                    appState.cursorColumn = column
                }
            )
        }
    }

    private var emptyEditor: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("从左侧文件树打开文件")
                .font(.system(size: 13, weight: .medium))
            Text("编辑文本文件，或预览图片、PDF。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }

    private var statusBar: some View {
        EditorStatusBar(
            cursorStore: appState.cursorStore,
            tab: appState.selectedTab
        )
    }

}

private struct EditorLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在加载“\(title)”")
                .font(.system(size: 13, weight: .medium))
            Text("文件内容会在读取完成后显示。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }
}

private struct EditorLoadFailedView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("无法打开“\(title)”")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }
}

private struct PreviewContentView: View {
    let preview: EditorPreview
    let title: String

    var body: some View {
        switch preview {
        case .image(let descriptor):
            ImagePreview(descriptor: descriptor)
        case .pdf(let data, let isValid):
            if isValid {
                PDFPreview(data: data)
            } else {
                UnsupportedPreviewView(title: title)
            }
        }
    }
}

private struct ImagePreview: View {
    let descriptor: ImagePreviewDescriptor

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 48)
            let height = max(1, proxy.size.height - 48)
            ImagePreviewCanvas(descriptor: descriptor, targetSize: CGSize(width: width, height: height))
                .frame(width: width, height: height)
                .padding(24)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
        .clipped()
    }
}

private struct ImagePreviewCanvas: NSViewRepresentable {
    let descriptor: ImagePreviewDescriptor
    let targetSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ImagePreviewContainerView {
        ImagePreviewContainerView()
    }

    func updateNSView(_ nsView: ImagePreviewContainerView, context: Context) {
        let scale = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let maxPixelSize = Self.targetPixelSize(for: targetSize, scale: scale) else { return }
        let key = RenderKey(url: descriptor.url, modifiedAt: descriptor.modifiedAt, maxPixelSize: maxPixelSize)
        let previousKey = context.coordinator.renderKey
        guard previousKey != key else { return }
        context.coordinator.renderKey = key
        context.coordinator.loadTask?.cancel()
        if previousKey?.url != descriptor.url || previousKey?.modifiedAt != descriptor.modifiedAt {
            nsView.imageView.image = nil
        }
        context.coordinator.loadTask = Task.detached(priority: .utility) { [descriptor, key, weak nsView, weak coordinator = context.coordinator] in
            let cgImage = Self.makeThumbnail(for: descriptor, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            await Self.applyThumbnail(cgImage, key: key, nsView: nsView, coordinator: coordinator)
        }
    }

    private static func targetPixelSize(for targetSize: CGSize, scale: CGFloat) -> Int? {
        let dimension = max(targetSize.width, targetSize.height)
        guard dimension >= 16 else { return nil }
        let rawSize = Int(ceil(dimension * scale))
        if rawSize <= 1024 { return 1024 }
        if rawSize <= 1536 { return 1536 }
        return 2048
    }

    @MainActor
    private static func applyThumbnail(_ cgImage: CGImage?, key: RenderKey, nsView: ImagePreviewContainerView?, coordinator: Coordinator?) {
        guard let nsView, let coordinator, coordinator.renderKey == key else { return }
        if let cgImage {
            nsView.imageView.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            nsView.imageView.image = nil
        }
    }

    private nonisolated static func makeThumbnail(for descriptor: ImagePreviewDescriptor, maxPixelSize: Int) -> CGImage? {
        let cacheKey = thumbnailCacheKey(for: descriptor, maxPixelSize: maxPixelSize)
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached.image
        }

        let url = resolvedURL(for: descriptor)
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        thumbnailCache.setObject(CachedThumbnail(image: image), forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }

    private nonisolated static func resolvedURL(for descriptor: ImagePreviewDescriptor) -> URL {
        guard let bookmarkData = descriptor.bookmarkData else { return descriptor.url }
        var isStale = false
        return (try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)) ?? descriptor.url
    }

    private nonisolated static func thumbnailCacheKey(for descriptor: ImagePreviewDescriptor, maxPixelSize: Int) -> NSString {
        let modifiedAt = descriptor.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(descriptor.url.path)|\(modifiedAt)|\(maxPixelSize)" as NSString
    }

    nonisolated(unsafe) private static let thumbnailCache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.countLimit = 24
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private final class CachedThumbnail {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    struct RenderKey: Equatable {
        let url: URL
        let modifiedAt: Date?
        let maxPixelSize: Int
    }

    final class Coordinator {
        var renderKey: RenderKey?
        var loadTask: Task<Void, Never>?

        deinit {
            loadTask?.cancel()
        }
    }
}

private final class ImagePreviewContainerView: NSView {
    let imageView = NSImageView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        applyAppearance()
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = AppTheme.editorBackgroundColor.cgColor
        imageView.layer?.backgroundColor = AppTheme.editorBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = AppTheme.editorBackgroundColor
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        nsView.document = PDFDocument(data: data)
    }

    final class Coordinator {
        var data: Data?
    }
}

private struct UnsupportedPreviewView: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("无法预览“\(title)”")
                .font(.system(size: 13, weight: .medium))
            Text("请使用外部应用打开这个文件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }
}

private struct EditorStatusBar: View {
    @ObservedObject var cursorStore: EditorCursorStore
    let tab: EditorTab?

    var body: some View {
        HStack(spacing: 10) {
            if let tab {
                Text(tab.title)
                    .lineLimit(1)
                Text(Self.fileSizeText(for: tab))
                Text(Self.statusText(for: tab, cursorStore: cursorStore))
                Spacer()
                if !tab.isLoadingContent {
                    Text("修改于\(Self.relativeModifiedText(tab.modifiedAt))")
                }
            } else {
                Text("未打开文件")
                Spacer()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(AppTheme.editorStatusBackground)
    }

    private static func fileSizeText(for tab: EditorTab) -> String {
        tab.isLoadingContent ? "加载中" : ByteCountFormatter.string(fromByteCount: Int64(tab.byteCount), countStyle: .file)
    }

    private static func statusText(for tab: EditorTab, cursorStore: EditorCursorStore) -> String {
        if tab.isLoadingContent {
            return "正在读取"
        }
        if tab.loadErrorMessage != nil {
            return "打开失败"
        }
        return tab.isTextEditable ? "第 \(cursorStore.line) 行" : tab.preview?.label ?? "预览"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func relativeModifiedText(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct EditorSurfaceBorderShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

private struct EditorSurfaceShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
