import Combine
import StreamingTextKit
import XCTest
@testable import SingleGreenGlassesKit

@MainActor
extension VoiceConversationControllerTests {
    func makeController(
        session: FakeSpeechSession,
        agent: any ConversationAgent
    ) -> VoiceConversationController {
        VoiceConversationController(dependencies: makeDependencies(session: session, agent: agent))
    }

    func makeDependencies(
        session: any SpeechRecognitionSession,
        agent: any ConversationAgent,
        configuration: @escaping () -> AIConversationConfiguration = { .valid },
        makeSpeechSession: ((SpeechRecognitionConfiguration) -> any SpeechRecognitionSession)? = nil,
        makeVoiceActivatedSpeechSession:
            ((SpeechRecognitionConfiguration) -> any VoiceActivatedSpeechRecognitionSession)? = nil,
        makeAgent: ((ConversationAgentConfiguration) -> any ConversationAgent)? = nil,
        credentialProvider: (any ConversationCredentialProvider)? = nil,
        requestMicrophonePermission: @escaping () async -> Bool = { true },
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 100) },
        sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() },
        reduceMotion: @escaping () -> Bool = { true },
        streamingTextPolicy: TypewriterPolicy = .comfortableReading,
        telemetry: any ConversationTelemetrySink = NoopConversationTelemetry(),
        monotonicNow: @escaping () -> UInt64 = { 0 }
    ) -> VoiceConversationDependencies {
        let contextIdentity = ConversationAgentContextIdentity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        return VoiceConversationDependencies(
            inputMode: { configuration().inputMode },
            voiceActivatedInputAvailable: {
                configuration().inputMode != .voiceActivated
                    || makeVoiceActivatedSpeechSession != nil
            },
            prepareSpeechInput: { mode in
                let current = configuration()
                let lease = try await credentialProvider?.lease() ?? .init(
                    speechAPIKey: current.speechAPIKey,
                    llmAPIKey: current.llmAPIKey,
                    searchAPIKey: current.bochaAPIKey,
                    expiresAt: .distantFuture
                )
                guard !lease.speechAPIKey.isEmpty, !current.asrResourceID.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "请先在设置中填写豆包 ASR API Key 和资源 ID。",
                        failureCode: .configurationMissing
                    )
                }
                let speechConfiguration = SpeechRecognitionConfiguration(
                    apiKey: lease.speechAPIKey,
                    resourceID: current.asrResourceID,
                    language: current.asrLanguage,
                    hotwords: current.hotwords
                )
                switch mode {
                case .pushToTalk:
                    return .pushToTalk((makeSpeechSession ?? { _ in session })(speechConfiguration))
                case .voiceActivated:
                    guard let makeVoiceActivatedSpeechSession else {
                        throw ConversationPreparationFailure(
                            userSafeMessage: Self.testPresentationCopy.voiceActivatedUnavailable,
                            failureCode: .configurationMissing
                        )
                    }
                    return .voiceActivated(makeVoiceActivatedSpeechSession(speechConfiguration))
                }
            },
            prepareAgent: {
                let current = configuration()
                let lease = try await credentialProvider?.lease() ?? .init(
                    speechAPIKey: current.speechAPIKey,
                    llmAPIKey: current.llmAPIKey,
                    searchAPIKey: current.bochaAPIKey,
                    expiresAt: .distantFuture
                )
                guard !lease.llmAPIKey.isEmpty, !current.llmModel.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "请先在设置中填写 DeepSeek API Key 和模型。",
                        failureCode: .configurationMissing
                    )
                }
                guard !current.enableSearch || !lease.searchAPIKey.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "已开启联网搜索，请先填写博查搜索 API Key。",
                        failureCode: .configurationMissing
                    )
                }
                let agentConfiguration = ConversationAgentConfiguration(
                    apiKey: lease.llmAPIKey,
                    model: current.llmModel,
                    enableSearch: current.enableSearch,
                    bochaAPIKey: lease.searchAPIKey,
                    systemPrompt: "test-system-prompt"
                )
                return PreparedConversationAgent(
                    contextIdentity: contextIdentity,
                    agent: (makeAgent ?? { _ in agent })(agentConfiguration)
                )
            },
            requestMicrophonePermission: requestMicrophonePermission,
            sleep: sleep,
            reduceMotion: reduceMotion,
            streamingTextPolicy: streamingTextPolicy,
            telemetry: telemetry,
            presentationCopy: Self.testPresentationCopy,
            monotonicNow: monotonicNow
        )
    }

    static let testPresentationCopy = ConversationPresentationCopy(
        voiceActivatedUnavailable: "本地语音检测暂不可用，请切换到手动语音输入。",
        microphonePermissionDenied: "未获得麦克风权限，请在系统设置中允许访问。",
        speechRecognitionUnavailable: "语音识别暂时不可用，请稍后重试。",
        noSpeech: "没有识别到有效语音，请靠近手机后重试。",
        replyPreparationUnavailable: "暂时无法准备 AI 回答服务，请稍后重试。",
        emptyReply: "模型返回了空回答",
        inconsistentReplyStream: "模型流的增量与完整回答不一致",
        incompleteReplyStream: "模型流未正常完成",
        unexpectedReplyFailure: "回答流程暂时中断。",
        interruptedReplyPrefix: "回答中断，请重试：",
        failedReplyPrefix: "AI 回复失败：",
        contextCommitFailed: "回答已显示，但对话上下文保存失败，请重试。"
    )

    func waitUntil(
        iterations: Int = 500,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }

    func waitUntilAsync(
        iterations: Int = 500,
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}

