import XCTest
@testable import ChatCore

final class ToolMessageGroupingTests: XCTestCase {
    func testGroupsToolRowsInsideAssistantTurn() {
        let user = ChatMessage(id: UUID(), kind: .user, text: "分析项目")
        let assistant = ChatMessage(id: UUID(), kind: .assistant, text: "我先看一下文件")
        let glob = ChatMessage(id: UUID(), kind: .toolCall, title: "Glob", text: "pattern: **/*")
        let result = ChatMessage(id: UUID(), kind: .toolResult, title: "Glob result", text: "README.md")

        let rows = ToolMessageGrouping.rows(for: [user, assistant, glob, result])

        XCTAssertEqual(rows.count, 3)
        guard case .toolGroup(let group) = rows[2] else {
            return XCTFail("Expected tool group")
        }
        XCTAssertEqual(group.turnID, assistant.id)
        XCTAssertEqual(group.messages.map(\.id), [glob.id, result.id])
        XCTAssertEqual(group.toolInvocationCount, 1)
    }

    func testAssistantTextStartsNewTurnForLaterTools() {
        let user = ChatMessage(id: UUID(), kind: .user, text: "先查")
        let firstTool = ChatMessage(id: UUID(), kind: .toolCall, title: "Glob", text: "pattern: **/*")
        let assistant = ChatMessage(id: UUID(), kind: .assistant, text: "再查一次")
        let secondTool = ChatMessage(id: UUID(), kind: .toolCall, title: "Grep", text: "pattern: TODO")

        let rows = ToolMessageGrouping.rows(for: [user, firstTool, assistant, secondTool])

        XCTAssertEqual(rows.count, 4)
        guard case .toolGroup(let firstGroup) = rows[1], case .toolGroup(let secondGroup) = rows[3] else {
            return XCTFail("Expected separated tool groups")
        }
        XCTAssertEqual(firstGroup.turnID, user.id)
        XCTAssertEqual(secondGroup.turnID, assistant.id)
    }

    func testNonToolOperationalRowsBreakContinuousToolGroups() {
        let user = ChatMessage(id: UUID(), kind: .user, text: "分析")
        let firstTool = ChatMessage(id: UUID(), kind: .toolCall, title: "Glob", text: "pattern: **/*")
        let reasoning = ChatMessage(id: UUID(), kind: .reasoning, text: "需要继续搜索")
        let secondTool = ChatMessage(id: UUID(), kind: .toolCall, title: "Read", text: "README.md")

        let rows = ToolMessageGrouping.rows(for: [user, firstTool, reasoning, secondTool])

        XCTAssertEqual(rows.count, 4)
        guard case .toolGroup(let firstGroup) = rows[1], case .message(let middle) = rows[2], case .toolGroup(let secondGroup) = rows[3] else {
            return XCTFail("Expected reasoning to split continuous tool groups")
        }
        XCTAssertEqual(middle.id, reasoning.id)
        XCTAssertEqual(firstGroup.messages.map(\.id), [firstTool.id])
        XCTAssertEqual(secondGroup.messages.map(\.id), [secondTool.id])
    }
}
