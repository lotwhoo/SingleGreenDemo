import AVFoundation
import Foundation
import LLMKit
import VoiceChatCore

struct AIConversationConfiguration: Equatable, Sendable {
    var speechAPIKey: String
    var asrResourceID: String
    var asrLanguage: String
    var hotwords: [String]
    var handsFree: Bool
    var llmAPIKey: String
    var llmModel: String
    var enableSearch: Bool
    var bochaAPIKey: String

    var isASRConfigured: Bool {
        !speechAPIKey.trimmed.isEmpty && !asrResourceID.trimmed.isEmpty
    }

    var isLLMConfigured: Bool {
        !llmAPIKey.trimmed.isEmpty && !llmModel.trimmed.isEmpty
    }

    var isSearchConfigured: Bool {
        !enableSearch || !bochaAPIKey.trimmed.isEmpty
    }
}

struct SpeechRecognitionConfiguration: Equatable, Sendable {
    var apiKey: String
    var resourceID: String
    var language: String
    var hotwords: [String]
}

enum SpeechRecognitionEvent: Equatable, Sendable {
    case transcript(String)
    case utterance(String)
    case level(Float)
    case finished
    case failed(String)
}

protocol SpeechRecognitionSession: AnyObject {
    var events: AsyncStream<SpeechRecognitionEvent> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

struct ConversationAgentConfiguration: Equatable, Sendable {
    var apiKey: String
    var model: String
    var enableSearch: Bool
    var bochaAPIKey: String
    var systemPrompt: String
}

protocol ConversationAgent: Sendable {
    func send(
        _ userText: String,
        onToolCall: (@Sendable (String) async -> Void)?
    ) async throws -> String
    func clearContext() async
}

struct VoiceConversationDependencies {
    var configuration: () -> AIConversationConfiguration
    var makeSpeechSession: (SpeechRecognitionConfiguration) -> any SpeechRecognitionSession
    var makeAgent: (ConversationAgentConfiguration) -> any ConversationAgent
    var requestMicrophonePermission: () async -> Bool
    var now: () -> Date
    var sleep: (Duration) async throws -> Void

    @MainActor
    static func live(settings: AISettings) -> Self {
        Self(
            configuration: {
                AIConversationConfiguration(
                    speechAPIKey: settings.speechAPIKey,
                    asrResourceID: settings.asrResourceID,
                    asrLanguage: settings.asrLanguage,
                    hotwords: settings.hotwords,
                    handsFree: settings.handsFree,
                    llmAPIKey: settings.llmAPIKey,
                    llmModel: settings.llmModel,
                    enableSearch: settings.enableSearch,
                    bochaAPIKey: settings.bochaAPIKey
                )
            },
            makeSpeechSession: { configuration in
                VoiceChatSpeechRecognitionSession(configuration: configuration)
            },
            makeAgent: { configuration in
                LLMKitConversationAgent(configuration: configuration)
            },
            requestMicrophonePermission: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:
                    return true
                case .denied:
                    return false
                case .undetermined:
                    return await withCheckedContinuation { continuation in
                        AVAudioApplication.requestRecordPermission {
                            continuation.resume(returning: $0)
                        }
                    }
                @unknown default:
                    return false
                }
            },
            now: { .now },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }
}

private final class VoiceChatSpeechRecognitionSession: SpeechRecognitionSession {
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

private actor LLMKitConversationAgent: ConversationAgent {
    private let base: LLMAgent

    init(configuration: ConversationAgentConfiguration) {
        let client = LLMChatClient(config: .init(
            apiKey: configuration.apiKey,
            model: configuration.model
        ))
        let executor: any LLMToolExecutor = configuration.enableSearch
            ? BochaSearchClient(config: .init(apiKey: configuration.bochaAPIKey))
            : NoopToolExecutor()
        base = LLMAgent(
            client: client,
            executor: executor,
            config: .init(systemPrompt: configuration.systemPrompt, maxMessages: 20)
        )
    }

    func send(
        _ userText: String,
        onToolCall: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        try await base.send(userText, onToolCall: onToolCall)
    }

    func clearContext() async {
        await base.clearContext()
    }
}
