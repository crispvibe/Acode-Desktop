import Foundation

/// WAN 直连线缆契约模型（文档 remote-chat-wan-direct.md §4.4）。
///
/// - `RemoteEndpoint` 对应 QR/`/pair`/`/connect_info` 里的 `{"a": address, "p": port}`。
/// - `PairedHost` 是 EndpointStore 持久化的一条已配对记录；
///   hostId 直接取 `certFP`（SPKI-SHA256 hex）——配对载荷本身不携带 hostId，
///   证书指纹是契约里唯一的稳定主机身份。
/// - `PairingPayload` 解析 `acode://pair?d=<base64url(JSON)>`。
struct RemoteEndpoint: Codable, Equatable, Hashable {
    let a: String
    let p: Int

    var isValid: Bool {
        !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(p)
    }

    /// 日志/展示用。IPv6 字面量加方括号，避免和端口分隔符混淆。
    var displayText: String {
        let host = a.contains(":") && !a.hasPrefix("[") ? "[\(a)]" : a
        return "\(host):\(p)"
    }
}

struct PairedHost: Equatable {
    /// 稳定主机身份 = 证书 SPKI-SHA256 hex（配对载荷不含独立 hostId 字段）。
    var hostId: String
    var name: String
    var token: String
    var certFP: String
    var eps: [RemoteEndpoint]
    var lastGood: RemoteEndpoint?
    var updatedAt: Date

    /// 连接候选排序：用户显式点选的目标（preferred）优先，其次 lastGood，
    /// 其余按存储顺序，全部去重。对应 §6 "lastGood 先行 + 其余 eps 并行"。
    func candidateEndpoints(preferred: RemoteEndpoint?) -> [RemoteEndpoint] {
        var ordered: [RemoteEndpoint] = []
        if let preferred, preferred.isValid {
            ordered.append(preferred)
        }
        if let lastGood, lastGood.isValid {
            ordered.append(lastGood)
        }
        ordered.append(contentsOf: eps)
        var seen = Set<RemoteEndpoint>()
        return ordered.filter { seen.insert($0).inserted }
    }
}

/// `acode://pair?d=<base64url(JSON)>` 载荷。字段：v/n/eps/t/fp。
struct PairingPayload: Equatable {
    let version: Int
    let name: String
    let endpoints: [RemoteEndpoint]
    let token: String
    let certFP: String

    enum ParseError: LocalizedError {
        case notPairingURL
        case malformedPayload
        case unsupportedVersion(Int)
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .notPairingURL:
                L10n.string("连接串格式无效，应为 acode://pair?d= 开头的串。")
            case .malformedPayload:
                L10n.string("连接串内容无法解析，请确认复制完整。")
            case .unsupportedVersion(let version):
                L10n.format("连接串版本（%d）暂不支持，请升级 App。", version)
            case .missingField(let field):
                L10n.format("连接串缺少字段 %@。", field)
            }
        }
    }

    private struct WirePayload: Decodable {
        let v: Int
        let n: String
        let eps: [RemoteEndpoint]
        let t: String
        let fp: String
    }

    static func parse(_ raw: String) throws -> PairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // acode://pair?d=… 解析后 scheme=acode、host=pair。
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "acode",
              components.host?.lowercased() == "pair",
              let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              !encoded.isEmpty else {
            throw ParseError.notPairingURL
        }
        return try decode(encoded)
    }

    private static func decode(_ base64url: String) throws -> PairingPayload {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else {
            throw ParseError.malformedPayload
        }
        let wire: WirePayload
        do {
            wire = try JSONDecoder().decode(WirePayload.self, from: data)
        } catch {
            throw ParseError.malformedPayload
        }
        guard wire.v == 1 else { throw ParseError.unsupportedVersion(wire.v) }
        guard !wire.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.missingField("t")
        }
        let fp = RemoteWanCredentials.normalizeFP(wire.fp)
        guard !fp.isEmpty else { throw ParseError.missingField("fp") }
        let validEndpoints = wire.eps.filter { $0.isValid }
        return PairingPayload(version: wire.v, name: wire.n, endpoints: validEndpoints, token: wire.t, certFP: fp)
    }
}

/// 指纹规范化：契约写 SPKI-SHA256 hex；容忍大小写与 `:`/空格分隔符。
enum RemoteWanCredentials {
    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func normalizeFP(_ raw: String) -> String {
        let hexOnly = String(String.UnicodeScalarView(raw.unicodeScalars.filter { hexDigits.contains($0) }))
        let normalized = hexOnly.lowercased()
        // SHA-256 = 32 字节 = 64 个 hex 字符；长度不对视为无效指纹。
        return normalized.count == 64 ? normalized : ""
    }
}

// MARK: - /pair & /connect_info DTO（§4.2）

struct RemotePairRequest: Encodable {
    let code: String
    let deviceName: String
}

/// `POST /pair` 200 响应：`{token, fp, name, eps}`。
struct RemotePairResponse: Decodable {
    let token: String
    let fp: String
    let name: String?
    let eps: [RemoteEndpoint]?
}

/// `GET /connect_info` 响应：`{name, eps}`。
struct RemoteConnectInfo: Decodable {
    let name: String?
    let eps: [RemoteEndpoint]?
}
