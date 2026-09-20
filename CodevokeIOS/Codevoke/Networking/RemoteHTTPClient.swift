import Foundation

/// iOS 端 HTTP 客户端 —— VNC 协议下绝大多数业务状态走 WebSocket snapshot/patch，
/// 只保留以下 HTTP 入口：
///
/// - `GET /health`：连接前 reachability 探测。
/// - `GET /projects/{id}/files`：iOS 侧栏文件树（主代理决策保留）。
/// - `POST /attachments`：附件预上传；WebSocket 恢复通道兜底。
struct RemoteHTTPClient {
    let config: RemoteChatConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let debugLog: (String) -> Void

    init(config: RemoteChatConfig, session: URLSession = .shared, debugLog: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.session = session
        self.debugLog = debugLog
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func fetchHealth() async throws -> RemoteHealth {
        try await get("/health")
    }

    /// 文件树仍走 HTTP（主代理决策保留）。
    func fetchProjectFiles(projectId: UUID, path: String = "") async throws -> RemoteProjectFiles {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return try await get("/projects/\(projectId.uuidString)/files?path=\(encodedPath)")
    }

    // MARK: - Attachment upload

    func uploadAttachment(filename: String, data: Data) async throws -> RemoteAttachmentUploadResponse {
        let request = RemoteAttachmentUploadRequest(filename: filename, contentBase64: data.base64EncodedString())
        return try await post("/attachments", body: request)
    }

    // MARK: - Internals

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        guard let baseURL = config.baseURL else { throw RemoteChatError.invalidURL }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw RemoteChatError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        debugLog("POST \(path)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("POST \(path) -> no HTTP response")
                throw RemoteChatError.emptyResponse
            }
            debugLog("POST \(path) -> HTTP \(httpResponse.statusCode), \(data.count) bytes")
            guard 200..<300 ~= httpResponse.statusCode else {
                throw decodedHTTPError(statusCode: httpResponse.statusCode, data: data)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                debugLog("POST \(path) decode failed: \(error.localizedDescription); body: \(preview)")
                throw error
            }
        } catch {
            debugLog("POST \(path) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let baseURL = config.baseURL else { throw RemoteChatError.invalidURL }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw RemoteChatError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        debugLog("GET \(path)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("GET \(path) -> no HTTP response")
                throw RemoteChatError.emptyResponse
            }
            debugLog("GET \(path) -> HTTP \(httpResponse.statusCode), \(data.count) bytes")
            guard 200..<300 ~= httpResponse.statusCode else {
                throw decodedHTTPError(statusCode: httpResponse.statusCode, data: data)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                debugLog("GET \(path) decode failed: \(error.localizedDescription); body: \(preview)")
                throw error
            }
        } catch {
            debugLog("GET \(path) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func decodedHTTPError(statusCode: Int, data: Data) -> RemoteChatError {
        if let payload = try? decoder.decode(RemoteServerErrorPayload.self, from: data),
           let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return .serverMessage(message, statusCode: statusCode)
        }
        return .badStatus(statusCode)
    }
}
