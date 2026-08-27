import XCTest
@testable import LLMKit

/// 记录调用次数的工具执行器。
final class MockToolExecutor: LLMToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var callCount: Int {
        lock.withLock { _calls.count }
    }
    var queries: [String] {
        lock.withLock { _calls }
    }

    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: "web_search", description: "搜索", parameters: [:]))]
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        lock.withLock { _calls.append(call.function.arguments) }
        return "搜索结果：北京今天晴，25 度"
    }
}

private struct FailingToolExecutor: LLMToolExecutor {
    enum Failure: Error { case expected }

    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: "web_search", description: "搜索", parameters: [:]))]
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        throw Failure.expected
    }
}

final class LLMAgentTests: XCTestCase {

    private func makeSession(handler: @escaping (Int) -> (HTTPURLResponse, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            let round = MockURLProtocol.requestCount
            MockURLProtocol.requestCount += 1
            return handler(round)
        }
        return URLSession(configuration: config)
    }

    /// 第一轮：模型请求 web_search；第二轮：给出最终回答。
    func testAgentExecutesToolLoop() async throws {
        let session = makeSession { round in
            if round == 0 {
                let json = """
                { "choices": [ { "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [ { "id": "call_1", "type": "function",
                      "function": { "name": "web_search", "arguments": "{\\"query\\":\\"北京天气\\"}" } } ]
                } } ] }
                """
                return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(json.utf8))
            }
            let json = """
            { "choices": [ { "message": { "role": "assistant", "content": "北京今天晴，25 度。出门记得防晒。" } } ] }
            """
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: executor,
                             config: .init(systemPrompt: "你是助手"))

        let answer = try await agent.send("今天北京天气怎么样？")
        XCTAssertEqual(answer, "北京今天晴，25 度。出门记得防晒。")
        XCTAssertEqual(executor.callCount, 1, "应恰好执行一次搜索")
        XCTAssertEqual(executor.queries.first, #"{"query":"北京天气"}"#)
    }

    /// 无工具调用时直接返回回答，不触发执行器。
    func testAgentNoToolWhenNotNeeded() async throws {
        let session = makeSession { _ in
            let json = """
            { "choices": [ { "message": { "role": "assistant", "content": "你好！" } } ] }
            """
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: executor, config: .init())

        let answer = try await agent.send("你好")
        XCTAssertEqual(answer, "你好！")
        XCTAssertEqual(executor.callCount, 0)
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["你好", "你好！"])
    }

    func testEmptyAnswerRollsBackContext() async {
        let session = makeSession { _ in
            let json = #"{ "choices": [ { "message": { "role": "assistant", "content": "   \n" } } ] }"#
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: NoopToolExecutor(), config: .init())

        do {
            _ = try await agent.send("不会保留的问题")
            XCTFail("空回答应抛错")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testToolFailureRollsBackContext() async {
        let session = makeSession { _ in
            let json = """
            { "choices": [ { "message": { "role": "assistant", "content": null,
              "tool_calls": [ { "id": "c", "type": "function",
                "function": { "name": "web_search", "arguments": "{}" } } ] } } ] }
            """
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: FailingToolExecutor(), config: .init())

        await XCTAssertThrowsErrorAsync(try await agent.send("搜索"))
        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testClearContextRemovesSuccessfulConversation() async throws {
        let session = makeSession { _ in
            let json = #"{ "choices": [ { "message": { "role": "assistant", "content": "回答" } } ] }"#
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: NoopToolExecutor(),
                             config: .init(systemPrompt: "系统"))

        _ = try await agent.send("问题")
        await agent.clearContext()

        let messages = await agent.chatMessages
        XCTAssertEqual(messages, [.init(role: .system, content: "系统")])
    }

    /// 超过工具轮数上限应抛错。
    func testAgentTooManyToolRounds() async throws {
        let session = makeSession { _ in
            let json = """
            { "choices": [ { "message": { "role": "assistant", "content": null,
              "tool_calls": [ { "id": "c", "type": "function",
                "function": { "name": "web_search", "arguments": "{}" } } ] } } ] }
            """
            return (HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(client: client, executor: executor,
                             config: .init(maxToolRounds: 2))

        do {
            _ = try await agent.send("搜索")
            XCTFail("应抛出 tooManyToolRounds")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .tooManyToolRounds)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }

        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty, "失败的一轮不应污染后续多轮上下文")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("应抛出错误", file: file, line: line)
    } catch {}
}