@MainActor
final class RecordingTelemetry: ConversationTelemetrySink {
    private(set) var events: [ConversationTelemetryEvent] = []
    func record(_ event: ConversationTelemetryEvent) { events.append(event) }

    func terminals(for phase: ConversationTelemetryPhase) -> [ConversationTelemetryEvent] {
        events.filter { $0.phase == phase && $0.outcome != .started }
    }
}

struct AIConversationConfiguration: Equatable, Sendable {
    let speechAPIKey: String
    let asrResourceID: String
    let asrLanguage: String
    let hotwords: [String]
    let inputMode: SpeechInputMode
    let llmAPIKey: String
    let llmModel: String
    let enableSearch: Bool
    let bochaAPIKey: String

    var handsFree: Bool { inputMode == .voiceActivated }

    init(
        speechAPIKey: String,
        asrResourceID: String,
        asrLanguage: String,
        hotwords: [String],
        inputMode: SpeechInputMode,
        llmAPIKey: String,
        llmModel: String,
        enableSearch: Bool,
        bochaAPIKey: String
    ) {
        self.speechAPIKey = speechAPIKey
        self.asrResourceID = asrResourceID
        self.asrLanguage = asrLanguage
        self.hotwords = hotwords
        self.inputMode = inputMode
        self.llmAPIKey = llmAPIKey
        self.llmModel = llmModel
        self.enableSearch = enableSearch
        self.bochaAPIKey = bochaAPIKey
    }

    init(
        speechAPIKey: String,
        asrResourceID: String,
        asrLanguage: String,
        hotwords: [String],
        handsFree: Bool,
        llmAPIKey: String,
        llmModel: String,
        enableSearch: Bool,
        bochaAPIKey: String
    ) {
        self.init(
            speechAPIKey: speechAPIKey,
            asrResourceID: asrResourceID,
            asrLanguage: asrLanguage,
            hotwords: hotwords,
            inputMode: handsFree ? .voiceActivated : .pushToTalk,
            llmAPIKey: llmAPIKey,
            llmModel: llmModel,
            enableSearch: enableSearch,
            bochaAPIKey: bochaAPIKey
        )
    }
}

struct SpeechRecognitionConfiguration: Equatable, Sendable {
    let apiKey: String
    let resourceID: String
    let language: String
    let hotwords: [String]
}

struct ConversationAgentConfiguration: Equatable, Sendable {
    let apiKey: String
    let model: String
    let enableSearch: Bool
    let bochaAPIKey: String
    let systemPrompt: String
}

