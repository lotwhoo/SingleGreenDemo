import Foundation

// MARK: - Configuration contracts

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

struct ConversationAgentConfiguration: Equatable, Sendable {
    var apiKey: String
    var model: String
    var enableSearch: Bool
    var bochaAPIKey: String
    var systemPrompt: String
}

// MARK: - ASR port

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

// MARK: - Agent port

enum ConversationAgentEvent: Equatable, Sendable {
    case toolCall(String)
    case contentDelta(String)
    case completed(String)
}

enum ConversationAgentStreamError: Error, LocalizedError, Sendable, Equatable {
    case discardPartial(String)

    var shouldDiscardPartial: Bool { true }

    var errorDescription: String? {
        switch self {
        case .discardPartial(let message): return message
        }
    }
}

protocol ConversationAgent: Sendable {
    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error>
    func clearContext() async
}
