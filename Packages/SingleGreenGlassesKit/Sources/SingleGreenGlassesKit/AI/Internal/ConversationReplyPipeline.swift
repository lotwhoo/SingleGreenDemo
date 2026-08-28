import Foundation

enum ReplyPipelineEvent: Sendable {
    case searching(ReplyOperation)
    case delta(ReplyOperation, String)
    case completed(ReplyOperation, String)
    case failed(ReplyOperation, ReplyPipelineFailure)
}

struct ReplyPipelineFailure: Error, LocalizedError, Equatable, Sendable {
    let message: String
    let shouldDiscardPartial: Bool
    let failureCode: ConversationFailureCode

    var errorDescription: String? { message }
}

/// Internal errors may carry only copy already selected from the host's
/// reviewed presentation bundle. Arbitrary provider/framework errors must not
/// conform to this protocol.
protocol ReviewedConversationPipelineError: Error {
    var reviewedMessage: String { get }
}

@MainActor
final class ConversationReplyPipeline {
    private var agent: (any ConversationAgent)?
    private var agentContextIdentity: ConversationAgentContextIdentity?
    private var replyTask: Task<Void, Never>?
    private var pendingAcknowledgement: (
        operation: ReplyOperation,
        token: ConversationAgentTransactionToken,
        agent: any ConversationAgent
    )?
    private var acknowledgement: (
        operation: ReplyOperation,
        token: ConversationAgentTransactionToken,
        agent: any ConversationAgent,
        task: Task<Void, Error>
    )?
    private var generation = 0

    var onEvent: @MainActor (ReplyPipelineEvent) throws -> Void = { _ in }

    deinit {
        replyTask?.cancel()
        acknowledgement?.task.cancel()
        if let pendingAcknowledgement {
            Task {
                await pendingAcknowledgement.agent.abort(pendingAcknowledgement.token)
            }
        }
    }

    func start(
        replyID: UUID,
        userText: String,
        preparedAgent: PreparedConversationAgent,
        incompleteStreamMessage: String,
        unexpectedFailureMessage: String
    ) async -> ReplyOperation {
        generation += 1
        let operation = ReplyOperation(id: replyID, generation: generation)
        if let retainedAgent = agent,
           agentContextIdentity == preparedAgent.contextIdentity {
            // The host may prepare a fresh transport-backed handle for the same
            // logical context. Keep the context-bearing Agent already retained
            // by the pipeline and release the unused preparation exactly once.
            await preparedAgent.discard()
            guard isCurrent(operation) else { return operation }
            agent = retainedAgent
        } else {
            let previousAgent = agent
            agent = nil
            agentContextIdentity = nil
            if let previousAgent { await previousAgent.clearContext() }
            guard isCurrent(operation) else {
                await preparedAgent.discard()
                return operation
            }
            agent = preparedAgent.agent
            agentContextIdentity = preparedAgent.contextIdentity
        }
        guard let agent else { return operation }

        replyTask = Task { [weak self] in
            let events = await agent.stream(userText)
            await Self.consume(
                events,
                operation: operation,
                incompleteStreamMessage: incompleteStreamMessage,
                unexpectedFailureMessage: unexpectedFailureMessage,
                pipeline: { [weak self] in self }
            )
        }
        return operation
    }

    func invalidate() async {
        await beginInvalidation().value
    }

    func beginInvalidation() -> Task<Void, Never> {
        generation += 1
        let task = replyTask
        replyTask = nil
        task?.cancel()
        let activeAcknowledgement = acknowledgement
        acknowledgement = nil
        activeAcknowledgement?.task.cancel()
        let pending = pendingAcknowledgement
        pendingAcknowledgement = nil
        return Task {
            await task?.value
            if let activeAcknowledgement {
                await activeAcknowledgement.agent.abort(activeAcknowledgement.token)
                _ = try? await activeAcknowledgement.task.value
                await activeAcknowledgement.agent.abort(activeAcknowledgement.token)
            }
            if let pending {
                await pending.agent.abort(pending.token)
            }
        }
    }

    func clearContext() async {
        let activeAcknowledgement = acknowledgement
        acknowledgement = nil
        if let activeAcknowledgement {
            activeAcknowledgement.task.cancel()
            await activeAcknowledgement.agent.abort(activeAcknowledgement.token)
            _ = try? await activeAcknowledgement.task.value
        }
        let pending = pendingAcknowledgement
        pendingAcknowledgement = nil
        if let pending {
            await pending.agent.abort(pending.token)
        }
        if let agent { await agent.clearContext() }
        agent = nil
        agentContextIdentity = nil
    }

