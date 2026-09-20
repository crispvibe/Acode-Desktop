import AppKit
import Foundation

struct RemoteChatServerDiagnostics: Equatable {
    var activeWebSocketCount: Int = 0
    var localWebSocketIDs: [String] = []
}

/// Everything the settings page needs to render the pairing panel.
struct RemotePairingPresentation {
    /// `acode://pair?d=...` connection string (QR content + copy source).
    let connectionString: String
    /// 6-digit LAN pairing code shown next to the QR.
    let pairingCode: String
    let codeExpiresAt: Date
    /// SPKI-SHA256 hex of the serving certificate.
    let fingerprint: String
}

extension Notification.Name {
    static let remoteChatServerDiagnosticsDidChange = Notification.Name("remoteChatServerDiagnosticsDidChange")
    static let remoteChatServerDidStart = Notification.Name("remoteChatServerDidStart")
    /// Posted when WAN endpoint snapshot or paired-device list changes.
    static let remotePairingStateDidChange = Notification.Name("remotePairingStateDidChange")
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

    private static let qrDeviceName = "扫码配对设备"

    private var server: RemoteChatServer?
    private var identity: RemoteHostIdentity.Identity?
    private(set) var endpointPublisher = WanEndpointPublisher()
    let authService = RemoteAuthService.shared
    let pairingService = RemotePairingService.shared

    private init() {
        authService.onDevicesChanged = { [weak self] in
            self?.postPairingStateChanged()
        }
        endpointPublisher.onSnapshot = { [weak self] _ in
            self?.postPairingStateChanged()
        }
    }

    deinit {
        server?.stop()
        endpointPublisher.stop()
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

        // TLS identity is mandatory now (spec §4.1): no identity → no server.
        let identity: RemoteHostIdentity.Identity
        do {
            identity = try RemoteHostIdentity.shared.identity()
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            print("RemoteChatServer identity unavailable: \(error)")
            return
        }
        self.identity = identity

        let server = RemoteChatServer(
            configuration: configuration,
            identity: identity,
            authService: authService,
            pairingService: pairingService,
            endpointPublisher: endpointPublisher
        )
        server.onDiagnosticsChanged = { [weak self] diagnostics in
            self?.updateDiagnostics(diagnostics)
        }
        updateDiagnostics(server.diagnosticsSnapshot())
        do {
            try server.start()
            self.server = server
            isRunning = true
            lastError = nil
            print("RemoteChatServer listening (wss+auth) on \(configuration.bindLAN ? "LAN" : "127.0.0.1"):\(configuration.port)")
            // WAN endpoint publication only makes sense when remote devices
            // can actually reach us — loopback-only mode skips it entirely.
            if configuration.bindLAN {
                endpointPublisher.start(port: configuration.port)
            }
            NotificationCenter.default.post(name: .remoteChatServerDidStart, object: self)
            postPairingStateChanged()
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
        endpointPublisher.stop()
        isRunning = false
        updateDiagnostics(RemoteChatServerDiagnostics())
        postPairingStateChanged()
    }

    /// Returns the latest local WebSocket diagnostics for account/settings UI.
    func currentDiagnostics() -> RemoteChatServerDiagnostics {
        if let server {
            updateDiagnostics(server.diagnosticsSnapshot())
        }
        return diagnostics
    }

    // MARK: - Pairing / WAN surface for the settings page

    /// Server fingerprint (SPKI-SHA256 hex); nil until the server is running.
    var fingerprint: String? {
        identity?.spkiSHA256Hex ?? (try? RemoteHostIdentity.shared.identity().spkiSHA256Hex)
    }

    /// Fresh pairing presentation: a new 6-digit code plus an `acode://pair`
    /// connection string carrying a one-device bearer token. Call only when
    /// the user opens the pairing UI — each call invalidates the old code.
    func makePairingPresentation() -> RemotePairingPresentation? {
        guard isRunning else { return nil }
        guard let fingerprint else { return nil }
        let code = pairingService.beginPairing()
        // The QR itself carries a usable bearer token (spec §4.4). Regenerating
        // revokes previous QR tokens that were never used, so a stale screenshot
        // cannot be replayed; a QR device that already connected is a real
        // paired device and stays.
        for device in authService.pairedDevices where device.deviceName == Self.qrDeviceName && device.lastSeen == nil {
            authService.revokeDevice(id: device.id)
        }
        let issued = authService.issueToken(deviceName: Self.qrDeviceName)
        let endpoints = endpointPublisher.currentSnapshot().endpoints.map {
            RemotePairingPayload.Endpoint(a: $0.address, p: $0.port)
        }
        let payload = RemotePairingPayload.make(
            name: RemoteHostInfo.displayName,
            endpoints: endpoints,
            token: issued.token,
            fingerprint: fingerprint
        )
        return RemotePairingPresentation(
            connectionString: payload,
            pairingCode: code.code,
            codeExpiresAt: code.expiresAt,
            fingerprint: fingerprint
        )
    }

    func pairedDevices() -> [RemotePairedDevice] {
        authService.pairedDevices
    }

    func revokeDevice(_ id: UUID) {
        authService.revokeDevice(id: id)
    }

    func wanSnapshot() -> WanEndpointPublisher.Snapshot {
        endpointPublisher.currentSnapshot()
    }

    private func postPairingStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .remotePairingStateDidChange, object: self)
        }
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
