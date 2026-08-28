import XCTest
@testable import LLMKit

/// URLProtocol 桩：拦截 URLSession 请求并返回预设响应。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            XCTFail("未设置 requestHandler")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LLMChatClientNetworkTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testRequestHeadersAndBody() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = """
            { "id": "x", "choices": [ { "message": { "role": "assistant", "content": "你好！" } } ] }
            """
            return (self.httpResponse(200), Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test-123"),
                                   session: makeSession())
        let reply = try await client.complete(
            messages: [.init(role: .user, content: "你好")],
            maxTokens: 256
        )
        XCTAssertEqual(reply, "你好！")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(Self.requestBodyData(request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
    }

    /// URLProtocol 拦截时 httpBody 可能已被转成 httpBodyStream，需要两者都处理。
    private static func requestBodyData(_ request: URLRequest) -> Data? {
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

    func testErrorResponseThrowsWithMessage() async {
        MockURLProtocol.requestHandler = { _ in
            let json = """
            { "error": { "message": "Insufficient Balance", "type": "invalid_request_error" } }
            """
            return (self.httpResponse(402), Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"),
                                   session: makeSession())
        do {
            _ = try await client.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("应抛出错误")
        } catch let error as LLMAPIError {
            XCTAssertEqual(error.statusCode, 402)
            XCTAssertTrue(error.message.contains("Insufficient Balance"))
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testEmptyContentThrows() async {
        MockURLProtocol.requestHandler = { _ in
            let json = #"{ "id": "x", "choices": [ { "message": { "role": "assistant", "content": "" } } ] }"#
            return (self.httpResponse(200), Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"),
                                   session: makeSession())
        do {
            _ = try await client.complete(messages: [.init(role: .user, content: "hi")])
            XCTFail("应抛出错误")
        } catch let error as LLMAPIError {
            XCTAssertEqual(error.statusCode, 200)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testStreamingParsesSSEIncrementally() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let sse = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: {"choices":[{"delta":{"content":"！"}}]}

            data: [DONE]

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"),
                                   session: makeSession())

        var deltas: [String] = []
        var collected = ""
        for try await delta in client.completeStreaming(messages: [.init(role: .user, content: "hi")]) {
            deltas.append(delta)
            collected += delta
        }
        XCTAssertEqual(deltas, ["你", "好", "！"])
        XCTAssertEqual(collected, "你好！")

        let body = try XCTUnwrap(Self.requestBodyData(try XCTUnwrap(captured)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testStreamingWithErrorStatus() async {
        MockURLProtocol.requestHandler = { _ in
            (self.httpResponse(500), Data(#"{"error":{"message":"boom"}}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"),
                                   session: makeSession())
        do {
            for try await _ in client.completeStreaming(messages: [.init(role: .user, content: "hi")]) {}
            XCTFail("应抛出错误")
        } catch let error as LLMAPIError {
            XCTAssertEqual(error.statusCode, 500)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMessageStreamingAssemblesContentAndToolCallFragments() async throws {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\":\\""}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"北京天气\\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        var events: [LLMStreamingEvent] = []
        for try await event in client.completeMessageStreaming(
            messages: [.init(role: .user, content: "搜索")],
            tools: [LLMTool(function: .init(name: "web_search", description: "搜索", parameters: [:]))]
        ) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 3)
        guard case .completed(let message) = events.last else {
            return XCTFail("应发布完整消息")
        }
        XCTAssertNil(message.content)
        XCTAssertEqual(message.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(message.toolCalls?.first?.function.name, "web_search")
        XCTAssertEqual(message.toolCalls?.first?.function.arguments, #"{"query":"北京天气"}"#)
    }

    func testMessageStreamingAssemblesInterleavedToolCallsByIndex() async throws {
        MockURLProtocol.requestHandler = { _ in
            let sse = #"""
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_1","type":"function","function":{"name":"second","arguments":"{\"value\":\""}},{"index":0,"id":"call_0","type":"function","function":{"name":"first","arguments":"{\"value\":\""}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"zero\"}"}},{"index":1,"function":{"arguments":"one\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """#
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        var completedMessage: LLMMessage?
        for try await event in client.completeMessageStreaming(messages: [.init(role: .user, content: "run")]) {
            if case .completed(let message) = event { completedMessage = message }
        }

        let calls = try XCTUnwrap(completedMessage?.toolCalls)
        XCTAssertEqual(calls.map(\.id), ["call_0", "call_1"])
        XCTAssertEqual(calls.map(\.function.arguments), [#"{"value":"zero"}"#, #"{"value":"one"}"#])
    }

    func testMessageStreamingPublishesContentFragmentsAndCompletedMessage() async throws {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":0,"delta":{"content":"你好"}}]}

            data: {"choices":[{"index":0,"delta":{"content":"👋"},"finish_reason":"stop"}]}

            data: [DONE]

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        var events: [LLMStreamingEvent] = []
        for try await event in client.completeMessageStreaming(
            messages: [.init(role: .user, content: "hi")]
        ) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .contentDelta("你好"),
            .contentDelta("👋"),
            .completed(.init(role: .assistant, content: "你好👋"))
        ])
    }

    func testMessageStreamingRejectsIncompleteToolCall() async {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":2,"function":{"arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        do {
            for try await _ in client.completeMessageStreaming(
                messages: [.init(role: .user, content: "搜索")]
            ) {}
            XCTFail("不完整工具调用应失败")
        } catch let error as LLMStreamingError {
            XCTAssertEqual(error, .incompleteToolCall(index: 2))
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMessageStreamingRejectsWhitespaceOnlyToolCallArguments() async {
        MockURLProtocol.requestHandler = { _ in
            let sse = #"""
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":3,"id":"call_3","type":"function","function":{"name":"web_search","arguments":"  \n\t"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """#
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        do {
            for try await _ in client.completeMessageStreaming(messages: [.init(role: .user, content: "搜索")]) {}
            XCTFail("空白工具参数应失败")
        } catch let error as LLMStreamingError {
            XCTAssertEqual(error, .incompleteToolCall(index: 3))
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMessageStreamingRejectsTruncatedToolCallArgumentsAfterAssembly() async {
        MockURLProtocol.requestHandler = { _ in
            let sse = #"""
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":4,"id":"call_4","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"北京"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """#
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        do {
            for try await _ in client.completeMessageStreaming(messages: [.init(role: .user, content: "搜索")]) {}
            XCTFail("截断工具参数应失败")
        } catch let error as LLMStreamingError {
            XCTAssertEqual(error, .malformedToolCallArguments(index: 4))
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMessageStreamingUsesOnlyFirstObservedChoice() async throws {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":1,"delta":{"content":"目标"}},{"index":0,"delta":{"content":"其他"}}]}

            data: {"choices":[{"index":0,"delta":{"content":"干扰"},"finish_reason":"stop"},{"index":1,"delta":{"content":"回答"},"finish_reason":"stop"}]}

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        var events: [LLMStreamingEvent] = []
        for try await event in client.completeMessageStreaming(messages: [.init(role: .user, content: "hi")]) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .contentDelta("目标"),
            .contentDelta("回答"),
            .completed(.init(role: .assistant, content: "目标回答"))
        ])
    }

    func testMessageStreamingAcceptsTargetFinishReasonWithoutDone() async throws {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":0,"delta":{"content":"完成"},"finish_reason":"stop"}]}

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        var events: [LLMStreamingEvent] = []
        for try await event in client.completeMessageStreaming(messages: [.init(role: .user, content: "hi")]) {
            events.append(event)
        }
        XCTAssertEqual(events.last, .completed(.init(role: .assistant, content: "完成")))
    }

    func testMessageStreamingRejectsContentThenConnectionCloseWithoutTerminator() async {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":0,"delta":{"content":"未完成"}}]}

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        do {
            for try await _ in client.completeMessageStreaming(messages: [.init(role: .user, content: "hi")]) {}
            XCTFail("没有结束信号应失败")
        } catch let error as LLMStreamingError {
            XCTAssertEqual(error, .incompleteStream)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMessageStreamingIgnoresNonTargetFinishReason() async {
        MockURLProtocol.requestHandler = { _ in
            let sse = """
            data: {"choices":[{"index":1,"delta":{"content":"目标"}},{"index":0,"delta":{"content":"其他"}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            """
            return (self.httpResponse(200), Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = LLMChatClient(config: .init(apiKey: "sk-test"), session: makeSession())
        do {
            for try await _ in client.completeMessageStreaming(messages: [.init(role: .user, content: "hi")]) {}
            XCTFail("非目标 choice 的 finish_reason 不得完成请求")
        } catch let error as LLMStreamingError {
            XCTAssertEqual(error, .incompleteStream)
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }
}
