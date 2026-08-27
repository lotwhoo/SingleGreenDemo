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

    private let client: LLMChatClient
    private let executor: LLMToolExecutor
    private let config: Config
    private var context: LLMChatContext

    public init(client: LLMChatClient, executor: LLMToolExecutor, config: Config) {
        self.client = client
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
        // 一轮请求是一个事务：失败或取消时恢复旧上下文，避免留下没有助手回复的孤立用户消息。
        let contextBeforeRequest = context
        context.appendUser(userText)
        do {
            var messages = context.chatMessages
            let tools = executor.toolDefinitions.isEmpty ? nil : executor.toolDefinitions

            for _ in 0..<config.maxToolRounds {
                try Task.checkCancellation()
                let reply = try await client.completeMessage(
                    messages: messages,
                    temperature: config.temperature,
                    tools: tools
                )
                messages.append(reply)

                if let toolCalls = reply.toolCalls, !toolCalls.isEmpty {
                    // 执行所有工具调用，结果作为 tool 消息回传
                    for call in toolCalls {
                        try Task.checkCancellation()
                        await onToolCall?(call.function.name)
                        let result = try await executor.execute(call)
                        messages.append(LLMMessage(role: .tool, content: result, toolCallID: call.id))
                    }
                    continue
                }

                // 无工具调用 → 最终回答
                let answer = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { throw LLMAgentError.emptyResponse }
                context.appendAssistant(answer)
                return answer
            }
            throw LLMAgentError.tooManyToolRounds
        } catch {
            context = contextBeforeRequest
            throw error
        }
    }

    /// 最近对话历史（不含 system）。
    public var chatMessages: [LLMMessage] { context.chatMessages }

    /// 重置上下文（保留 system prompt）。
    public func clearContext() {
        context.clear()
    }
}

public enum LLMAgentError: Error, LocalizedError, Sendable {
    case tooManyToolRounds
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .tooManyToolRounds: return "工具调用轮数超过上限，请稍后再试"
        case .emptyResponse: return "模型返回了空回答"
        }
    }
}

/// 空工具执行器：不提供任何工具（关闭联网搜索时用，模型不会触发搜索）。
public struct NoopToolExecutor: LLMToolExecutor {
    public init() {}
    public var toolDefinitions: [LLMTool] { [] }
    public func execute(_ call: LLMToolCall) async throws -> String {
        throw LLMAgentError.tooManyToolRounds
    }
}
