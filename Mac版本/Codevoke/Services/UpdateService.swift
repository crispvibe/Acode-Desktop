import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted after the Settings window is opened so `SettingsPageView` can jump
    /// straight to the 关于与版本 pane that hosts the update card.
    static let acodeShowUpdateSettings = Notification.Name("acodeShowUpdateSettings")
}

/// Semver comparison kept as a pure value type so it can be exercised in tests
/// without touching the network or the filesystem.
struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Accepts "1.2.3", "v1.2.3", "1.2", "v0.4.0-beta", "1.2.3+build5".
    /// Returns nil when the numeric prefix is not a valid version.
    init?(parsing raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        if let cut = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            value = String(value[..<cut])
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// GitHub Releases based version check + in-app download/install for the unsigned
/// dmg distribution. No server, no Sparkle: GET the latest release JSON, compare
/// `tag_name` with `CFBundleShortVersionString`, download the macOS dmg asset,
/// mount it via hdiutil, stage acode.app, then swap it into place and relaunch.
@MainActor
final class UpdateService: ObservableObject {
    /// nonisolated so views can grab it in property initializers
    /// (`@ObservedObject var x = UpdateService.shared`).
    nonisolated static let shared = UpdateService()

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case failed(String)
    }

    enum InstallState: Equatable {
        case idle
        /// progress in 0...1, nil when the server did not send a content length.
        case downloading(progress: Double?)
        /// Localized step description ("正在挂载 DMG…" etc).
        case installing(step: String)
        case finished
        case failed(String)
    }

    struct ReleaseInfo: Equatable {
        let tagName: String
        let title: String
        let notes: String
        let htmlURL: URL?
        let publishedAt: String
        let assetName: String
        let assetSize: Int64
        let assetURL: URL
    }

    enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case rateLimited
        case invalidResponse
        case versionUnparseable(String)
        case dmgAssetMissing
        case mountFailed(String)
        case appMissingInDMG
        case notInApplications(String)
        case applicationsNotWritable(String)
        case trashFailed(String)
        case replaceFailed(String)
        case relaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): "检查更新失败：GitHub 返回 HTTP \(code)。"
            case .rateLimited: "GitHub API 访问频率超限，请稍后再试。"
            case .invalidResponse: "检查更新失败：响应数据无法解析。"
            case .versionUnparseable(let tag): "无法解析发布版本号「\(tag)」。"
            case .dmgAssetMissing: "最新发布中没有 macOS 安装包（.dmg）。"
            case .mountFailed(let detail): "挂载 DMG 失败\(detail.isEmpty ? "。" : "：\(detail)")"
            case .appMissingInDMG: "DMG 中未找到 acode.app。"
            case .notInApplications(let path):
                "当前运行的应用位于 \(path)，不在 /Applications 内，无法自动替换。请手动将 DMG 中的 acode.app 拖入 /Applications。"
            case .applicationsNotWritable(let path):
                "无权限写入 \(path)。请打开 DMG 后手动把 acode.app 拖入 /Applications（可能需要管理员授权）。"
            case .trashFailed(let detail): "无法将旧版本移至废纸篓：\(detail)"
            case .replaceFailed(let detail):
                "旧版本已移至废纸篓，但写入新版本失败：\(detail)。可从废纸篓拖回旧版本恢复。"
            case .relaunchFailed(let detail): "新版本已安装，但自动重启失败：\(detail)。请手动打开 acode。"
            }
        }
    }

    private enum Keys {
        static let lastAutoCheckAt = "update.lastAutoCheckAt"
        static let lastAlertedTag = "update.lastAlertedTag"
        /// UserDefaults override (seconds) for `autoCheckInterval`; absent = default.
        static let autoCheckInterval = "update.autoCheckInterval"
    }

    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var latestRelease: ReleaseInfo?
    @Published private(set) var lastCheckedAt: Date?
    /// Kept when download succeeds but a later step fails, so the UI can offer
    /// "手动打开 DMG" for a drag-in install.
    @Published private(set) var downloadedDMGURL: URL?

    static let releasePageURL = URL(string: "https://github.com/crispvibe/Acode-Desktop/releases/latest")!
    private nonisolated static let apiURL = URL(string: "https://api.github.com/repos/crispvibe/Acode-Desktop/releases/latest")!
    private nonisolated static let preferredAssetName = "acode-macos-universal.dmg"
    private nonisolated static let defaultAutoCheckInterval: TimeInterval = 60 * 60
    private nonisolated static let maxReleaseNotesLength = 1500

    /// Minimum spacing between automatic checks. Configurable: set the
    /// `update.autoCheckInterval` UserDefault (seconds) to override, default 1h.
    static var autoCheckInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: Keys.autoCheckInterval)
        return override > 0 ? override : defaultAutoCheckInterval
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var downloadSession: URLSession?
    private var isInstalling = false

    private nonisolated init() {}

    // MARK: - Check

    /// Entry point called once on app launch. Silent: skips when the last
    /// automatic check happened within `autoCheckInterval`, never surfaces
    /// network errors as alerts — state only. Alerts once per new release tag.
    nonisolated func checkForUpdatesIfNeeded() {
        Task { @MainActor in
            let defaults = UserDefaults.standard
            let last = defaults.double(forKey: Keys.lastAutoCheckAt)
            if last > 0, Date().timeIntervalSince1970 - last < Self.autoCheckInterval {
                return
            }
            await self.checkForUpdates(manual: false)
        }
    }

    /// Settings "检查更新" button — always runs, result shown inline in the card.
    func checkManually() {
        Task { await checkForUpdates(manual: true) }
    }

    private func checkForUpdates(manual: Bool) async {
        guard checkState != .checking else { return }
        checkState = .checking
        do {
            let release = try await Self.fetchLatestRelease(currentVersion: currentVersion)
            latestRelease = release
            lastCheckedAt = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastAutoCheckAt)

            guard let remote = SemanticVersion(parsing: release.tagName) else {
                checkState = .failed(UpdateError.versionUnparseable(release.tagName).localizedDescription)
                return
            }
            guard let current = SemanticVersion(parsing: currentVersion) else {
                checkState = .failed(UpdateError.versionUnparseable(currentVersion).localizedDescription)
                return
            }
            if remote > current {
                checkState = .updateAvailable
                if !manual {
                    presentUpdateAlert(release)
                }
            } else {
                checkState = .upToDate
            }
        } catch {
            checkState = .failed(Self.networkErrorDescription(error))
        }
    }

    /// Pure comparison helper, kept static for tests.
    nonisolated static func isUpdateAvailable(remoteTag: String, currentVersion: String) -> Bool {
        guard let remote = SemanticVersion(parsing: remoteTag),
              let current = SemanticVersion(parsing: currentVersion) else { return false }
        return remote > current
    }

    private nonisolated static func fetchLatestRelease(currentVersion: String) async throws -> ReleaseInfo {
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("acode-mac/\(currentVersion.isEmpty ? "unknown" : currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw UpdateError.rateLimited
        }
        guard http.statusCode == 200 else { throw UpdateError.httpStatus(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.invalidResponse
        }
        return try parseRelease(json)
    }

    /// Separated from the network call so the parsing rules stay testable.
    nonisolated static func parseRelease(_ json: [String: Any]) throws -> ReleaseInfo {
        guard let tagName = json["tag_name"] as? String, !tagName.isEmpty else {
            throw UpdateError.invalidResponse
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first(where: { ($0["name"] as? String) == preferredAssetName })
            ?? assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })
        guard let asset,
              let assetName = asset["name"] as? String,
              let assetURLString = asset["browser_download_url"] as? String,
              let assetURL = URL(string: assetURLString) else {
            throw UpdateError.dmgAssetMissing
        }
        var notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > maxReleaseNotesLength {
            notes = String(notes.prefix(maxReleaseNotesLength)) + "…"
        }
        return ReleaseInfo(
            tagName: tagName,
            title: json["name"] as? String ?? tagName,
            notes: notes,
            htmlURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
            publishedAt: json["published_at"] as? String ?? "",
            assetName: assetName,
            assetSize: (asset["size"] as? NSNumber)?.int64Value ?? 0,
            assetURL: assetURL
        )
    }

    // MARK: - Download & Install

    /// Runs the full pipeline: download dmg → hdiutil attach → stage acode.app →
    /// detach → trash old app → move new app into place → relaunch. Any failure
    /// lands in `installState` as a localized Chinese message.
    func downloadAndInstall() {
        guard let release = latestRelease, !isInstalling else { return }
        isInstalling = true
        installState = .downloading(progress: 0)
        downloadedDMGURL = nil
        Task {
            do {
                let dmgURL = try await downloadAsset(release)
                downloadedDMGURL = dmgURL
                installState = .installing(step: "正在挂载 DMG…")
                let stagedApp = try await Task.detached(priority: .userInitiated) {
                    try Self.stageAppBundle(dmgURL: dmgURL, release: release)
                }.value
                installState = .installing(step: "正在替换旧版本…")
                try await replaceInstalledApp(with: stagedApp)
                installState = .finished
                relaunch(at: Bundle.main.bundleURL)
            } catch {
                installState = .failed(Self.networkErrorDescription(error))
                isInstalling = false
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(latestRelease?.htmlURL ?? Self.releasePageURL)
    }

    /// Reveal the downloaded dmg so the user can finish a manual drag install.
    func openDownloadedDMG() {
        guard let url = downloadedDMGURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openUpdateSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
        // The Settings window's view tree needs a runloop turn to materialize
        // before it can receive the navigation notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .acodeShowUpdateSettings, object: nil)
        }
    }

    private func presentUpdateAlert(_ release: ReleaseInfo) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.lastAlertedTag) != release.tagName else { return }
        defaults.set(release.tagName, forKey: Keys.lastAlertedTag)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = "当前版本 \(currentVersion)。可在「设置 → 关于与版本」查看更新说明并安装。"
        alert.addButton(withTitle: "前往更新")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openUpdateSettings()
        }
    }

    // MARK: - Pipeline steps

    private func downloadAsset(_ release: ReleaseInfo) async throws -> URL {
        let staging = try Self.stagingDirectory(for: release)
        let destination = staging.appendingPathComponent(release.assetName)
        try? FileManager.default.removeItem(at: destination)

        var request = URLRequest(url: release.assetURL, timeoutInterval: 60)
        request.setValue("acode-mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(destination: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.installState = .downloading(progress: progress)
                }
            } completion: { [weak self] result in
                Task { @MainActor in self?.downloadSession = nil }
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            downloadSession = session
            session.downloadTask(with: request).resume()
        }
    }

    /// hdiutil attach -nobrowse -readonly → locate acode.app inside → copy to the
    /// staging dir → detach. Runs on a background thread via the caller's
    /// detached task; throws localized Chinese errors for each step.
    private nonisolated static func stageAppBundle(dmgURL: URL, release: ReleaseInfo) throws -> URL {
        let (status, output, stderr) = try runCommand("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-plist", dmgURL.path
        ])
        guard status == 0 else {
            throw UpdateError.mountFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed("无法解析挂载结果")
        }
        defer {
            _ = try? runCommand("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
        }

        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
        let appName = entries.first(where: { $0 == "acode.app" })
            ?? entries.first(where: { $0.hasSuffix(".app") })
        guard let appName else { throw UpdateError.appMissingInDMG }

        let stagedApp = try stagingDirectory(for: release).appendingPathComponent("acode.app")
        try? FileManager.default.removeItem(at: stagedApp)
        try FileManager.default.copyItem(at: mountURL.appendingPathComponent(appName), to: stagedApp)
        // The dmg asset lands with com.apple.quarantine; the unsigned app would
        // hit a Gatekeeper prompt on relaunch. Strip it best-effort — the
        // running build is unsigned anyway so trust level is unchanged.
        _ = try? runCommand("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])
        return stagedApp
    }

    private nonisolated func replaceInstalledApp(with stagedApp: URL) async throws {
        let currentBundle = Bundle.main.bundleURL
        let parent = currentBundle.deletingLastPathComponent()
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        guard parent.path == "/Applications" || parent.path == homeApplications else {
            throw UpdateError.notInApplications(currentBundle.path)
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: currentBundle.path) else {
            throw UpdateError.applicationsNotWritable(parent.path)
        }
        do {
            try fm.trashItem(at: currentBundle, resultingItemURL: nil)
        } catch {
            throw UpdateError.trashFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: stagedApp, to: currentBundle)
        } catch {
            throw UpdateError.replaceFailed(error.localizedDescription)
        }
    }

    private func relaunch(at bundleURL: URL) {
        Task {
            do {
                try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
                NSApp.terminate(nil)
            } catch {
                installState = .failed(UpdateError.relaunchFailed(error.localizedDescription).localizedDescription)
                isInstalling = false
            }
        }
    }

    private nonisolated static func stagingDirectory(for release: ReleaseInfo) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acode-update-\(release.tagName)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func runCommand(_ path: String, _ arguments: [String]) throws -> (Int32, Data, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waitUntilExit so a full pipe buffer can't deadlock the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
    }

    private nonisolated static func networkErrorDescription(_ error: Error) -> String {
        if let updateError = error as? UpdateError, let description = updateError.errorDescription {
            return description
        }
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet:
            return "网络不可用"
        case .timedOut:
            return "网络超时"
        case .cannotFindHost, .cannotConnectToHost:
            return "无法连接 GitHub"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "TLS 连接失败"
        case .cancelled:
            return "已取消"
        default:
            return urlError.localizedDescription
        }
    }
}

/// URLSessionDownloadDelegate → CheckedContinuation bridge. `didFinishDownloadingTo`
/// must move the file inside the callback (the temp file is deleted on return),
/// so the delegate owns both the destination and the completion.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progressHandler: (Double?) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var finished = false

    init(destination: URL, progress: @escaping (Double?) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progressHandler = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progressHandler(nil)
            return
        }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // didFinishDownloadingTo fires before didCompleteWithError — check the
        // HTTP status here or a 404/500 error page would be treated as the dmg.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(UpdateService.UpdateError.httpStatus(http.statusCode)), session: session)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination), session: session)
        } catch {
            finish(.failure(error), session: session)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error), session: session)
            return
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(UpdateService.UpdateError.httpStatus(http.statusCode)), session: session)
            return
        }
    }

    private func finish(_ result: Result<URL, Error>, session: URLSession) {
        guard !finished else { return }
        finished = true
        // Invalidating releases the delegate (session retains it otherwise).
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
