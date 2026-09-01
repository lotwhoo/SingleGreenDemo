import Foundation
import SingleGreenConversationAdapters
import SingleGreenGlassesKit
import VoiceChatCore

struct SpeechProviderConfiguration: Equatable, Sendable {
    let apiKey: String
    let resourceID: String
    let language: String
    let hotwords: [String]
}

struct ConversationAgentAccountScope: Hashable, Sendable {
    let opaqueID: String

    init(opaqueID: String) {
        self.opaqueID = opaqueID
    }
}

struct AgentProviderScope: Hashable, Sendable {
    let providerID: String
    let account: ConversationAgentAccountScope
    let model: String
    let externalInformationLookupEnabled: Bool
}

struct AgentProviderConfiguration: Sendable {
    let scope: AgentProviderScope
    let credentialProvider: any ConversationCredentialProvider
    let systemPrompt: String
}

@MainActor
final class ConversationPreparationResolver {
    /// Builds a configured but inactive voice-input session. Implementations
    /// may allocate and validate a detector here, but must not start capture or
    /// open the recognizer transport before the returned session is armed.
    typealias VoiceActivatedFactory =
        (SpeechProviderConfiguration) throws -> any VoiceActivatedSpeechRecognitionSession
    typealias AgentFactory = (AgentProviderConfiguration) -> any ConversationAgent

    private struct CachedAgent {
        let scope: AgentProviderScope
        let identity: ConversationAgentContextIdentity
        let agent: any ConversationAgent
    }

    private let settings: AISettings
    private let credentialProvider: any ConversationCredentialProvider
    private let makeVoiceActivatedSession: VoiceActivatedFactory?
    private let microphoneLeaseCoordinator: MicrophoneLeaseCoordinator?
    private let makeAgent: AgentFactory
    private var cachedAgent: CachedAgent?

    var requestedInputMode: SpeechInputMode {
        settings.requestedSpeechInputMode
    }

    var voiceActivatedInputAvailable: Bool {
        makeVoiceActivatedSession != nil
            && settings.speechInputAvailability.voiceActivatedIsAvailable
    }

    init(
        settings: AISettings,
        credentialProvider: any ConversationCredentialProvider,
        makeVoiceActivatedSession: VoiceActivatedFactory?,
        microphoneLeaseCoordinator: MicrophoneLeaseCoordinator? = nil,
        makeAgent: @escaping AgentFactory = ProductionConversationAgentFactory.make
    ) {
        self.settings = settings
        self.credentialProvider = credentialProvider
        self.makeVoiceActivatedSession = makeVoiceActivatedSession
        self.microphoneLeaseCoordinator = microphoneLeaseCoordinator
        self.makeAgent = makeAgent
    }

    func prepareSpeechInput(mode: SpeechInputMode) async throws -> PreparedSpeechInputSession {
        if mode == .voiceActivated, !voiceActivatedInputAvailable {
            throw ConversationPreparationFailure(
                userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                failureCode: .configurationMissing
            )
        }

        let lease = try await validatedLease()
        guard lease.isSpeechUsable(at: .now, minimumRemainingLifetime: 0),
              !settings.asrResourceID.trimmed.isEmpty else {
            throw ConversationPreparationFailure(
                userSafeMessage: "请先在设置中完成语音识别配置。",
                failureCode: .configurationMissing
            )
        }
        let configuration = SpeechProviderConfiguration(
            apiKey: lease.speechAPIKey.trimmed,
            resourceID: settings.asrResourceID.trimmed,
            language: settings.asrLanguage,
            hotwords: settings.hotwords
        )
        switch mode {
        case .pushToTalk:
            let config = ASRSession.Config(
                apiKey: configuration.apiKey,
                resourceID: configuration.resourceID,
                language: configuration.language,
                hotwords: configuration.hotwords
            )
            let supervisor = ASRSessionSupervisor(
                config: config,
                policy: .disabled(disposition: .retryableFailure)
            )
            let session: any SpeechRecognitionSession =
                VoiceChatSupervisedSpeechRecognitionAdapter(supervisor: supervisor)
            if let microphoneLeaseCoordinator {
                return .pushToTalk(MicrophoneLeasedSpeechRecognitionSession(
                    base: session,
                    coordinator: microphoneLeaseCoordinator
                ))
            }
            return .pushToTalk(session)
        case .voiceActivated:
            guard let makeVoiceActivatedSession else {
                throw ConversationPreparationFailure(
                    userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                    failureCode: .configurationMissing
                )
            }
            do {
                let session = try makeVoiceActivatedSession(configuration)
                if let microphoneLeaseCoordinator {
                    return .voiceActivated(
                        MicrophoneLeasedVoiceActivatedSpeechRecognitionSession(
                            base: session,
                            coordinator: microphoneLeaseCoordinator
                        )
                    )
                }
                return .voiceActivated(session)
            } catch {
                // Factory failures may contain detector or framework details.
                // Collapse them to reviewed copy and coarse telemetry only.
                throw ConversationPreparationFailure(
                    userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                    failureCode: .preparationUnavailable
                )
            }
        }
    }

    func prepareAgent() async throws -> PreparedConversationAgent {
        let lease = try await validatedLease()
        let model = settings.llmModel.trimmed
        guard lease.isLLMUsable(at: .now, minimumRemainingLifetime: 0),
              !model.isEmpty else {
            throw ConversationPreparationFailure(
                userSafeMessage: "请先在设置中完成 AI 回答配置。",
                failureCode: .configurationMissing
            )
        }
        guard !settings.enableSearch || !lease.searchAPIKey.trimmed.isEmpty else {
            throw ConversationPreparationFailure(
                userSafeMessage: "已开启联网信息查询，请先完成搜索服务配置。",
                failureCode: .configurationMissing
            )
        }

        let scope = AgentProviderScope(
            providerID: "openai-compatible",
            account: lease.agentAccountScope,
            model: model,
            externalInformationLookupEnabled: settings.enableSearch
        )
        if let cachedAgent, cachedAgent.scope == scope {
            return PreparedConversationAgent(
                contextIdentity: cachedAgent.identity,
                agent: cachedAgent.agent
            )
        }

        let configuration = AgentProviderConfiguration(
            scope: scope,
            credentialProvider: credentialProvider,
            systemPrompt: Self.systemPrompt
        )
        let agent = makeAgent(configuration)
        let cached = CachedAgent(
            scope: scope,
            identity: ConversationAgentContextIdentity(),
            agent: agent
        )
        cachedAgent = cached
        return PreparedConversationAgent(
            contextIdentity: cached.identity,
            agent: cached.agent
        )
    }

    private func validatedLease() async throws -> ConversationCredentialLease {
        do {
            let lease = try await credentialProvider.lease()
            guard lease.isCurrent(at: .now, minimumRemainingLifetime: 0) else {
                throw ServerCredentialError.expiredLease
            }
            return lease
        } catch let failure as ConversationPreparationFailure {
            throw failure
        } catch {
            throw ConversationPreparationFailure(
                userSafeMessage: "暂时无法准备对话服务，请稍后重试。",
                failureCode: .preparationUnavailable
            )
        }
    }

    private static let systemPrompt =
        "你是单绿眼镜中的友好语音助手。请优先用简洁、自然的中文回答，一般不超过 200 字。遇到需要最新、实时或外部信息的问题时使用联网信息查询工具，并基于查询结果回答。"
}
