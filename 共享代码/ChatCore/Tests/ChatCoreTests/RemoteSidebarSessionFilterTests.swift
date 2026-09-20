import XCTest
@testable import ChatCore

final class RemoteSidebarSessionFilterTests: XCTestCase {
    func testSidebarSessionsFollowFallbackSelectedProject() {
        let projectIDs = [
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        ]
        let sessionIDs = [
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000006")!
        ]
        let sessions = projectIDs.enumerated().flatMap { projectIndex, projectID in
            (0..<2).map { sessionIndex in
                makeSession(
                    id: sessionIDs[projectIndex * 2 + sessionIndex],
                    projectId: projectID,
                    title: "P\(projectIndex + 1)-S\(sessionIndex + 1)"
                )
            }
        }
        let snapshot = makeSnapshot(sessions: sessions, currentSessionId: sessions[2].id)
        let fallbackSelectedProjectId = snapshot.sessions.first { $0.id == snapshot.currentSessionId }?.projectId

        let filtered = PanelSessionFilters.sessions(snapshot.sessions, forSelectedProjectId: fallbackSelectedProjectId)

        XCTAssertEqual(filtered.map(\.id), [sessions[2].id, sessions[3].id])
    }

    private func makeSnapshot(sessions: [PanelSessionDTO], currentSessionId: UUID?) -> PanelStateSnapshot {
        PanelStateSnapshot(
            revision: 1,
            sessionId: currentSessionId,
            projects: [],
            models: [],
            sessions: sessions,
            currentSessionId: currentSessionId,
            messages: [],
            queuedRequests: [],
            streamingTexts: [],
            status: "idle",
            statusText: "",
            isAwaitingFirstModelOutput: false,
            isLoadingHistory: false,
            tokensUsed: 0,
            tokensTotal: 0,
            activeRunStartedAt: nil,
            isMirroringRemoteSession: false,
            composer: PanelComposerDTO(
                text: "",
                cli: "claude",
                modelID: "default",
                contextModelID: nil,
                permissionMode: "autoEdit",
                reasoningEffort: "high",
                attachments: [],
                isEnabled: true,
                placeholder: ""
            ),
            capabilities: []
        )
    }

    private func makeSession(id: UUID, projectId: UUID, title: String) -> PanelSessionDTO {
        PanelSessionDTO(
            id: id,
            cli: "claude",
            projectId: projectId,
            projectName: title,
            projectPath: "/tmp/\(title)",
            title: title,
            modelID: "default",
            runStatus: "idle",
            statusText: "",
            createdAt: .distantPast,
            updatedAt: .distantPast,
            lastCompletedAt: nil,
            queuedCount: 0
        )
    }
}
