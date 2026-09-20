import Darwin
import Foundation

@MainActor
final class ChatModelService: ObservableObject {
    @Published var claudeModels: [ChatModelOption] = []
    @Published var codexModels: [ChatModelOption] = []
    @Published var isFetching = false
    @Published private var customClaudeModels: [ChatModelOption] = []
    @Published private var customCodexModels: [ChatModelOption] = []

    private var lastClaudeBaseURL: String = ""
    private var lastCodexBaseURL: String = ""
    private var configuredClaudeModels: [ChatModelOption] = []
    private var configuredCodexModels: [ChatModelOption] = []
    private var configuredClaudeDefaultModelID: String?
    private var configuredCodexDefaultModelID: String?

    init() {
        customClaudeModels = Self.loadCustomModels(for: .claude)
        customCodexModels = Self.loadCustomModels(for: .codex)
    }

    // MARK: - Public API

    func options(for cli: CLIType) -> [ChatModelOption] {
        switch cli.visibleValue {
        case .claude:
            return withConfiguredDefaultTitle(
                mergedOptions(ChatModelCatalog.options(for: .claude), claudeModels, configuredClaudeModels, customClaudeModels),
                cli: .claude
            )
        case .codex:
            return withConfiguredDefaultTitle(
                mergedOptions(ChatModelCatalog.options(for: .codex), codexModels, configuredCodexModels, customCodexModels),
                cli: .codex
            )
        case .gemini, .custom:
            return withConfiguredDefaultTitle(
                mergedOptions(ChatModelCatalog.options(for: .claude), claudeModels, configuredClaudeModels, customClaudeModels),
                cli: .claude
            )
        }
    }

    func title(for id: String, cli: CLIType) -> String {
        options(for: cli).first { $0.id == id }?.title ?? id
    }

    func defaultModelID(for cli: CLIType) -> String {
        switch cli.visibleValue {
        case .claude:
            configuredClaudeDefaultModelID?.nonEmptyTrimmed ?? ChatModelCatalog.defaultModelID(for: cli)
        case .codex:
            configuredCodexDefaultModelID?.nonEmptyTrimmed ?? ChatModelCatalog.defaultModelID(for: cli)
        case .gemini, .custom:
            configuredClaudeDefaultModelID?.nonEmptyTrimmed ?? ChatModelCatalog.defaultModelID(for: cli)
        }
    }

    func contextModelID(for id: String, cli: CLIType) -> String {
        let catalogDefault = ChatModelCatalog.defaultModelID(for: cli)
        if catalogDefault == "default", id == catalogDefault {
            return defaultModelID(for: cli)
        }
        return id
    }

    func contextWindow(for id: String, cli: CLIType) -> Int {
        let visibleCLI = cli.visibleValue
        let executionID = ChatModelCatalog.executionModelID(for: id).lowercased()
        let metadataWindow = options(for: visibleCLI)
            .first { ChatModelCatalog.executionModelID(for: $0.id).lowercased() == executionID }?
            .contextWindow
        return ChatModelCatalog.contextWindow(for: id, cli: visibleCLI, metadataWindow: metadataWindow)
    }

    func defaultReasoningEffort(for cli: CLIType) -> ChatReasoningEffort {
        .high
    }

