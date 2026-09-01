import Foundation

// Provider-neutral chat and streaming value types.

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

// MARK: - Provider-neutral request options

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

/// Provider-neutral structured response request.
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

public struct LLMAPIError: Error, LocalizedError, Sendable {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? {
        "API 错误 (\(statusCode)): \(message)"
    }
}
