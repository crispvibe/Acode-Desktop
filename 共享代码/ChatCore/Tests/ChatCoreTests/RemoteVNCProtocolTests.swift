import XCTest
@testable import ChatCore

final class RemoteVNCProtocolTests: XCTestCase {
    func testFocusProjectCommandRoundTripsProjectId() throws {
        let projectId = UUID()
        let command = Command(op: .focusProject, args: CommandArgs(projectId: projectId))

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(decoded.op, .focusProject)
        XCTAssertEqual(decoded.args.projectId, projectId)
    }

    func testNewDraftSessionCarriesProjectIdBeforeSend() throws {
        let projectId = UUID()
        let command = Command(op: .newDraftSession, args: CommandArgs(projectId: projectId))

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(decoded.op, .newDraftSession)
        XCTAssertEqual(decoded.args.projectId, projectId)
    }

    func testCommandExpectedContextRoundTrips() throws {
        let projectId = UUID()
        let sessionId = UUID()
        let command = Command(
            op: .composerSend,
            sessionId: sessionId,
            args: CommandArgs(expectedProjectId: projectId, expectedSessionId: sessionId)
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.args.expectedProjectId, projectId)
        XCTAssertEqual(decoded.args.expectedSessionId, sessionId)
    }

    func testComposerSetModelCanCarryOwningCLI() throws {
        let command = Command(
            op: .composerSetModel,
            args: CommandArgs(cli: "codex", modelID: "gpt-5.5")
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(decoded.op, .composerSetModel)
        XCTAssertEqual(decoded.args.cli, "codex")
        XCTAssertEqual(decoded.args.modelID, "gpt-5.5")
    }

    func testResumeRequestRoundTripsFocusedSessionAndRevision() throws {
        let sessionId = UUID()
        let resume = ResumeRequest(sessionId: sessionId, lastRevision: 42)

        let data = try JSONEncoder().encode(resume)
        let decoded = try JSONDecoder().decode(ResumeRequest.self, from: data)

        XCTAssertEqual(decoded.type, RemoteVNCFrameType.resume)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.lastRevision, 42)
    }

