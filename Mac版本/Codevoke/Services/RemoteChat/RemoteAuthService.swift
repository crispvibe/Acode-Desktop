import CryptoKit
import Foundation
import os

private let remoteAuthLog = Logger(subsystem: "com.codevoke.mac", category: "RemoteAuth")

/// One paired remote client (spec §4.2). Only `SHA-256(token)` is persisted —
/// the token itself lives in the QR payload / the client's own storage, so a
/// stolen devices file can not be replayed.
struct RemotePairedDevice: Codable, Identifiable, Equatable {
    var id: UUID
    var deviceName: String
    var tokenHash: String
    var createdAt: Date
    var lastSeen: Date?
}

/// Bearer-token store + auth rate limiting for the remote chat host.
///
/// Wire contract (doc §4.2):
/// - tokens are 32 random bytes, base64url-encoded;
/// - every endpoint except `/health` and `/pair` requires
///   `Authorization: Bearer <token>`;
/// - per-IP: >10 auth failures within a minute → banned for 60s;
/// - per-connection failure counting lives in `RemoteChatServer`.
final class RemoteAuthService {
    static let shared = RemoteAuthService()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.codevoke.remote-auth", qos: .utility)

    private var devices: [RemotePairedDevice] = []
    private var failureTimestamps: [String: [Date]] = [:]
    private var bannedUntil: [String: Date] = [:]
    private var lastPersistedSeen: [UUID: Date] = [:]
    private var didLoad = false

    /// Posted on the main queue whenever the paired-device list changes.
    var onDevicesChanged: (() -> Void)?

    private init() {}

    // MARK: - Devices

    var pairedDevices: [RemotePairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return devices.sorted { ($0.lastSeen ?? $0.createdAt) > ($1.lastSeen ?? $1.createdAt) }
    }

    /// Issue a fresh bearer token. Returns the raw token (shown once, in the
    /// QR payload / pair response) alongside the persisted device record.
    @discardableResult
    func issueToken(deviceName: String) -> (device: RemotePairedDevice, token: String) {
        var random = Data(count: 32)
        let status = random.withUnsafeMutableBytes { buffer in
            buffer.baseAddress.map { SecRandomCopyBytes(kSecRandomDefault, 32, $0) } ?? errSecParam
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let token = Self.base64URL(random)

        let device = RemotePairedDevice(
            id: UUID(),
            deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未命名设备"
                : deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenHash: Self.sha256Hex(token),
            createdAt: Date(),
            lastSeen: nil
        )
        lock.lock()
        ensureLoadedLocked()
        devices.append(device)
        persistLocked()
        lock.unlock()
        notifyChanged()
        return (device, token)
    }

    /// Validate a bearer token; on success returns the device and refreshes
    /// `lastSeen`. Comparison is over SHA-256 digests so raw tokens are never
    /// touched beyond hashing.
    func authenticate(token: String) -> RemotePairedDevice? {
        let hash = Self.sha256Hex(token)
        lock.lock()
        ensureLoadedLocked()
        guard let index = devices.firstIndex(where: { Self.constantTimeEquals($0.tokenHash, hash) }) else {
            lock.unlock()
            return nil
        }
        devices[index].lastSeen = Date()
        let device = devices[index]
        // lastSeen 是高频更新字段，落盘节流 60s 一次即可（崩溃最多丢一分钟）。
        let lastPersist = lastPersistedSeen[device.id]
        if lastPersist == nil || Date().timeIntervalSince(lastPersist!) > 60 {
            lastPersistedSeen[device.id] = Date()
            persistLocked()
        }
        lock.unlock()
        return device
    }

    func revokeDevice(id: UUID) {
        lock.lock()
        ensureLoadedLocked()
        devices.removeAll { $0.id == id }
        persistLocked()
        lock.unlock()
        notifyChanged()
    }

    // MARK: - Rate limiting (spec §4.2)

    /// >10 failures per IP per minute → ban for 60 seconds.
    private static let failureWindow: TimeInterval = 60
    private static let failureThreshold = 10
    private static let banDuration: TimeInterval = 60

    func isBanned(ip: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = bannedUntil[ip] else { return false }
        if until > Date() { return true }
        bannedUntil.removeValue(forKey: ip)
        return false
    }

    func recordAuthFailure(ip: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var stamps = (failureTimestamps[ip] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
        stamps.append(now)
        failureTimestamps[ip] = stamps
        if stamps.count > Self.failureThreshold {
            bannedUntil[ip] = now.addingTimeInterval(Self.banDuration)
            failureTimestamps[ip] = []
            remoteAuthLog.warning("remote auth banned ip=\(ip, privacy: .private) for \(Int(Self.banDuration))s")
        }
    }

    // MARK: - Persistence

    private func ensureLoadedLocked() {
        guard !didLoad else { return }
        didLoad = true
        devices = Self.loadFromDisk()
    }

    private static var storeURL: URL? {
        (try? ProjectStore.appSupportDirectory)?.appendingPathComponent("remote-paired-devices.json")
    }

    private static func loadFromDisk() -> [RemotePairedDevice] {
        guard let url = storeURL, FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try RemoteChatHTTPCodec.jsonDecoder.decode([RemotePairedDevice].self, from: data)
        } catch {
            ProjectStore.backupCorruptedFile(at: url)
            return []
        }
    }

    /// Caller must hold `lock`.
    private func persistLocked() {
        let snapshot = devices
        queue.async {
            guard let url = Self.storeURL,
                  let data = try? RemoteChatHTTPCodec.jsonEncoder.encode(snapshot) else { return }
            do {
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                remoteAuthLog.error("paired device store write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onDevicesChanged?()
        }
    }

    // MARK: - Helpers

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Fixed-length hex digests → index-safe constant-time compare.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        for i in 0..<max(ab.count, bb.count) {
            diff |= Int(ab[i % max(ab.count, 1)]) ^ Int(bb[i % max(bb.count, 1)])
        }
        return diff == 0 && !ab.isEmpty
    }
}
