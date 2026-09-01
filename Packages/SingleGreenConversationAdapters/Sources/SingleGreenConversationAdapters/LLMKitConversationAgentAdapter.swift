import Foundation
import AgentCore
import LLMCore
import SingleGreenGlassesKit

/// Host-owned semantic mapping applied at the LLMKit-to-glasses boundary.
/// Error mappings must return reviewed presentation copy and must never expose
/// provider payloads or arbitrary localized descriptions.
public struct LLMKitConversationAgentAdapterPolicy: Sendable {
    public typealias ToolActivityMapper =
        @Sendable (_ rawToolName: String) -> ConversationToolActivity?
    public typealias StreamErrorMapper =
        @Sendable (_ error: any Error) -> ConversationAgentStreamError

    private let toolActivityMapper: ToolActivityMapper
    private let streamErrorMapper: StreamErrorMapper

    public init(
        toolActivity: @escaping ToolActivityMapper,
        failure: @escaping StreamErrorMapper
    ) {
        self.toolActivityMapper = toolActivity
        self.streamErrorMapper = failure
    }

    func toolActivity(forRawToolName rawToolName: String) -> ConversationToolActivity? {
        toolActivityMapper(rawToolName)
    }

    func streamError(for error: any Error) -> ConversationAgentStreamError {
        streamErrorMapper(error)
    }
}

/// Adapts an already configured LLMKit Agent to the glasses conversation port.
/// Provider credentials, transport construction, tools, and presentation copy
/// remain responsibilities of the host that creates the Agent and policy.
public actor LLMKitConversationAgentAdapter: ConversationAgent {
    private let base: LLMAgent
    private let policy: LLMKitConversationAgentAdapterPolicy
    private var pendingTransaction: (
        port: ConversationAgentTransactionToken,
        agent: LLMAgentTransactionToken
    )?
    private var rollbackTransaction: (
        port: ConversationAgentTransactionToken,
        agent: LLMAgentTransactionToken
    )?

    public init(
        agent: LLMAgent,
        policy: LLMKitConversationAgentAdapterPolicy
    ) {
        self.base = agent
        self.policy = policy
    }

    public func stream(
        _ userText: String
    ) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        rollbackTransaction = nil
        let transaction = await base.sendStreaming(userText)
        let portToken = ConversationAgentTransactionToken()
        pendingTransaction = (portToken, transaction.token)
        let policy = policy
        return AsyncThrowingStream { continuation in
            continuation.yield(.transaction(portToken))
            let task = Task { [weak self, base, policy] in
                do {
                    for try await event in transaction.events {
                        switch event {
                        case .toolCall(let name):
                            if let activity = policy.toolActivity(forRawToolName: name) {
                                continuation.yield(.toolActivity(activity))
                            }
                        case .contentDelta(let delta):
                            continuation.yield(.contentDelta(delta))
                        case .completed(let answer):
                            continuation.yield(.completed(answer))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: policy.streamError(for: error))
                    await base.abort(transaction.token)
                    await self?.discard(portToken)
                }
            }
            continuation.onTermination = { [weak self, base] termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task {
                    await base.abort(transaction.token)
                    await self?.discard(portToken)
                }
            }
        }
    }

    public func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard let pendingTransaction, pendingTransaction.port == token else {
            throw LLMAgentTransactionError.notPending
        }
        try await base.commit(pendingTransaction.agent)
        self.pendingTransaction = nil
        rollbackTransaction = pendingTransaction
    }

    public func abort(_ token: ConversationAgentTransactionToken) async {
        if let pendingTransaction, pendingTransaction.port == token {
            self.pendingTransaction = nil
            await base.abort(pendingTransaction.agent)
        } else if let rollbackTransaction, rollbackTransaction.port == token {
            self.rollbackTransaction = nil
            await base.abort(rollbackTransaction.agent)
        }
    }

    public func clearContext() async {
        pendingTransaction = nil
        rollbackTransaction = nil
        await base.clearContext()
    }

    private func discard(_ token: ConversationAgentTransactionToken) {
        guard pendingTransaction?.port == token else { return }
        pendingTransaction = nil
    }

    func hasPendingTransaction(_ token: ConversationAgentTransactionToken) -> Bool {
        pendingTransaction?.port == token
    }
}
