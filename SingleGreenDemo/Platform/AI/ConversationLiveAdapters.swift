import Foundation
import LLMKit
import SingleGreenGlassesKit
import VoiceChatCore

protocol VoiceChatASRSessionBase: Sendable {
    var events: AsyncStream<ASRSession.Event> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

extension ASRSession: VoiceChatASRSessionBase {}

protocol VoiceChatVoiceActivatedASRSessionBase: Sendable {
    var events: AsyncStream<VoiceActivatedASREvent> { get }
    func arm() async throws
    func finish() async
    func cancel() async
}

extension VoiceActivatedASRSession: VoiceChatVoiceActivatedASRSessionBase {}

/// VoiceChatCore ASR 到 App 端口事件的唯一生产适配器。
actor VoiceChatSpeechRecognitionSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>

    private let base: any VoiceChatASRSessionBase
    private var bridgeTask: Task<Void, Never>?

    init(configuration: SpeechProviderConfiguration) {
        let base = ASRSession(config: .init(
            apiKey: configuration.apiKey,
            resourceID: configuration.resourceID,
            language: configuration.language,
            hotwords: configuration.hotwords
        ))
        self.init(base: base)
    }

    init(base: any VoiceChatASRSessionBase) {
        self.base = base

        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        bridgeTask = Task {
            for await event in base.events {
                switch event {
                case .transcript(let text):
                    continuation.yield(.transcript(text))
                case .utterance(let text):
                    continuation.yield(.utterance(text))
                case .level(let value):
                    continuation.yield(.level(value))
                case .state(.finished):
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                case .state(.failed(let failure)):
                    continuation.yield(.failed(Self.failure(forCoreFailure: failure)))
                    continuation.finish()
                    return
                case .error(let failure):
                    continuation.yield(.failed(Self.failure(forCoreFailure: failure)))
                    continuation.finish()
                    return
                case .state:
                    break
                }
            }
            continuation.finish()
        }
    }

    deinit {
        bridgeTask?.cancel()
    }

    func start() async throws {
        do {
            try await base.start()
        } catch {
            throw Self.failure(forStartError: error)
        }
    }
    func finish() async { await base.finish() }
    func cancel() async { await base.cancel() }

    static func failure(forStartError error: Error) -> SpeechRecognitionFailure {
        guard let failure = error as? ASRFailure else {
            return SpeechRecognitionFailure(code: .unknown)
        }
        return Self.failure(forCoreFailure: failure)
    }

    static func failure(forCoreFailure failure: ASRFailure) -> SpeechRecognitionFailure {
        let code: SpeechRecognitionFailure.Code = switch failure.code {
        case .unauthorized: .unauthorized
        case .networkUnavailable: .networkUnavailable
        case .timeout: .timeout
        case .connectionLost: .connectionLost
        case .protocolFailure: .protocolFailure
        case .audioInterrupted: .audioInterrupted
        case .audioUnavailable: .audioUnavailable
        case .voiceActivityUnavailable: .voiceActivityUnavailable
        case .voiceActivityProcessingFailed: .voiceActivityProcessingFailed
        case .audioCaptureOverrun: .audioCaptureOverrun
        case .uploadBackpressureExceeded: .uploadBackpressureExceeded
        case .unknown: .unknown
        }
        return SpeechRecognitionFailure(code: code, userSafeMessage: failure.userSafeMessage)
    }

    static func failure(forAudioSystemEvent event: AudioCapture.AudioSystemEvent) -> SpeechRecognitionFailure? {
        ASRFailure.audioSystemEvent(event).map { Self.failure(forCoreFailure: $0) }
    }
}

/// The sole bridge from VoiceChatCore's local-VAD session into the
/// provider-neutral glasses contract. One-shot terminal handling is enforced
/// here as a second boundary against duplicate or late Core events.
actor VoiceChatVoiceActivatedSpeechRecognitionSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>

    private let base: any VoiceChatVoiceActivatedASRSessionBase
    private let eventBridge: VoiceActivatedASREventBridge
    private var bridgeTask: Task<Void, Never>?
    private var hasCancelledBase = false

    init(base: any VoiceChatVoiceActivatedASRSessionBase) {
        self.base = base
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        let eventBridge = VoiceActivatedASREventBridge(continuation: continuation)
        self.eventBridge = eventBridge
        bridgeTask = Task { [base, eventBridge] in
            for await event in base.events {
                guard !Task.isCancelled else { return }
                guard await eventBridge.receive(event) else { return }
            }
            await eventBridge.finishWithoutSyntheticTerminal()
        }
    }

    deinit {
        bridgeTask?.cancel()
    }

    func arm() async throws {
        do {
            try await base.arm()
        } catch {
            throw VoiceChatSpeechRecognitionSession.failure(forStartError: error)
        }
    }

    func finish() async {
        guard await eventBridge.isActive else { return }
        await base.finish()
    }

    func cancel() async {
        guard !hasCancelledBase else { return }
        hasCancelledBase = true
        bridgeTask?.cancel()
        bridgeTask = nil
        await eventBridge.terminate()
        await base.cancel()
    }
}

