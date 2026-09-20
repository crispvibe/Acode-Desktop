import SwiftUI
import UniformTypeIdentifiers

enum FileTreePlaceholderKind {
    case empty
    case loading
}

struct VisibleFileTreeRow: Identifiable {
    let id: String
    let node: FileNode?
    let title: String
    let level: Int
    let isDirectory: Bool
    let isExpanded: Bool
    let isOpenFile: Bool
    let isSelected: Bool
    let isModified: Bool
    let placeholderKind: FileTreePlaceholderKind?

    static func node(_ node: FileNode, level: Int, isExpanded: Bool, isOpenFile: Bool, isSelected: Bool, isModified: Bool) -> VisibleFileTreeRow {
        VisibleFileTreeRow(
            id: node.id,
            node: node,
            title: node.name,
            level: level,
            isDirectory: node.isDirectory,
            isExpanded: isExpanded,
            isOpenFile: isOpenFile,
            isSelected: isSelected,
            isModified: isModified,
            placeholderKind: nil
        )
    }

    static func empty(parent: FileNode, level: Int) -> VisibleFileTreeRow {
        placeholder(parent: parent, title: "空文件夹", kind: .empty, level: level)
    }

    static func loading(parent: FileNode, level: Int) -> VisibleFileTreeRow {
        placeholder(parent: parent, title: "加载中…", kind: .loading, level: level)
    }

    private static func placeholder(parent: FileNode, title: String, kind: FileTreePlaceholderKind, level: Int) -> VisibleFileTreeRow {
        VisibleFileTreeRow(
            id: "\(parent.id):\(kind)",
            node: nil,
            title: title,
            level: level,
            isDirectory: false,
            isExpanded: false,
            isOpenFile: false,
            isSelected: false,
            isModified: false,
            placeholderKind: kind
        )
    }
}

struct FileTreeLayout {
    static func visibleRows(rootNodes: [FileNode], childCache: [String: [FileNode]], expandedPaths: Set<String>, loadingNodeIDs: Set<String>, selectedURL: URL?, selectedFileTreePaths: Set<String>, modifiedFilePaths: Set<String>) -> [VisibleFileTreeRow] {
        var rows: [VisibleFileTreeRow] = []
        appendRows(from: rootNodes, level: 0, childCache: childCache, expandedPaths: expandedPaths, loadingNodeIDs: loadingNodeIDs, selectedURL: selectedURL, selectedFileTreePaths: selectedFileTreePaths, modifiedFilePaths: modifiedFilePaths, into: &rows)
        return rows
    }

    private static func appendRows(from nodes: [FileNode], level: Int, childCache: [String: [FileNode]], expandedPaths: Set<String>, loadingNodeIDs: Set<String>, selectedURL: URL?, selectedFileTreePaths: Set<String>, modifiedFilePaths: Set<String>, into rows: inout [VisibleFileTreeRow]) {
        for node in nodes {
            let nodePath = normalizedPath(node.url.path)
            let isExpanded = node.isDirectory && expandedPaths.contains(nodePath)
            rows.append(.node(node, level: level, isExpanded: isExpanded, isOpenFile: selectedURL == node.url, isSelected: selectedFileTreePaths.contains(nodePath), isModified: isModified(nodePath: nodePath, isDirectory: node.isDirectory, modifiedFilePaths: modifiedFilePaths)))
            guard node.isDirectory, isExpanded else { continue }
            guard let children = childCache[node.id] else {
                rows.append(.loading(parent: node, level: level + 1))
                continue
            }
            let pendingChildren = children.filter(\.isPendingCreation)
            let regularChildren = children.filter { !$0.isPendingCreation }
            let orderedChildren = pendingChildren + regularChildren
            if orderedChildren.isEmpty {
                rows.append(.empty(parent: node, level: level + 1))
            } else {
                appendRows(from: orderedChildren, level: level + 1, childCache: childCache, expandedPaths: expandedPaths, loadingNodeIDs: loadingNodeIDs, selectedURL: selectedURL, selectedFileTreePaths: selectedFileTreePaths, modifiedFilePaths: modifiedFilePaths, into: &rows)
            }
        }
    }

    private static func isModified(nodePath: String, isDirectory: Bool, modifiedFilePaths: Set<String>) -> Bool {
        if !isDirectory { return modifiedFilePaths.contains(nodePath) }
        let prefix = nodePath.hasSuffix("/") ? nodePath : nodePath + "/"
        return modifiedFilePaths.contains { $0.hasPrefix(prefix) }
    }

    private static func normalizedPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }
}

struct FileTreeItemView: View {
    let row: VisibleFileTreeRow
    let onActivate: (FileNode, EventModifiers) -> Void
    let onOpen: (FileNode) -> Void
    let onCreateFile: (FileNode) -> Void
    let onCreateFolder: (FileNode) -> Void
    let onRefresh: (FileNode) -> Void
    let onReveal: (FileNode) -> Void
    let onOpenInFinder: (FileNode) -> Void
    let onCopyAbsolutePath: (FileNode) -> Void
    let onCopyRelativePath: (FileNode) -> Void
    let onRename: (FileNode) -> Void
    let onCommitRename: (FileNode, String) -> Bool
    let onCancelRename: (FileNode) -> Void
    let onMoveToTrash: (FileNode) -> Void
    let onImportDroppedFiles: ([NSItemProvider], FileNode) -> Bool
    let renamingPath: String?
    @Binding var renameText: String