    func testPanelStateEnvelopeRoundTripsPatch() throws {
        let sessionId = UUID()
        let patch = PanelStatePatch(
            revision: 2,
            baseRevision: 1,
            sessionId: sessionId,
            currentSessionId: NullableUUIDWrapper(nil),
            status: "idle"
        )
        let envelope = PanelStateEnvelope(patch: patch)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(PanelStateEnvelope.self, from: data)

        XCTAssertEqual(decoded.type, RemoteVNCFrameType.panelState)
        XCTAssertEqual(decoded.kind, .patch)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.patch?.baseRevision, 1)
        XCTAssertEqual(decoded.patch?.currentSessionId?.value, nil)
    }

    func testRecoveryMessagesRequestRoundTripsPagingFields() throws {
        let sessionId = UUID()
        let request = RemoteRecoveryRequest(op: .messages, sessionId: sessionId, limit: 120, before: 40, page: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(RemoteRecoveryRequest.self, from: data)

        XCTAssertEqual(decoded.type, RemoteVNCFrameType.recoveryRequest)
        XCTAssertEqual(decoded.op, .messages)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.limit, 120)
        XCTAssertEqual(decoded.before, 40)
        XCTAssertEqual(decoded.page, true)
    }

    func testRecoveryCatalogRoundTripsProjectsModelsAndSessions() throws {
        let requestId = UUID()
        let projectId = UUID()
        let sessionId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let response = RemoteRecoveryResponse.ok(
            requestId: requestId,
            projects: [
                PanelProjectDTO(
                    id: projectId,
                    name: "Demo",
                    path: "/tmp/demo",
                    defaultCLI: "claude",
                    createdAt: now,
                    updatedAt: now,
                    lastOpenedAt: now
                )
            ],
            models: [
                PanelModelDTO(id: "default", title: "默认", cli: "claude", isDefault: true)
            ],
            sessions: [
                PanelSessionDTO(
                    id: sessionId,
                    cli: "claude",
                    projectId: projectId,
                    projectName: "Demo",
                    projectPath: "/tmp/demo",
                    title: "对话",
                    modelID: "default",
                    runStatus: "idle",
                    statusText: "",
                    createdAt: now,
                    updatedAt: now,
                    lastCompletedAt: nil,
                    queuedCount: 0
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encodedRequest = try encoder.encode(RemoteRecoveryRequest(op: .catalog, projectId: projectId))
        let decodedRequest = try decoder.decode(RemoteRecoveryRequest.self, from: encodedRequest)
        let encodedResponse = try encoder.encode(response)
        let decodedResponse = try decoder.decode(RemoteRecoveryResponse.self, from: encodedResponse)

        XCTAssertEqual(decodedRequest.op, .catalog)
        XCTAssertEqual(decodedResponse.projects?.first?.id, projectId)
        XCTAssertEqual(decodedResponse.models?.first?.id, "default")
        XCTAssertEqual(decodedResponse.sessions?.first?.id, sessionId)
    }

    func testRecoveryProjectFilesRequestRoundTripsPath() throws {
        let projectId = UUID()
        let request = RemoteRecoveryRequest(op: .projectFiles, projectId: projectId, path: "Sources/App")

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RemoteRecoveryRequest.self, from: data)

        XCTAssertEqual(decoded.op, .projectFiles)
        XCTAssertEqual(decoded.projectId, projectId)
        XCTAssertEqual(decoded.path, "Sources/App")
    }

    func testRecoveryUploadAttachmentRoundTripsPayloadAndResponse() throws {
        let requestId = UUID()
        let request = RemoteRecoveryRequest(
            requestId: requestId,
            op: .uploadAttachment,
            filename: "note.txt",
            contentBase64: Data("hello".utf8).base64EncodedString()
        )
        let response = RemoteRecoveryResponse.ok(
            requestId: requestId,
            attachmentUpload: RemoteRecoveryAttachmentUploadDTO(filename: "note.txt", path: "/tmp/note.txt")
        )

        let encodedRequest = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(RemoteRecoveryRequest.self, from: encodedRequest)
        let encodedResponse = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(RemoteRecoveryResponse.self, from: encodedResponse)

        XCTAssertEqual(decodedRequest.op, .uploadAttachment)
        XCTAssertEqual(decodedRequest.filename, "note.txt")
        XCTAssertEqual(decodedRequest.contentBase64, Data("hello".utf8).base64EncodedString())
        XCTAssertEqual(decodedResponse.type, RemoteVNCFrameType.recoveryResponse)
        XCTAssertEqual(decodedResponse.requestId, requestId)
        XCTAssertEqual(decodedResponse.status, .ok)
        XCTAssertEqual(decodedResponse.attachmentUpload?.filename, "note.txt")
        XCTAssertEqual(decodedResponse.attachmentUpload?.path, "/tmp/note.txt")
    }

    func testRecoveryResponseRoundTripsSessionsMessagesAndFiles() throws {
        let requestId = UUID()
        let projectId = UUID()
        let sessionId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let message = ChatMessage(
            id: UUID(),
            sessionID: sessionId,
            kind: .assistant,
            title: "Assistant",
            subtitle: "",
            text: "恢复消息",
            status: "completed",
            createdAt: now
        )
        let response = RemoteRecoveryResponse.ok(
            requestId: requestId,
            sessions: [
                PanelSessionDTO(
                    id: sessionId,
                    cli: "claude",
                    projectId: projectId,
                    projectName: "Demo",
                    projectPath: "/tmp/demo",
                    title: "对话",
                    modelID: "sonnet",
                    runStatus: "idle",
                    statusText: "就绪",
                    createdAt: now,
                    updatedAt: now,
                    lastCompletedAt: now,
                    queuedCount: 0
                )
            ],
            messagePage: RemoteRecoveryMessagePageDTO(messages: [message], nextBeforeIndex: nil, hasMore: false, totalCount: 1),
            files: RemoteRecoveryProjectFilesDTO(
                projectId: projectId,
                path: "",
                parentPath: nil,
                entries: [RemoteRecoveryProjectFileEntryDTO(name: "README.md", relativePath: "README.md", isDirectory: false)]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(RemoteRecoveryResponse.self, from: data)

        XCTAssertEqual(decoded.sessions?.first?.id, sessionId)
        XCTAssertEqual(decoded.messagePage?.messages.first?.text, "恢复消息")
        XCTAssertEqual(decoded.messagePage?.totalCount, 1)
        XCTAssertEqual(decoded.files?.entries.first?.relativePath, "README.md")
    }
}
