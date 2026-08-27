import XCTest
@testable import LLMKit

final class TokenEstimatorTests: XCTestCase {

    func testChineseEstimation() {
        let text = "你好世界"  // 4 个汉字 ≈ 4 token
        XCTAssertEqual(LLMTokenEstimator.estimate(text), 4)
    }

    func testASCIIEstimation() {
        let text = "hello"  // 5 字符 ≈ 2 token (5/4 向上取整)
        XCTAssertEqual(LLMTokenEstimator.estimate(text), 2)
    }

    func testMixedEstimation() {
        let text = "你好 hello"
        XCTAssertEqual(LLMTokenEstimator.estimate(text), 2 + 2)  // 2 中文 + 6 字符/4
    }
}

final class ChatContextTokenBudgetTests: XCTestCase {

    func testTokenBudgetTrimsOldest() {
        var context = LLMChatContext(maxMessages: 50, maxTokens: 20)
        // 每条消息约 10 token（"问题内容内容内容" 7 字）
        for i in 1...4 {
            context.appendUser("问题\(i)内容内容内容内容")
        }
        let chat = context.chatMessages
        // 20 token 预算只能容纳约 2-3 条 → 最旧的被丢弃
        let total = chat.reduce(0) { $0 + LLMTokenEstimator.estimate($1.content ?? "") }
        XCTAssertLessThanOrEqual(total, 20)
        XCTAssertTrue(chat.count < 4, "应裁剪掉最早的消息")
        XCTAssertFalse((chat.first?.content ?? "").contains("问题1"), "最早的问题1应被丢弃")
    }

    func testSmallBudgetKeepsOnlyRecent() {
        var context = LLMChatContext(maxTokens: 5)
        context.appendUser("很长的历史消息内容内容内容")
        context.appendUser("新")
        let chat = context.chatMessages
        XCTAssertEqual(chat.count, 1)
        XCTAssertEqual(chat.first?.content, "新")
    }

    func testZeroBudgetNoTruncation() {
        var context = LLMChatContext(maxTokens: 0)
        context.appendUser("一条")
        context.appendUser("两条")
        XCTAssertEqual(context.chatMessages.count, 2)
    }
}

final class RetryConfigTests: XCTestCase {

    func testRetryableStatusCodes() {
        let config = LLMRetryConfig()
        XCTAssertTrue(config.isRetryable(LLMAPIError(statusCode: 429, message: "rate limit")))
        XCTAssertTrue(config.isRetryable(LLMAPIError(statusCode: 503, message: "busy")))
        XCTAssertFalse(config.isRetryable(LLMAPIError(statusCode: 400, message: "bad request")))
        XCTAssertFalse(config.isRetryable(LLMAPIError(statusCode: 401, message: "unauthorized")))
    }

    func testRetryableNetworkErrors() {
        let config = LLMRetryConfig()
        XCTAssertTrue(config.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(config.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(config.isRetryable(URLError(.cancelled)))
    }

    func testBackoffIncreases() {
        let config = LLMRetryConfig(baseDelayMs: 1000, maxDelayMs: 5000)
        let d0 = config.delay(forAttempt: 0)  // ~1s
        let d2 = config.delay(forAttempt: 2)  // ~4s
        XCTAssertGreaterThan(d2, d0)
        XCTAssertLessThanOrEqual(d2, 5.0)
    }
}

/// 模拟 500 → 200 的失败重试。
final class RetryNetworkTests: XCTestCase {

    func testRetryOnServerError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            let count = MockURLProtocol.requestCount
            MockURLProtocol.requestCount += 1
            if count == 0 {
                return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                        statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":{"message":"busy"}}"#.utf8))
            }
            let json = #"{ "choices": [ { "message": { "role": "assistant", "content": "重试成功" } } ] }"#
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test",
                                                 retryConfig: .init(maxRetries: 3, baseDelayMs: 1, maxDelayMs: 10)),
                                   session: URLSession(configuration: config))
        let reply = try await client.complete(messages: [.init(role: .user, content: "hi")])
        XCTAssertEqual(reply, "重试成功")
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "应恰好重试一次")
    }

    func testNoRetryOnClientError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.requestCount += 1
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"message":"bad"}}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test",
                                                 retryConfig: .init(maxRetries: 3, baseDelayMs: 1, maxDelayMs: 10)),
                                   session: URLSession(configuration: config))
        do {
            _ = try await client.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("应抛出错误")
        } catch let error as LLMAPIError {
            XCTAssertEqual(error.statusCode, 400)
        } catch {
            XCTFail("错误类型不对")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "客户端错误不应重试")
    }
}