    /// Commits Agent context only after display catch-up, then executes the
    /// controller's synchronous MainActor acceptance before acknowledgement
    /// state can be cleared or another lifecycle action can interleave.
    func acknowledgeCompletion(
        for operation: ReplyOperation,
        accepting acceptance: @MainActor () -> Bool
    ) async throws -> Bool {
        guard isCurrent(operation) else { return false }
        guard let pendingAcknowledgement else {
            // Compatibility agents without context transactions require no acknowledgement.
            return acceptance()
        }
        guard pendingAcknowledgement.operation == operation else { return false }
        self.pendingAcknowledgement = nil
        let commitTask = Task {
            try await pendingAcknowledgement.agent.commit(pendingAcknowledgement.token)
        }
        acknowledgement = (
            operation: operation,
            token: pendingAcknowledgement.token,
            agent: pendingAcknowledgement.agent,
            task: commitTask
        )

        do {
            try await commitTask.value
        } catch {
            guard isAcknowledging(operation) else { return false }
            let recoveryTask = Task<Void, Error> {
                await pendingAcknowledgement.agent.abort(pendingAcknowledgement.token)
            }
            acknowledgement = (
                operation: operation,
                token: pendingAcknowledgement.token,
                agent: pendingAcknowledgement.agent,
                task: recoveryTask
            )
            _ = try? await recoveryTask.value
            guard isAcknowledging(operation) else { return false }
            acknowledgement = nil
            throw error
        }
        guard isAcknowledging(operation) else { return false }
        guard acceptance() else {
            let recoveryTask = Task<Void, Error> {
                await pendingAcknowledgement.agent.abort(pendingAcknowledgement.token)
            }
            acknowledgement = (
                operation: operation,
                token: pendingAcknowledgement.token,
                agent: pendingAcknowledgement.agent,
                task: recoveryTask
            )
            _ = try? await recoveryTask.value
            guard isAcknowledging(operation) else { return false }
            acknowledgement = nil
            return false
        }
        acknowledgement = nil
        return true
    }

    func isCurrent(_ operation: ReplyOperation) -> Bool {
        operation.generation == generation
    }

    private static func consume(
        _ events: AsyncThrowingStream<ConversationAgentEvent, Error>,
        operation: ReplyOperation,
        incompleteStreamMessage: String,
        unexpectedFailureMessage: String,
        pipeline: @escaping @MainActor () -> ConversationReplyPipeline?
    ) async {
        do {
            var didReceiveCompletionEvent = false
            for try await event in events {
                try Task.checkCancellation()
                if let pipeline = pipeline() {
                    guard pipeline.isCurrent(operation) else { return }
                    switch event {
                    case .transaction(let token):
                        pipeline.registerAcknowledgement(
                            token,
                            operation: operation
                        )
                    case .toolActivity(let activity):
                        if activity == .externalInformationLookup {
                            try pipeline.onEvent(.searching(operation))
                        }
                    case .contentDelta(let delta):
                        try pipeline.onEvent(.delta(operation, delta))
                    case .completed(let answer):
                        try pipeline.onEvent(.completed(operation, answer))
                        didReceiveCompletionEvent = true
                    }
                } else {
                    return
                }
            }
            guard let pipeline = pipeline(), pipeline.isCurrent(operation) else { return }
            if !didReceiveCompletionEvent {
                throw ReplyPipelineFailure(
                    message: incompleteStreamMessage,
                    shouldDiscardPartial: false,
                    failureCode: .incompleteStream
                )
            }
            pipeline.replyTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard let currentPipeline = pipeline(),
                  currentPipeline.isCurrent(operation) else { return }
            let pending = currentPipeline.takeAcknowledgement(for: operation)
            if let pending {
                await pending.agent.abort(pending.token)
            }
            guard let pipeline = pipeline(), pipeline.isCurrent(operation) else { return }
            let failure: ReplyPipelineFailure
            if let pipelineFailure = error as? ReplyPipelineFailure {
                failure = pipelineFailure
            } else if let agentFailure = error as? ConversationAgentStreamError {
                failure = ReplyPipelineFailure(
                    message: agentFailure.errorDescription ?? unexpectedFailureMessage,
                    shouldDiscardPartial: agentFailure.shouldDiscardPartial,
                    failureCode: agentFailure.failureCode
                )
            } else if let reviewedFailure = error as? ReviewedConversationPipelineError {
                failure = ReplyPipelineFailure(
                    message: reviewedFailure.reviewedMessage,
                    shouldDiscardPartial: false,
                    failureCode: .protocolFailure
                )
            } else {
                failure = ReplyPipelineFailure(
                    message: unexpectedFailureMessage,
                    shouldDiscardPartial: false,
                    failureCode: .unknown
                )
            }
            pipeline.replyTask = nil
            try? pipeline.onEvent(.failed(operation, failure))
        }
    }

    private func registerAcknowledgement(
        _ token: ConversationAgentTransactionToken,
        operation: ReplyOperation
    ) {
        guard isCurrent(operation), let agent else { return }
        pendingAcknowledgement = (operation, token, agent)
    }

    private func isAcknowledging(_ operation: ReplyOperation) -> Bool {
        isCurrent(operation) && acknowledgement?.operation == operation
    }

    private func takeAcknowledgement(
        for operation: ReplyOperation
    ) -> (token: ConversationAgentTransactionToken, agent: any ConversationAgent)? {
        guard let pendingAcknowledgement,
              pendingAcknowledgement.operation == operation else { return nil }
        self.pendingAcknowledgement = nil
        return (pendingAcknowledgement.token, pendingAcknowledgement.agent)
    }
}
