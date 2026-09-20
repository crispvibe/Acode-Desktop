import AppKit
import Foundation

enum ProjectStoreError: LocalizedError {
    case applicationSupportUnavailable
    case bookmarkInvalid

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: "无法访问 Application Support 目录。"
        case .bookmarkInvalid: "项目目录权限已失效，请重新添加项目。"
        }
    }
}

private final class FileTreeStatePersistenceQueue {
    static let shared = FileTreeStatePersistenceQueue()

    private let queue = DispatchQueue(label: "com.codevoke.filetree-state-persist", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: Set<String>] = [:]
    private var flushScheduled = false
    private let debounceInterval: TimeInterval = 1.0

    private init() {}

    func enqueue(paths: Set<String>, projectPath: String) {
        lock.lock()
        pending[projectPath] = paths
        let alreadyScheduled = flushScheduled
        flushScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        queue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            self?.flushIfNeeded()
        }
    }

    func flushImmediately() {
        queue.sync { [weak self] in
            self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        lock.lock()
        let snapshot = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        try? ProjectStore.writeExpandedStateMerged(snapshot)
    }
}

struct ProjectStore {
    /// Serializes settings/projects/config-profile read-modify-write sequences so concurrent
    /// writers (Settings UI vs the remote chat server queue) can't lose each other's updates.
    /// Use the `mutate*` helpers for load+modify+save; direct `save*` calls also take it.
    private static let ioLock = NSRecursiveLock()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static var appSupportDirectory: URL {
        get throws {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw ProjectStoreError.applicationSupportUnavailable
            }
            let directory = base.appendingPathComponent("Codevoke", isDirectory: true)
            let legacyDirectory = base.appendingPathComponent("ClaudeMac", isDirectory: true)
            let sandboxDirectory = sandboxAppSupportDirectory(named: "Codevoke")
                ?? sandboxAppSupportDirectory(named: "ClaudeMac")
            if !FileManager.default.fileExists(atPath: directory.path) {
                if let sandboxDirectory, FileManager.default.fileExists(atPath: sandboxDirectory.path) {
                    try? FileManager.default.copyItem(at: sandboxDirectory, to: directory)
                } else if FileManager.default.fileExists(atPath: legacyDirectory.path) {
                    try? FileManager.default.copyItem(at: legacyDirectory, to: directory)
                }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    private static func sandboxAppSupportDirectory(named name: String) -> URL? {
        guard let identifier = Bundle.main.bundleIdentifier,
              let home = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.deletingLastPathComponent() else { return nil }
        return home
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static var projectsURL: URL { get throws { try appSupportDirectory.appendingPathComponent("projects.json") } }
    private static var settingsURL: URL { get throws { try appSupportDirectory.appendingPathComponent("settings.json") } }
    private static var fileTreeStateURL: URL { get throws { try appSupportDirectory.appendingPathComponent("file-tree-state.json") } }
    private static var configProfilesURL: URL { get throws { try appSupportDirectory.appendingPathComponent("config-profiles.json") } }

    static func loadProjects() -> [ProjectItem] {
        do {
            let url = try projectsURL
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            do {
                return try decoder.decode([ProjectItem].self, from: data)
            } catch {
                // The file exists but failed to decode (crash mid-write, disk full, schema
                // drift). Move it aside instead of returning empty and letting the next save
                // atomically overwrite recoverable data.
                backupCorruptedFile(at: url)
                return []
            }
        } catch {
            return []
        }
    }

    /// Preserve a file that read OK but failed to decode, so a subsequent atomic save can't
    /// destroy data the user may still be able to recover.
    static func backupCorruptedFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    static func saveProjects(_ projects: [ProjectItem]) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let data = try encoder.encode(projects)
        try data.write(to: projectsURL, options: [.atomic])
    }

    static func loadSettings() -> AppSettings {
        var settings = loadSettingsRaw()
        if migrateLegacyUserDefaults(into: &settings) {
            try? saveSettings(settings)
        }
        return settings
    }

    private static func loadSettingsRaw() -> AppSettings {
        do {
            let url = try settingsURL
            guard FileManager.default.fileExists(atPath: url.path) else { return .default }
            let data = try Data(contentsOf: url)
            do {
                return try decoder.decode(AppSettings.self, from: data)
            } catch {
                backupCorruptedFile(at: url)
                return .default
            }
        } catch {
            return .default
        }
    }

    static func saveSettings(_ settings: AppSettings) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }

    /// Atomically load → mutate → save settings under the I/O lock. Returns the saved value.
    @discardableResult
    static func mutateSettings(_ transform: (inout AppSettings) -> Void) -> AppSettings {
        ioLock.lock()
        defer { ioLock.unlock() }
        var settings = loadSettings()
        transform(&settings)
        try? saveSettings(settings)
        return settings
    }

    /// Atomically load → mutate → save config profiles under the I/O lock.
    static func mutateConfigProfiles(_ transform: (inout ConfigProfileCollection) throws -> Void) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        var collection = loadConfigProfiles()
        try transform(&collection)
        try saveConfigProfiles(collection)
    }

