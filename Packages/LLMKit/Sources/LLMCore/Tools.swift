import Foundation

// Provider-neutral tool contracts and JSON values.

// MARK: - 工具调用（OpenAI 兼容 Function Calling）

/// 工具定义（请求侧）：`{"type":"function","function":{...}}`
public struct LLMTool: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        /// JSON Schema 对象（参数定义）。
        public var parameters: [String: AnyJSON]

        enum CodingKeys: String, CodingKey { case name, description, parameters }

        public init(name: String, description: String, parameters: [String: AnyJSON]) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            parameters = try c.decodeIfPresent([String: AnyJSON].self, forKey: .parameters) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            try c.encode(parameters, forKey: .parameters)
        }
    }

    public var type: String
    public var function: Function

    public init(type: String = "function", function: Function) {
        self.type = type
        self.function = function
    }
}

/// 模型发起的工具调用（响应侧）。
public struct LLMToolCall: Codable, Sendable, Equatable {
    public struct FunctionCall: Codable, Sendable, Equatable {
        public var name: String
        /// 参数的 JSON 字符串（如 `{"query":"北京天气"}`）。
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var id: String
    public var type: String?
    public var function: FunctionCall

    public init(id: String, type: String?, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

package enum LLMToolCallValidationFailure: Equatable {
    case incomplete
    case malformedArguments
}

package extension LLMToolCall {
    /// Validation is intentionally deferred until every streamed fragment has
    /// been assembled. Function arguments must be a complete JSON object before
    /// an agent may hand the call to an executor.
    func validationFailure() -> LLMToolCallValidationFailure? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = function.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArguments = function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty, !trimmedArguments.isEmpty else {
            return .incomplete
        }
        guard let data = trimmedArguments.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] else {
            return .malformedArguments
        }
        return nil
    }
}

/// 简易 JSON 值类型（用于工具参数 Schema / arguments 解析）。
public enum AnyJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let a = try? container.decode([AnyJSON].self) { self = .array(a) }
        else if let o = try? container.decode([String: AnyJSON].self) { self = .object(o) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知 JSON 值") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

/// 工具调用执行器：由搜索/其他工具实现。
public protocol LLMToolExecutor: Sendable {
    /// 执行一个工具调用，返回给模型的文本结果。
    func execute(_ call: LLMToolCall) async throws -> String
    /// 该执行器支持的工具定义（用于请求 tools 参数）。
    var toolDefinitions: [LLMTool] { get }
}
