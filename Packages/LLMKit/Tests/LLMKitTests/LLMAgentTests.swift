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

    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
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
        let agent = LLMAgent(transport: client, executor: executor,
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
        let agent = LLMAgent(transport: client, executor: executor, config: .init())

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
        let agent = LLMAgent(transport: client, executor: NoopToolExecutor(), config: .init())

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
        let agent = LLMAgent(transport: client, executor: FailingToolExecutor(), config: .init())

        await XCTAssertThrowsErrorAsync(try await agent.send("搜索"))
        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testAgentRejectsIncompleteOrMalformedToolCallsBeforeExecution() async {
        let cases: [(LLMToolCall, LLMAgentError)] = [
            (.init(id: "", type: "function", function: .init(name: "web_search", arguments: "{}")),
             .incompleteToolCall(index: 0)),
            (.init(id: "call", type: "function", function: .init(name: " \n", arguments: "{}")),
             .incompleteToolCall(index: 0)),
            (.init(id: "call", type: "function", function: .init(name: "web_search", arguments: "")),
             .incompleteToolCall(index: 0)),
            (.init(id: "call", type: "function", function: .init(name: "web_search", arguments: " \t")),
             .incompleteToolCall(index: 0)),
            (.init(id: "call", type: "function", function: .init(name: "web_search", arguments: #"{"query":"北京""#)),
             .malformedToolCallArguments(index: 0)),
            (.init(id: "call", type: "function", function: .init(name: "web_search", arguments: #"{"query":}"#)),
             .malformedToolCallArguments(index: 0))
        ]

        for (call, expectedError) in cases {
            let executor = MockToolExecutor()
            let agent = LLMAgent(
                transport: FixedToolMessageTransport(
                    message: .init(role: .assistant, content: nil, toolCalls: [call])
                ),
                executor: executor,
                config: .init()
            )

            do {
                _ = try await agent.send("run")
                XCTFail("invalid tool call must fail")
            } catch let error as LLMAgentError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(executor.callCount, 0, "validation must precede execution")
            let messages = await agent.chatMessages
            XCTAssertTrue(messages.isEmpty, "invalid tool calls must roll back context")
        }
    }

    func testAgentValidatesEveryToolCallBeforeExecutingAnyCall() async {
        let valid = LLMToolCall(
            id: "valid",
            type: "function",
            function: .init(name: "web_search", arguments: "{}")
        )
        let invalid = LLMToolCall(
            id: "invalid",
            type: "function",
            function: .init(name: "web_search", arguments: "{")
        )
        let executor = MockToolExecutor()
        let agent = LLMAgent(
            transport: FixedToolMessageTransport(
                message: .init(role: .assistant, content: nil, toolCalls: [valid, invalid])
            ),
            executor: executor,
            config: .init()
        )

        do {
            _ = try await agent.send("run")
            XCTFail("malformed second call must reject the whole round")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .malformedToolCallArguments(index: 1))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(executor.callCount, 0)
    }

    func testAgentDiscardsUnpublishedToolPreambleBeforeExecution() async throws {
        let session = makeSession { round in
            let json = round == 0
                ? #"{"choices":[{"message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call","type":"function","function":{"name":"web_search","arguments":"{}"}}]}}]}"#
                : #"{"choices":[{"message":{"role":"assistant","content":"final"}}]}"#
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let agent = LLMAgent(
            transport: LLMChatClient(config: .init(apiKey: "sk-test"), session: session),
            executor: executor,
            config: .init()
        )

        let answer = try await agent.send("run")
        XCTAssertEqual(answer, "final")
        XCTAssertEqual(executor.callCount, 1)
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["run", "final"])
        XCTAssertFalse(messages.contains { $0.content == "Let me check." })
    }

    func testStreamingSameDeltaToolPreambleIsNotPublishedAndToolExecutes() async throws {
        let session = makeSession { round in
            let sse = round == 0
                ? """
                  data: {"choices":[{"index":0,"delta":{"content":"Let me check.","tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"web_search","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

                  data: [DONE]

                  """
                : """
                  data: {"choices":[{"index":0,"delta":{"content":"final"},"finish_reason":"stop"}]}

                  data: [DONE]

                  """
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let agent = LLMAgent(
            transport: LLMChatClient(config: .init(apiKey: "sk-test"), session: session),
            executor: executor,
            config: .init()
        )

        var events: [LLMAgentEvent] = []
        let transaction = await agent.sendStreaming("run")
        for try await event in transaction { events.append(event) }
        try await agent.commit(transaction.token)

        XCTAssertEqual(events, [
            .toolCall("web_search"),
            .contentDelta("final"),
            .completed("final")
        ])
        XCTAssertEqual(executor.callCount, 1)
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["run", "final"])
        XCTAssertFalse(events.contains(.contentDelta("Let me check.")))
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
        let agent = LLMAgent(transport: client, executor: NoopToolExecutor(),
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
        let agent = LLMAgent(transport: client, executor: executor,
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

    func testStreamingAgentExecutesToolThenPublishesFinalAnswerDeltas() async throws {
        let session = makeSession { round in
            let sse: String
            if round == 0 {
                sse = """
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\"北京天气\\"}"}}]}}]}

                data: [DONE]

                """
            } else {
                sse = """
                data: {"choices":[{"delta":{"content":"北京今天"}}]}

                data: {"choices":[{"delta":{"content":"晴朗。"}}]}

                data: [DONE]

                """
            }
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: executor, config: .init())

        var events: [LLMAgentEvent] = []
        let stream = await agent.sendStreaming("北京天气")
        for try await event in stream { events.append(event) }
        try await agent.commit(stream.token)

        XCTAssertEqual(events, [
            .toolCall("web_search"),
            .contentDelta("北京今天"),
            .contentDelta("晴朗。"),
            .completed("北京今天晴朗。")
        ])
        XCTAssertEqual(executor.callCount, 1)
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.last?.content, "北京今天晴朗。")
    }

    func testThinkingToolRoundReplaysReasoningAndNonNullContentInSecondRequest() async throws {
        var requestBodies: [[String: Any]] = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let data = try XCTUnwrap(self.requestBodyData(request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            requestBodies.append(body)
            let sse: String
            if requestBodies.count == 1 {
                sse = """
                data: {"choices":[{"index":0,"delta":{"reasoning_content":"need "}}]}

                data: {"choices":[{"index":0,"delta":{"reasoning_content":"search"}}]}

                data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """
            } else {
                sse = """
                data: {"choices":[{"index":0,"delta":{"reasoning_content":"use result"}}]}

                data: {"choices":[{"index":0,"delta":{"content":"final answer"},"finish_reason":"stop"}]}

                data: [DONE]

                """
            }
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(
            config: .init(apiKey: "sk-test", thinking: .enabled(effort: .high)),
            session: URLSession(configuration: config)
        )
        let agent = LLMAgent(
            transport: client,
            executor: MockToolExecutor(),
            config: .init(temperature: 0.7)
        )

        var events: [LLMAgentEvent] = []
        let transaction = await agent.sendStreaming("search")
        for try await event in transaction { events.append(event) }
        try await agent.commit(transaction.token)

        XCTAssertEqual(events, [
            .toolCall("web_search"),
            .contentDelta("final answer"),
            .completed("final answer")
        ])
        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertNil(requestBodies[0]["temperature"])
        XCTAssertNil(requestBodies[1]["temperature"])
        for body in requestBodies {
            XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "enabled")
            XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        }

        let secondMessages = try XCTUnwrap(requestBodies[1]["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(secondMessages.first { ($0["role"] as? String) == "assistant" })
        XCTAssertEqual(assistant["content"] as? String, "")
        XCTAssertEqual(assistant["reasoning_content"] as? String, "need search")
        XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.count, 1)

        let durableMessages = await agent.chatMessages
        XCTAssertEqual(durableMessages.map(\.content), ["search", "final answer"])
        XCTAssertTrue(durableMessages.allSatisfy { $0.reasoningContent == nil })

        let secondTransaction = await agent.sendStreaming("follow up")
        for try await _ in secondTransaction {}
        try await agent.commit(secondTransaction.token)
        XCTAssertEqual(requestBodies.count, 3)
        let thirdMessages = try XCTUnwrap(requestBodies[2]["messages"] as? [[String: Any]])
        let priorAssistant = try XCTUnwrap(thirdMessages.first {
            ($0["role"] as? String) == "assistant" && ($0["content"] as? String) == "final answer"
        })
        XCTAssertEqual(priorAssistant["reasoning_content"] as? String, "use result")
    }

    func testFinalReasoningDoesNotEnterDurableContextWhenToolsAreDisabled() async throws {
        let agent = LLMAgent(
            transport: FixedToolMessageTransport(
                message: .init(
                    role: .assistant,
                    content: "visible answer",
                    reasoningContent: "private reasoning"
                )
            ),
            executor: NoopToolExecutor(),
            config: .init()
        )

        var events: [LLMAgentEvent] = []
        let transaction = await agent.sendStreaming("question")
        for try await event in transaction { events.append(event) }
        try await agent.commit(transaction.token)

        XCTAssertEqual(events, [.completed("visible answer")])
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["question", "visible answer"])
        XCTAssertTrue(messages.allSatisfy { $0.reasoningContent == nil })
    }

    func testStreamingMixedContentAndToolCallFailsAndRollsBackContext() async {
        let session = makeSession { _ in
            let sse = """
            data: {"choices":[{"delta":{"content":"不应提交"}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{}"}}]}}]}

            data: [DONE]

            """
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = MockToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: executor, config: .init())
        var receivedError: Error?
        var events: [LLMAgentEvent] = []

        let stream = await agent.sendStreaming("混合输出")
        do {
            for try await event in stream { events.append(event) }
        } catch {
            receivedError = error
        }

        XCTAssertEqual(receivedError as? LLMAgentStreamError, .discardPartialMixedContentAndToolCall)
        XCTAssertEqual(events, [.contentDelta("不应提交")])
        XCTAssertFalse(events.contains { if case .completed = $0 { return true }; return false })
        XCTAssertEqual(executor.callCount, 0)
        let messagesAfterMixedOutput = await agent.chatMessages
        XCTAssertTrue(messagesAfterMixedOutput.isEmpty, "混合输出失败不应污染 Agent 上下文")
    }

    func testStreamingTransportFailureAfterPartialDeltaRollsBackContext() async {
        let session = makeSession { _ in
            let sse = """
            data: {"choices":[{"delta":{"content":"部分"}}]}

            data: {not-json}

            """
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: NoopToolExecutor(), config: .init())
        var events: [LLMAgentEvent] = []

        do {
            let stream = await agent.sendStreaming("会失败的问题")
            for try await event in stream { events.append(event) }
            XCTFail("损坏的 SSE 应失败")
        } catch {}

        XCTAssertEqual(events, [.contentDelta("部分")])
        let messagesAfterFailure = await agent.chatMessages
        XCTAssertTrue(messagesAfterFailure.isEmpty, "部分流失败不应提交孤立用户消息")
    }

    func testClearContextInvalidatesSuspendedStreamingTransaction() async {
        let session = makeSession { _ in
            let sse = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{}"}}]}}]}

            data: [DONE]

            """
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sse.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = SuspendedToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: executor, config: .init())
        let stream = await agent.sendStreaming("将被清空")
        let consumption = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        for _ in 0..<500 {
            if executor.isWaiting { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(executor.isWaiting)
        await agent.clearContext()
        executor.complete(with: "迟到的工具结果")

        let error = await consumption.value
        XCTAssertTrue(error is CancellationError)
        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty, "clearContext 后旧事务不得提交或回滚旧快照")
    }

    func testNewSendInvalidatesSuspendedStreamingTransactionAndKeepsNewContext() async throws {
        let session = makeSession { round in
            let body: String
            if round == 0 {
                body = """
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{}"}}]}}]}

                data: [DONE]

                """
            } else {
                body = #"{ "choices": [ { "message": { "role": "assistant", "content": "新回答" } } ] }"#
            }
            return (
                HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let executor = SuspendedToolExecutor()
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: executor, config: .init())
        let oldStream = await agent.sendStreaming("旧问题")
        let oldConsumption = Task { () -> Error? in
            do {
                for try await _ in oldStream {}
                return nil
            } catch {
                return error
            }
        }

        for _ in 0..<500 {
            if executor.isWaiting { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(executor.isWaiting)

        let newAnswer = try await agent.send("新问题")
        executor.complete(with: "迟到的工具结果")

        XCTAssertEqual(newAnswer, "新回答")
        let oldError = await oldConsumption.value
        XCTAssertTrue(oldError is CancellationError)
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["新问题", "新回答"])
    }

    func testCancellingConsumerAfterPartialPreventsLateStreamingCommit() async {
        let server = ControlledSSEServer()
        ControlledStreamingURLProtocol.server = server
        defer { ControlledStreamingURLProtocol.server = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledStreamingURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: session)
        let agent = LLMAgent(transport: client, executor: NoopToolExecutor(), config: .init())
        let partialReceived = LockedFlag()
        let stream = await agent.sendStreaming("取消中的问题")
        let consumption = Task { () -> Error? in
            do {
                for try await event in stream {
                    if event == .contentDelta("部分回答") {
                        partialReceived.set()
                    }
                }
                return nil
            } catch {
                return error
            }
        }

        for _ in 0..<500 {
            if partialReceived.value { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(partialReceived.value)

        consumption.cancel()
        for _ in 0..<500 {
            if server.wasStopped { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(server.wasStopped, "消费者取消必须先传播到流式传输任务")
        server.complete()
        _ = await consumption.value
        try? await Task.sleep(for: .milliseconds(10))

        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty, "消费者取消后，上游迟到完成不得提交对话上下文")
    }

    func testAgentDependsOnTransportProtocolInsteadOfConcreteHTTPClient() async throws {
        let transport = StubChatTransport(answer: "可替换传输回答")
        let agent = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )

        var events: [LLMAgentEvent] = []
        let stream = await agent.sendStreaming("协议化测试")
        for try await event in stream { events.append(event) }
        try await agent.commit(stream.token)

        XCTAssertEqual(events, [
            .contentDelta("可替换传输回答"),
            .completed("可替换传输回答")
        ])
        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["协议化测试", "可替换传输回答"])
    }

    func testFinalizedStreamingResponseRemainsPendingUntilCommitted() async throws {
        let transport = StubChatTransport(answer: "已完成")
        let agent = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let transaction = await agent.sendStreaming("待确认")

        var events: [LLMAgentEvent] = []
        for try await event in transaction { events.append(event) }

        XCTAssertEqual(events.last, .completed("已完成"))
        var messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty, "buffered completion must not commit context")

        try await agent.commit(transaction.token)
        messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["待确认", "已完成"])
    }

    func testFinalizedStreamingResponseCanBeAbortedWithoutCommitting() async throws {
        let transport = StubChatTransport(answer: "上游已完成")
        let agent = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let transaction = await agent.sendStreaming("将被取消")

        for try await _ in transaction {}
        await agent.abort(transaction.token)

        let messages = await agent.chatMessages
        XCTAssertTrue(messages.isEmpty, "aborting after upstream finalization must discard staged context")
    }

    func testAbortAfterCommitRollsBackOnlyThatStreamingTransaction() async throws {
        let transport = StubChatTransport(answer: "accepted")
        let agent = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let accepted = await agent.sendStreaming("preserved")
        for try await _ in accepted {}
        try await agent.commit(accepted.token)

        let transaction = await agent.sendStreaming("tentative")
        for try await _ in transaction {}

        try await agent.commit(transaction.token)
        await agent.abort(transaction.token)
        await agent.abort(transaction.token)

        let messages = await agent.chatMessages
        XCTAssertEqual(
            messages.map(\.content),
            ["preserved", "accepted"],
            "rollback must be token-scoped and idempotent"
        )
    }

    func testNewTransactionMakesStaleStreamingCommitHarmless() async throws {
        let transport = SequencedChatTransport(streamingAnswer: "旧回答", directAnswer: "新回答")
        let agent = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let oldTransaction = await agent.sendStreaming("旧问题")
        for try await _ in oldTransaction {}

        let newAnswer = try await agent.send("新问题")
        XCTAssertEqual(newAnswer, "新回答")

        do {
            try await agent.commit(oldTransaction.token)
            XCTFail("stale transaction must not commit")
        } catch let error as LLMAgentTransactionError {
            XCTAssertEqual(error, .notPending)
        }

        let messages = await agent.chatMessages
        XCTAssertEqual(messages.map(\.content), ["新问题", "新回答"])
    }
}

private struct StubChatTransport: LLMChatTransport {
    let answer: String

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        LLMMessage(role: .assistant, content: answer)
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(answer))
            continuation.yield(.completed(.init(role: .assistant, content: answer)))
            continuation.finish()
        }
    }
}

private struct FixedToolMessageTransport: LLMChatTransport {
    let message: LLMMessage

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        message
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(message))
            continuation.finish()
        }
    }
}

private struct SequencedChatTransport: LLMChatTransport {
    let streamingAnswer: String
    let directAnswer: String

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        LLMMessage(role: .assistant, content: directAnswer)
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(streamingAnswer))
            continuation.yield(.completed(.init(role: .assistant, content: streamingAnswer)))
            continuation.finish()
        }
    }
}

private final class SuspendedToolExecutor: LLMToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: "web_search", description: "搜索", parameters: [:]))]
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func complete(with result: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() {
        lock.withLock { storage = true }
    }
}

private final class ControlledSSEServer: @unchecked Sendable {
    private let lock = NSLock()
    private weak var protocolInstance: ControlledStreamingURLProtocol?
    private var stopped = false

    var wasStopped: Bool { lock.withLock { stopped } }

    func attach(_ protocolInstance: ControlledStreamingURLProtocol) {
        lock.withLock { self.protocolInstance = protocolInstance }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }

    func complete() {
        let protocolInstance = lock.withLock { self.protocolInstance }
        protocolInstance?.completeResponse()
    }
}

private final class ControlledStreamingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var server: ControlledSSEServer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server else {
            XCTFail("未设置 ControlledSSEServer")
            return
        }
        server.attach(self)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"部分回答\"}}]}\n\n".utf8)
        )
    }

    override func stopLoading() {
        Self.server?.markStopped()
    }

    func completeResponse() {
        client?.urlProtocol(
            self,
            didLoad: Data("data: {\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{}}]}\n\n".utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
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
