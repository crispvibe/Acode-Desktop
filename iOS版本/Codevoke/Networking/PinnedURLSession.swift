import Foundation
import CryptoKit
import Security

/// SPKI-SHA256 提取与比对（文档 §4.3）。
///
/// 服务端证书固定为自签 ECDSA P-256。iOS 的 `SecKeyCopyExternalRepresentation`
/// 对 EC 私钥输出 ANSI X9.63 未压缩点（65 字节，0x04 开头），不是完整 SPKI；
/// 拼上 P-256 固定的 AlgorithmIdentifier DER 头后即得到标准 DER SPKI，
/// 与 host 端（swift-certificates / node 侧）计算的 SPKI-SHA256 一致。
enum RemoteSPKI {
    /// DER: SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING } 的前缀。
    /// `03 42 00` 后面紧跟 65 字节 X9.63 点。
    private static let p256SPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13,
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00,
    ])

    /// 单个证书的 SPKI-SHA256 hex（非 P-256 公钥返回 nil）。
    static func fingerprint(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attributes[kSecAttrKeySizeInBits as String] as? Int) == 256 else {
            return nil
        }
        guard let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              point.count == 65, point.first == 0x04 else {
            return nil
        }
        let spki = p256SPKIPrefix + point
        return sha256Hex(spki)
    }

    /// 整链逐个比对：任一证书的 SPKI 命中 pin 即通过（§4.3 只认 pin，
    /// 忽略 CN/SAN/有效期/链，因此不做 SecTrustEvaluate）。
    static func trust(_ trust: SecTrust, containsPin normalizedPin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return false
        }
        return chain.contains { fingerprint(of: $0) == normalizedPin }
    }

    /// 叶子证书指纹（discovery 路径回传用）。
    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return fingerprint(of: leaf)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// wss/https 校验代理（§4.3）：只认 SPKI-SHA256 pin。
///
/// pin 命中 → `.useCredential`（跳过默认链校验——默认校验必然拒绝自签证书）；
/// 不匹配 → `.cancelAuthenticationChallenge` = 连接失败。
final class PinnedTrustDelegate: NSObject, URLSessionDelegate {
    private let normalizedPin: String
    private let lock = NSLock()
    private var _sawPinMismatch = false

    /// 是否出现过"证书能对上但 pin 不匹配"的拒绝——上层据此区分
    /// "地址失效"与"证书轮换需重新配对"（§4.3 UI 提示要求）。
    var sawPinMismatch: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sawPinMismatch
    }

    init(certFP: String) {
        normalizedPin = RemoteWanCredentials.normalizeFP(certFP)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard !normalizedPin.isEmpty, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if RemoteSPKI.trust(trust, containsPin: normalizedPin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock(); _sawPinMismatch = true; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// 发现/配对仪式专用代理：接受任意自签证书（此时还没有 pin 可校验），
/// 同时记录每个主机出示的叶子证书 SPKI-SHA256——用于：
/// 1. 子网扫描识别"这台主机是不是已配对设备"（指纹即 hostId）；
/// 2. `/pair` 后比对响应里的 fp 与实际出示证书，防 LAN 中间人。
///
/// 仅用于无鉴权的 `/health` 与一次性 `/pair` 握手；业务流量一律走 pinned session。
final class DiscoveryTrustDelegate: NSObject, URLSessionDelegate {
    private let lock = NSLock()
    private var fingerprints: [String: String] = [:]

    private static func key(for space: URLProtectionSpace) -> String {
        "\(space.host):\(space.port)"
    }

    func fingerprint(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return fingerprints["\(host):\(port)"]
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let fp = RemoteSPKI.leafFingerprint(of: trust) {
            lock.lock()
            fingerprints[Self.key(for: challenge.protectionSpace)] = fp
            lock.unlock()
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum RemoteSecureSessionFactory {
    /// 已配对主机流量：wss /connect_info /files /attachments 全走这里。
    static func pinnedSession(certFP: String) -> (session: URLSession, delegate: PinnedTrustDelegate) {
        let delegate = PinnedTrustDelegate(certFP: certFP)
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }

    /// `/health` 扫描与 `/pair` 仪式：接受任意证书并记录指纹。
    static func discoverySession() -> (session: URLSession, delegate: DiscoveryTrustDelegate) {
        let delegate = DiscoveryTrustDelegate()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }
}
