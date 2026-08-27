import Foundation

/// OpenAI 兼容 Chat Completions 客户端。
/// 默认指向 DeepSeek（https://api.deepseek.com/v1，模型 deepseek-v4-flash），
/// baseURL / model 可配置以对接任意兼容服务。
public actor LLMChatClient {

    public struct Config: Sendable, Equatable {
        public var baseURL: URL
        public var apiKey: String
        public var model: String
        public var timeoutInterval: TimeInterval
        public var retryConfig: LLMRetryConfig

        public init(baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
                    apiKey: String,
                    model: String = "deepseek-v4-flash",
                    timeoutInterval: TimeInterval = 60,
                    retryConfig: LLMRetryConfig = .init()) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.timeoutInterval = timeoutInterval
            self.retryConfig = retryConfig
        }
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// 发送一轮对话，返回模型回复文本。
    public func complete(messages: [LLMMessage],
                         temperature: Double? = nil,
                         maxTokens: Int? = nil) async throws -> String {
        let message = try await completeMessage(messages: messages,
                                                temperature: temperature,
                                                maxTokens: maxTokens)
        guard let content = message.content, !content.isEmpty else {
            throw LLMAPIError(statusCode: 200, message: "响应中没有内容")
        }
        return content
    }

    /// 发送一轮对话（可选工具），返回完整消息（含 tool_calls，用于 Function Calling 场景）。
    public func completeMessage(messages: [LLMMessage],
                                temperature: Double? = nil,
                                maxTokens: Int? = nil,
                                tools: [LLMTool]? = nil) async throws -> LLMMessage {
        let body = LLMChatRequest(model: config.model, messages: messages,
                                  temperature: temperature, maxTokens: maxTokens,
                                  stream: false, tools: tools)
        let data = try await send(body: body)

        let chat = try JSONDecoder().decode(LLMChatResponse.self, from: data)
        guard let message = chat.choices.first?.message else {
            throw LLMAPIError(statusCode: 200, message: "响应中没有消息")
        }
        return message
    }

    /// 流式对话：返回增量文本流（SSE），逐段 yield，结束 finish。
    /// 建连阶段失败（首个增量前）自动重试；已产出内容后失败不重试（避免重复输出）。
    public nonisolated func completeStreaming(messages: [LLMMessage],
                                              temperature: Double? = nil,
                                              maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let body = LLMChatRequest(model: config.model, messages: messages,
                                          temperature: temperature, maxTokens: maxTokens,
                                          stream: true)
                var attempt = 0
                var emitted = false

                while true {
                    do {
                        let request = try makeRequest(body: body)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw LLMAPIError(statusCode: -1, message: "无效的 HTTP 响应")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            throw LLMAPIError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
                        }

                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let chunk = try? JSONDecoder().decode(LLMSSEChunk.self, from: data),
                                  let delta = chunk.choices.first?.delta?.content,
                                  !delta.isEmpty else { continue }
                            emitted = true
                            continuation.yield(delta)
                        }
                        continuation.finish()
                        return
                    } catch {
                        // 已产出内容或不可重试 → 直接失败
                        guard !emitted, attempt < config.retryConfig.maxRetries,
                              config.retryConfig.isRetryable(error) else {
                            continuation.finish(throwing: error)
                            return
                        }
                        attempt += 1
                        try? await Task.sleep(for: .seconds(config.retryConfig.delay(forAttempt: attempt - 1)))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    /// 构造标准 POST 请求。
    private nonisolated func makeRequest(body: LLMChatRequest) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// 发送非流式请求并校验响应，带指数退避重试。
    private func send(body: LLMChatRequest) async throws -> Data {
        let request = try makeRequest(body: body)
        var attempt = 0

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMAPIError(statusCode: -1, message: "无效的 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let errBody = try? JSONDecoder().decode(LLMErrorResponse.self, from: data)
                    let msg = errBody?.error?.message
                        ?? String(data: data, encoding: .utf8)
                        ?? "HTTP \(http.statusCode)"
                    throw LLMAPIError(statusCode: http.statusCode, message: msg)
                }
                return data
            } catch {
                guard attempt < config.retryConfig.maxRetries,
                      config.retryConfig.isRetryable(error) else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: .seconds(config.retryConfig.delay(forAttempt: attempt - 1)))
            }
        }
    }
}
