import Foundation

struct FileTreeScanner {
    static let defaultIgnoredNames: Set<String> = [
        ".git", ".hg", ".svn", ".DS_Store", "node_modules", "dist", "build", ".dart_tool",
        ".idea", ".vscode", "vendor", "DerivedData", ".build", ".swiftpm", ".next", ".cache",
        "__pycache__", ".venv"
    ]

    let ignoredNames: Set<String>

    init(ignoredNames: Set<String> = FileTreeScanner.defaultIgnoredNames) {
        self.ignoredNames = ignoredNames
    }

    func scanChildren(of directory: URL) throws -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .nameKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )

        return urls.compactMap { url -> FileNode? in
            guard !ignoredNames.contains(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink != true else { return nil }
            let isDirectory = values?.isDirectory == true
            let isRegularFile = values?.isRegularFile == true
            guard isDirectory || isRegularFile else { return nil }
            return FileNode(url: url, name: url.lastPathComponent, isDirectory: isDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
