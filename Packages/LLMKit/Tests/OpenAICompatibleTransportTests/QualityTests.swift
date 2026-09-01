import XCTest
import LLMCore
@testable import OpenAICompatibleTransport

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

    func testHTTP401BeforeContentDoesNotRetry() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.requestCount += 1
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"message":"unauthorized"}}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test",
                                                 retryConfig: .init(maxRetries: 3, baseDelayMs: 1, maxDelayMs: 10)),
                                   session: URLSession(configuration: config))
        do {
            _ = try await client.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("应抛出错误")
        } catch let error as LLMAPIError {
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("错误类型不对")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "401 before content must not retry")
    }
}