private actor VoiceActivatedASREventBridge {
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation
    private var emittedArmed = false
    private var emittedSpeechStarted = false
    private var emittedFinalizing = false
    private(set) var isActive = true

    init(continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    /// Returns whether the source observation should continue.
    func receive(_ event: VoiceActivatedASREvent) -> Bool {
        guard isActive else { return false }
        switch event {
        case .state(.armed):
            guard !emittedArmed else { return true }
            emittedArmed = true
            continuation.yield(.phase(.armed))
        case .state(.openingRecognizer):
            guard !emittedSpeechStarted else { return true }
            emittedSpeechStarted = true
            continuation.yield(.phase(.speechStarted))
        case .state(.draining(let reason)), .state(.finalizing(let reason)):
            guard !emittedFinalizing else { return true }
            emittedFinalizing = true
            continuation.yield(.phase(.finalizing(Self.endpointReason(for: reason))))
        case .state(.finished):
            continuation.yield(.finished)
            terminate()
        case .state(.failed(let failure)):
            continuation.yield(.failed(
                VoiceChatSpeechRecognitionSession.failure(forCoreFailure: failure)
            ))
            terminate()
        case .state:
            break
        case .transcript(let text):
            continuation.yield(.transcript(text))
        case .utterance(let text):
            continuation.yield(.utterance(text))
        case .level(let value):
            continuation.yield(.level(value))
        case .noSpeech:
            // `noSpeech` is terminal in the glasses contract. Core follows it
            // with `.finished`; closing here prevents a duplicate completion.
            continuation.yield(.noSpeech)
            terminate()
        }
        return isActive
    }

    func finishWithoutSyntheticTerminal() {
        terminate()
    }

    func terminate() {
        guard isActive else { return }
        isActive = false
        continuation.finish()
    }

    private static func endpointReason(
        for reason: VoiceActivatedEndpointReason
    ) -> VoiceEndpointReason {
        switch reason {
        case .silence: .silence
        case .maximumDuration: .maximumDuration
        case .manual: .manual
        }
    }
}

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
            LLMChatClient(config: .init(apiKey: credential, model: model))
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
        guard lease.isUsable(at: .now, minimumRemainingLifetime: 0) else {
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
        guard lease.isUsable(at: .now, minimumRemainingLifetime: 0) else {
            throw AgentCredentialRefreshFailure.unusableLease
        }
        guard lease.agentAccountScope == scope.account else {
            throw AgentCredentialRefreshFailure.accountScopeChanged
        }
        let credential = lease.searchAPIKey.trimmed
        guard !credential.isEmpty else {
            throw AgentCredentialRefreshFailure.searchCredentialMissing
        }
        try Task.checkCancellation()
        let executor = makeExecutor(credential)
        try Task.checkCancellation()
        return try await executor.execute(call)
    }
}

/// LLMKit Agent 到 App 会话端口的唯一生产适配器。
actor LLMKitConversationAgent: ConversationAgent {
    private let base: LLMAgent
    private var pendingTransaction: (
        port: ConversationAgentTransactionToken,
        agent: LLMAgentTransactionToken
    )?
    private var rollbackTransaction: (
        port: ConversationAgentTransactionToken,
        agent: LLMAgentTransactionToken
    )?

    init(configuration: AgentProviderConfiguration) {
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
        base = LLMAgent(
            transport: transport,
            executor: executor,
            config: .init(systemPrompt: configuration.systemPrompt, maxMessages: 20)
        )
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        rollbackTransaction = nil
        let transaction = await base.sendStreaming(userText)
        let portToken = ConversationAgentTransactionToken()
        pendingTransaction = (portToken, transaction.token)
        return AsyncThrowingStream { continuation in
            continuation.yield(.transaction(portToken))
            let task = Task { [weak self, base] in
                do {
                    for try await event in transaction.events {
                        switch event {
                        case .toolCall(let name):
                            if let activity = Self.toolActivity(for: name) {
                                continuation.yield(.toolActivity(activity))
                            }
                        case .contentDelta(let delta): continuation.yield(.contentDelta(delta))
                        case .completed(let answer): continuation.yield(.completed(answer))
                        }
                    }
                    continuation.finish()
                } catch {
                    if let streamError = error as? LLMAgentStreamError,
                       streamError == .discardPartialMixedContentAndToolCall {
                        continuation.finish(throwing: ConversationAgentStreamError.discardPartial(
                            streamError.localizedDescription
                        ))
                    } else {
                        continuation.finish(throwing: Self.coarseFailure(for: error))
                    }
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

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard let pendingTransaction, pendingTransaction.port == token else {
            throw LLMAgentTransactionError.notPending
        }
        try await base.commit(pendingTransaction.agent)
        self.pendingTransaction = nil
        rollbackTransaction = pendingTransaction
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        if let pendingTransaction, pendingTransaction.port == token {
            self.pendingTransaction = nil
            await base.abort(pendingTransaction.agent)
        } else if let rollbackTransaction, rollbackTransaction.port == token {
            self.rollbackTransaction = nil
            await base.abort(rollbackTransaction.agent)
        }
    }

    func clearContext() async {
        pendingTransaction = nil
        rollbackTransaction = nil
        await base.clearContext()
    }

    private func discard(_ token: ConversationAgentTransactionToken) {
        guard pendingTransaction?.port == token else { return }
        pendingTransaction = nil
    }

    nonisolated static func toolActivity(for rawName: String) -> ConversationToolActivity? {
        rawName == "web_search" ? .externalInformationLookup : nil
    }

    private static func coarseFailure(for error: Error) -> ConversationAgentStreamError {
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
