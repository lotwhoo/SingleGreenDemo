import XCTest
import LLMCore
@testable import AgentCore

final class LLMChatContextTests: XCTestCase {

    func testAppendAndTrim() {
        var context = LLMChatContext(systemPrompt: "你是助手", maxMessages: 3)
        context.appendUser("  你好  ")
        XCTAssertEqual(context.messages.count, 1)
        XCTAssertEqual(context.messages.first?.content, "你好")  // 去空白
        context.appendUser("  ")
        XCTAssertEqual(context.messages.count, 1)  // 空文本忽略
    }

    func testMaxMessagesTrimsOldest() {
        var context = LLMChatContext(maxMessages: 3)
        for i in 1...5 {
            context.appendUser("问题\(i)")
        }
        XCTAssertEqual(context.messages.count, 3)
        XCTAssertEqual(context.messages.first?.content, "问题3")
        XCTAssertEqual(context.messages.last?.content, "问题5")
    }

    func testChatMessagesIncludeSystemAndFilterEmpty() {
        var context = LLMChatContext(systemPrompt: "系统提示")
        context.appendUser("问题A")
        context.appendAssistant("")
        context.appendAssistant("回答B")
        let chat = context.chatMessages
        XCTAssertEqual(chat.count, 3)
        XCTAssertEqual(chat[0], LLMMessage(role: .system, content: "系统提示"))
        XCTAssertEqual(chat[1], LLMMessage(role: .user, content: "问题A"))
        XCTAssertEqual(chat[2], LLMMessage(role: .assistant, content: "回答B"))
    }

    func testClearKeepsSystemPrompt() {
        var context = LLMChatContext(systemPrompt: "提示")
        context.appendUser("问题")
        context.clear()
        XCTAssertTrue(context.messages.isEmpty)
        XCTAssertEqual(context.systemPrompt, "提示")
        XCTAssertEqual(context.chatMessages.count, 1)  // 只剩 system
    }
}
