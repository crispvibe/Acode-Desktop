import CryptoKit
import Foundation
import Network
import Security
import SwiftASN1
import X509
import os

private let remoteHostIdentityLog = Logger(subsystem: "com.codevoke.mac", category: "RemoteHostIdentity")

/// Self-signed TLS identity for the remote chat host (spec §4.3): an ECDSA
/// P-256 certificate with CN=acode-host and a 10 year validity, persisted in
/// the login Keychain as a `SecIdentity`. Clients never chain-validate the
/// cert — they pin SPKI-SHA256 — so the fingerprint below is the only value
/// pairing payloads need to carry.
final class RemoteHostIdentity {
    struct Identity {
        /// `sec_identity_t` ready for `sec_protocol_options_set_local_identity`.
        let secIdentity: sec_identity_t
        /// DER bytes of the leaf certificate (what clients pin against).
        let certificateDER: Data
        /// `SHA-256(SPKI DER)` as lowercase hex — the `fp` field in pair payloads.
        let spkiSHA256Hex: String
    }

    enum IdentityError: LocalizedError {
        case keyGenerationFailed(OSStatus)
        case certificateStoreFailed(OSStatus)
        case identityLookupFailed
        case certificateEncodingFailed

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed(let status):
                return "生成设备证书私钥失败（Keychain \(status)）。"
            case .certificateStoreFailed(let status):
                return "设备证书写入 Keychain 失败（\(status)）。"
            case .identityLookupFailed:
                return "无法在 Keychain 中找到设备证书对应的私钥。"
            case .certificateEncodingFailed:
                return "设备证书编码失败。"
            }
        }
    }

    static let shared = RemoteHostIdentity()

    private let lock = NSLock()
    private var cached: Identity?

    private static let certificateLabel = "acode-host"
    private static let privateKeyTag = Data("com.codevoke.remote-host.private-key".utf8)

    /// Load the persisted identity, generating a fresh self-signed
    /// certificate on first run. The result is cached for the process
    /// lifetime — regenerating per launch would change `fp` and force clients
    /// to re-pair every restart.
    func identity() throws -> Identity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        if let certificate = Self.findStoredCertificate(),
           let resolved = Self.resolveIdentity(for: certificate) {
            let identity = try Self.makeIdentity(from: resolved, certificate: certificate)
            cached = identity
            return identity
        }

        let identity = try Self.generateAndStoreIdentity()
        cached = identity
        return identity
    }

    /// Drop the cached handle. Stored keychain items are untouched; call
    /// `resetStoredIdentity` for a real rotation.
    func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Delete the stored certificate + private key so the next `identity()`
    /// call mints a fresh one. Rotation changes `fp` — every paired client
    /// must re-pair, which is exactly what the spec wants surfaced.
    func resetStoredIdentity() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: Self.certificateLabel,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Self.privateKeyTag,
        ] as CFDictionary)
    }

    // MARK: - Keychain plumbing

    private static func findStoredCertificate() -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecCertificate)
    }

    /// A SecIdentity is implicit: a private key plus a certificate carrying
    /// the matching public key in the same keychain. There is no public API
    /// to link them manually, so scan identities and match on cert bytes.
    private static func resolveIdentity(for certificate: SecCertificate) -> SecIdentity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else { return nil }

        let expectedDER = SecCertificateCopyData(certificate) as Data
        for identity in identities {
            var candidate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &candidate) == errSecSuccess, let candidate else { continue }
            if (SecCertificateCopyData(candidate) as Data) == expectedDER {
                return identity
            }
        }
        return nil
    }

    private static func makeIdentity(from secIdentity: SecIdentity, certificate: SecCertificate) throws -> Identity {
        let der = SecCertificateCopyData(certificate) as Data
        guard let parsed = try? Certificate(certificate),
              let tlsIdentity = sec_identity_create(secIdentity) else {
            throw IdentityError.certificateEncodingFailed
        }
        let spki = Data(parsed.publicKey.subjectPublicKeyInfoBytes)
        return Identity(
            secIdentity: tlsIdentity,
            certificateDER: der,
            spkiSHA256Hex: sha256Hex(spki)
        )
    }

    private static func generateAndStoreIdentity() throws -> Identity {
        let privateKey = try generatePrivateKey()
        var error: Unmanaged<CFError>?
        guard let publicSecKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicSecKey, &error) as Data? else {
            throw IdentityError.keyGenerationFailed(errSecParam)
        }

        let name = try DistinguishedName { CommonName(certificateLabel) }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(try P256.Signing.PublicKey(x963Representation: publicKeyData)),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(10 * 365.25 * 24 * 60 * 60),
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: try Certificate.PrivateKey(privateKey)
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = Data(serializer.serializedBytes)
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateEncodingFailed
        }

        let addStatus = storeCertificate(secCertificate)
        guard addStatus == errSecSuccess else {
            throw IdentityError.certificateStoreFailed(addStatus)
        }

        guard let secIdentity = resolveIdentity(for: secCertificate),
              let tlsIdentity = sec_identity_create(secIdentity) else {
            throw IdentityError.identityLookupFailed
        }
        return Identity(
            secIdentity: tlsIdentity,
            certificateDER: der,
            spkiSHA256Hex: sha256Hex(Data(certificate.publicKey.subjectPublicKeyInfoBytes))
        )
    }

    /// `kSecAttrApplicationTag` is a primary key for `kSecClassKey`, so an
    /// orphaned key from a deleted certificate would make generation fail
    /// with `errSecDuplicateItem` forever. Delete the orphan and retry once.
    private static func generatePrivateKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: privateKeyTag,
                kSecAttrLabel: certificateLabel,
            ],
        ]
        for _ in 0..<2 {
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) {
                return key
            }
            let status = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? -1
            guard status == Int(errSecDuplicateItem) else {
                throw IdentityError.keyGenerationFailed(OSStatus(status))
            }
            SecItemDelete([
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: privateKeyTag,
            ] as CFDictionary)
        }
        throw IdentityError.keyGenerationFailed(errSecDuplicateItem)
    }

    /// Insert the certificate; if a stale cert with our label exists (e.g.
    /// its private key was deleted, so `resolveIdentity` failed and we
    /// regenerated), replace it so the fresh cert always lands in Keychain.
    private static func storeCertificate(_ certificate: SecCertificate) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecValueRef: certificate,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
        ] as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
