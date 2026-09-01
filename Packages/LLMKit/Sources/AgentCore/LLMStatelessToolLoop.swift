import Foundation
import LLMCore

/// Executes a bounded, non-streaming tool loop without retaining conversation context.
/// Callers own every input message and receive one final validated assistant message.
public struct LLMStatelessToolLoop: Sendable {
    public struct Config: Sendable, Equatable {
        public var temperature: Double?
        public var maxTokens: Int?
        public var maxToolRounds: Int

        public init(
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            maxToolRounds: Int = 3
        ) {
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.maxToolRounds = maxToolRounds
        }
    }

    public struct Result: Sendable, Equatable {
        public let message: LLMMessage
        public let executedToolNames: [String]

        public init(message: LLMMessage, executedToolNames: [String]) {
            self.message = message
            self.executedToolNames = executedToolNames
        }
    }

    private let transport: any LLMChatTransport
    private let executor: any LLMToolExecutor
    private let config: Config

    public init(
        transport: any LLMChatTransport,
        executor: any LLMToolExecutor,
        config: Config = .init()
    ) {
        self.transport = transport
        self.executor = executor
        self.config = config
    }

    public func complete(messages initialMessages: [LLMMessage]) async throws -> Result {
        var messages = initialMessages
        let tools = executor.toolDefinitions.isEmpty ? nil : executor.toolDefinitions
        var executedToolNames: [String] = []

        for _ in 0..<config.maxToolRounds {
            try Task.checkCancellation()
            let reply = try await transport.completeMessage(
                messages: messages,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                tools: tools
            )
            try Task.checkCancellation()
            messages.append(reply)

            if let toolCalls = reply.toolCalls, !toolCalls.isEmpty {
                try LLMToolRoundValidator.validate(toolCalls, content: reply.content)
                for call in toolCalls {
                    try Task.checkCancellation()
                    let result = try await executor.execute(call)
                    try Task.checkCancellation()
                    executedToolNames.append(call.function.name)
                    messages.append(
                        LLMMessage(role: .tool, content: result, toolCallID: call.id)
                    )
                }
                continue
            }

            guard !(reply.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                throw LLMAgentError.emptyResponse
            }
            return Result(message: reply, executedToolNames: executedToolNames)
        }
        throw LLMAgentError.tooManyToolRounds
    }
}

enum LLMToolRoundValidator {
    static func validate(_ toolCalls: [LLMToolCall], content: String?) throws {
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMAgentError.mixedContentAndToolCall
        }
        for (index, call) in toolCalls.enumerated() {
            switch call.validationFailure() {
            case .incomplete:
                throw LLMAgentError.incompleteToolCall(index: index)
            case .malformedArguments:
                throw LLMAgentError.malformedToolCallArguments(index: index)
            case nil:
                continue
            }
        }
    }
}
