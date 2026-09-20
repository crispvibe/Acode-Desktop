import Foundation
import ChatCore

// MARK: - Convenience aliases for ChatCore types

typealias ChatMessage = ChatCore.ChatMessage
typealias ChatMessageKind = ChatCore.ChatMessageKind

// Panel DTOs 在 spec 里只 Codable+Equatable —— iOS 端用 SwiftUI ForEach 时显式传
// `id: \.id`，因此不需要给它们补 Identifiable/Hashable conformance（避免 cross-
// module extension warning，也避免和 protocol-server 合并时的口径分歧）。

// MARK: - File tree (still HTTP-driven, see RemoteHTTPClient)

struct RemoteProjectFileEntry: Identifiable, Codable, Hashable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

struct RemoteProjectFiles: Codable, Hashable {
    let projectId: UUID
    let path: String
    let parentPath: String?
    let entries: [RemoteProjectFileEntry]
}

// MARK: - Attachment upload

struct RemoteAttachmentUploadRequest: Codable {
    let filename: String
    let contentBase64: String
}

struct RemoteAttachmentUploadResponse: Codable, Hashable {
    let filename: String
    let path: String
}

/// 本地待发送/上传完成的附件占位，UI 在 composer 中展示。
/// 上传成功后会变成 `ChatMessageAttachment` 通过 `composerAttach` 写入 server 端 composer。
struct RemoteUploadedAttachment: Identifiable, Hashable {
    let id: UUID
    let filename: String
    let path: String
    let previewData: Data?
    let approximateSize: Int

    init(id: UUID = UUID(), filename: String, path: String, previewData: Data? = nil, approximateSize: Int = 0) {
        self.id = id
        self.filename = filename
        self.path = path
        self.previewData = previewData
        self.approximateSize = approximateSize
    }
}


// MARK: - Health

// 各 host 的 /health 载荷不一致（Windows 端只回 {"status":"ok"}），字段全部按可选解。
// WAN 契约（§4.2）新增：`proto:2` = 鉴权版服务端、`pair:true` = 支持 6 位码配对、
// `name` = 主机名（复用现有字段）。
struct RemoteHealth: Codable {
    let ok: Bool?
    let name: String?
    let version: Int?
    let bindLAN: Bool?
    let port: UInt16?
    let authRequired: Bool?
    let proto: Int?
    let pair: Bool?
}
