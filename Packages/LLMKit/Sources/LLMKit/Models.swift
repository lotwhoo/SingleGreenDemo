import Foundation

// MARK: - 消息

/// LLM 对话消息（OpenAI 兼容格式）。
public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    /// Provider reasoning retained only for protocol replay; presentation layers must ignore it.
    public var reasoningContent: String?
    /// 助手消息携带的工具调用（模型请求执行工具时非空）。
    public var toolCalls: [LLMToolCall]?
    /// tool 角色消息关联的工具调用 id。
    public var toolCallID: String?

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
        self.reasoningContent = nil
        self.toolCalls = nil
        self.toolCallID = nil
    }

    public init(role: Role, content: String?,
                toolCalls: [LLMToolCall]? = nil,
                toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = nil
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public init(role: Role, content: String?,
                reasoningContent: String?,
                toolCalls: [LLMToolCall]? = nil,
                toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

// MARK: - 请求

/// Provider-neutral opt-in for models that expose an internal thinking mode.
public struct LLMThinkingConfiguration: Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case enabled
        case disabled
    }

    public enum Effort: String, Codable, Sendable, Equatable {
        case low
        case high
        case maximum = "max"
    }

    public let mode: Mode
    public let effort: Effort?

    public init(mode: Mode, effort: Effort? = nil) {
        self.mode = mode
        self.effort = mode == .enabled ? effort : nil
    }

    public static func enabled(effort: Effort? = nil) -> Self {
        .init(mode: .enabled, effort: effort)
    }

    public static let disabled = Self(mode: .disabled)
}

/// Provider-neutral structured response request for OpenAI-compatible APIs.
public struct LLMResponseFormat: Codable, Sendable, Equatable {
    public enum FormatType: String, Codable, Sendable, Equatable {
        case jsonObject = "json_object"
    }

    public let type: FormatType

    public init(type: FormatType) {
        self.type = type
    }

    public static let jsonObject = Self(type: .jsonObject)
}

/// Chat Completions 请求体。
public struct LLMChatRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [LLMMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool
    /// 可用工具列表（Function Calling）。
    public var tools: [LLMTool]?
    /// Explicit thinking policy. Nil preserves generic OpenAI-compatible payloads.
    public var thinking: LLMThinkingConfiguration?
    /// Optional structured response contract. Nil preserves existing payloads.
    public var responseFormat: LLMResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools, thinking
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case responseFormat = "response_format"
    }

    public init(model: String, messages: [LLMMessage],
                temperature: Double? = nil, maxTokens: Int? = nil,
                stream: Bool = false, tools: [LLMTool]? = nil) {
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

    public init(model: String, messages: [LLMMessage],
                temperature: Double? = nil, maxTokens: Int? = nil,
                stream: Bool = false, tools: [LLMTool]? = nil,
                thinking: LLMThinkingConfiguration?) {
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

    public init(model: String, messages: [LLMMessage],
                temperature: Double? = nil, maxTokens: Int? = nil,
                stream: Bool = false, tools: [LLMTool]? = nil,
                thinking: LLMThinkingConfiguration?,
                responseFormat: LLMResponseFormat?) {
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

// MARK: - 响应

/// Chat Completions 响应体。
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

/// SSE 流式分块响应。
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

/// Chat Completions SSE 输出。正文和工具片段按到达顺序发布，最后发布拼装后的完整消息。
public enum LLMStreamingEvent: Sendable, Equatable {
    case contentDelta(String)
    case toolCallDelta(index: Int, id: String?, type: String?, functionName: String?, arguments: String?)
    case completed(LLMMessage)
}

public enum LLMStreamingError: Error, LocalizedError, Sendable, Equatable {
    case incompleteToolCall(index: Int)
    case malformedToolCallArguments(index: Int)
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .incompleteToolCall(let index):
            return "流式工具调用 \(index) 不完整"
        case .malformedToolCallArguments(let index):
            return "流式工具调用 \(index) 的参数不是完整 JSON 对象"
        case .incompleteStream:
            return "流式响应在结束信号前中断"
        }
    }
}

// MARK: - 错误

/// OpenAI 兼容错误响应体（{"error": {"message": ...}}）。
public struct LLMErrorResponse: Codable, Sendable {
    public struct ErrorBody: Codable, Sendable {
        public var message: String?
        public var type: String?
        public var code: String?
    }
    public var error: ErrorBody?
}

public struct LLMAPIError: Error, LocalizedError, Sendable {
    public let statusCode: Int
    public let message: String

    public var errorDescription: String? {
        "API 错误 (\(statusCode)): \(message)"
    }
}
