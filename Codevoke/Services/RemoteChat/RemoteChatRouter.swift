import Foundation
import ChatCore
import Darwin
import os

private let remoteChatRouterLog = Logger(subsystem: "com.codevoke.mac", category: "RemoteChatRouter")

struct RemoteChatServerConfiguration {
    let port: UInt16
    let bindLAN: Bool
}

protocol RemoteChatDataProviding {
    func loadProjects() -> [ProjectItem]
    func loadSessions() -> [ChatSessionRecord]
    func loadSession(id: UUID) -> ChatSessionRecord?
    func loadMessages(sessionID: UUID) -> [ChatMessage]
    func loadMessagePage(sessionID: UUID, beforeIndex: Int?, limit: Int) -> ChatMessagePage
}

struct RemoteChatStoreProvider: RemoteChatDataProviding {
    func loadProjects() -> [ProjectItem] {
        ProjectStore.loadProjects()
    }

    func loadSessions() -> [ChatSessionRecord] {
        ChatSessionStore.loadSessions()
    }

    func loadSession(id: UUID) -> ChatSessionRecord? {
        ChatSessionStore.loadSession(id: id)
    }

    func loadMessages(sessionID: UUID) -> [ChatMessage] {
        ChatSessionStore.loadMessages(sessionID: sessionID)
    }

    func loadMessagePage(sessionID: UUID, beforeIndex: Int?, limit: Int) -> ChatMessagePage {
        ChatSessionStore.loadMessagePage(sessionID: sessionID, beforeIndex: beforeIndex, limit: limit)
    }
}

struct RemoteChatRouter {
    private let configuration: RemoteChatServerConfiguration
    private let dataProvider: RemoteChatDataProviding

    init(configuration: RemoteChatServerConfiguration, dataProvider: RemoteChatDataProviding = RemoteChatStoreProvider()) {
        self.configuration = configuration
        self.dataProvider = dataProvider
    }