    func addCustomModel(id rawID: String, cli: CLIType) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let visibleCLI = cli.visibleValue == .codex ? CLIType.codex : CLIType.claude
        let option = ChatModelOption(id: id, title: prettifyModelID(id, cli: visibleCLI), cli: visibleCLI)
        if visibleCLI == .codex {
            customCodexModels = mergedOptions(customCodexModels, [option])
            Self.saveCustomModels(customCodexModels.map(\.id), for: .codex)
        } else {
            customClaudeModels = mergedOptions(customClaudeModels, [option])
            Self.saveCustomModels(customClaudeModels.map(\.id), for: .claude)
        }
    }

    func reloadConfiguredModels() {
        let claude = Self.loadClaudeConfiguredModels()
        configuredClaudeDefaultModelID = claude.defaultModelID
        configuredClaudeModels = claude.modelIDs.map { ChatModelOption(id: $0, title: prettifyModelID($0, cli: .claude), cli: .claude) }

        let codex = Self.loadCodexConfiguredModel()
        configuredCodexDefaultModelID = codex
        configuredCodexModels = codex.map { [ChatModelOption(id: $0, title: prettifyModelID($0, cli: .codex), cli: .codex)] } ?? []
    }

    /// Fetch models for both CLI types using the configured base URLs and keys.
    func fetchAll(claudeBaseURL: String, claudeKey: String, codexBaseURL: String, codexKey: String) {
        fetchClaudeModels(baseURL: claudeBaseURL, apiKey: claudeKey)
        fetchCodexModels(baseURL: codexBaseURL, apiKey: codexKey)
    }

    /// Fetch Claude models from the API.
    func fetchClaudeModels(baseURL: String, apiKey: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else {
            claudeModels = []
            return
        }

        lastClaudeBaseURL = trimmedURL

        isFetching = true

        let candidates = [
            trimmedURL.hasSuffix("/") ? trimmedURL + "v1/models" : trimmedURL + "/v1/models",
            trimmedURL.hasSuffix("/") ? trimmedURL + "models" : trimmedURL + "/models",
        ]

        Task {
            let fetched = await fetchModels(from: candidates, apiKey: apiKey, cli: .claude)
            await MainActor.run {
                if !fetched.isEmpty {
                    // Always prepend "default" option
                    var result = [ChatModelOption(id: ChatModelCatalog.defaultClaudeModelID, title: "默认", cli: .claude)]
                    result.append(contentsOf: fetched)
                    self.claudeModels = result
                }
                self.isFetching = false
            }
        }
    }

    /// Fetch Codex models from the API.
    func fetchCodexModels(baseURL: String, apiKey: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else {
            codexModels = []
            return
        }

        lastCodexBaseURL = trimmedURL

        isFetching = true

        let candidates = [
            trimmedURL.hasSuffix("/") ? trimmedURL + "models" : trimmedURL + "/models",
        ]

        Task {
            let fetched = await fetchModels(from: candidates, apiKey: apiKey, cli: .codex)
            await MainActor.run {
                if !fetched.isEmpty {
                    self.codexModels = fetched
                }
                self.isFetching = false
            }
        }
    }

    /// Force re-fetch (ignores cache).
    func refresh(claudeBaseURL: String, claudeKey: String, codexBaseURL: String, codexKey: String) {
        lastClaudeBaseURL = ""
        lastCodexBaseURL = ""
        claudeModels = []
        codexModels = []
        reloadConfiguredModels()
        fetchAll(claudeBaseURL: claudeBaseURL, claudeKey: claudeKey, codexBaseURL: codexBaseURL, codexKey: codexKey)
    }

    // MARK: - Private

    private func mergedOptions(_ groups: [ChatModelOption]...) -> [ChatModelOption] {
        groups.flatMap { $0 }.reduce(into: [ChatModelOption]()) { result, option in
            let key = modelIdentityKey(option)
            if let existingIndex = result.firstIndex(where: { modelIdentityKey($0) == key }) {
                result[existingIndex] = option
            } else {
                result.append(option)
            }
        }
    }

    private func modelIdentityKey(_ option: ChatModelOption) -> String {
        let executionID = ChatModelCatalog.executionModelID(for: option.id).lowercased()
        return "\(option.cli.visibleValue.rawValue):\(executionID)"
    }

    private func withConfiguredDefaultTitle(_ options: [ChatModelOption], cli: CLIType) -> [ChatModelOption] {
        let catalogDefault = ChatModelCatalog.defaultModelID(for: cli)
        let configured = defaultModelID(for: cli)
        guard catalogDefault == "default", configured != catalogDefault else { return options }

        let configuredTitle = prettifyModelID(configured, cli: cli)
        return options.map { option in
            guard option.id == catalogDefault else { return option }
            return ChatModelOption(id: option.id, title: "默认（\(configuredTitle)）", cli: option.cli, contextWindow: option.contextWindow)
        }
    }

    private func fetchModels(from candidates: [String], apiKey: String, cli: CLIType) async -> [ChatModelOption] {
        let token = apiKey.trimmingCharacters(in: .whitespaces)

        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { continue }
                if let models = parseModelListResponse(data) {
                    return models.sorted { $0.id < $1.id }.map { model in
                        let contextWindow = model.contextWindow ?? ChatModelCatalog.contextWindow(for: model.id, cli: cli)
                        return ChatModelOption(id: model.id, title: prettifyModelID(model.id, cli: cli), cli: cli, contextWindow: contextWindow)
                    }
                }
            } catch {
                continue
            }
        }

        return []
    }

    private struct FetchedModel {
        let id: String
        let contextWindow: Int?
    }

    /// Parse OpenAI-compatible /models response.
    private func parseModelListResponse(_ data: Data) -> [FetchedModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Some relays return a plain array
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let models = arr.compactMap { modelOption(from: $0) }
                return models.isEmpty ? nil : models
            }
            return nil
        }

        // OpenAI format: { "data": [{ "id": "model-name", ... }] }
        if let dataArray = json["data"] as? [[String: Any]] {
            let models = dataArray.compactMap { modelOption(from: $0) }
            return models.isEmpty ? nil : models
        }

        return nil
    }

    private func modelOption(from object: [String: Any]) -> FetchedModel? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        return FetchedModel(id: id, contextWindow: contextWindow(from: object))
    }

    private func contextWindow(from object: [String: Any]) -> Int? {
        let keys = [
            "context_window", "contextWindow",
            "max_context_window", "maxContextWindow",
            "context_length", "contextLength",
            "max_context_tokens", "maxContextTokens",
            "input_token_limit", "inputTokenLimit",
            "max_input_tokens", "maxInputTokens"
        ]
        for key in keys {
            if let value = intValue(object[key]), value > 0 {
                return value
            }
        }
        for nestedKey in ["metadata", "capabilities", "limits", "token_limits"] {
            if let nested = object[nestedKey] as? [String: Any],
               let nestedWindow = contextWindow(from: nested) {
                return nestedWindow
            }
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// Generate a human-friendly title from a model ID.
    private func prettifyModelID(_ id: String, cli: CLIType) -> String {
        let knownOptions = ChatModelCatalog.options(for: cli)
        let executionID = ChatModelCatalog.executionModelID(for: id)
        if let known = knownOptions.first(where: { $0.id == executionID }) {
            if id.lowercased().contains("[1m]"), !known.title.lowercased().contains("1m") {
                return "\(known.title) 1M"
            }
            return known.title
        }
        return id
    }

    /// Thread-safe snapshot of the model list and the effective default ID, read
    /// directly from the on-disk configuration (catalog + ~/.claude/settings.json /
    /// ~/.codex/config.toml + ProjectStore custom IDs).
    /// Live-fetched relay models are NOT included here because they only exist on
    /// the @MainActor live instance — the remote HTTP API uses this snapshot so it
    /// can be called from the network thread without crossing actor boundaries.
    nonisolated static func diskSnapshotOptions(for cli: CLIType) -> (options: [ChatModelOption], defaultModelID: String) {
        let visibleCLI = cli.visibleValue
        let catalog = ChatModelCatalog.options(for: visibleCLI)
        let custom = loadCustomModels(for: visibleCLI)
        let configured: [ChatModelOption]
        let configuredDefault: String?
        switch visibleCLI {
        case .claude, .gemini, .custom:
            let info = loadClaudeConfiguredModels()
            configured = info.modelIDs.map { ChatModelOption(id: $0, title: snapshotPrettify($0, cli: .claude), cli: .claude) }
            configuredDefault = info.defaultModelID?.nonEmptyTrimmed
        case .codex:
            let id = loadCodexConfiguredModel()
            configured = id.map { [ChatModelOption(id: $0, title: snapshotPrettify($0, cli: .codex), cli: .codex)] } ?? []
            configuredDefault = id?.nonEmptyTrimmed
        }

        let merged = snapshotMerge([catalog, configured, custom])
        let effectiveDefault = configuredDefault ?? ChatModelCatalog.defaultModelID(for: visibleCLI)
        let final = snapshotApplyDefaultTitle(merged, cli: visibleCLI, configured: effectiveDefault)
        return (final, effectiveDefault)
    }

    nonisolated private static func snapshotMerge(_ groups: [[ChatModelOption]]) -> [ChatModelOption] {
        groups.flatMap { $0 }.reduce(into: [ChatModelOption]()) { result, option in
            let key = snapshotIdentityKey(option)
            if let existingIndex = result.firstIndex(where: { snapshotIdentityKey($0) == key }) {
                result[existingIndex] = option
            } else {
                result.append(option)
            }
        }
    }

    nonisolated private static func snapshotIdentityKey(_ option: ChatModelOption) -> String {
        let executionID = ChatModelCatalog.executionModelID(for: option.id).lowercased()
        return "\(option.cli.visibleValue.rawValue):\(executionID)"
    }

    nonisolated private static func snapshotPrettify(_ id: String, cli: CLIType) -> String {
        let known = ChatModelCatalog.options(for: cli)
        let executionID = ChatModelCatalog.executionModelID(for: id)
        if let match = known.first(where: { $0.id == executionID }) { return match.title }
        return id
    }

    nonisolated private static func snapshotApplyDefaultTitle(_ options: [ChatModelOption], cli: CLIType, configured: String) -> [ChatModelOption] {
        let catalogDefault = ChatModelCatalog.defaultModelID(for: cli)
        guard catalogDefault == "default", configured != catalogDefault else { return options }
        let configuredTitle = snapshotPrettify(configured, cli: cli)
        return options.map { option in
            guard option.id == catalogDefault else { return option }
            return ChatModelOption(id: option.id, title: "默认（\(configuredTitle)）", cli: option.cli, contextWindow: option.contextWindow)
        }
    }

    nonisolated private static func loadClaudeConfiguredModels() -> (defaultModelID: String?, modelIDs: [String]) {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: String] else {
            return (nil, [])
        }

        let ids = [
            env["ANTHROPIC_MODEL"],
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"],
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"],
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]
        ]
        .compactMap { $0?.nonEmptyTrimmed }

        return (env["ANTHROPIC_MODEL"]?.nonEmptyTrimmed, unique(ids))
    }

    nonisolated private static func loadCodexConfiguredModel() -> String? {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return nil }
        return parseTomlValue(text, key: "model")?.nonEmptyTrimmed
    }

    nonisolated private static func loadCustomModels(for cli: CLIType) -> [ChatModelOption] {
        customModelIDs(for: cli).map { id in
            ChatModelOption(id: id, title: id, cli: cli.visibleValue == .codex ? .codex : .claude)
        }
    }

    nonisolated private static func customModelIDs(for cli: CLIType) -> [String] {
        let settings = ProjectStore.loadSettings()
        return cli.visibleValue == .codex ? settings.customCodexModelIDs : settings.customClaudeModelIDs
    }

    private static func saveCustomModels(_ ids: [String], for cli: CLIType) {
        var settings = ProjectStore.loadSettings()
        let unique = unique(ids)
        if cli.visibleValue == .codex {
            settings.customCodexModelIDs = unique
        } else {
            settings.customClaudeModelIDs = unique
        }
        try? ProjectStore.saveSettings(settings)
    }

    nonisolated private static func parseTomlValue(_ text: String, key: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            return parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    nonisolated private static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    nonisolated private static var realHomeDirectory: URL {
        if let passwd = getpwuid(getuid()), let directory = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated private static var claudeSettingsURL: URL {
        realHomeDirectory.appendingPathComponent(".claude/settings.json")
    }

    nonisolated private static var codexConfigURL: URL {
        realHomeDirectory.appendingPathComponent(".codex/config.toml")
    }
}
