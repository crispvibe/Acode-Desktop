import Foundation

/// 已配对主机持久化（文档 §6 EndpointStore）。
///
/// 记录形态 `[{hostId, name, token, certFP, eps, lastGood, updatedAt}]`：
/// - `token`/`certFP` 存 Keychain（`kSecClassGenericPassword`，ThisDeviceOnly，
///   不随备份迁移——证书换机/轮换后必须重新配对，与 §4.3 一致）；
/// - 其余字段存 UserDefaults（JSON 编码的记录数组，不含敏感字段）。
///
/// 读写可能来自 URLSession delegate 队列与 @MainActor，内部用 NSLock 串行化。
final class EndpointStore {
    static let shared = EndpointStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let recordsKey = "remote.pairedHosts"
    private static let keychainService = "com.codevoke.remote.pairing"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    func allRecords() -> [PairedHost] {
        lock.lock(); defer { lock.unlock() }
        return loadStubsLocked().compactMap { materialize($0) }
    }

    func record(forHostId hostId: String) -> PairedHost? {
        lock.lock(); defer { lock.unlock() }
        guard let stub = loadStubsLocked().first(where: { $0.hostId == hostId }) else { return nil }
        return materialize(stub)
    }

    /// 按 TLS 握手实际出示的证书指纹查记录——hostId 即指纹，两者等价。
    func record(forCertFP fp: String) -> PairedHost? {
        record(forHostId: RemoteWanCredentials.normalizeFP(fp))
    }

    // MARK: - Write

    /// 新建/更新整条记录（token+fp 进 Keychain，其余进 UserDefaults）。
    /// Keychain 写失败时整体不写，避免留下"有记录没凭据"的僵尸数据。
    @discardableResult
    func upsert(_ record: PairedHost) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard saveSecretsLocked(hostId: record.hostId, token: record.token, certFP: record.certFP) else {
            return false
        }
        var stubs = loadStubsLocked()
        let stub = Stub(record)
        if let index = stubs.firstIndex(where: { $0.hostId == record.hostId }) {
            stubs[index] = stub
        } else {
            stubs.append(stub)
        }
        saveStubsLocked(stubs)
        return true
    }

    /// 同 LAN 静默刷新（§6）：/connect_info 回来更新 name/eps/updatedAt，不动凭据。
    func applyConnectInfo(hostId: String, name: String?, eps: [RemoteEndpoint]) {
        lock.lock(); defer { lock.unlock() }
        var stubs = loadStubsLocked()
        guard let index = stubs.firstIndex(where: { $0.hostId == hostId }) else { return }
        if let name, !name.isEmpty {
            stubs[index].name = name
        }
        let valid = eps.filter { $0.isValid }
        if !valid.isEmpty {
            stubs[index].eps = valid
        }
        stubs[index].updatedAt = Date()
        saveStubsLocked(stubs)
    }

    func updateLastGood(hostId: String, endpoint: RemoteEndpoint) {
        lock.lock(); defer { lock.unlock() }
        var stubs = loadStubsLocked()
        guard let index = stubs.firstIndex(where: { $0.hostId == hostId }) else { return }
        stubs[index].lastGood = endpoint
        stubs[index].updatedAt = Date()
        saveStubsLocked(stubs)
    }

    func remove(hostId: String) {
        lock.lock(); defer { lock.unlock() }
        var stubs = loadStubsLocked()
        stubs.removeAll { $0.hostId == hostId }
        saveStubsLocked(stubs)
        deleteSecretsLocked(hostId: hostId)
    }

    // MARK: - UserDefaults 部分

    /// UserDefaults 里不落 token/certFP —— 敏感字段只进 Keychain。
    private struct Stub: Codable {
        var hostId: String
        var name: String
        var eps: [RemoteEndpoint]
        var lastGood: RemoteEndpoint?
        var updatedAt: Date

        init(_ record: PairedHost) {
            hostId = record.hostId
            name = record.name
            eps = record.eps
            lastGood = record.lastGood
            updatedAt = record.updatedAt
        }
    }

    private func loadStubsLocked() -> [Stub] {
        guard let data = defaults.data(forKey: Self.recordsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Tolerant
        return (try? decoder.decode([Stub].self, from: data)) ?? []
    }

    private func saveStubsLocked(_ stubs: [Stub]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stubs) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    private func materialize(_ stub: Stub) -> PairedHost? {
        guard let secrets = loadSecretsLocked(hostId: stub.hostId) else { return nil }
        return PairedHost(
            hostId: stub.hostId,
            name: stub.name,
            token: secrets.token,
            certFP: secrets.certFP,
            eps: stub.eps,
            lastGood: stub.lastGood,
            updatedAt: stub.updatedAt
        )
    }

    // MARK: - Keychain 部分

    private struct Secrets: Codable {
        let token: String
        let certFP: String
    }

    private func keychainQueryLocked(hostId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: hostId,
        ]
    }

    private func saveSecretsLocked(hostId: String, token: String, certFP: String) -> Bool {
        let secrets = Secrets(token: token, certFP: certFP)
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        var query = keychainQueryLocked(hostId: hostId)
        SecItemDelete(query as CFDictionary)  // 幂等更新：先删后加。
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func loadSecretsLocked(hostId: String) -> Secrets? {
        var query = keychainQueryLocked(hostId: hostId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }

    private func deleteSecretsLocked(hostId: String) {
        SecItemDelete(keychainQueryLocked(hostId: hostId) as CFDictionary)
    }
}