    func route(_ request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        if request.path == "/health" {
            guard request.method == "GET" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return .json(RemoteHealthDTO(
                ok: true,
                name: "Codevoke Remote Chat",
                version: 1,
                bindLAN: configuration.bindLAN,
                port: configuration.port,
                authRequired: false
            ))
        }

        let components = pathComponents(request.path)

        if components == ["attachments"] {
            guard request.method == "POST" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return uploadAttachmentResponse(request)
        }

        if components == ["config", "profiles"] {
            guard request.method == "GET" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return configProfilesResponse()
        }

        if components == ["config", "claude-profile"] {
            guard request.method == "POST" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return saveClaudeProfileResponse(request)
        }

        if components == ["config", "claude-profile", "activate"] {
            guard request.method == "POST" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return activateClaudeProfileResponse(request)
        }

        if components == ["config", "claude-models"] {
            guard request.method == "POST" else {
                return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
            }
            return fetchClaudeModelsResponse(request)
        }

        guard request.method == "GET" else {
            return .error("method_not_allowed", message: "当前请求方式不支持。", statusCode: 405, reasonPhrase: "Method Not Allowed")
        }

        if components == ["projects"] {
            return projectsResponse()
        }

        if components == ["models"] {
            return modelsResponse(cli: request.queryItems["cli"])
        }

        if components.count == 3, components[0] == "projects", components[2] == "files" {
            return projectFilesResponse(projectId: components[1], relativePath: request.queryItems["path"] ?? "")
        }

        if components == ["sessions"] {
            return sessionsResponse(projectId: request.queryItems["projectId"], cli: request.queryItems["cli"])
        }

        if components.count == 2, components[0] == "sessions" {
            return sessionResponse(id: components[1])
        }

        if components.count == 3, components[0] == "sessions", components[2] == "messages" {
            return messagesResponse(
                sessionId: components[1],
                limit: request.queryItems["limit"],
                before: request.queryItems["before"],
                page: request.queryItems["page"]
            )
        }

        if components == ["events"] {
            return .error("events_not_available", message: "实时消息暂不可用，请重新进入对话。", statusCode: 501, reasonPhrase: "Not Implemented")
        }

        return .error("not_found", message: "没有找到对应内容，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
    }

    func recoveryResponse(for request: RemoteRecoveryRequest) -> RemoteRecoveryResponse {
        switch request.op {
        case .catalog:
            return .ok(
                requestId: request.requestId,
                projects: recoveryProjects(),
                models: recoveryModels(cli: request.cli),
                sessions: recoverySessions(projectId: request.projectId, cli: request.cli)
            )

        case .sessions:
            let sessions = recoverySessions(projectId: request.projectId, cli: request.cli)
            return .ok(requestId: request.requestId, sessions: sessions)

        case .messages:
            guard let sessionId = request.sessionId else {
                return .error(requestId: request.requestId, message: "对话信息无效，请重新选择对话。")
            }
            guard dataProvider.loadSession(id: sessionId) != nil else {
                return .error(requestId: request.requestId, message: "没有找到这个对话，请刷新后重试。")
            }
            let limit = request.limit.map { min(max($0, 1), 500) } ?? 120
            if request.page == true {
                let page = dataProvider.loadMessagePage(sessionID: sessionId, beforeIndex: request.before, limit: limit)
                return .ok(
                    requestId: request.requestId,
                    messagePage: RemoteRecoveryMessagePageDTO(
                        messages: page.messages,
                        nextBeforeIndex: page.nextBeforeIndex,
                        hasMore: page.hasMore,
                        totalCount: page.totalCount
                    )
                )
            }
            let messages = Array(dataProvider.loadMessages(sessionID: sessionId).suffix(limit))
            return .ok(requestId: request.requestId, messages: messages)

        case .projectFiles:
            guard let projectId = request.projectId else {
                return .error(requestId: request.requestId, message: "项目信息无效，请重新选择项目。")
            }
            let response = projectFilesResponse(projectId: projectId.uuidString, relativePath: request.path ?? "")
            guard 200..<300 ~= response.statusCode else {
                let message = (try? RemoteChatHTTPCodec.jsonDecoder.decode(RemoteErrorDTO.self, from: response.body).message)
                    ?? "文件列表读取失败，请在 Mac 端确认项目权限。"
                return .error(requestId: request.requestId, message: message)
            }
            guard let files = try? RemoteChatHTTPCodec.jsonDecoder.decode(RemoteRecoveryProjectFilesDTO.self, from: response.body) else {
                return .error(requestId: request.requestId, message: "文件列表响应格式不正确，请重试。")
            }
            return .ok(requestId: request.requestId, files: files)

        case .uploadAttachment:
            guard let filename = request.filename,
                  let contentBase64 = request.contentBase64 else {
                return .error(requestId: request.requestId, message: "附件信息不完整，请重新上传。")
            }
            switch storeUploadedAttachment(filename: filename, contentBase64: contentBase64, maxBytes: RemoteRecoveryLimits.maximumAttachmentBytes) {
            case .success(let upload):
                return .ok(requestId: request.requestId, attachmentUpload: upload)
            case .failure(let error):
                return .error(requestId: request.requestId, message: error.message)
            }
        }
    }

    private func projectsResponse() -> RemoteChatHTTPResponse {
        .json(dataProvider.loadProjects().map(RemoteProjectDTO.init(project:)))
    }

    private func modelsResponse(cli rawCLI: String?) -> RemoteChatHTTPResponse {
        let cli = CLIType(rawValue: rawCLI ?? "")?.visibleValue ?? .claude
        // Read the merged disk snapshot (catalog + configured + custom) instead
        // of just the builtin catalog so iOS sees every model the user has
        // actually set up on Mac (relay-backed Claude IDs, custom IDs etc.).
        let snapshot = ChatModelService.diskSnapshotOptions(for: cli)
        return .json(snapshot.options.map { RemoteModelDTO(option: $0, defaultModelID: snapshot.defaultModelID) })
    }

    private func uploadAttachmentResponse(_ request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        do {
            let upload = try JSONDecoder().decode(RemoteAttachmentUploadRequestDTO.self, from: request.body)
            switch storeUploadedAttachment(filename: upload.filename, contentBase64: upload.contentBase64, maxBytes: Self.maximumHTTPAttachmentBytes) {
            case .success(let uploaded):
                return .json(RemoteAttachmentUploadResponseDTO(filename: uploaded.filename, path: uploaded.path), statusCode: 201, reasonPhrase: "Created")
            case .failure(let error):
                return .error(error.code, message: error.message, statusCode: error.statusCode, reasonPhrase: error.reasonPhrase)
            }
        } catch {
            return .error("upload_failed", message: error.localizedDescription, statusCode: 400, reasonPhrase: "Bad Request")
        }
    }

    private struct AttachmentUploadFailure: Error {
        let code: String
        let message: String
        let statusCode: Int
        let reasonPhrase: String
    }

    private static let maximumHTTPAttachmentBytes = RemoteRecoveryLimits.maximumAttachmentBytes
    private static let maximumFilenameLength = 180

    private func storeUploadedAttachment(filename rawFilename: String, contentBase64: String, maxBytes: Int) -> Result<RemoteRecoveryAttachmentUploadDTO, AttachmentUploadFailure> {
        let filename = sanitizedFilename(rawFilename)
        guard !filename.isEmpty else {
            return .failure(AttachmentUploadFailure(code: "invalid_filename", message: "文件名不能为空。", statusCode: 400, reasonPhrase: "Bad Request"))
        }
        guard filename.count <= Self.maximumFilenameLength else {
            return .failure(AttachmentUploadFailure(code: "filename_too_long", message: "文件名过长，请重命名后再上传。", statusCode: 400, reasonPhrase: "Bad Request"))
        }
        guard Self.isBase64ContentLength(contentBase64.count, withinDecodedByteLimit: maxBytes) else {
            return .failure(AttachmentUploadFailure(code: "attachment_too_large", message: "附件超过大小限制，请压缩后再上传。", statusCode: 413, reasonPhrase: "Payload Too Large"))
        }
        guard let data = Data(base64Encoded: contentBase64) else {
            return .failure(AttachmentUploadFailure(code: "invalid_content", message: "文件内容格式不正确，请重新上传。", statusCode: 400, reasonPhrase: "Bad Request"))
        }
        if data.count > maxBytes {
            return .failure(AttachmentUploadFailure(code: "attachment_too_large", message: "附件超过大小限制，请压缩后再上传。", statusCode: 413, reasonPhrase: "Payload Too Large"))
        }
        guard Self.isAllowedAttachmentExtension(filename) else {
            return .failure(AttachmentUploadFailure(code: "attachment_type_not_allowed", message: "暂不支持这种附件类型。", statusCode: 415, reasonPhrase: "Unsupported Media Type"))
        }
        do {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodevokeRemoteChatAttachments", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
            try data.write(to: fileURL, options: [.atomic])
            return .success(RemoteRecoveryAttachmentUploadDTO(filename: filename, path: fileURL.path))
        } catch {
            return .failure(AttachmentUploadFailure(code: "upload_failed", message: error.localizedDescription, statusCode: 400, reasonPhrase: "Bad Request"))
        }
    }

    /// Audit B-P1-6: extension allow-list for uploaded attachments. Keeps the
    /// surface to images, common documents, and source code files — the
    /// universe Codevoke actually surfaces in chat.
    private static let allowedAttachmentExtensions: Set<String> = [
        // images
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic",
        // documents
        "pdf", "txt", "md", "rtf", "csv",
        // structured text / data
        "json", "yaml", "yml", "toml", "xml", "html", "htm",
        // source code
        "swift", "py", "rb", "go", "rs", "js", "ts", "tsx", "jsx",
        "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "kts",
        "sh", "bash", "zsh", "fish", "lua", "sql", "ini", "conf",
        "log"
    ]

    private static func isAllowedAttachmentExtension(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true } // accept extension-less text files
        return allowedAttachmentExtensions.contains(ext)
    }

