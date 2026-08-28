import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class ConversationReplyPipelineTests: XCTestCase {
    func testFinalizedTransactionCommitsOnlyAfterExplicitDisplayAcknowledgement() async throws {
        let token = ConversationAgentTransactionToken()
        let agent = TransactionalReplyAgent(token: token)
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }
        let operation = await pipeline.start(
            replyID: UUID(),
            userText: "问题",
            preparedAgent: .init(contextIdentity: .fixture, agent: agent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )

        await waitUntil { received.containsCompleted(operation) }
        let committedBeforeAcknowledgement = await agent.committed
        XCTAssertTrue(committedBeforeAcknowledgement.isEmpty)

        var didAccept = false
        let acknowledged = try await pipeline.acknowledgeCompletion(for: operation) {
            didAccept = true
            return true
        }
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(didAccept)

        let committed = await agent.committed
        let aborted = await agent.aborted
        XCTAssertEqual(committed, [token])
        XCTAssertTrue(aborted.isEmpty)
    }

    func testFinalizedTransactionIsAbortedWhenControllerInvalidatesBeforeDisplayCatchUp() async {
        let token = ConversationAgentTransactionToken()
        let agent = TransactionalReplyAgent(token: token)
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }
        let operation = await pipeline.start(
            replyID: UUID(),
            userText: "会被中断",
            preparedAgent: .init(contextIdentity: .fixture, agent: agent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.containsCompleted(operation) }

        await pipeline.invalidate()

        let committed = await agent.committed
        let aborted = await agent.aborted
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(aborted, [token])
    }

    func testStreamClosureWithoutCompletionEmitsIncompleteFailure() async {
        let agent = ScriptedReplyAgent(events: [.contentDelta("部分")])
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }

        let operation = await pipeline.start(
            replyID: UUID(),
            userText: "问题",
            preparedAgent: .init(contextIdentity: .fixture, agent: agent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.count == 2 }

        guard case .delta(operation, "部分") = received[0],
              case .failed(operation, let failure) = received[1] else {
            return XCTFail("Expected a tagged delta followed by an incomplete-stream failure")
        }
        XCTAssertEqual(failure.message, "模型流未正常完成")
        XCTAssertFalse(failure.shouldDiscardPartial)
    }

    func testInvalidationRejectsEventsFromPreviousGeneration() async {
        let oldAgent = SuspendedReplyAgent()
        let newAgent = ScriptedReplyAgent(events: [.completed("新回答")])
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }

        let old = await pipeline.start(
            replyID: UUID(),
            userText: "旧问题",
            preparedAgent: .init(contextIdentity: .fixture, agent: oldAgent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { await oldAgent.isConnected }
        await pipeline.invalidate()
        await oldAgent.emit(.contentDelta("迟到"))

        let new = await pipeline.start(
            replyID: UUID(),
            userText: "新问题",
            preparedAgent: .init(contextIdentity: .secondFixture, agent: newAgent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.containsCompleted(new) }

        XCTAssertFalse(pipeline.isCurrent(old))
        XCTAssertFalse(received.containsOperation(old))
        XCTAssertTrue(received.containsCompleted(new))
    }

    func testInvalidationWhileClearingPriorContextRejectsAndDiscardsPreparedAgent() async {
        let oldAgent = PausingClearContextAgent()
        let newAgent = CountingReplyAgent()
        let discardRecorder = DiscardRecorder()
        let pipeline = ConversationReplyPipeline()

        _ = await pipeline.start(
            replyID: UUID(),
            userText: "旧问题",
            preparedAgent: .init(contextIdentity: .fixture, agent: oldAgent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )

        let startTask = Task { @MainActor in
            await pipeline.start(
                replyID: UUID(),
                userText: "新问题",
                preparedAgent: .init(
                    contextIdentity: .secondFixture,
                    agent: newAgent,
                    discardPreparation: { await discardRecorder.record() }
                ),
                incompleteStreamMessage: "模型流未正常完成",
                unexpectedFailureMessage: "回答流程暂时中断"
            )
        }
        await waitUntil { await oldAgent.didBeginClear }

        await pipeline.invalidate()
        await oldAgent.resumeClear()
        let rejectedOperation = await startTask.value
        let streamCallCount = await newAgent.streamCallCount
        let discardCount = await discardRecorder.count

        XCTAssertFalse(pipeline.isCurrent(rejectedOperation))
        XCTAssertEqual(streamCallCount, 0)
        XCTAssertEqual(discardCount, 1)
    }

    func testSameContextRetainsExistingAgentAndDiscardsDistinctPreparedAgentExactlyOnce() async {
        let retainedAgent = CountingReplyAgent()
        let unusedPreparedAgent = CountingReplyAgent()
        let discardRecorder = DiscardRecorder()
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }

        let first = await pipeline.start(
            replyID: UUID(),
            userText: "第一轮",
            preparedAgent: .init(contextIdentity: .fixture, agent: retainedAgent),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.containsCompleted(first) }

        let second = await pipeline.start(
            replyID: UUID(),
            userText: "第二轮",
            preparedAgent: .init(
                contextIdentity: .fixture,
                agent: unusedPreparedAgent,
                discardPreparation: { await discardRecorder.record() }
            ),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.containsCompleted(second) }

        let retainedCalls = await retainedAgent.streamCallCount
        let unusedCalls = await unusedPreparedAgent.streamCallCount
        let discardCount = await discardRecorder.count
        XCTAssertEqual(retainedCalls, 2)
        XCTAssertEqual(unusedCalls, 0)
        XCTAssertEqual(discardCount, 1)
    }

    func testUnknownAgentErrorUsesReviewedCopyWithoutLeakingLocalizedDescription() async {
        let sentinel = "SENTINEL_PRIVATE_PROVIDER_PAYLOAD"
        let pipeline = ConversationReplyPipeline()
        var received: [ReplyPipelineEvent] = []
        pipeline.onEvent = { received.append($0) }

        let operation = await pipeline.start(
            replyID: UUID(),
            userText: "问题",
            preparedAgent: .init(
                contextIdentity: .fixture,
                agent: ThrowingReplyAgent(error: SentinelError(message: sentinel))
            ),
            incompleteStreamMessage: "模型流未正常完成",
            unexpectedFailureMessage: "回答流程暂时中断"
        )
        await waitUntil { received.containsOperation(operation) }

        guard case .failed(operation, let failure) = received.last else {
            return XCTFail("Expected a tagged generic failure")
        }
        XCTAssertEqual(failure.message, "回答流程暂时中断")
        XCTAssertEqual(failure.failureCode, .unknown)
        XCTAssertFalse(failure.message.contains(sentinel))
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for reply pipeline")
    }
}

private actor ScriptedReplyAgent: ConversationAgent {
    let events: [ConversationAgentEvent]

    init(events: [ConversationAgentEvent]) {
        self.events = events
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        let events = events
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func clearContext() async {}
}

private actor SuspendedReplyAgent: ConversationAgent {
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    var isConnected: Bool { continuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ event: ConversationAgentEvent) {
        continuation?.yield(event)
    }

    func clearContext() async {}
}

private actor TransactionalReplyAgent: ConversationAgent {
    let token: ConversationAgentTransactionToken
    private(set) var committed: [ConversationAgentTransactionToken] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []

    init(token: ConversationAgentTransactionToken) {
        self.token = token
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        let token = token
        return AsyncThrowingStream { continuation in
            continuation.yield(.transaction(token))
            continuation.yield(.contentDelta("回答"))
            continuation.yield(.completed("回答"))
            continuation.finish()
        }
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        committed.append(token)
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        aborted.append(token)
    }

    func clearContext() async {}
}

private actor PausingClearContextAgent: ConversationAgent {
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private(set) var didBeginClear = false

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed("旧回答"))
            continuation.finish()
        }
    }

    func clearContext() async {
        didBeginClear = true
        await withCheckedContinuation { continuation in
            clearContinuation = continuation
        }
    }

    func resumeClear() {
        clearContinuation?.resume()
        clearContinuation = nil
    }
}

private actor CountingReplyAgent: ConversationAgent {
    private(set) var streamCallCount = 0

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        streamCallCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed("新回答"))
            continuation.finish()
        }
    }

    func clearContext() async {}
}

private actor ThrowingReplyAgent: ConversationAgent {
    let error: any Error & Sendable

    init(error: any Error & Sendable) {
        self.error = error
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        let error = error
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    func clearContext() async {}
}

private struct SentinelError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private actor DiscardRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private extension ConversationAgentContextIdentity {
    static let fixture = Self(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let secondFixture = Self(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
}

private extension Array where Element == ReplyPipelineEvent {
    func containsOperation(_ operation: ReplyOperation) -> Bool {
        contains { event in
            switch event {
            case .searching(let value), .delta(let value, _), .completed(let value, _), .failed(let value, _):
                value == operation
            }
        }
    }

    func containsCompleted(_ operation: ReplyOperation) -> Bool {
        contains { event in
            guard case .completed(let value, _) = event else { return false }
            return value == operation
        }
    }
}
