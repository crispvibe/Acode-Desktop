import XCTest
@testable import ChatCore

final class ChatMessageFilterTests: XCTestCase {
    func testHidesCodexProtocolNoiseMethods() {
        let titles = [
            "mcpServer/startupStatus/updated",
            "thread/status/changed",
            "remoteControl/status/changed",
            "account/rateLimits/updated",
            "thread/tokenUsage/updated",
            "session/configured",
            "session/connected",
            "stderr",
            "userInput",
            "user_message",
            "userMessage",
            "reasoning"
        ]

        for title in titles {
            XCTAssertTrue(
                ChatMessageFilter.shouldHideOperationalMessage(kind: .rawOutput, title: title, subtitle: "Codex", text: "{}"),
                "Expected \(title) to be hidden"
            )
        }
    }

    func testHidesProtocolNoiseByBody() {
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .rawOutput,
            title: "raw",
            subtitle: "Codex",
            text: #"{"type":"stderr","message":"debug"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .toolResult,
            title: "response",
            subtitle: "Codex",
            text: #"{"type":"user_message","text":"hi"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .toolResult,
            title: "response",
            subtitle: "Codex",
            text: #"{"type":"userMessage","text":"hi"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .rawOutput,
            title: "response",
            subtitle: "Codex",
            text: #"{"type":"reasoning","text":"internal"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .toolCall,
            title: "userMessage",
            subtitle: "Codex",
            text: #"{"text":"hidden"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .toolResult,
            title: "reasoning",
            subtitle: "Codex",
            text: #"{"text":"hidden"}"#
        ))
        XCTAssertTrue(ChatMessageFilter.shouldHideOperationalMessage(
            kind: .diff,
            title: "changes.diff",
            subtitle: "Codex",
            text: #"{"diff":"diff --git a/CodevokeIOS/Codevoke/Views/ChatView.swift b/CodevokeIOS/Codevoke/Views/ChatView.swift\n+test"}"#
        ))
    }

    func testCleansClaudeToolInventoryToEmptyText() {
        let text = """
        Mac tools:
        - read
        - grep: connected
        - terminal
        """

        XCTAssertEqual(ChatMessageFilter.cleanedAgentToolInventoryText(text), "")
        XCTAssertEqual(ChatMessageFilter.extractMacToolNames(from: text), ["read", "grep", "terminal"])
    }

    func testHidesCountedMacToolInventory() {
        let text = """
        Mac tools: 10 connected
        - chatgpt-web
        - mysql_mac
        - mysql_pay_anna_vin
        - mysql_photo
        - mysql_photo_new
        - mysql_sms
        - mysql_xy
        - skill-router
        - terminal
        - mysql_codevoke
        """

        XCTAssertTrue(ChatMessageFilter.looksLikeClaudeToolInventory(text))
        XCTAssertTrue(ChatMessageFilter.shouldHideAgentToolInventoryText(text))
        XCTAssertEqual(ChatMessageFilter.cleanedAgentToolInventoryText(text), "")
        XCTAssertEqual(ChatMessageFilter.extractMacToolNames(from: text), [
            "chatgpt-web",
            "mysql_mac",
            "mysql_pay_anna_vin",
            "mysql_photo",
            "mysql_photo_new",
            "mysql_sms",
            "mysql_xy",
            "skill-router",
            "terminal",
            "mysql_codevoke"
        ])
    }

    func testDoesNotTreatCodeAsToolInventory() {
        let text = """
        let task = Task.detached(priority: .userInitiated) {
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        """

        XCTAssertFalse(ChatMessageFilter.looksLikeClaudeToolInventory(text))
        XCTAssertEqual(ChatMessageFilter.extractMacToolNames(from: text), [])
    }

    func testDetectsProtocolBlob() {
        XCTAssertTrue(ChatMessageFilter.isProtocolBlob(#"{"type":"system","session_id":"abc","status":"requesting"}"#))
        XCTAssertTrue(ChatMessageFilter.isProtocolBlob(#"{"uuid":"abc","type":"system"}"#))
        XCTAssertFalse(ChatMessageFilter.isProtocolBlob("普通回复"))
    }

    func testUnifiedHideMessageHidesProtocolNoise() {
        XCTAssertTrue(ChatMessageFilter.shouldHideMessage(
            kind: .rawOutput,
            title: "thread/status/changed",
            subtitle: "Codex",
            text: #"{"status":"requesting","session_id":"abc"}"#
        ))
    }

    func testHidesModelCLIMismatchSystemNotice() {
        XCTAssertTrue(ChatMessageFilter.shouldHideMessage(
            kind: .system,
            title: "model",
            subtitle: "Codex",
            text: "模型与当前 CLI 不匹配，已改用当前 CLI 默认模型。"
        ))
    }

    func testUnifiedHideMessageKeepsRealToolCallsVisible() {
        XCTAssertFalse(ChatMessageFilter.shouldHideMessage(
            kind: .toolCall,
            title: "Read",
            subtitle: "tool",
            text: #"{"file_path":"/Users/oreo/Desktop/ClaudeMac/CodevokeIOS/Codevoke/Views/ChatView.swift"}"#
        ))
        XCTAssertFalse(ChatMessageFilter.shouldHideMessage(
            kind: .commandOutput,
            title: "xcodebuild",
            subtitle: "command",
            text: "** BUILD SUCCEEDED **"
        ))
    }
}