    private static func isBase64ContentLength(_ encodedLength: Int, withinDecodedByteLimit limit: Int) -> Bool {
        let maximumEncodedLength = ((limit + 2) / 3) * 4
        return encodedLength <= maximumEncodedLength
    }

    private func configProfilesResponse() -> RemoteChatHTTPResponse {
        .json(RemoteConfigProfilesDTO(collection: ProjectStore.loadConfigProfiles()))
    }

    private func saveClaudeProfileResponse(_ request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        do {
            let saveRequest = try JSONDecoder().decode(RemoteClaudeRelayProfileSaveRequestDTO.self, from: request.body)
            let profileID = saveRequest.profile.profile.id
            try ProjectStore.mutateConfigProfiles { collection in
                var profile = saveRequest.profile.profile
                let now = Date()
                if let index = collection.claudeRelayProfiles.firstIndex(where: { $0.id == profile.id }) {
                    if profile.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       saveRequest.profile.authTokenSet {
                        profile.authToken = collection.claudeRelayProfiles[index].authToken
                    }
                    profile.createdAt = collection.claudeRelayProfiles[index].createdAt
                    profile.updatedAt = now
                    collection.claudeRelayProfiles[index] = profile
                } else {
                    profile.createdAt = now
                    profile.updatedAt = now
                    collection.claudeRelayProfiles.insert(profile, at: 0)
                }
                if saveRequest.activate {
                    collection.activeClaudeRelayProfileID = profile.id
                }
            }
            let updated = ProjectStore.loadConfigProfiles()
            if saveRequest.activate, let profile = updated.claudeRelayProfiles.first(where: { $0.id == profileID }) {
                try writeClaudeSettings(profile)
            }
            return .json(RemoteConfigProfilesDTO(collection: updated))
        } catch {
            return .error("profile_save_failed", message: error.localizedDescription, statusCode: 400, reasonPhrase: "Bad Request")
        }
    }