    @State private var didFinishRename = false
    @State private var isHovered = false
    @State private var isDropTargeted = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        if let node = row.node {
            if isRenaming(node) {
                rowContent(for: node, isRenaming: true)
                    .contextMenu {
                        contextMenuItems(for: node)
                    }
            } else {
                rowContent(for: node, isRenaming: false)
                    .onTapGesture {
                        onActivate(node, currentEventModifiers)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        onActivate(node, [])
                    }
                    .contextMenu {
                        contextMenuItems(for: node)
                    }
                    .onDrag {
                        dragProvider(for: node)
                    }
                    .fileTreeDropTarget(
                        isEnabled: node.isDirectory,
                        isTargeted: $isDropTargeted,
                        onDrop: { providers in
                            onImportDroppedFiles(providers, node)
                        }
                    )
            }
        } else {
            Text(row.title)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, CGFloat(row.level) * 14 + 32)
                .padding(.vertical, 5)
        }
    }

    private var currentEventModifiers: EventModifiers {
        var modifiers = EventModifiers()
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private func rowContent(for node: FileNode, isRenaming: Bool) -> some View {
        HStack(spacing: 7) {
            if node.isDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 11)
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: fileIconName(for: node))
                    .font(.system(size: 13))
                    .foregroundStyle(fileIconColor(for: node))
                    .frame(width: 13)
                    .padding(.leading, 18)
            }
            if isRenaming {
                TextField("名称", text: $renameText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { finishRename(node) }
                    .onExitCommand { cancelRename(node) }
                    .onAppear {
                        didFinishRename = false
                        renameFieldFocused = true
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused {
                            finishRename(node)
                        }
                    }
            } else {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(row.isModified ? AppTheme.fileTreeModifiedName : AppTheme.fileTreeName)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.level) * 14 + 7)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay {
            if isDropTargeted, node.isDirectory {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if row.isSelected { return AppTheme.sidebarSelectedSurface.opacity(row.isOpenFile ? 1 : 0.72) }
        if row.isOpenFile { return AppTheme.sidebarSelectedSurface }
        if isHovered { return AppTheme.fileTreeHoverSurface }
        return .clear
    }

    private func isRenaming(_ node: FileNode) -> Bool {
        renamingPath == normalizedPath(node.url.path)
    }

    private func finishRename(_ node: FileNode) {
        guard !didFinishRename, isRenaming(node) else { return }
        didFinishRename = true
        if !onCommitRename(node, renameText) {
            didFinishRename = false
            Task { @MainActor in
                renameFieldFocused = true
            }
        }
    }

    private func cancelRename(_ node: FileNode) {
        guard !didFinishRename, isRenaming(node) else { return }
        didFinishRename = true
        onCancelRename(node)
    }

    private func normalizedPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    @ViewBuilder
    private func contextMenuItems(for node: FileNode) -> some View {
        if node.isPendingCreation {
            Button("取消新建", systemImage: "xmark") {
                onCancelRename(node)
            }
        } else {
            if node.isDirectory {
                Button(row.isExpanded ? "折叠" : "展开", systemImage: row.isExpanded ? "chevron.down" : "chevron.right") {
                    onActivate(node, [])
                }
                Button("新建文件", systemImage: "doc.badge.plus") {
                    onCreateFile(node)
                }
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    onCreateFolder(node)
                }
                Divider()
                Button("刷新文件夹", systemImage: "arrow.clockwise") {
                    onRefresh(node)
                }
            } else {
                Button("打开", systemImage: "doc.text") {
                    onOpen(node)
                }
            }

            Button("在 Finder 中显示", systemImage: "magnifyingglass") {
                onReveal(node)
            }
            Button("在 Finder 中打开", systemImage: "folder") {
                onOpenInFinder(node)
            }

            Divider()

            Button("复制绝对路径", systemImage: "doc.on.doc") {
                onCopyAbsolutePath(node)
            }
            Button("复制相对路径", systemImage: "doc.on.clipboard") {
                onCopyRelativePath(node)
            }

            Divider()

            Button("重命名", systemImage: "pencil") {
                onRename(node)
            }
            Button("移到废纸篓", systemImage: "trash", role: .destructive) {
                onMoveToTrash(node)
            }
        }
    }

    private func dragProvider(for node: FileNode) -> NSItemProvider {
        let provider = NSItemProvider(object: node.url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(node.url.absoluteString.data(using: .utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(node.url.absoluteString.data(using: .utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(node.url.path.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    private func fileIconName(for node: FileNode) -> String {
        switch node.url.pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "jsx", "ts", "tsx": "curlybraces"
        case "json", "plist", "yaml", "yml", "toml": "list.bullet.rectangle"
        case "md", "markdown", "txt": "doc.richtext"
        case "html", "htm", "xml": "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "sass", "less": "paintbrush"
        case "py": "terminal"
        case "go", "rs", "java", "kt", "kts", "c", "cc", "cpp", "h", "hpp", "cs", "rb", "php": "chevron.left.slash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf": "photo"
        default: "doc.text"
        }
    }

    private func fileIconColor(for node: FileNode) -> Color {
        switch node.url.pathExtension.lowercased() {
        case "swift": .orange
        case "js", "jsx": .yellow
        case "ts", "tsx": .blue
        case "json", "plist", "yaml", "yml", "toml": .purple
        case "md", "markdown", "txt": .mint
        case "html", "htm", "xml": .red
        case "css", "scss", "sass", "less": .indigo
        case "py": .green
        case "go": .cyan
        case "rs": .brown
        case "java", "kt", "kts": .pink
        case "c", "cc", "cpp", "h", "hpp", "cs": .teal
        case "rb", "php": .purple
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf": .orange
        default: .secondary
        }
    }
}

private extension View {
    @ViewBuilder
    func fileTreeDropTarget(isEnabled: Bool, isTargeted: Binding<Bool>, onDrop: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if isEnabled {
            self.onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier], isTargeted: isTargeted, perform: onDrop)
        } else {
            self
        }
    }
}
