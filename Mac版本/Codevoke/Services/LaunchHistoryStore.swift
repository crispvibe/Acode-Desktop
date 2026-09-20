import Foundation

struct LaunchHistoryStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var historyURL: URL { get throws { try ProjectStore.appSupportDirectory.appendingPathComponent("launch-history.json") } }

    static func load() -> [LaunchRecord] {
        do {
            let url = try historyURL
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try decoder.decode([LaunchRecord].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ records: [LaunchRecord]) throws {
        let trimmed = Array(records.prefix(50))
        let data = try encoder.encode(trimmed)
        try data.write(to: historyURL, options: [.atomic])
    }
}
