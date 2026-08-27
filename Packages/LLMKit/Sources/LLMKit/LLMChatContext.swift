import Foundation

/// 多轮对话上下文管理：自动维护消息历史、裁剪长度、过滤空消息。
///
/// ```swift
/// var context = LLMChatContext(systemPrompt: "你是语音助手")
/// context.appendUser("你好")
/// // ...调用 LLMChatClient.complete(messages: context.chatMessages)...
/// context.appendAssistant("你好！有什么可以帮你？")
/// ```
public struct LLMChatContext: Sendable, Equatable {
    /// 系统提示词（可选）。
    public var systemPrompt: String?
    /// 保留的最大消息条数（超过后丢弃最早消息）。
    public var maxMessages: Int
    /// 上下文 token 预算（chatMessages 按预算从旧到新裁剪，超出丢弃最早消息）。
    public var maxTokens: Int
    /// 历史消息（不包含 system）。
    public private(set) var messages: [LLMMessage]

    public init(systemPrompt: String? = nil, maxMessages: Int = 20, maxTokens: Int = 4000) {
        self.systemPrompt = systemPrompt
        self.maxMessages = maxMessages
        self.maxTokens = maxTokens
        self.messages = []
    }

    /// 追加用户消息（自动去除首尾空白、忽略空文本）。
    public mutating func appendUser(_ text: String) {
        append(.user, text)
    }

    /// 追加助手回复。
    public mutating func appendAssistant(_ text: String) {
        append(.assistant, text)
    }

    public mutating func append(_ role: LLMMessage.Role, _ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(LLMMessage(role: role, content: trimmed))
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }

    /// 清空历史（保留 systemPrompt）。
    public mutating func clear() {
        messages.removeAll()
    }

    /// 最终发送给模型的完整消息列表：
    /// system（可选）+ 历史；先按条数裁剪，再按 token 预算从旧到新丢弃（保留最近的）。
    public var chatMessages: [LLMMessage] {
        var result: [LLMMessage] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            result.append(LLMMessage(role: .system, content: systemPrompt))
        }
        let recent = messages.filter { !($0.content ?? "").isEmpty }

        // token 预算裁剪：从最旧消息开始丢弃，直到总估算 ≤ maxTokens
        if maxTokens > 0 {
            let recentTokens = recent.reduce(0) { $0 + LLMTokenEstimator.estimate($1.content ?? "") }
            var total = result.reduce(0) { $0 + LLMTokenEstimator.estimate($1.content ?? "") } + recentTokens
            var kept = recent
            while kept.count > 0, total > maxTokens {
                let removed = kept.removeFirst()
                total -= LLMTokenEstimator.estimate(removed.content ?? "")
            }
            result += kept
        } else {
            result += recent
        }
        return result
    }
}
