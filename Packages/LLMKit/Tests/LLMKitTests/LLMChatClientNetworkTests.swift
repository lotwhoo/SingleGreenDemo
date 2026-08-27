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
}
