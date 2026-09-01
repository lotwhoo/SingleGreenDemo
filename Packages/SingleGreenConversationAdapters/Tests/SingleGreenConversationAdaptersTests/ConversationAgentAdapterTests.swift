import Foundation
import AgentCore
import LLMCore
import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenConversationAdapters

final class ConversationAgentAdapterTests: XCTestCase {
    func testTransactionPrecedesMappedToolActivityDeltasAndCompletion() async throws {
        let toolCall = try makeToolCall(name: "host_lookup")
        let transport = QueuedStreamingTransport(responses: [
            [.completed(.init(role: .assistant, content: nil, toolCalls: [toolCall]))],
            [
                .contentDelta("result "),
                .contentDelta("ready"),
                .completed(.init(role: .assistant, content: "result ready"))
            ]
        ])
        let base = LLMAgent(
            transport: transport,
            executor: StaticToolExecutor(toolName: "host_lookup"),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)

        let events = try await collect(adapter.stream("question"))

        guard case .transaction = events.first else {
            return XCTFail("Transaction token must be the first event")
        }
        let semanticEvents: [ConversationAgentEvent] = [
            .toolActivity(.externalInformationLookup),
            .contentDelta("result "),
            .contentDelta("ready"),
            .completed("result ready")
        ]
        XCTAssertEqual(Array(events.dropFirst()), semanticEvents)
    }

    func testUnmappedRawToolNameDoesNotLeakAcrossSemanticBoundary() async throws {
        let toolCall = try makeToolCall(name: "provider_private_tool")
        let transport = QueuedStreamingTransport(responses: [
            [.completed(.init(role: .assistant, content: nil, toolCalls: [toolCall]))],
            [.completed(.init(role: .assistant, content: "answer"))]
        ])
        let base = LLMAgent(
            transport: transport,
            executor: StaticToolExecutor(toolName: "provider_private_tool"),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)

        let events = try await collect(adapter.stream("question"))

        XCTAssertEqual(events.count, 2)
        guard case .transaction = events[0] else {
            return XCTFail("Transaction token must be first")
        }
        XCTAssertEqual(events[1], ConversationAgentEvent.completed("answer"))
        XCTAssertFalse(events.contains { event in
            if case .toolActivity = event { return true }
            return false
        })
        XCTAssertFalse(String(describing: events).contains("provider_private_tool"))
    }

    func testCommitThenAbortRollsBackExactTransaction() async throws {
        let base = makeAnsweringAgent(answer: "accepted")
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let events = try await collect(adapter.stream("question"))
        let token = try transactionToken(in: events)

        try await adapter.commit(token)
        let committed = await base.chatMessages
        XCTAssertEqual(committed.map(\.content), ["question", "accepted"])

        await adapter.abort(token)
        let rolledBack = await base.chatMessages
        XCTAssertTrue(rolledBack.isEmpty)
    }

    func testWrongAbortTokenCannotRollBackCommittedTransaction() async throws {
        let base = makeAnsweringAgent(answer: "accepted")
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let events = try await collect(adapter.stream("question"))
        let token = try transactionToken(in: events)
        try await adapter.commit(token)

        await adapter.abort(ConversationAgentTransactionToken())

        let preserved = await base.chatMessages
        XCTAssertEqual(preserved.map(\.content), ["question", "accepted"])
        await adapter.abort(token)
        let rolledBack = await base.chatMessages
        XCTAssertTrue(rolledBack.isEmpty)
    }

    func testNewTransactionEndsPriorRollbackWindowWithoutRemovingAcceptedHistory() async throws {
        let transport = QueuedStreamingTransport(responses: [
            [.completed(.init(role: .assistant, content: "first answer"))],
            [.completed(.init(role: .assistant, content: "second answer"))]
        ])
        let base = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let firstToken = try transactionToken(in: try await collect(adapter.stream("first")))
        try await adapter.commit(firstToken)

        let secondToken = try transactionToken(in: try await collect(adapter.stream("second")))
        await adapter.abort(firstToken)
        await adapter.abort(secondToken)

        let messages = await base.chatMessages
        XCTAssertEqual(messages.map(\.content), ["first", "first answer"])
    }

