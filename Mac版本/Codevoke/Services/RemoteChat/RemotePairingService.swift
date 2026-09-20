import Foundation
import Security
import os

private let remotePairingLog = Logger(subsystem: "com.codevoke.mac", category: "RemotePairing")

/// LAN pairing-code lifecycle (spec §4.2 `/pair`): a 6-digit code shown on
/// the Mac screen, valid for 5 minutes, single-use, with at most 5 attempts
/// per source IP per minute.
final class RemotePairingService {
    static let shared = RemotePairingService()

    struct ActiveCode: Equatable {
        let code: String
        let expiresAt: Date
    }

    struct IssuedCredential {
        let device: RemotePairedDevice
        /// Raw bearer token — returned to the client in the `/pair` response.
        let token: String
    }

    enum Failure: Error {
        /// Code wrong / expired / none active — deliberately indistinguishable.
        case invalidCode
        /// >5 attempts from this IP in the last minute.
        case rateLimited
    }

    private let lock = NSLock()
    private var activeCode: ActiveCode?
    private var attemptTimestamps: [String: [Date]] = [:]

    private static let codeTTL: TimeInterval = 5 * 60
    private static let attemptsWindow: TimeInterval = 60
    private static let maxAttemptsPerWindow = 5

    private init() {}

    /// Mint a new 6-digit code; any previously shown code is invalidated.
    /// Called when the user opens the pairing panel on the Mac.
    @discardableResult
    func beginPairing(now: Date = Date()) -> ActiveCode {
        // SecRandomCopyBytes-backed uniform 6-digit code. Bytes ≥250 are
        // rejected so `byte % 10` stays uniform (250 = 25 full decades).
        var code = ""
        while code.count < 6 {
            var byte: UInt8 = 0
            let status = withUnsafeMutableBytes(of: &byte) { SecRandomCopyBytes(kSecRandomDefault, 1, $0.baseAddress!) }
            precondition(status == errSecSuccess)
            guard byte < 250 else { continue }
            code.append(String(Int(byte) % 10))
        }
        let active = ActiveCode(code: code, expiresAt: now.addingTimeInterval(Self.codeTTL))
        lock.lock()
        activeCode = active
        attemptTimestamps.removeAll()
        lock.unlock()
        return active
    }

    /// Drop the active code (e.g. settings panel dismissed).
    func cancelPairing() {
        lock.lock()
        activeCode = nil
        lock.unlock()
    }

    var currentCode: ActiveCode? {
        lock.lock()
        defer { lock.unlock() }
        guard let code = activeCode, code.expiresAt > Date() else { return nil }
        return code
    }

    /// Validate `code` from `peerIP`; on success consume the code and issue a
    /// bearer token via `RemoteAuthService`.
    func redeem(code rawCode: String, deviceName: String, peerIP: String) -> Result<IssuedCredential, Failure> {
        let now = Date()
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        var stamps = (attemptTimestamps[peerIP] ?? []).filter { now.timeIntervalSince($0) < Self.attemptsWindow }
        if stamps.count >= Self.maxAttemptsPerWindow {
            attemptTimestamps[peerIP] = stamps
            lock.unlock()
            remotePairingLog.warning("pair attempt rate limited ip=\(peerIP, privacy: .private)")
            return .failure(.rateLimited)
        }
        stamps.append(now)
        attemptTimestamps[peerIP] = stamps

        guard let active = activeCode,
              active.expiresAt > now,
              code == active.code else {
            lock.unlock()
            return .failure(.invalidCode)
        }
        // One-time: consume before issuing so a retry can never succeed.
        activeCode = nil
        lock.unlock()

        let issued = RemoteAuthService.shared.issueToken(deviceName: deviceName)
        return .success(IssuedCredential(device: issued.device, token: issued.token))
    }
}

/// `acode://pair?d=<base64url(JSON)>` payload builder (spec §4.4).
enum RemotePairingPayload {
    struct Endpoint: Codable, Equatable {
        /// Address (IPv6 literal or mapped IPv4).
        let a: String
        /// Port.
        let p: UInt16
    }

    struct Payload: Codable, Equatable {
        /// Payload version — always 1.
        let v: Int
        /// Host display name.
        let n: String
        /// Candidate endpoints, global IPv6 first then mapped IPv4.
        let eps: [Endpoint]
        /// Bearer token (base64url).
        let t: String
        /// SPKI-SHA256 hex of the server certificate.
        let fp: String
    }

    static func make(name: String, endpoints: [Endpoint], token: String, fingerprint: String) -> String {
        let payload = Payload(v: 1, n: name, eps: endpoints, t: token, fp: fingerprint)
        guard let data = try? JSONEncoder().encode(payload) else { return "acode://pair" }
        let encoded = RemoteAuthService.base64URL(data)
        return "acode://pair?d=\(encoded)"
    }
}