struct ConversationCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let speechAPIKey: String
    let llmAPIKey: String
    let searchAPIKey: String
    let expiresAt: Date

    var description: String {
        "ConversationCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

protocol ConversationCredentialProvider: Sendable {
    func lease() async throws -> ConversationCredentialLease
}

extension AIConversationConfiguration {
    static let valid = valid(handsFree: false)

    static func valid(inputMode: SpeechInputMode) -> Self {
        Self(
            speechAPIKey: "speech-key",
            asrResourceID: "volc.seedasr.sauc.duration",
            asrLanguage: "zh-CN",
            hotwords: ["单绿眼镜"],
            inputMode: inputMode,
            llmAPIKey: "llm-key",
            llmModel: "deepseek-v4-flash",
            enableSearch: true,
            bochaAPIKey: "bocha-key"
        )
    }

    static func valid(handsFree: Bool) -> Self {
        Self(
            speechAPIKey: "speech-key",
            asrResourceID: "volc.seedasr.sauc.duration",
            asrLanguage: "zh-CN",
            hotwords: ["单绿眼镜"],
            handsFree: handsFree,
            llmAPIKey: "llm-key",
            llmModel: "deepseek-v4-flash",
            enableSearch: true,
            bochaAPIKey: "bocha-key"
        )
    }

    static let missingASR = Self(
        speechAPIKey: "",
        asrResourceID: "volc.seedasr.sauc.duration",
        asrLanguage: "zh-CN",
        hotwords: [],
        handsFree: false,
        llmAPIKey: "llm-key",
        llmModel: "deepseek-v4-flash",
        enableSearch: false,
        bochaAPIKey: ""
    )
}

@MainActor
final class FakeSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation

    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }

    func start() async throws { startCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}

@MainActor
final class FakeVoiceActivatedSpeechSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation

    private(set) var armCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: VoiceActivatedRecognitionEvent) {
        continuation.yield(event)
    }

    func arm() async throws { armCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}

