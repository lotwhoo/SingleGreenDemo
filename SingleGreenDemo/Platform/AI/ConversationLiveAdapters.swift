import Foundation
import AgentCore
import BochaSearchAdapter
import LLMCore
import OpenAICompatibleTransport
import SingleGreenConversationAdapters
import SingleGreenGlassesKit

enum AgentCredentialRefreshFailure: Error, Equatable, Sendable {
    case unusableLease
    case accountScopeChanged
    case searchCredentialMissing
}

/// Resolves a fresh transport credential for every model request while binding
/// the retained Agent context to one stable, non-secret account scope.
struct CredentialRefreshingLLMChatTransport: LLMChatTransport {
    typealias Factory = @Sendable (_ credential: String, _ model: String) -> any LLMChatTransport

    private let scope: AgentProviderScope
    private let credentialProvider: any ConversationCredentialProvider
    private let makeTransport: Factory
    private let onStreamingOperationFinished: @Sendable () -> Void

    init(
        scope: AgentProviderScope,
        credentialProvider: any ConversationCredentialProvider,
        makeTransport: @escaping Factory = { credential, model in
            LLMChatClient(config: .init(
                apiKey: credential,
                model: model,
                thinking: .enabled(effort: .high)
            ))
        },
        onStreamingOperationFinished: @escaping @Sendable () -> Void = {}
    ) {
        self.scope = scope
        self.credentialProvider = credentialProvider
        self.makeTransport = makeTransport
        self.onStreamingOperationFinished = onStreamingOperationFinished
    }

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        let transport = try await resolvedTransport()
        try Task.checkCancellation()
        return try await transport.completeMessage(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools
        )
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                defer { onStreamingOperationFinished() }
                do {
                    let transport = try await resolvedTransport()
                    try Task.checkCancellation()
                    for try await event in transport.completeMessageStreaming(
                        messages: messages,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        tools: tools
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolvedTransport() async throws -> any LLMChatTransport {
        try Task.checkCancellation()
        let lease = try await credentialProvider.lease()
        try Task.checkCancellation()
        guard lease.isLLMUsable(at: .now, minimumRemainingLifetime: 0) else {
            throw AgentCredentialRefreshFailure.unusableLease
        }
        guard lease.agentAccountScope == scope.account else {
            throw AgentCredentialRefreshFailure.accountScopeChanged
        }
        try Task.checkCancellation()
        return makeTransport(lease.llmAPIKey.trimmed, scope.model)
    }
}

/// Resolves search credentials per tool execution and rejects an account-scope
/// change before any prior conversation context can cross that boundary.
struct CredentialRefreshingSearchToolExecutor: LLMToolExecutor {
    typealias Factory = @Sendable (_ credential: String) -> any LLMToolExecutor

    let toolDefinitions: [LLMTool]
    private let scope: AgentProviderScope
    private let credentialProvider: any ConversationCredentialProvider
    private let makeExecutor: Factory

    init(
        scope: AgentProviderScope,
        credentialProvider: any ConversationCredentialProvider,
        makeExecutor: @escaping Factory = { credential in
            BochaSearchClient(config: .init(apiKey: credential))
        }
    ) {
        self.scope = scope
        self.credentialProvider = credentialProvider
        self.makeExecutor = makeExecutor
        toolDefinitions = BochaSearchClient(config: .init(apiKey: "")).toolDefinitions
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        try Task.checkCancellation()
        let lease = try await credentialProvider.lease()
        try Task.checkCancellation()
        guard lease.isCurrent(at: .now, minimumRemainingLifetime: 0) else {
            throw AgentCredentialRefreshFailure.unusableLease
        }
        guard lease.agentAccountScope == scope.account else {
            throw AgentCredentialRefreshFailure.accountScopeChanged
        }
        let credential = lease.searchAPIKey.trimmed
        guard lease.isSearchUsable(at: .now, minimumRemainingLifetime: 0) else {
            throw AgentCredentialRefreshFailure.searchCredentialMissing
        }
        try Task.checkCancellation()
        let executor = makeExecutor(credential)
        try Task.checkCancellation()
        return try await executor.execute(call)
    }
}

/// App-owned construction and semantic policy for the reusable Agent bridge.
enum ProductionConversationAgentFactory {
    static func make(
        configuration: AgentProviderConfiguration
    ) -> LLMKitConversationAgentAdapter {
        let transport = CredentialRefreshingLLMChatTransport(
            scope: configuration.scope,
            credentialProvider: configuration.credentialProvider
        )
        let executor: any LLMToolExecutor = configuration.scope.externalInformationLookupEnabled
            ? CredentialRefreshingSearchToolExecutor(
                scope: configuration.scope,
                credentialProvider: configuration.credentialProvider
            )
            : NoopToolExecutor()
        let agent = LLMAgent(
            transport: transport,
            executor: executor,
            config: .init(systemPrompt: configuration.systemPrompt, maxMessages: 20)
        )
        return LLMKitConversationAgentAdapter(agent: agent, policy: adapterPolicy)
    }

    static let adapterPolicy = LLMKitConversationAgentAdapterPolicy(
        toolActivity: { rawName in
            toolActivity(for: rawName)
        },
        failure: { error in
            streamError(for: error)
        }
    )

    static func toolActivity(for rawToolName: String) -> ConversationToolActivity? {
        rawToolName == "web_search" ? .externalInformationLookup : nil
    }

    static func streamError(for error: Error) -> ConversationAgentStreamError {
        if let streamError = error as? LLMAgentStreamError,
           streamError == .discardPartialMixedContentAndToolCall {
            return .discardPartial(
                "模型同时返回正文和工具调用，已丢弃不可信的部分正文"
            )
        }
        if let error = error as? LLMAPIError {
            let code: ConversationFailureCode = [401, 403].contains(error.statusCode)
                ? .unauthorized
                : .networkUnavailable
            return .failed(
                code == .unauthorized ? "服务凭证未通过验证。" : "网络或模型服务暂时不可用。",
                code
            )
        }
        if let error = error as? LLMStreamingError {
            let code: ConversationFailureCode = error == .incompleteStream
                ? .incompleteStream
                : .interrupted
            return .failed("模型流未正常完成。", code)
        }
        if let error = error as? BochaSearchClient.BochaError,
           case .apiError(let statusCode, _) = error,
           [401, 403].contains(statusCode) {
            return .failed("搜索服务凭证未通过验证。", .unauthorized)
        }
        if error is URLError || error is BochaSearchClient.BochaError {
            return .failed("网络或搜索服务暂时不可用。", .networkUnavailable)
        }
        if let error = error as? LLMAgentError {
            switch error {
            case .missingCompletedMessage:
                return .failed("模型流未正常完成。", .incompleteStream)
            case .tooManyToolRounds,
                 .emptyResponse,
                 .mixedContentAndToolCall,
                 .incompleteToolCall,
                 .malformedToolCallArguments:
                return .failed("模型未能生成有效回答。", .interrupted)
            }
        }
        return .failed("回答流程暂时中断。", .interrupted)
    }
}
