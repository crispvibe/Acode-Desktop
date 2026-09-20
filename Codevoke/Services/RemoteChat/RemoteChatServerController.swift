import AppKit
import Foundation

struct RemoteChatServerDiagnostics: Equatable {
    var activeWebSocketCount: Int = 0
    var localWebSocketIDs: [String] = []
}

extension Notification.Name {
    static let remoteChatServerDiagnosticsDidChange = Notification.Name("remoteChatServerDiagnosticsDidChange")
    static let remoteChatServerDidStart = Notification.Name("remoteChatServerDidStart")
}

final class RemoteChatAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        RemoteChatServerController.shared.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RemoteChatServerController.shared.stop()
    }
}

final class RemoteChatServerController {
    static let shared = RemoteChatServerController()
    static let defaultPort: UInt16 = 18765

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var diagnostics = RemoteChatServerDiagnostics()

    private var server: RemoteChatServer?

    deinit {
        server?.stop()
    }

    func startIfNeeded() {
        let settings = ProjectStore.loadSettings()
        guard settings.remoteChatServerEnabled else { return }
        guard server == nil else { return }

        // Stale attachment tmp files are never cleaned up; over time they
        // accumulate and a connected client could fill the disk. Sweep
        // anything older than 24h on startup.
        Self.sweepStaleAttachments()

        let port = UInt16(clamping: settings.remoteChatServerPort)
        let configuration = RemoteChatServerConfiguration(
            port: port == 0 ? Self.defaultPort : port,
            bindLAN: settings.remoteChatServerBindLAN
        )
        let server = RemoteChatServer(configuration: configuration)
        server.onDiagnosticsChanged = { [weak self] diagnostics in
            self?.updateDiagnostics(diagnostics)
        }
        updateDiagnostics(server.diagnosticsSnapshot())
        do {
            try server.start()
            self.server = server
            isRunning = true
            lastError = nil
            print("RemoteChatServer listening on \(configuration.bindLAN ? "LAN" : "127.0.0.1"):\(configuration.port)")
            NotificationCenter.default.post(name: .remoteChatServerDidStart, object: self)
        } catch {
            self.server = nil
            isRunning = false
            lastError = error.localizedDescription
            print("RemoteChatServer failed to start: \(error)")
        }
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        updateDiagnostics(RemoteChatServerDiagnostics())
    }

    /// Returns the latest local WebSocket diagnostics for account/settings UI.
    func currentDiagnostics() -> RemoteChatServerDiagnostics {
        if let server {
            updateDiagnostics(server.diagnosticsSnapshot())
        }
        return diagnostics
    }

    private func updateDiagnostics(_ diagnostics: RemoteChatServerDiagnostics) {
        guard self.diagnostics != diagnostics else { return }
        self.diagnostics = diagnostics
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .remoteChatServerDiagnosticsDidChange, object: self)
        }
    }

    /// Audit A-P1: best-effort cleanup of stale attachment tmp directories.
    /// Each upload lives in `tmp/CodevokeRemoteChatAttachments/<uuid>/<file>`.
    /// We delete any subdirectory whose modification date is older than the
    /// retention window. Called from `startIfNeeded` so it runs once per app
    /// launch — adding a recurring sweeper would be overkill for the volume
    /// we expect.
    private static func sweepStaleAttachments() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodevokeRemoteChatAttachments", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in entries {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
