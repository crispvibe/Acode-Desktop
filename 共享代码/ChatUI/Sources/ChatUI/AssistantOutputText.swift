import SwiftUI

public struct AssistantOutputText: View {
    public let text: String
    public var onOpenFile: ((ChatFileReference) -> Void)?
    private let blocks: [OutputBlock]

    public init(text: String, onOpenFile: ((ChatFileReference) -> Void)? = nil) {
        self.text = text
        self.onOpenFile = onOpenFile
        self.blocks = Self.cachedBlocks(for: text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text:
                    textBlock(block.content)
                case .code:
                    codeBlock(block.content)
                case .spacer:
                    Color.clear.frame(height: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func textBlock(_ value: String) -> some View {
        let paths = Self.filePaths(in: value)
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(ChatTheme.assistantText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(paths, id: \.self) { path in
                pathChip(path)
            }
        }
    }

    private func codeBlock(_ value: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(value.isEmpty ? " " : value)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(2)
                .foregroundStyle(ChatTheme.ink.opacity(0.88))
                .padding(10)
        }
        .background(ChatTheme.codeSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ChatTheme.toolStroke, lineWidth: 1))
    }

    private func pathChip(_ path: String) -> some View {
        Menu {
            Button {
                copyToClipboard(path)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if let onOpenFile {
                Button {
                    onOpenFile(ChatFileReference(path: path))
                } label: {
                    Label("打开", systemImage: "arrow.up.forward.app")
                }
            }
        } label: {
            Text(path)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTheme.chipTint)
                .underline()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.chatPress)
    }

    private static func filePaths(in value: String) -> [String] {
        let key = value as NSString
        if let cached = filePathCache.object(forKey: key) {
            return cached.values
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = filePathRegex.matches(in: value, range: nsRange)
        var results: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: value) else { continue }
            let path = String(value[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)。），"))
            guard path.count > 1, !results.contains(path) else { continue }
            let last = (path as NSString).lastPathComponent
            guard last.contains(".") else { continue }
            results.append(path)
        }
        filePathCache.setObject(StringArrayCacheEntry(results), forKey: key, cost: max(1, value.utf8.count))
        return results
    }

    private static func cachedBlocks(for text: String) -> [OutputBlock] {
        let key = text as NSString
        if let cached = blockCache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = OutputBlock.parse(text)
        blockCache.setObject(OutputBlockCacheEntry(blocks), forKey: key, cost: max(1, text.utf8.count))
        return blocks
    }

    private static let blockCache: NSCache<NSString, OutputBlockCacheEntry> = {
        let cache = NSCache<NSString, OutputBlockCacheEntry>()
        cache.countLimit = 600
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static let filePathCache: NSCache<NSString, StringArrayCacheEntry> = {
        let cache = NSCache<NSString, StringArrayCacheEntry>()
        cache.countLimit = 1_000
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    private static let filePathRegex = try! NSRegularExpression(
        pattern: #"(?<!\w)(/(?:[^\s`"'<>|]+/)*[^\s`"'<>|/]+\.[A-Za-z0-9]{1,8})(?!\w)"#
    )
}

private final class StringArrayCacheEntry {
    let values: [String]

    init(_ values: [String]) {
        self.values = values
    }
}

private final class OutputBlockCacheEntry {
    let blocks: [OutputBlock]

    init(_ blocks: [OutputBlock]) {
        self.blocks = blocks
    }
}

private struct OutputBlock: Identifiable {
    enum Kind {
        case text
        case code
        case spacer
    }

    let id: String
    let kind: Kind
    let content: String

    static func parse(_ text: String) -> [OutputBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [OutputBlock] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(OutputBlock(index: blocks.count, kind: .code, content: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                }
                isInCodeBlock.toggle()
                continue
            }

            if isInCodeBlock {
                codeLines.append(line)
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(OutputBlock(index: blocks.count, kind: .spacer, content: ""))
            } else {
                blocks.append(OutputBlock(index: blocks.count, kind: .text, content: line))
            }
        }

        if !codeLines.isEmpty {
            blocks.append(OutputBlock(index: blocks.count, kind: .code, content: codeLines.joined(separator: "\n")))
        }
        return blocks.isEmpty ? [OutputBlock(index: 0, kind: .text, content: " ")] : blocks
    }

    private init(index: Int, kind: Kind, content: String) {
        self.id = "\(index)-\(kind.rawValue)-\(content.hashValue)"
        self.kind = kind
        self.content = content
    }
}

extension OutputBlock.Kind: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "code": self = .code
        case "spacer": self = .spacer
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .text: "text"
        case .code: "code"
        case .spacer: "spacer"
        }
    }
}
