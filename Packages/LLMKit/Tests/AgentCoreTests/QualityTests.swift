import XCTest
import LLMCore
@testable import AgentCore

final class TokenEstimatorTests: XCTestCase {
    func testChineseEstimation() {
        XCTAssertEqual(LLMTokenEstimator.estimate("你好世界"), 4)
    }

    func testASCIIEstimation() {
        XCTAssertEqual(LLMTokenEstimator.estimate("hello"), 2)
    }

    func testMixedEstimation() {
        XCTAssertEqual(LLMTokenEstimator.estimate("你好 hello"), 2 + 2)
    }
}

final class ChatContextTokenBudgetTests: XCTestCase {
    func testTokenBudgetTrimsOldest() {
        var context = LLMChatContext(maxMessages: 50, maxTokens: 20)
        for i in 1...4 {
            context.appendUser("问题\(i)内容内容内容内容")
        }
        let chat = context.chatMessages
        let total = chat.reduce(0) { $0 + LLMTokenEstimator.estimate($1.content ?? "") }
        XCTAssertLessThanOrEqual(total, 20)
        XCTAssertTrue(chat.count < 4, "应裁剪掉最早的消息")
        XCTAssertFalse((chat.first?.content ?? "").contains("问题1"), "最早的问题1应被丢弃")
    }

    func testSmallBudgetKeepsOnlyRecent() {
        var context = LLMChatContext(maxTokens: 5)
        context.appendUser("很长的历史消息内容内容内容")
        context.appendUser("新")
        XCTAssertEqual(context.chatMessages.map(\.content), ["新"])
    }

    func testZeroBudgetNoTruncation() {
        var context = LLMChatContext(maxTokens: 0)
        context.appendUser("一条")
        context.appendUser("两条")
        XCTAssertEqual(context.chatMessages.count, 2)
    }

    func testToolReasoningCountsTowardContextBudget() {
        var context = LLMChatContext(maxMessages: 20, maxTokens: 6)
        context.appendAssistant("旧", reasoningContent: "需要很多推理内容")
        context.appendUser("新")
        XCTAssertEqual(context.chatMessages.map(\.content), ["新"])
    }
}
