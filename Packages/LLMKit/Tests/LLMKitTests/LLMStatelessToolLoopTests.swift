import Foundation
import XCTest
@testable import LLMKit

final class LLMStatelessToolLoopTests: XCTestCase {
    func testStatelessLoopExecutesToolAndForwardsBudgets() async throws {
        let transport = StatelessRecordingTransport(responses: [
            LLMMessage(
                role: .assistant,
                content: nil,
                toolCalls: [LLMToolCall(
                    id: "search-1",
                    type: "function",
                    function: .init(name: "web_search", arguments: #"{"query":"近期AI短剧"}"#)
                )]
            ),
            LLMMessage(role: .assistant, content: #"{"theme":"人机边界"}"#)
        ])
        let executor = StatelessRecordingExecutor()
        let loop = LLMStatelessToolLoop(
            transport: transport,
            executor: executor,
            config: .init(temperature: 0.25, maxTokens: 321, maxToolRounds: 2)
        )

        let result = try await loop.complete(messages: [
            LLMMessage(role: .system, content: "system"),
            LLMMessage(role: .user, content: "search first")
        ])

        XCTAssertEqual(result.message.content, #"{"theme":"人机边界"}"#)
        XCTAssertEqual(result.executedToolNames, ["web_search"])
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(transport.requests.map(\.maxTokens), [321, 321])
        XCTAssertEqual(transport.requests.map(\.temperature), [0.25, 0.25])
        XCTAssertEqual(transport.requests.map(\.messages.count), [2, 4])
        XCTAssertEqual(transport.requests[1].messages.last?.role, .tool)
    }

    func testStatelessLoopHasNoContextBetweenInvocations() async throws {
        let transport = StatelessRecordingTransport(responses: [
            LLMMessage(role: .assistant, content: "first"),
            LLMMessage(role: .assistant, content: "second")
        ])
        let loop = LLMStatelessToolLoop(
            transport: transport,
            executor: NoopToolExecutor()
        )

        _ = try await loop.complete(messages: [LLMMessage(role: .user, content: "one")])
        _ = try await loop.complete(messages: [LLMMessage(role: .user, content: "two")])

        XCTAssertEqual(transport.requests.map(\.messages.count), [1, 1])
        XCTAssertEqual(transport.requests[0].messages.first?.content, "one")
        XCTAssertEqual(transport.requests[1].messages.first?.content, "two")
    }

    func testStatelessLoopRejectsMixedContentBeforeExecutingTool() async {
        let transport = StatelessRecordingTransport(responses: [
            LLMMessage(
                role: .assistant,
                content: "untrusted preamble",
                toolCalls: [LLMToolCall(
                    id: "search-1",
                    type: "function",
                    function: .init(name: "web_search", arguments: "{}")
                )]
            )
        ])
        let executor = StatelessRecordingExecutor()
        let loop = LLMStatelessToolLoop(transport: transport, executor: executor)

        do {
            _ = try await loop.complete(messages: [LLMMessage(role: .user, content: "search")])
            XCTFail("mixed content and tool call must fail")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .mixedContentAndToolCall)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(executor.callCount, 0)
    }

    func testAgentKeepsMaxTokensAsContextBudgetForDirectAndStreamingRequests() async throws {
        let directTransport = StatelessRecordingTransport(responses: [
            LLMMessage(role: .assistant, content: "done")
        ])
        let directAgent = LLMAgent(
            transport: directTransport,
            executor: NoopToolExecutor(),
            config: .init(maxTokens: 777)
        )
        _ = try await directAgent.send("question")
        XCTAssertNil(directTransport.requests.first?.maxTokens)

        let streamingTransport = StreamingTokenRecordingTransport()
        let streamingAgent = LLMAgent(
            transport: streamingTransport,
            executor: NoopToolExecutor(),
            config: .init(maxTokens: 555)
        )
        let transaction = await streamingAgent.sendStreaming("question")
        for try await _ in transaction {}
        XCTAssertNil(streamingTransport.maxTokens)
    }

    func testAgentForwardsSeparateCompletionMaxTokensForDirectAndStreamingRequests() async throws {
        let directTransport = StatelessRecordingTransport(responses: [
            LLMMessage(role: .assistant, content: "done")
        ])
        let directAgent = LLMAgent(
            transport: directTransport,
            executor: NoopToolExecutor(),
            config: .init(maxTokens: 777, completionMaxTokens: 123)
        )
        _ = try await directAgent.send("question")
        XCTAssertEqual(directTransport.requests.first?.maxTokens, 123)

        let streamingTransport = StreamingTokenRecordingTransport()
        let streamingAgent = LLMAgent(
            transport: streamingTransport,
            executor: NoopToolExecutor(),
            config: .init(maxTokens: 555, completionMaxTokens: 222)
        )
        let transaction = await streamingAgent.sendStreaming("question")
        for try await _ in transaction {}
        XCTAssertEqual(streamingTransport.maxTokens, 222)
    }
}

private final class StatelessRecordingTransport: LLMChatTransport, @unchecked Sendable {
    struct Request {
        let messages: [LLMMessage]
        let temperature: Double?
        let maxTokens: Int?
    }

    private let lock = NSLock()
    private var responses: [LLMMessage]
    private var storage: [Request] = []

    init(responses: [LLMMessage]) {
        self.responses = responses
    }

    var requests: [Request] { lock.withLock { storage } }

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        try lock.withLock {
            storage.append(Request(
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            ))
            guard !responses.isEmpty else { throw LLMAgentError.emptyResponse }
            return responses.removeFirst()
        }
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMAgentError.missingCompletedMessage) }
    }
}

private final class StatelessRecordingExecutor: LLMToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var callCount: Int { lock.withLock { storage } }
    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: "web_search", description: "search", parameters: [:]))]
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        lock.withLock { storage += 1 }
        return "untrusted raw result"
    }
}

private final class StreamingTokenRecordingTransport: LLMChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?

    var maxTokens: Int? { lock.withLock { storage } }

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        LLMMessage(role: .assistant, content: "done")
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        lock.withLock { storage = maxTokens }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMMessage(role: .assistant, content: "done")))
            continuation.finish()
        }
    }
}