    func testAbortPendingTransactionPreventsCommitAndLeavesContextEmpty() async throws {
        let base = makeAnsweringAgent(answer: "tentative")
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let events = try await collect(adapter.stream("question"))
        let token = try transactionToken(in: events)

        await adapter.abort(token)
        do {
            try await adapter.commit(token)
            XCTFail("Aborted transaction must not commit")
        } catch let error as LLMAgentTransactionError {
            XCTAssertEqual(error, .notPending)
        }
        let messages = await base.chatMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testNewStreamMakesOldPortTokenStaleAndCommitsOnlyNewestTurn() async throws {
        let transport = QueuedStreamingTransport(responses: [
            [.completed(.init(role: .assistant, content: "old answer"))],
            [.completed(.init(role: .assistant, content: "new answer"))]
        ])
        let base = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let oldToken = try transactionToken(in: try await collect(adapter.stream("old")))
        let newToken = try transactionToken(in: try await collect(adapter.stream("new")))

        do {
            try await adapter.commit(oldToken)
            XCTFail("Stale transaction must not commit")
        } catch let error as LLMAgentTransactionError {
            XCTAssertEqual(error, .notPending)
        }
        try await adapter.commit(newToken)

        let messages = await base.chatMessages
        XCTAssertEqual(messages.map(\.content), ["new", "new answer"])
    }

    func testClearContextInvalidatesPendingAndCommittedRollbackHandles() async throws {
        let base = makeAnsweringAgent(answer: "answer")
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let token = try transactionToken(in: try await collect(adapter.stream("question")))
        try await adapter.commit(token)

        await adapter.clearContext()
        await adapter.abort(token)

        let messages = await base.chatMessages
        XCTAssertTrue(messages.isEmpty)
        do {
            try await adapter.commit(token)
            XCTFail("Cleared transaction must not commit")
        } catch let error as LLMAgentTransactionError {
            XCTAssertEqual(error, .notPending)
        }
    }

    func testFailureUsesReviewedPolicyCopyAndAbortsPendingContext() async throws {
        let transport = FailingStreamingTransport(
            events: [.contentDelta("partial")],
            error: SensitiveAgentFixtureError()
        )
        let base = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        var received: [ConversationAgentEvent] = []
        var receivedError: Error?

        do {
            for try await event in await adapter.stream("question") {
                received.append(event)
            }
        } catch {
            receivedError = error
        }

        guard case .transaction(let token) = received.first else {
            return XCTFail("Transaction token must precede failure")
        }
        XCTAssertEqual(received.dropFirst(), [.contentDelta("partial")])
        XCTAssertEqual(
            receivedError as? ConversationAgentStreamError,
            .failed("Reviewed stream failure.", .networkUnavailable)
        )
        XCTAssertFalse(
            String(describing: receivedError).contains(SensitiveAgentFixtureError.sentinel)
        )
        await waitUntil { await base.chatMessages.isEmpty }
        await waitUntil { !(await adapter.hasPendingTransaction(token)) }
        let remainsPending = await adapter.hasPendingTransaction(token)
        XCTAssertFalse(remainsPending)
        do {
            try await adapter.commit(token)
            XCTFail("Failed transaction must not commit")
        } catch let error as LLMAgentTransactionError {
            XCTAssertEqual(error, .notPending)
        }
    }

    func testMixedPartialAndToolFailureUsesReviewedDiscardCopy() async {
        let transport = QueuedStreamingTransport(responses: [[
            .contentDelta("untrusted"),
            .toolCallDelta(
                index: 0,
                id: "call-1",
                type: "function",
                functionName: "host_lookup",
                arguments: "{}"
            )
        ]])
        let base = LLMAgent(
            transport: transport,
            executor: StaticToolExecutor(toolName: "host_lookup"),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        var receivedError: Error?

        do {
            for try await _ in await adapter.stream("question") {}
        } catch {
            receivedError = error
        }

        XCTAssertEqual(
            receivedError as? ConversationAgentStreamError,
            .discardPartial("Reviewed mixed stream.")
        )
        XCTAssertFalse(
            receivedError?.localizedDescription.contains("tool") == true,
            "Adapter must use host-reviewed copy, not LLMAgent localizedDescription"
        )
        let messages = await base.chatMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testCancellingConsumerAbortsUnderlyingTransaction() async {
        let transport = ControlledStreamingTransport()
        let base = LLMAgent(
            transport: transport,
            executor: NoopToolExecutor(),
            config: .init()
        )
        let adapter = LLMKitConversationAgentAdapter(agent: base, policy: .fixture)
        let receivedPartial = LockedFlag()
        let tokenRecorder = TransactionTokenRecorder()
        let output = await adapter.stream("cancelled")
        let consumption = Task {
            do {
                for try await event in output {
                    if case .transaction(let token) = event {
                        await tokenRecorder.record(token)
                    }
                    if event == .contentDelta("partial") {
                        receivedPartial.set()
                    }
                }
            } catch {}
        }

        await waitUntil { receivedPartial.value }
        await waitUntil { await tokenRecorder.token != nil }
        consumption.cancel()
        await waitUntil { transport.terminationCount == 1 }
        await consumption.value

        XCTAssertEqual(transport.terminationCount, 1)
        let messages = await base.chatMessages
        XCTAssertTrue(messages.isEmpty)
        if let token = await tokenRecorder.token {
            await waitUntil { !(await adapter.hasPendingTransaction(token)) }
            let remainsPending = await adapter.hasPendingTransaction(token)
            XCTAssertFalse(remainsPending)
        } else {
            XCTFail("Missing transaction token")
        }
    }

    private func makeAnsweringAgent(answer: String) -> LLMAgent {
        LLMAgent(
            transport: QueuedStreamingTransport(responses: [[
                .contentDelta(answer),
                .completed(.init(role: .assistant, content: answer))
            ]]),
            executor: NoopToolExecutor(),
            config: .init()
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ConversationAgentEvent, Error>
    ) async throws -> [ConversationAgentEvent] {
        var values: [ConversationAgentEvent] = []
        for try await value in stream { values.append(value) }
        return values
    }

    private func transactionToken(
        in events: [ConversationAgentEvent]
    ) throws -> ConversationAgentTransactionToken {
        guard case .transaction(let token) = events.first else {
            throw TestFailure.missingTransaction
        }
        return token
    }

    private func makeToolCall(name: String) throws -> LLMToolCall {
        let object: [String: Any] = [
            "id": "call-1",
            "type": "function",
            "function": ["name": name, "arguments": "{}"]
        ]
        return try JSONDecoder().decode(
            LLMToolCall.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func waitUntil(
        iterations: Int = 1_000,
        _ predicate: () async -> Bool
    ) async {
        for _ in 0 ..< iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic adapter state")
    }
}

private extension LLMKitConversationAgentAdapterPolicy {
    static let fixture = Self(
        toolActivity: { rawName in
            rawName == "host_lookup" ? .externalInformationLookup : nil
        },
        failure: { error in
            if error is SensitiveAgentFixtureError {
                return .failed("Reviewed stream failure.", .networkUnavailable)
            }
            if let error = error as? LLMAgentStreamError,
               error == .discardPartialMixedContentAndToolCall {
                return .discardPartial("Reviewed mixed stream.")
            }
            return .failed("Reviewed generic failure.", .interrupted)
        }
    )
}

private final class QueuedStreamingTransport: LLMChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[LLMStreamingEvent]]

    init(responses: [[LLMStreamingEvent]]) {
        self.responses = responses
    }

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        throw TestFailure.unexpectedNonStreamingRequest
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        let response = lock.withLock {
            responses.isEmpty ? [] : responses.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in response { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct FailingStreamingTransport: LLMChatTransport {
    let events: [LLMStreamingEvent]
    let error: SensitiveAgentFixtureError

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        throw error
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: error)
        }
    }
}

private final class ControlledStreamingTransport: LLMChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTerminationCount = 0

    var terminationCount: Int { lock.withLock { storedTerminationCount } }

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        throw TestFailure.unexpectedNonStreamingRequest
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("partial"))
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.storedTerminationCount += 1 }
            }
        }
    }
}

private struct StaticToolExecutor: LLMToolExecutor {
    let toolName: String

    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: toolName, description: "fixture", parameters: [:]))]
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        "tool result"
    }
}

private struct SensitiveAgentFixtureError: LocalizedError, Sendable {
    static let sentinel = "SENSITIVE_PROVIDER_STREAM_PAYLOAD"
    var errorDescription: String? { Self.sentinel }
}

private enum TestFailure: Error {
    case missingTransaction
    case unexpectedNonStreamingRequest
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() {
        lock.withLock { storage = true }
    }
}

private actor TransactionTokenRecorder {
    private(set) var token: ConversationAgentTransactionToken?

    func record(_ token: ConversationAgentTransactionToken) {
        self.token = token
    }
}
