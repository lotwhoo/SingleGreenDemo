import Foundation

/// Agent 依赖的语义传输端口。
///
/// 新的 LLM 供应商只需适配此协议；Agent 的工具循环、上下文事务和 UI 无需修改。
public protocol LLMChatTransport: Sendable {
    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error>
}

extension LLMChatClient: LLMChatTransport {}