    private func activateClaudeProfileResponse(_ request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        do {
            let activateRequest = try JSONDecoder().decode(RemoteClaudeRelayProfileActivateRequestDTO.self, from: request.body)
            var didFind = false
            try ProjectStore.mutateConfigProfiles { collection in
                guard let profile = collection.claudeRelayProfiles.first(where: { $0.id == activateRequest.id }) else { return }
                collection.activeClaudeRelayProfileID = profile.id
                didFind = true
            }
            guard didFind else {
                return .error("profile_not_found", message: "没有找到这个配置，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
            }
            let updated = ProjectStore.loadConfigProfiles()
            if let profile = updated.claudeRelayProfiles.first(where: { $0.id == activateRequest.id }) {
                try writeClaudeSettings(profile)
            }
            return .json(RemoteConfigProfilesDTO(collection: updated))
        } catch {
            return .error("profile_activate_failed", message: error.localizedDescription, statusCode: 400, reasonPhrase: "Bad Request")
        }
    }

    private func fetchClaudeModelsResponse(_ request: RemoteChatHTTPRequest) -> RemoteChatHTTPResponse {
        do {
            let fetchRequest = try JSONDecoder().decode(RemoteClaudeModelFetchRequestDTO.self, from: request.body)
            let baseURL = fetchRequest.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseURL.isEmpty else {
                return .error("missing_base_url", message: "请填写接口地址。", statusCode: 400, reasonPhrase: "Bad Request")
            }
            guard let normalizedBaseURL = normalizedExternalModelBaseURL(baseURL) else {
                return .error("invalid_base_url", message: "接口地址不能是本机或内网地址。", statusCode: 400, reasonPhrase: "Bad Request")
            }
            let candidates = [
                normalizedBaseURL.appendingPathComponent("v1/models"),
                normalizedBaseURL.appendingPathComponent("models"),
            ]
            let models = fetchClaudeModelIDs(from: candidates, token: fetchRequest.authToken)
            return .json(RemoteClaudeModelFetchResponseDTO(models: models))
        } catch {
            return .error("model_fetch_failed", message: error.localizedDescription, statusCode: 400, reasonPhrase: "Bad Request")
        }
    }

    private func projectFilesResponse(projectId: String, relativePath rawRelativePath: String) -> RemoteChatHTTPResponse {
        guard let uuid = UUID(uuidString: projectId) else {
            return .error("invalid_project_id", message: "项目信息无效，请重新选择项目。", statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard let project = dataProvider.loadProjects().first(where: { $0.id == uuid }) else {
            return .error("project_not_found", message: "没有找到这个项目，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
        }

        let rootURL: URL
        do {
            rootURL = try ProjectStore.resolveURL(for: project)
        } catch {
            remoteChatRouterLog.error("project files resolve failed projectId=\(projectId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .error("project_access_denied", message: "项目目录授权失效，请在 Mac 端重新添加或重新授权项目。", statusCode: 403, reasonPhrase: "Forbidden")
        }

        let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
        guard didStartAccessing else {
            remoteChatRouterLog.error("project files access denied projectId=\(projectId, privacy: .public)")
            return .error("project_access_denied", message: "没有权限读取这个项目，请在 Mac 端重新授权。", statusCode: 403, reasonPhrase: "Forbidden")
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let relativePath = sanitizedRelativePath(rawRelativePath)
        let directoryURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        guard isURL(directoryURL, inside: rootURL) else {
            return .error("invalid_path", message: "只能读取项目文件夹内的内容。", statusCode: 400, reasonPhrase: "Bad Request")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .error("directory_not_found", message: "没有找到这个文件夹，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
        }

        do {
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .nameKey]
            let urls = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
            let entries = urls.compactMap { url -> RemoteProjectFileEntryDTO? in
                guard let values = try? url.resourceValues(forKeys: resourceKeys), values.isHidden != true else { return nil }
                let name = values.name ?? url.lastPathComponent
                guard !name.isEmpty else { return nil }
                let isDirectory = values.isDirectory == true
                let childRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                return RemoteProjectFileEntryDTO(name: name, relativePath: childRelativePath, isDirectory: isDirectory)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

            return .json(RemoteProjectFilesDTO(
                projectId: uuid,
                path: relativePath,
                parentPath: parentPath(for: relativePath),
                entries: Array(entries.prefix(200))
            ))
        } catch {
            let nsError = error as NSError
            remoteChatRouterLog.error("project files listing failed projectId=\(projectId, privacy: .public) relativePath=\(relativePath, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            if isPermissionDenied(nsError) {
                return .error("project_access_denied", message: "没有权限读取这个文件夹，请在 Mac 端重新授权项目。", statusCode: 403, reasonPhrase: "Forbidden")
            }
            if isMissingFile(nsError) {
                return .error("directory_not_found", message: "没有找到这个文件夹，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
            }
            return .error("file_listing_failed", message: "文件列表读取失败，请在 Mac 端确认项目权限。", statusCode: 500, reasonPhrase: "Internal Server Error")
        }
    }

    private func sessionsResponse(projectId: String?, cli rawCLI: String?) -> RemoteChatHTTPResponse {
        var sessions = dataProvider.loadSessions()
        if let rawCLI, !rawCLI.isEmpty {
            let cli = CLIType(rawValue: rawCLI)?.visibleValue ?? .claude
            sessions = sessions.filter { $0.cli.visibleValue == cli }
        }
        if let projectId {
            guard let uuid = UUID(uuidString: projectId) else {
                return .error("invalid_project_id", message: "项目信息无效，请重新选择项目。", statusCode: 400, reasonPhrase: "Bad Request")
            }
            guard let project = dataProvider.loadProjects().first(where: { $0.id == uuid }) else {
                return .error("project_not_found", message: "没有找到这个项目，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
            }
            let projectPath = normalizedPath(project.path)
            sessions = sessions.filter { normalizedPath($0.projectPath) == projectPath }
        }
        return .json(sessions.map(RemoteSessionDTO.init(session:)))
    }

    private func recoverySessions(projectId: UUID?, cli rawCLI: String?) -> [PanelSessionDTO] {
        let projects = dataProvider.loadProjects()
        let projectByPath = Dictionary(grouping: projects.compactMap { project -> (String, ProjectItem)? in
            let path = normalizedPath(project.path)
            guard !path.isEmpty else { return nil }
            return (path, project)
        }, by: { $0.0 })
        var sessions = dataProvider.loadSessions()
        if let rawCLI, !rawCLI.isEmpty {
            let cli = CLIType(rawValue: rawCLI)?.visibleValue ?? .claude
            sessions = sessions.filter { $0.cli.visibleValue == cli }
        }
        if let projectId,
           let project = projects.first(where: { $0.id == projectId }) {
            let projectPath = normalizedPath(project.path)
            sessions = sessions.filter { normalizedPath($0.projectPath) == projectPath }
        }
        return sessions.compactMap { session in
            let project = projectByPath[normalizedPath(session.projectPath)]?.first?.1
            if let projectId, project?.id != projectId {
                return nil
            }
            return PanelSessionDTO(
                id: session.id,
                cli: session.cli.rawValue,
                projectId: project?.id,
                projectName: project?.name ?? session.projectName,
                projectPath: session.projectPath,
                title: session.title,
                modelID: session.modelID,
                runStatus: session.runStatus.rawValue,
                statusText: session.statusText,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                lastCompletedAt: session.lastCompletedAt,
                queuedCount: 0
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func recoveryProjects() -> [PanelProjectDTO] {
        dataProvider.loadProjects().map { project in
            PanelProjectDTO(
                id: project.id,
                name: project.name,
                path: project.path,
                defaultCLI: project.defaultCLI.rawValue,
                createdAt: project.createdAt,
                updatedAt: project.updatedAt,
                lastOpenedAt: project.lastOpenedAt
            )
        }
    }

    private func recoveryModels(cli rawCLI: String?) -> [PanelModelDTO] {
        let cliTypes: [CLIType]
        if let rawCLI, !rawCLI.isEmpty {
            cliTypes = [CLIType(rawValue: rawCLI)?.visibleValue ?? .claude]
        } else {
            cliTypes = CLIType.visibleCases
        }
        return cliTypes.flatMap { cli in
            let snapshot = ChatModelService.diskSnapshotOptions(for: cli)
            return snapshot.options.map { option in
                PanelModelDTO(
                    id: option.id,
                    title: option.title,
                    cli: cli.rawValue,
                    isDefault: option.id == snapshot.defaultModelID
                )
            }
        }
    }

    private func sessionResponse(id: String) -> RemoteChatHTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .error("invalid_session_id", message: "对话信息无效，请重新选择对话。", statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard let session = dataProvider.loadSession(id: uuid) else {
            return .error("session_not_found", message: "没有找到这个对话，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
        }
        return .json(RemoteSessionDTO(session: session))
    }

    private func messagesResponse(sessionId: String, limit rawLimit: String?, before rawBefore: String?, page rawPage: String?) -> RemoteChatHTTPResponse {
        guard let uuid = UUID(uuidString: sessionId) else {
            return .error("invalid_session_id", message: "对话信息无效，请重新选择对话。", statusCode: 400, reasonPhrase: "Bad Request")
        }
        guard dataProvider.loadSession(id: uuid) != nil else {
            return .error("session_not_found", message: "没有找到这个对话，请刷新后重试。", statusCode: 404, reasonPhrase: "Not Found")
        }
        let limit = rawLimit.flatMap(Int.init).map { min(max($0, 1), 500) } ?? 120
        let beforeIndex = rawBefore.flatMap(Int.init)
        if rawPage == "true" {
            return .json(RemoteMessagePageDTO(page: dataProvider.loadMessagePage(sessionID: uuid, beforeIndex: beforeIndex, limit: limit)))
        }
        var messages = dataProvider.loadMessages(sessionID: uuid)
        messages = Array(messages.suffix(limit))
        return .json(messages.map(RemoteMessageDTO.init(message:)))
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func sanitizedRelativePath(_ path: String) -> String {
        path.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private func parentPath(for relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        return false
    }

    private func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
        }
        return false
    }

    private func sanitizedFilename(_ rawValue: String) -> String {
        let fallback = "attachment"
        let name = (rawValue as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name.isEmpty ? fallback : name
        let disallowed = CharacterSet(charactersIn: "/:\\0").union(.newlines)
        return value.components(separatedBy: disallowed).joined(separator: "_")
    }

    private func writeClaudeSettings(_ profile: ClaudeRelayProfile) throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var env = (json["env"] as? [String: Any]) ?? [:]
        let fields: [(String, String)] = [
            ("ANTHROPIC_BASE_URL", profile.baseURL),
            ("ANTHROPIC_API_KEY", profile.authToken),
            ("ANTHROPIC_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", profile.haikuModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", profile.sonnetModel),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", profile.opusModel),
            ("HTTP_PROXY", profile.httpProxy),
            ("HTTPS_PROXY", profile.httpsProxy),
        ]
        for (key, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                env.removeValue(forKey: key)
            } else {
                env[key] = trimmed
            }
        }
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        json["env"] = env
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func fetchClaudeModelIDs(from candidates: [URL], token rawToken: String) -> [String] {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in candidates {
            guard isAllowedExternalModelFetchURL(url) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: [String] = []
            URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { semaphore.signal() }
                guard let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }
                result = parseModelListResponse(data)
            }.resume()
            _ = semaphore.wait(timeout: .now() + 16)
            if !result.isEmpty {
                return result.sorted()
            }
        }
        return []
    }

    private func normalizedExternalModelBaseURL(_ rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard isAllowedExternalHost(host) else { return nil }
        return components.url
    }

    private func isAllowedExternalModelFetchURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else {
            return false
        }
        return isAllowedExternalHost(host)
    }

    private func isAllowedExternalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
            return false
        }
        if let ipv4 = Self.ipv4Address(normalized) {
            let first = Int(ipv4[0])
            let second = Int(ipv4[1])
            if first == 10 || first == 127 || first == 0 { return false }
            if first == 169 && second == 254 { return false }
            if first == 172 && (16...31).contains(second) { return false }
            if first == 192 && second == 168 { return false }
            if first >= 224 { return false }
            return true
        }
        if let ipv6 = Self.ipv6Address(normalized) {
            if ipv6.allSatisfy({ $0 == 0 }) { return false }
            if ipv6.dropLast().allSatisfy({ $0 == 0 }) && ipv6.last == 1 { return false }
            if ipv6.prefix(10).allSatisfy({ $0 == 0 }), ipv6[10] == 0xff, ipv6[11] == 0xff {
                return isAllowedExternalHost(ipv6.suffix(4).map(String.init).joined(separator: "."))
            }
            if ipv6[0] & 0xfe == 0xfc { return false }
            if ipv6[0] == 0xfe && (ipv6[1] & 0xc0) == 0x80 { return false }
            if ipv6[0] == 0xff { return false }
            return true
        }
        return true
    }

    private static func ipv4Address(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address, Array.init)
    }

    private static func ipv6Address(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address, Array.init)
    }

    private func parseModelListResponse(_ data: Data) -> [String] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArray = json["data"] as? [[String: Any]] {
            return dataArray.compactMap { $0["id"] as? String }
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { $0["id"] as? String }
        }
        return []
    }

    private func isURL(_ url: URL, inside rootURL: URL) -> Bool {
        // 必须先 resolveSymlinksInPath 再比较，否则项目目录下的 symlink（例如 link -> /etc）
        // 可以让远程客户端访问到项目以外的文件。standardizedFileURL 不会展开 symlink。
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
