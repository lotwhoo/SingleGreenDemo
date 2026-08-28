import AVFoundation
import Foundation
import OSLog
import SingleGreenConversationAdapters
import SingleGreenGlassesKit
import UIKit
import VoiceChatCore
import WebRTCVoiceActivityDetection

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

struct ConversationCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let speechAPIKey: String
    let llmAPIKey: String
    let searchAPIKey: String
    let agentAccountScope: ConversationAgentAccountScope
    let expiresAt: Date

    func isUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumRemainingLifetime
            && !speechAPIKey.trimmed.isEmpty
            && !llmAPIKey.trimmed.isEmpty
            && !agentAccountScope.opaqueID.trimmed.isEmpty
    }

    var description: String {
        "ConversationCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

protocol ConversationCredentialProvider: Sendable {
    func lease() async throws -> ConversationCredentialLease
}

extension VoiceConversationDependencies {
    @MainActor
    static func live(settings: AISettings) -> Self {
        let telemetry = ConversationTelemetryStore()
        #if DEBUG
        let credentialProvider: any ConversationCredentialProvider
        if settings.buildPolicy.allowsDemoCredentialStorage {
            credentialProvider = DemoKeychainCredentialProvider(settings: settings)
        } else {
            credentialProvider = ServerIssuedCredentialProvider(
                transport: FailClosedServerCredentialTransport()
            )
        }
        #else
        let credentialProvider: any ConversationCredentialProvider = ServerIssuedCredentialProvider(
            transport: FailClosedServerCredentialTransport()
        )
        #endif

        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: credentialProvider,
            makeVoiceActivatedSession: ProductionVoiceActivatedSessionFactory.make
        )
        return Self(
            inputMode: { settings.requestedSpeechInputMode },
            voiceActivatedInputAvailable: { resolver.voiceActivatedInputAvailable },
            prepareSpeechInput: { mode in
                try await resolver.prepareSpeechInput(mode: mode)
            },
            prepareAgent: {
                try await resolver.prepareAgent()
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
            sleep: { duration in try await Task.sleep(for: duration) },
            reduceMotion: { UIAccessibility.isReduceMotionEnabled },
            telemetry: telemetry,
            presentationCopy: .singleGreenDemo
        )
    }
}

/// App-owned production composition for hands-free speech input. Constructing
/// this graph is intentionally inert: microphone capture and ASR transport do
/// not start until the returned session receives `arm()`.
enum ProductionVoiceActivatedSessionFactory {
    /// Mode 2 balances rejecting common mobile ambient noise against clipping
    /// conversational speech. The choice remains an App policy rather than a
    /// detector-package default or a glasses-core concern.
    static let aggressiveness: WebRTCVADAggressiveness = .aggressive
    static let policy: VoiceActivatedASRPolicy = .standard

    static func make(
        configuration: SpeechProviderConfiguration
    ) throws -> any VoiceActivatedSpeechRecognitionSession {
        let base = try makeCoreSession(configuration: configuration)
        return VoiceChatVoiceActivatedSpeechRecognitionAdapter(session: base)
    }

    static func makeCoreSession(
        configuration: SpeechProviderConfiguration
    ) throws -> VoiceActivatedASRSession {
        let detector = try WebRTCVoiceActivityDetector(
            aggressiveness: aggressiveness
        )
        return VoiceActivatedASRSession(
            config: ASRSession.Config(
                apiKey: configuration.apiKey,
                resourceID: configuration.resourceID,
                language: configuration.language,
                hotwords: configuration.hotwords
            ),
            detector: detector,
            policy: policy
        )
    }
}

@MainActor
final class ConversationPreparationResolver {
    /// Builds a configured but inactive voice-input session. Implementations
    /// may allocate and validate a detector here, but must not start capture or
    /// open the recognizer transport before the returned session is armed.
    typealias VoiceActivatedFactory =
        (SpeechProviderConfiguration) throws -> any VoiceActivatedSpeechRecognitionSession

    private struct CachedAgent {
        let scope: AgentProviderScope
        let identity: ConversationAgentContextIdentity
        let agent: any ConversationAgent
    }

    private let settings: AISettings
    private let credentialProvider: any ConversationCredentialProvider
    private let makeVoiceActivatedSession: VoiceActivatedFactory?
    private var cachedAgent: CachedAgent?

    var voiceActivatedInputAvailable: Bool {
        makeVoiceActivatedSession != nil
            && settings.speechInputAvailability.voiceActivatedIsAvailable
    }

    init(
        settings: AISettings,
        credentialProvider: any ConversationCredentialProvider,
        makeVoiceActivatedSession: VoiceActivatedFactory?
    ) {
        self.settings = settings
        self.credentialProvider = credentialProvider
        self.makeVoiceActivatedSession = makeVoiceActivatedSession
    }

    func prepareSpeechInput(mode: SpeechInputMode) async throws -> PreparedSpeechInputSession {
        if mode == .voiceActivated, !voiceActivatedInputAvailable {
            throw ConversationPreparationFailure(
                userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                failureCode: .configurationMissing
            )
        }

        let lease = try await validatedLease()
        guard !settings.asrResourceID.trimmed.isEmpty else {
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
            let coreSession = ASRSession(config: .init(
                apiKey: configuration.apiKey,
                resourceID: configuration.resourceID,
                language: configuration.language,
                hotwords: configuration.hotwords
            ))
            return .pushToTalk(
                VoiceChatSpeechRecognitionAdapter(session: coreSession)
            )
        case .voiceActivated:
            guard let makeVoiceActivatedSession else {
                throw ConversationPreparationFailure(
                    userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                    failureCode: .configurationMissing
                )
            }
            do {
                return .voiceActivated(try makeVoiceActivatedSession(configuration))
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
        guard !model.isEmpty else {
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
        let agent = ProductionConversationAgentFactory.make(configuration: configuration)
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
            guard lease.isUsable(at: .now, minimumRemainingLifetime: 0) else {
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

extension ConversationPresentationCopy {
    static let singleGreenDemo = Self(
        voiceActivatedUnavailable: "本地语音检测暂不可用，请切换到手动语音输入。",
        microphonePermissionDenied: "未获得麦克风权限，请在系统设置中允许访问。",
        speechRecognitionUnavailable: "语音识别暂时不可用，请稍后重试。",
        noSpeech: "没有识别到有效语音，请靠近手机后重试。",
        replyPreparationUnavailable: "暂时无法准备 AI 回答服务，请稍后重试。",
        emptyReply: "AI 服务返回了空回答。",
        inconsistentReplyStream: "AI 回答流的增量与完整内容不一致。",
        incompleteReplyStream: "AI 回答流未正常完成。",
        unexpectedReplyFailure: "回答流程暂时中断。",
        interruptedReplyPrefix: "回答中断，请重试：",
        failedReplyPrefix: "AI 回复失败：",
        contextCommitFailed: "回答已显示，但对话上下文保存失败，请重试。"
    )
}

#if DEBUG
@MainActor
final class DemoKeychainCredentialProvider: ConversationCredentialProvider {
    private let settings: AISettings

    init(settings: AISettings) {
        self.settings = settings
    }

    func lease() async throws -> ConversationCredentialLease {
        ConversationCredentialLease(
            speechAPIKey: settings.speechAPIKey,
            llmAPIKey: settings.llmAPIKey,
            searchAPIKey: settings.bochaAPIKey,
            agentAccountScope: try settings.demoLLMAccountScope(),
            expiresAt: .distantFuture
        )
    }
}
#endif

protocol ServerCredentialTransport: Sendable {
    func fetchLease() async throws -> ConversationCredentialLease
}

enum ServerCredentialError: Error, Equatable, Sendable, CustomStringConvertible {
    case transportNotConfigured
    case expiredLease

    var description: String {
        switch self {
        case .transportNotConfigured: "ServerCredentialError.transportNotConfigured(redacted)"
        case .expiredLease: "ServerCredentialError.expiredLease(redacted)"
        }
    }
}

struct FailClosedServerCredentialTransport: ServerCredentialTransport {
    func fetchLease() async throws -> ConversationCredentialLease {
        throw ServerCredentialError.transportNotConfigured
    }
}

actor ServerIssuedCredentialProvider: ConversationCredentialProvider {
    private let transport: any ServerCredentialTransport
    private let now: @Sendable () -> Date
    private let minimumRemainingLifetime: TimeInterval
    private let onJoinInFlight: @Sendable () -> Void
    private var cached: ConversationCredentialLease?
    private var inFlight: Task<ConversationCredentialLease, Error>?

    init(
        transport: any ServerCredentialTransport,
        now: @escaping @Sendable () -> Date = { .now },
        minimumRemainingLifetime: TimeInterval = 30,
        onJoinInFlight: @escaping @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.now = now
        self.minimumRemainingLifetime = minimumRemainingLifetime
        self.onJoinInFlight = onJoinInFlight
    }

    func lease() async throws -> ConversationCredentialLease {
        if let cached, cached.isUsable(at: now(), minimumRemainingLifetime: minimumRemainingLifetime) {
            return cached
        }
        if let inFlight {
            onJoinInFlight()
            return try await inFlight.value
        }
        let transport = transport
        let now = now
        let minimumRemainingLifetime = minimumRemainingLifetime
        let task = Task {
            let lease = try await transport.fetchLease()
            guard lease.isUsable(
                at: now(),
                minimumRemainingLifetime: minimumRemainingLifetime
            ) else {
                throw ServerCredentialError.expiredLease
            }
            return lease
        }
        inFlight = task
        defer { inFlight = nil }
        let lease = try await task.value
        cached = lease
        return lease
    }
}

@MainActor
final class ConversationTelemetryStore: ConversationTelemetrySink {
    private let logger = Logger(subsystem: "com.local.SingleGreenDemo", category: "conversation")
    private let capacity: Int
    private(set) var events: [ConversationTelemetryEvent] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: ConversationTelemetryEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let failure = event.failureCode?.rawValue ?? "none"
        logger.info(
            "phase=\(event.phase.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) duration_ms=\(event.elapsedMilliseconds, privacy: .public) failure=\(failure, privacy: .public)"
        )
    }
}