    /// One-time migration of legacy UserDefaults keys into AppSettings.
    /// Idempotent: subsequent calls become no-ops once `settingsSchemaVersion >= 1`.
    /// Returns true when settings was mutated and should be written back to disk.
    static func migrateLegacyUserDefaults(into settings: inout AppSettings) -> Bool {
        guard settings.settingsSchemaVersion < 1 else { return false }
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "remoteChatServerEnabled") != nil {
            settings.remoteChatServerEnabled = defaults.bool(forKey: "remoteChatServerEnabled")
        }
        let port = defaults.integer(forKey: "remoteChatServerPort")
        if port > 0, port <= Int(UInt16.max) {
            settings.remoteChatServerPort = port
        }
        if defaults.object(forKey: "remoteChatServerBindLAN") != nil {
            settings.remoteChatServerBindLAN = defaults.bool(forKey: "remoteChatServerBindLAN")
        }
        if let claudeModels = defaults.stringArray(forKey: "customClaudeModelIDs"), !claudeModels.isEmpty {
            settings.customClaudeModelIDs = claudeModels
        }
        if let codexModels = defaults.stringArray(forKey: "customCodexModelIDs"), !codexModels.isEmpty {
            settings.customCodexModelIDs = codexModels
        }
        if let width = defaults.object(forKey: "root.chatPanelWidth") as? Double, width > 0 {
            settings.chatPanelWidth = width
        }

        settings.settingsSchemaVersion = 1
        return true
    }

    static func loadExpandedFileTreePaths(for projectPath: String) -> Set<String> {
        do {
            let url = try fileTreeStateURL
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            let state = try decoder.decode([String: [String]].self, from: data)
            return Set(state[normalizedProjectPath(projectPath)] ?? [])
        } catch {
            return []
        }
    }

    static func saveExpandedFileTreePaths(_ paths: Set<String>, for projectPath: String) throws {
        FileTreeStatePersistenceQueue.shared.enqueue(paths: paths, projectPath: projectPath)
    }

    static func saveExpandedFileTreePathsImmediately(_ paths: Set<String>, for projectPath: String) throws {
        try writeExpandedStateMerged([projectPath: paths])
    }

    static func flushPendingFileTreeState() {
        FileTreeStatePersistenceQueue.shared.flushImmediately()
    }

    static func loadConfigProfiles() -> ConfigProfileCollection {
        do {
            let url = try configProfilesURL
            guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
            let data = try Data(contentsOf: url)
            do {
                return try decoder.decode(ConfigProfileCollection.self, from: data)
            } catch {
                backupCorruptedFile(at: url)
                return .empty
            }
        } catch {
            return .empty
        }
    }

    static func saveConfigProfiles(_ profiles: ConfigProfileCollection) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let data = try encoder.encode(profiles)
        let url = try configProfilesURL
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    fileprivate static func writeExpandedStateMerged(_ snapshot: [String: Set<String>]) throws {
        let url = try fileTreeStateURL
        var state: [String: [String]] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            state = (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
        }
        for (projectPath, paths) in snapshot {
            state[normalizedProjectPath(projectPath)] = paths.sorted()
        }
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private static func normalizedProjectPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    static func resolveURL(for project: ProjectItem) throws -> URL {
        // A stale bookmark still resolves to a valid, usable URL — staleness only signals
        // that the bookmark should be recreated, not that access is gone. This app is
        // non-sandboxed, so when the bookmark can't be resolved at all we fall back to the
        // stored path, which is directly readable once the user grants disk access.
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: project.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        let fallback = URL(fileURLWithPath: project.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw ProjectStoreError.bookmarkInvalid
        }
        return fallback
    }

    @MainActor
    static func chooseProjectDirectory() throws -> ProjectItem? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "添加项目"
        panel.message = "选择要在 AI CLI 工作台中管理的项目目录。"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let now = Date()
        return ProjectItem(
            id: UUID(),
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            path: url.path,
            bookmarkData: bookmark,
            defaultCLI: .claude,
            defaultTerminal: .terminal,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now
        )
    }
}
