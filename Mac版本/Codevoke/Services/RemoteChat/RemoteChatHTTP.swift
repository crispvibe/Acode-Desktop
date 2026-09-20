import Foundation

struct RemoteChatHTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data
}

struct RemoteChatHTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200, reasonPhrase: String = "OK") -> RemoteChatHTTPResponse {
        let body: Data
        do {
            body = try RemoteChatHTTPCodec.jsonEncoder.encode(value)
        } catch {
            body = Data("{\"error\":\"encoding_failed\",\"message\":\"响应生成失败，请稍后重试。\"}".utf8)
        }
        return RemoteChatHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    static func error(_ error: String, message: String, statusCode: Int, reasonPhrase: String) -> RemoteChatHTTPResponse {
        json(RemoteErrorDTO(error: error, message: userFacingMessage(error: error, message: message)), statusCode: statusCode, reasonPhrase: reasonPhrase)
    }

    private static func userFacingMessage(error: String, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.range(of: "[A-Za-z_]{3,}", options: .regularExpression) == nil {
            return trimmed
        }
        switch error {
        case "method_not_allowed":
            return "当前请求方式不支持。"
        case "unauthorized":
            return "连接凭证无效，请重新连接。"
        case "bad_request":
            return "请求内容格式不正确，请重试。"
        case "request_timeout":
            return "请求等待时间过长，请重试。"
        case "request_too_large":
            return "请求内容太大，请减少内容后重试。"
        case "bad_websocket_upgrade":
            return "实时连接启动失败，请重新进入对话。"
        case "websocket_payload_too_large":
            return "单条消息太大，请减少内容后重试。"
        case "websocket_decode_failed", "invalid_payload":
            return "实时消息格式不正确，请重新进入对话。"
        case "events_not_available":
            return "实时消息暂不可用，请重新进入对话。"
        case "not_found":
            return "没有找到对应内容，请刷新后重试。"
        case "invalid_filename":
            return "文件名不能为空。"
        case "invalid_content":
            return "文件内容格式不正确，请重新上传。"
        case "attachment_too_large":
            return "附件超过 10MB，请压缩后再上传。"
        case "attachment_type_not_allowed":
            return "暂不支持这种附件类型。"
        case "profile_not_found":
            return "没有找到这个配置，请刷新后重试。"
        case "missing_base_url":
            return "请填写接口地址。"
        case "invalid_base_url":
            return "接口地址不能是本机或内网地址。"
        case "invalid_project_id":
            return "项目信息无效，请重新选择项目。"
        case "project_not_found":
            return "没有找到这个项目，请刷新后重试。"
        case "project_access_denied":
            return "没有权限读取这个项目，请在 Mac 端重新授权。"
        case "invalid_path":
            return "只能读取项目文件夹内的内容。"
        case "directory_not_found":
            return "没有找到这个文件夹，请刷新后重试。"
        case "invalid_session_id":
            return "对话信息无效，请重新选择对话。"
        case "session_not_found":
            return "没有找到这个对话，请刷新后重试。"
        case "encoding_failed":
            return "响应生成失败，请稍后重试。"
        case "profile_save_failed":
            return "配置保存失败，请检查内容后重试。"
        case "profile_activate_failed":
            return "配置启用失败，请稍后重试。"
        case "model_fetch_failed":
            return "模型列表获取失败，请检查接口地址和密钥。"
        case "file_listing_failed":
            return "文件列表读取失败，请在 Mac 端确认项目权限。"
        default:
            return trimmed.isEmpty ? "操作失败，请稍后重试。" : "操作失败，请稍后重试。"
        }
    }

    var data: Data {
        var responseHeaders = headers
        if !body.isEmpty || statusCode != 101 {
            responseHeaders["Content-Length"] = "\(body.count)"
        }
        if responseHeaders["Connection"] == nil {
            responseHeaders["Connection"] = "close"
        }
        if statusCode != 101 {
            responseHeaders["Access-Control-Allow-Origin"] = "*"
        }

        var text = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for key in responseHeaders.keys.sorted() {
            text += "\(key): \(responseHeaders[key] ?? "")\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

enum RemoteChatHTTPCodec {
    // Audit A-P1: lowered from 64MB to 25MB to bound malicious / accidental
    // huge uploads. Single-file attachment cap (B-P1-6) is also 25MB, so a
    // legitimate request never needs more than this.
    static let maxRequestBytes = 25 * 1024 * 1024

    /// Audit A-P1: receiving an HTTP request used to block forever if the
    /// client sent a `Content-Length` header but then went silent. 30s read
    /// deadline is generous for legitimate uploads on slow networks.
    static let requestReadDeadline: TimeInterval = 30

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func parseRequest(from data: Data) throws -> RemoteChatHTTPRequest {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteChatHTTPError.malformedRequest
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { throw RemoteChatHTTPError.malformedRequest }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { throw RemoteChatHTTPError.malformedRequest }

        let target = requestParts[1]
        let targetParts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = targetParts[0].removingPercentEncoding ?? targetParts[0]
        let queryItems = parseQuery(targetParts.count > 1 ? targetParts[1] : "")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return RemoteChatHTTPRequest(
            method: requestParts[0].uppercased(),
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: bodyData(from: data, lines: lines)
        )
    }

    static func containsHeaderTerminator(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil || data.range(of: Data("\n\n".utf8)) != nil
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        guard !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for item in query.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[0]
            let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
            result[key] = value
        }
        return result
    }

    static func expectedRequestLength(for data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").dropFirst()
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "content-length" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let length = Int(value), length >= 0 else { return nil }
            return headerRange.upperBound + length
        }
        return headerRange.upperBound
    }

    private static func bodyData(from data: Data, lines: [String]) -> Data {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else { return Data() }
        return Data(data[headerRange.upperBound...])
    }
}

enum RemoteChatHTTPError: Error {
    case malformedRequest
    case requestTooLarge
}
