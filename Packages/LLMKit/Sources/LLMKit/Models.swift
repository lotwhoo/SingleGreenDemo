import Foundation

// MARK: - 消息

/// LLM 对话消息（OpenAI 兼容格式）。
public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    /// 助手消息携带的工具调用（模型请求执行工具时非空）。
    public var toolCalls: [LLMToolCall]?
    /// tool 角色消息关联的工具调用 id。
    public var toolCallID: String?

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
        self.toolCalls = nil
        self.toolCallID = nil
    }

    public init(role: Role, content: String?,
                toolCalls: [LLMToolCall]? = nil,
                toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

// MARK: - 请求

/// Chat Completions 请求体。
public struct LLMChatRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [LLMMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool
    /// 可用工具列表（Function Calling）。
    public var tools: [LLMTool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools
        case maxTokens = "max_tokens"
    }

    public init(model: String, messages: [LLMMessage],
                temperature: Double? = nil, maxTokens: Int? = nil,
                stream: Bool = false, tools: [LLMTool]? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
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
        }
        public var delta: Delta?
    }
    public var choices: [Choice]
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
