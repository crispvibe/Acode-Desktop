import Foundation

public struct ChatFileReference: Identifiable, Hashable {
    public var id: String { raw ?? path }
    public let raw: String?
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(raw: String? = nil, path: String, line: Int? = nil, column: Int? = nil) {
        self.raw = raw
        self.path = path
        self.line = line
        self.column = column
    }
}
