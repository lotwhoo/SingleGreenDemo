import Foundation
import LLMCore

/// OpenAI-compatible Chat Completions request payload.
public struct LLMChatRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [LLMMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool
    public var tools: [LLMTool]?
    public var thinking: LLMThinkingConfiguration?
    public var responseFormat: LLMResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools, thinking
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case responseFormat = "response_format"
    }

    public init(
        model: String,
        messages: [LLMMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [LLMTool]? = nil
    ) {
        self.init(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: stream,
            tools: tools,
            thinking: nil,
            responseFormat: nil
        )
    }

    public init(
        model: String,
        messages: [LLMMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [LLMTool]? = nil,
        thinking: LLMThinkingConfiguration?
    ) {
        self.init(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: stream,
            tools: tools,
            thinking: thinking,
            responseFormat: nil
        )
    }

    public init(
        model: String,
        messages: [LLMMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [LLMTool]? = nil,
        thinking: LLMThinkingConfiguration?,
        responseFormat: LLMResponseFormat?
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
        self.thinking = thinking
        self.responseFormat = responseFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([LLMMessage].self, forKey: .messages)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        stream = try container.decode(Bool.self, forKey: .stream)
        tools = try container.decodeIfPresent([LLMTool].self, forKey: .tools)
        responseFormat = try container.decodeIfPresent(LLMResponseFormat.self, forKey: .responseFormat)
        if let wireThinking = try container.decodeIfPresent(WireThinking.self, forKey: .thinking) {
            thinking = LLMThinkingConfiguration(
                mode: wireThinking.type,
                effort: try container.decodeIfPresent(
                    LLMThinkingConfiguration.Effort.self,
                    forKey: .reasoningEffort
                )
            )
        } else {
            thinking = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        if let thinking {
            try container.encode(WireThinking(type: thinking.mode), forKey: .thinking)
            try container.encodeIfPresent(thinking.effort, forKey: .reasoningEffort)
        }
    }

    private struct WireThinking: Codable {
        let type: LLMThinkingConfiguration.Mode
    }
}

/// OpenAI-compatible Chat Completions response payload.
public struct LLMChatResponse: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public var index: Int?
        public var message: LLMMessage
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public var id: String?
    public var choices: [Choice]
    public var usage: Usage?
}

/// OpenAI-compatible SSE chunk payload.
public struct LLMSSEChunk: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public struct Delta: Codable, Sendable {
            public var content: String?
            public var reasoningContent: String?
            public var toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        public struct ToolCallDelta: Codable, Sendable, Equatable {
            public struct FunctionDelta: Codable, Sendable, Equatable {
                public var name: String?
                public var arguments: String?
            }

            public var index: Int
            public var id: String?
            public var type: String?
            public var function: FunctionDelta?
        }

        public var index: Int?
        public var delta: Delta?
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    public var choices: [Choice]
}

/// OpenAI-compatible error payload (`{"error":{"message":...}}`).
public struct LLMErrorResponse: Codable, Sendable {
    public struct ErrorBody: Codable, Sendable {
        public var message: String?
        public var type: String?
        public var code: String?
    }

    public var error: ErrorBody?
}
