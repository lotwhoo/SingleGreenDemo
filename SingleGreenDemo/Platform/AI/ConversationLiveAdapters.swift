import Foundation
import LLMKit
import VoiceChatCore

/// VoiceChatCore ASR 到 App 端口事件的唯一生产适配器。
final class VoiceChatSpeechRecognitionSession: SpeechRecognitionSession {
    let events: AsyncStream<SpeechRecognitionEvent>

    private let base: ASRSession
    private var bridgeTask: Task<Void, Never>?

    init(configuration: SpeechRecognitionConfiguration) {
        let base = ASRSession(config: .init(
            apiKey: configuration.apiKey,
            resourceID: configuration.resourceID,
            language: configuration.language,
            hotwords: configuration.hotwords
        ))
        self.base = base

        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        bridgeTask = Task {
            for await event in base.events {
                switch event {
                case .transcript(let text):
                    continuation.yield(.transcript(text))
                case .utterance(let text):
                    continuation.yield(.utterance(text))
                case .level(let value):
                    continuation.yield(.level(value))
                case .state(.finished):
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                case .state(.failed(let message)), .error(let message):
                    continuation.yield(.failed(message))
                    continuation.finish()
                    return
                case .state:
                    break
                }
            }
            continuation.finish()
        }
    }

    deinit {
        bridgeTask?.cancel()
    }

    func start() async throws { try await base.start() }
    func finish() async { await base.finish() }
    func cancel() async { await base.cancel() }
}

/// LLMKit Agent 到 App 会话端口的唯一生产适配器。
actor LLMKitConversationAgent: ConversationAgent {
    private let base: LLMAgent

    init(configuration: ConversationAgentConfiguration) {
        let transport = LLMChatClient(config: .init(
            apiKey: configuration.apiKey,
            model: configuration.model
        ))
        let executor: any LLMToolExecutor = configuration.enableSearch
            ? BochaSearchClient(config: .init(apiKey: configuration.bochaAPIKey))
            : NoopToolExecutor()
        base = LLMAgent(
            transport: transport,
            executor: executor,
            config: .init(systemPrompt: configuration.systemPrompt, maxMessages: 20)
        )
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        let events = await base.sendStreaming(userText)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event {
                        case .toolCall(let name): continuation.yield(.toolCall(name))
                        case .contentDelta(let delta): continuation.yield(.contentDelta(delta))
                        case .completed(let answer): continuation.yield(.completed(answer))
                        }
                    }
                    continuation.finish()
                } catch {
                    if let streamError = error as? LLMAgentStreamError,
                       streamError == .discardPartialMixedContentAndToolCall {
                        continuation.finish(throwing: ConversationAgentStreamError.discardPartial(
                            streamError.localizedDescription
                        ))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func clearContext() async {
        await base.clearContext()
    }
}
