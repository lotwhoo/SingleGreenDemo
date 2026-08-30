import Foundation

/// 带工具的 LLM 智能体：自动执行「模型请求工具 → 执行 → 回传结果 → 再请求」循环，
/// 直到模型给出最终回答。调用方只需 `send()` 一句。
public actor LLMAgent {

    public struct Config: Sendable, Equatable {
        public var systemPrompt: String?
        public var maxMessages: Int
        /// Retained conversation-context budget used by `LLMChatContext`.
        public var maxTokens: Int
        /// Optional provider completion cap. `nil` preserves provider defaults.
        public var completionMaxTokens: Int?
        public var maxToolRounds: Int
        public var temperature: Double

        public init(systemPrompt: String? = nil,
                    maxMessages: Int = 20,
                    maxTokens: Int = 4000,
                    maxToolRounds: Int = 3,
                    temperature: Double = 0.7) {
            self.init(
                systemPrompt: systemPrompt,
                maxMessages: maxMessages,
                maxTokens: maxTokens,
                maxToolRounds: maxToolRounds,
                temperature: temperature,
                completionMaxTokens: nil
            )
        }

        public init(systemPrompt: String? = nil,
                    maxMessages: Int = 20,
                    maxTokens: Int = 4000,
                    maxToolRounds: Int = 3,
                    temperature: Double = 0.7,
                    completionMaxTokens: Int?) {
            self.systemPrompt = systemPrompt
            self.maxMessages = maxMessages
            self.maxTokens = maxTokens
            self.completionMaxTokens = completionMaxTokens
            self.maxToolRounds = maxToolRounds
            self.temperature = temperature
        }
    }

    private let transport: any LLMChatTransport
    private let executor: LLMToolExecutor
    private let config: Config
    private var context: LLMChatContext
    private var transactionGeneration = 0
    private var activeTransaction: Int?
    private var pendingCompletion: PendingCompletion?
    private var rollbackCompletion: RollbackCompletion?

    public init(
        transport: any LLMChatTransport,
        executor: LLMToolExecutor,
        config: Config
    ) {
        self.transport = transport
        self.executor = executor
        self.config = config
        self.context = LLMChatContext(systemPrompt: config.systemPrompt,
                                      maxMessages: config.maxMessages,
                                      maxTokens: config.maxTokens)
    }

    /// 保留旧构造器的源码兼容；新代码应依赖 `LLMChatTransport`。
    @available(*, deprecated, renamed: "init(transport:executor:config:)")
    public init(client: LLMChatClient, executor: LLMToolExecutor, config: Config) {
        self.transport = client
        self.executor = executor
        self.config = config
        self.context = LLMChatContext(systemPrompt: config.systemPrompt,
                                      maxMessages: config.maxMessages,
                                      maxTokens: config.maxTokens)
    }

    /// 发送用户消息，自动执行工具循环，返回最终回答文本。
    /// `onToolCall` 在每次执行工具前回调（用于 UI 显示"正在搜索…"）。
    public func send(_ userText: String,
                     onToolCall: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        let transaction = beginTransaction()
        var workingContext = context
        workingContext.appendUser(userText)
        do {
            var messages = workingContext.chatMessages
            let tools = executor.toolDefinitions.isEmpty ? nil : executor.toolDefinitions

            for _ in 0..<config.maxToolRounds {
                try Task.checkCancellation()
                let reply = try await transport.completeMessage(
                    messages: messages,
                    temperature: config.temperature,
                    maxTokens: config.completionMaxTokens,
                    tools: tools
                )
                try ensureActive(transaction)
                messages.append(reply)

                if let toolCalls = reply.toolCalls, !toolCalls.isEmpty {
                    // Non-streaming tool preambles are provider protocol data.
                    // They were never published, so discard them and execute the tools.
                    try validateToolRound(toolCalls, content: nil)
                    // 执行所有工具调用，结果作为 tool 消息回传
                    for call in toolCalls {
                        try Task.checkCancellation()
                        await onToolCall?(call.function.name)
                        try ensureActive(transaction)
                        let result = try await executor.execute(call)
                        try ensureActive(transaction)
                        messages.append(LLMMessage(role: .tool, content: result, toolCallID: call.id))
                    }
                    continue
                }

                // 无工具调用 → 最终回答
                let answer = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { throw LLMAgentError.emptyResponse }
                workingContext.appendAssistant(
                    answer,
                    reasoningContent: tools == nil ? nil : reply.reasoningContent
                )
                try commit(workingContext, transaction: transaction)
                return answer
            }
            throw LLMAgentError.tooManyToolRounds
        } catch {
            abort(transaction)
            throw error
        }
    }

    /// 发送用户消息并流式发布最终回答。
    ///
    /// The full exchange remains a context transaction. Finalization stages the
    /// context, while the caller explicitly commits or aborts after downstream
    /// delivery. Failed, cancelled, or mixed content/tool rounds are discarded.
    public func sendStreaming(_ userText: String) -> LLMAgentStreamingTransaction {
        let transaction = beginTransaction()
        var initialContext = context
        initialContext.appendUser(userText)
        let events = AsyncThrowingStream<LLMAgentEvent, Error> { continuation in
            let task = Task {
                await runStreaming(
                    workingContext: initialContext,
                    transaction: transaction,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LLMAgentStreamingTransaction(
            token: LLMAgentTransactionToken(generation: transaction),
            events: events
        )
    }

    /// Commits a successfully finalized streaming response to conversation context.
    ///
    /// Callers should acknowledge only after every downstream consumer has accepted
    /// the completion. Merely receiving or buffering `.completed` does not commit.
    public func commit(_ token: LLMAgentTransactionToken) throws {
        try Task.checkCancellation()
        guard let pendingCompletion,
              pendingCompletion.transaction == token.generation else {
            throw LLMAgentTransactionError.notPending
        }
        rollbackCompletion = RollbackCompletion(
            transaction: token.generation,
            context: context
        )
        context = pendingCompletion.context
        self.pendingCompletion = nil
    }

    /// Discards a staged streaming response. This operation is idempotent.
    public func abort(_ token: LLMAgentTransactionToken) {
        abort(token.generation)
    }

    /// 最近对话历史（不含 system）。
    ///
    /// Provider-only reasoning is intentionally redacted from the public projection.
    /// Internal requests continue to use `context.chatMessages` so tool-enabled
    /// thinking turns can replay the provider protocol without leaking it to UI or logs.
    public var chatMessages: [LLMMessage] {
        context.chatMessages.map { message in
            var redacted = message
            redacted.reasoningContent = nil
            return redacted
        }
    }

    /// 重置上下文（保留 system prompt）。
    public func clearContext() {
        transactionGeneration += 1
        activeTransaction = nil
        pendingCompletion = nil
        rollbackCompletion = nil
        context.clear()
    }

    private func runStreaming(
        workingContext initialContext: LLMChatContext,
        transaction: Int,
        continuation: AsyncThrowingStream<LLMAgentEvent, Error>.Continuation
    ) async {
        var workingContext = initialContext
        do {
            var messages = workingContext.chatMessages
            let tools = executor.toolDefinitions.isEmpty ? nil : executor.toolDefinitions

            for _ in 0..<config.maxToolRounds {
                try Task.checkCancellation()
                try ensureActive(transaction)
                var completedMessage: LLMMessage?
                var roundContent = ""
                var isToolRound = false

                for try await event in transport.completeMessageStreaming(
                    messages: messages,
                    temperature: config.temperature,
                    maxTokens: config.completionMaxTokens,
                    tools: tools
                ) {
                    try Task.checkCancellation()
                    try ensureActive(transaction)
                    switch event {
                    case .contentDelta(let delta):
                        guard !isToolRound else {
                            throw LLMAgentStreamError.discardPartialMixedContentAndToolCall
                        }
                        roundContent += delta
                        continuation.yield(.contentDelta(delta))

                    case .toolCallDelta:
                        guard roundContent.isEmpty else {
                            throw LLMAgentStreamError.discardPartialMixedContentAndToolCall
                        }
                        isToolRound = true

                    case .completed(let message):
                        completedMessage = message
                    }
                }

                try Task.checkCancellation()
                try ensureActive(transaction)
                guard let reply = completedMessage else {
                    throw LLMAgentError.missingCompletedMessage
                }
                messages.append(reply)

                if let toolCalls = reply.toolCalls, !toolCalls.isEmpty {
                    guard roundContent.isEmpty else {
                        throw LLMAgentStreamError.discardPartialMixedContentAndToolCall
                    }
                    try validateToolRound(toolCalls, content: roundContent)
                    for call in toolCalls {
                        try Task.checkCancellation()
                        try ensureActive(transaction)
                        continuation.yield(.toolCall(call.function.name))
                        let result = try await executor.execute(call)
                        try ensureActive(transaction)
                        messages.append(LLMMessage(role: .tool, content: result, toolCallID: call.id))
                    }
                    continue
                }

                let answer = reply.content ?? roundContent
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LLMAgentError.emptyResponse
                }
                workingContext.appendAssistant(
                    answer,
                    reasoningContent: tools == nil ? nil : reply.reasoningContent
                )
                try stageCompletion(workingContext, transaction: transaction)
                continuation.yield(.completed(answer))
                continuation.finish()
                return
            }
            throw LLMAgentError.tooManyToolRounds
        } catch {
            abort(transaction)
            continuation.finish(throwing: error)
        }
    }

    private func beginTransaction() -> Int {
        transactionGeneration += 1
        activeTransaction = transactionGeneration
        pendingCompletion = nil
        rollbackCompletion = nil
        return transactionGeneration
    }

    private func ensureActive(_ transaction: Int) throws {
        guard activeTransaction == transaction else { throw CancellationError() }
    }

    private func validateToolRound(_ toolCalls: [LLMToolCall], content: String?) throws {
        try LLMToolRoundValidator.validate(toolCalls, content: content)
    }

    private func commit(_ newContext: LLMChatContext, transaction: Int) throws {
        try Task.checkCancellation()
        try ensureActive(transaction)
        context = newContext
        activeTransaction = nil
    }

    private func stageCompletion(_ newContext: LLMChatContext, transaction: Int) throws {
        try Task.checkCancellation()
        try ensureActive(transaction)
        pendingCompletion = PendingCompletion(transaction: transaction, context: newContext)
        activeTransaction = nil
    }

    private func abort(_ transaction: Int) {
        if activeTransaction == transaction { activeTransaction = nil }
        if pendingCompletion?.transaction == transaction { pendingCompletion = nil }
        if rollbackCompletion?.transaction == transaction {
            context = rollbackCompletion?.context ?? context
            rollbackCompletion = nil
        }
    }

    private struct PendingCompletion {
        let transaction: Int
        let context: LLMChatContext
    }

    private struct RollbackCompletion {
        let transaction: Int
        let context: LLMChatContext
    }
}

/// Opaque identity for one streaming context transaction.
public struct LLMAgentTransactionToken: Sendable, Equatable, Hashable {
    fileprivate let generation: Int
}

/// A stream plus the token required to commit or abort its staged context.
public struct LLMAgentStreamingTransaction: AsyncSequence, Sendable {
    public typealias Element = LLMAgentEvent
    public typealias AsyncIterator = AsyncThrowingStream<LLMAgentEvent, Error>.Iterator

    public let token: LLMAgentTransactionToken
    public let events: AsyncThrowingStream<LLMAgentEvent, Error>

    fileprivate init(
        token: LLMAgentTransactionToken,
        events: AsyncThrowingStream<LLMAgentEvent, Error>
    ) {
        self.token = token
        self.events = events
    }

    public func makeAsyncIterator() -> AsyncIterator {
        events.makeAsyncIterator()
    }
}

public enum LLMAgentTransactionError: Error, LocalizedError, Sendable, Equatable {
    case notPending

    public var errorDescription: String? {
        "The streaming response is not pending acknowledgement."
    }
}

public enum LLMAgentError: Error, LocalizedError, Sendable, Equatable {
    case tooManyToolRounds
    case emptyResponse
    case missingCompletedMessage
    case mixedContentAndToolCall
    case incompleteToolCall(index: Int)
    case malformedToolCallArguments(index: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyToolRounds: return "工具调用轮数超过上限，请稍后再试"
        case .emptyResponse: return "模型返回了空回答"
        case .missingCompletedMessage: return "流式响应未正常完成"
        case .mixedContentAndToolCall: return "模型同时返回了正文和工具调用"
        case .incompleteToolCall(let index): return "工具调用 \(index) 不完整"
        case .malformedToolCallArguments(let index):
            return "工具调用 \(index) 的参数不是完整 JSON 对象"
        }
    }
}

/// 需要上层丢弃已显示 partial 的非规范流式错误。
public enum LLMAgentStreamError: Error, LocalizedError, Sendable, Equatable {
    case discardPartialMixedContentAndToolCall

    public var errorDescription: String? {
        "模型同时返回正文和工具调用，已丢弃不可信的部分正文"
    }
}

public enum LLMAgentEvent: Sendable, Equatable {
    case toolCall(String)
    case contentDelta(String)
    case completed(String)
}

/// 空工具执行器：不提供任何工具（关闭联网搜索时用，模型不会触发搜索）。
public struct NoopToolExecutor: LLMToolExecutor {
    public init() {}
    public var toolDefinitions: [LLMTool] { [] }
    public func execute(_ call: LLMToolCall) async throws -> String {
        throw LLMAgentError.tooManyToolRounds
    }
}
