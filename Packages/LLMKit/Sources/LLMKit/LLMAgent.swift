import Foundation

/// 带工具的 LLM 智能体：自动执行「模型请求工具 → 执行 → 回传结果 → 再请求」循环，
/// 直到模型给出最终回答。调用方只需 `send()` 一句。
public actor LLMAgent {

    public struct Config: Sendable, Equatable {
        public var systemPrompt: String?
        public var maxMessages: Int
        public var maxTokens: Int
        public var maxToolRounds: Int
        public var temperature: Double

        public init(systemPrompt: String? = nil,
                    maxMessages: Int = 20,
                    maxTokens: Int = 4000,
                    maxToolRounds: Int = 3,
                    temperature: Double = 0.7) {
            self.systemPrompt = systemPrompt
            self.maxMessages = maxMessages
            self.maxTokens = maxTokens
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
                    maxTokens: nil,
                    tools: tools
                )
                try ensureActive(transaction)
                messages.append(reply)

                if let toolCalls = reply.toolCalls, !toolCalls.isEmpty {
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
                workingContext.appendAssistant(answer)
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
    /// 整轮对话仍是一个上下文事务：只有最终回答成功时才提交；失败、取消或
    /// 混合的正文/工具响应都回滚。工具轮不会向 UI 发布伪正文。
    public func sendStreaming(_ userText: String) -> AsyncThrowingStream<LLMAgentEvent, Error> {
        let transaction = beginTransaction()
        var initialContext = context
        initialContext.appendUser(userText)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await runStreaming(
                    workingContext: initialContext,
                    transaction: transaction,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 最近对话历史（不含 system）。
    public var chatMessages: [LLMMessage] { context.chatMessages }

    /// 重置上下文（保留 system prompt）。
    public func clearContext() {
        transactionGeneration += 1
        activeTransaction = nil
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
                    maxTokens: nil,
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
                workingContext.appendAssistant(answer)
                try commit(workingContext, transaction: transaction)
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
        return transactionGeneration
    }

    private func ensureActive(_ transaction: Int) throws {
        guard activeTransaction == transaction else { throw CancellationError() }
    }

    private func commit(_ newContext: LLMChatContext, transaction: Int) throws {
        try Task.checkCancellation()
        try ensureActive(transaction)
        context = newContext
        activeTransaction = nil
    }

    private func abort(_ transaction: Int) {
        if activeTransaction == transaction { activeTransaction = nil }
    }
}

public enum LLMAgentError: Error, LocalizedError, Sendable {
    case tooManyToolRounds
    case emptyResponse
    case missingCompletedMessage

    public var errorDescription: String? {
        switch self {
        case .tooManyToolRounds: return "工具调用轮数超过上限，请稍后再试"
        case .emptyResponse: return "模型返回了空回答"
        case .missingCompletedMessage: return "流式响应未正常完成"
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