@MainActor
final class SuspendedCancelSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let eventsContinuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isCancelSuspended = false
    private(set) var observedCancellation = false

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.eventsContinuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        eventsContinuation.yield(event)
    }

    func start() async throws { startCount += 1 }
    func finish() async {}

    func cancel() async {
        cancelCount += 1
        observedCancellation = observedCancellation || Task.isCancelled
        isCancelSuspended = true
        await withCheckedContinuation { continuation in
            cancelContinuation = continuation
        }
        isCancelSuspended = false
        observedCancellation = observedCancellation || Task.isCancelled
    }

    func resolveCancel() {
        let continuation = cancelContinuation
        cancelContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class SuspendedFinishSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0
    private(set) var isFinishSuspended = false
    private(set) var isResourceActive = false

    init() {
        events = AsyncStream { _ in }
    }

    func start() async throws {
        isResourceActive = true
    }

    func finish() async {
        isFinishSuspended = true
        await withCheckedContinuation { finishContinuation = $0 }
        isFinishSuspended = false
        isResourceActive = true
    }

    func cancel() async {
        cancelCount += 1
        isResourceActive = false
    }

    func resolveFinish() {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class SuspendedArmVoiceActivatedSpeechSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>
    private(set) var armCount = 0
    private(set) var cancelCount = 0
    private(set) var isArmSuspended = false
    private(set) var isResourceActive = false
    private var armContinuation: CheckedContinuation<Void, Error>?

    init() {
        events = AsyncStream { _ in }
    }

    func arm() async throws {
        armCount += 1
        isArmSuspended = true
        try await withCheckedThrowingContinuation { continuation in
            armContinuation = continuation
        }
        isArmSuspended = false
        isResourceActive = true
    }

    func finish() async {}

    func cancel() async {
        cancelCount += 1
        isResourceActive = false
    }

    func resolveArm() {
        armContinuation?.resume(returning: ())
        armContinuation = nil
    }
}

@MainActor
final class SuspendedAbortConversationAgent: ConversationAgent {
    let token = ConversationAgentTransactionToken()
    private var streamContinuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var abortContinuation: CheckedContinuation<Void, Never>?
    private(set) var isAbortSuspended = false
    private(set) var clearCount = 0

    var isWaiting: Bool { streamContinuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            streamContinuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        let continuation = streamContinuation
        streamContinuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        isAbortSuspended = true
        await withCheckedContinuation { abortContinuation = $0 }
        isAbortSuspended = false
    }

    func clearContext() async { clearCount += 1 }

    func resolveAbort() {
        let continuation = abortContinuation
        abortContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class FirstClearSuspendedConversationAgent: ConversationAgent {
    private let reply: String
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private(set) var clearCount = 0
    private(set) var isFirstClearSuspended = false

    init(reply: String) {
        self.reply = reply
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(reply))
            continuation.yield(.completed(reply))
            continuation.finish()
        }
    }

    func clearContext() async {
        clearCount += 1
        guard clearCount == 1 else { return }
        isFirstClearSuspended = true
        await withCheckedContinuation { clearContinuation = $0 }
        isFirstClearSuspended = false
    }

    func resolveFirstClear() {
        let continuation = clearContinuation
        clearContinuation = nil
        continuation?.resume()
    }
}

actor SuspendedCredentialProvider: ConversationCredentialProvider {
    private let value = ConversationCredentialLease(
        speechAPIKey: "speech-fixture",
        llmAPIKey: "llm-fixture",
        searchAPIKey: "search-fixture",
        expiresAt: .distantFuture
    )
    private var continuations: [Int: CheckedContinuation<ConversationCredentialLease, Never>] = [:]
    private var nextRequest = 0

    var requestCount: Int { nextRequest }

    func lease() async throws -> ConversationCredentialLease {
        let request = nextRequest
        nextRequest += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func resolve(_ request: Int) {
        continuations.removeValue(forKey: request)?.resume(returning: value)
    }
}

actor CountingCredentialProvider: ConversationCredentialProvider {
    private(set) var requestCount = 0

    func lease() async throws -> ConversationCredentialLease {
        requestCount += 1
        return ConversationCredentialLease(
            speechAPIKey: "unused",
            llmAPIKey: "unused",
            searchAPIKey: "unused",
            expiresAt: .distantFuture
        )
    }
}

struct FailingCredentialProvider: ConversationCredentialProvider {
    func lease() async throws -> ConversationCredentialLease {
        throw CredentialFixtureError.unavailable
    }
}

enum CredentialFixtureError: Error {
    case unavailable
}

@MainActor
final class SuspendedPermissionRequest {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var isSuspended = false

    func request() async -> Bool {
        isSuspended = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ granted: Bool) {
        isSuspended = false
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
final class SuspendedStartSpeechSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isStartSuspended = false
    private(set) var isResourceActive = false
    private var startContinuation: CheckedContinuation<Void, Error>?

    init() {
        self.events = AsyncStream { _ in }
    }

    func start() async throws {
        startCount += 1
        isStartSuspended = true
        do {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        } catch {
            isStartSuspended = false
            isResourceActive = true
            throw error
        }
        isStartSuspended = false
        isResourceActive = true
    }

    func finish() async {}

    func cancel() async {
        cancelCount += 1
        isResourceActive = false
    }

    func resolveStart() {
        startContinuation?.resume(returning: ())
        startContinuation = nil
    }

    func resolveStart(throwing error: Error) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil
    }
}

enum SuspendedStartError: Error {
    case failed
}

@MainActor
final class FakeConversationAgent: ConversationAgent {
    private let reply: String
    private let error: Error?
    private(set) var receivedTexts: [String] = []
    private(set) var clearCount = 0

    init(reply: String = "", error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        receivedTexts.append(userText)
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for character in reply {
                continuation.yield(.contentDelta(String(character)))
            }
            continuation.yield(.completed(reply))
            continuation.finish()
        }
    }

    func clearContext() async { clearCount += 1 }
}

@MainActor
final class ControlledConversationAgent: ConversationAgent {
    private let toolName: String?
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private(set) var clearCount = 0
    private(set) var wasCancelled = false

    var isWaiting: Bool {
        continuation != nil
    }

    init(toolName: String? = nil) {
        self.toolName = toolName
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            if toolName != nil {
                continuation.yield(.toolActivity(.externalInformationLookup))
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { @MainActor in
                    self?.wasCancelled = true
                    self?.continuation = nil
                }
            }
        }
    }

    func complete(with text: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.completed(text))
        continuation?.finish()
    }

    func emit(_ event: ConversationAgentEvent) {
        continuation?.yield(event)
    }

    func fail(_ error: Error) {
        let continuation = continuation
        self.continuation = nil
        continuation?.finish(throwing: error)
    }

    func finishWithoutCompletion() {
        let continuation = continuation
        self.continuation = nil
        continuation?.finish()
    }

    func clearContext() async { clearCount += 1 }
}

@MainActor
final class TransactionalControlledAgent: ConversationAgent {
    let token = ConversationAgentTransactionToken()
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private(set) var committed: [ConversationAgentTransactionToken] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []
    private(set) var clearCount = 0

    var isWaiting: Bool { continuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        committed.append(token)
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        aborted.append(token)
    }

    func clearContext() async { clearCount += 1 }
}

@MainActor
final class SuspendedCommitConversationAgent: ConversationAgent {
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var activeUserText = ""
    private var stagedAnswer = ""
    private var activeToken: ConversationAgentTransactionToken?

    private(set) var committedContext: [String] = []
    private(set) var contextSnapshotsAtStreamStart: [[String]] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []
    private(set) var clearCount = 0
    private(set) var isCommitSuspended = false

    var isWaiting: Bool { continuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        contextSnapshotsAtStreamStart.append(committedContext)
        activeUserText = userText
        stagedAnswer = ""
        let token = ConversationAgentTransactionToken()
        activeToken = token
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        stagedAnswer = answer
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard activeToken == token else { throw CommitFixtureError.failed }
        isCommitSuspended = true
        try await withCheckedThrowingContinuation { continuation in
            commitContinuation = continuation
        }
        isCommitSuspended = false
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        aborted.append(token)
    }

    func clearContext() async {
        clearCount += 1
        committedContext.removeAll()
    }

    func resolveCommitSuccessfully() {
        committedContext.append(contentsOf: [activeUserText, stagedAnswer])
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: ())
    }

    func resolveCommitFailure() {
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(throwing: CommitFixtureError.failed)
    }
}

@MainActor
final class PostCommitGateConversationAgent: ConversationAgent {
    let token = ConversationAgentTransactionToken()
    private var streamContinuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var activeUserText = ""
    private var stagedAnswer = ""

    private(set) var committedContext: [String] = []
    private(set) var aborted: [ConversationAgentTransactionToken] = []
    private(set) var isCommitAppliedButNotReturned = false

    var isWaiting: Bool { streamContinuation != nil }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        activeUserText = userText
        stagedAnswer = ""
        return AsyncThrowingStream { continuation in
            streamContinuation = continuation
            continuation.yield(.transaction(token))
        }
    }

    func finalize(with answer: String) {
        stagedAnswer = answer
        let continuation = streamContinuation
        streamContinuation = nil
        continuation?.yield(.contentDelta(answer))
        continuation?.yield(.completed(answer))
        continuation?.finish()
    }

    func commit(_ token: ConversationAgentTransactionToken) async throws {
        guard token == self.token else { throw CommitFixtureError.failed }
        committedContext.append(contentsOf: [activeUserText, stagedAnswer])
        isCommitAppliedButNotReturned = true
        try await withCheckedThrowingContinuation { continuation in
            commitContinuation = continuation
        }
        isCommitAppliedButNotReturned = false
    }

    func abort(_ token: ConversationAgentTransactionToken) async {
        guard token == self.token else { return }
        if aborted.last != token { aborted.append(token) }
        if isCommitAppliedButNotReturned {
            committedContext.removeAll()
            isCommitAppliedButNotReturned = false
            let continuation = commitContinuation
            commitContinuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }

    func clearContext() async {
        committedContext.removeAll()
    }

    func allowAcceptance() {
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: ())
    }
}

enum CommitFixtureError: Error {
    case failed
}

/// Test-only injected clock; all reads and writes are confined to the MainActor controller test.
final class MutableTime: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

final class ManualSleeper: Sendable {
    private let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (ticks, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.ticks = ticks
        self.continuation = continuation
    }

    func sleep() async throws {
        var iterator = ticks.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func advance() {
        continuation.yield(())
    }
}

@MainActor
final class CancellationTrackingSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isSleeping = false
    private(set) var cancellationCount = 0

    func sleep() async throws {
        isSleeping = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                cancellationCount += 1
                isSleeping = false
                continuation?.resume()
                continuation = nil
            }
        }
        try Task.checkCancellation()
    }
}

/// Test-only recorder whose mutable value is fully protected by `lock`.
final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Duration?

    var value: Duration? { lock.withLock { storage } }

    func record(_ duration: Duration) {
        lock.withLock { storage = duration }
    }
}

enum TestFailure: LocalizedError {
    case agent

    var errorDescription: String? { "SENTINEL_PRIVATE_PROVIDER_PAYLOAD" }
}
