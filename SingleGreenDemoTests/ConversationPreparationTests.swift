import Foundation
import LLMKit
import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class ConversationPreparationTests: XCTestCase {
    func testProductionFactoryCreatesRealDetectorAndInactiveCoreSession() async throws {
        let configuration = SpeechProviderConfiguration(
            apiKey: "fixture-speech-key",
            resourceID: "fixture-resource",
            language: "zh-CN",
            hotwords: ["单绿眼镜"]
        )

        let base = try ProductionVoiceActivatedSessionFactory.makeCoreSession(
            configuration: configuration
        )

        let stateBeforeExplicitArm = await base.state
        guard case .idle = stateBeforeExplicitArm else {
            await base.cancel()
            return XCTFail("Production factory must return an inactive Core session")
        }
        XCTAssertEqual(ProductionVoiceActivatedSessionFactory.aggressiveness.rawValue, 2)
        XCTAssertEqual(ProductionVoiceActivatedSessionFactory.policy, .standard)
        await base.cancel()
    }

    func testUnavailableVoiceActivationFailsBeforeCredentialPreparation() async {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorPending
        )
        let provider = CountingPreparationCredentialProvider()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil
        )

        do {
            _ = try await resolver.prepareSpeechInput(mode: .voiceActivated)
            XCTFail("Expected unavailable voice activation to fail closed")
        } catch let failure as ConversationPreparationFailure {
            XCTAssertEqual(failure.failureCode, .configurationMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testThrowingVoiceActivatedFactoryFailsSafelyWithoutStartingSession() async {
        let settings = voiceActivatedSettings()
        let provider = CountingPreparationCredentialProvider()
        let candidateSession = PreparationVoiceActivatedSession()
        let factoryCount = ThreadSafeFactoryCounter()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: { _ in
                factoryCount.increment()
                _ = candidateSession
                throw PreparationFixtureError.sensitiveDetectorFailure
            }
        )

        do {
            _ = try await resolver.prepareSpeechInput(mode: .voiceActivated)
            XCTFail("Expected detector preparation to fail")
        } catch let failure as ConversationPreparationFailure {
            XCTAssertEqual(
                failure.userSafeMessage,
                ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable
            )
            XCTAssertEqual(failure.failureCode, .preparationUnavailable)
            XCTAssertFalse(failure.userSafeMessage.contains(PreparationFixtureError.sentinel))
            XCTAssertFalse(failure.userSafeMessage.localizedCaseInsensitiveContains("webrtc"))
            XCTAssertFalse(failure.userSafeMessage.localizedCaseInsensitiveContains("provider"))
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }

        let armCount = await candidateSession.armCount
        let credentialRequestCount = await provider.requestCount
        XCTAssertEqual(factoryCount.value, 1)
        XCTAssertEqual(armCount, 0)
        XCTAssertEqual(credentialRequestCount, 1)
    }

    func testNilVoiceActivatedFactoryRemainsUnavailableBeforeCredentialPreparation() async {
        let settings = voiceActivatedSettings()
        let provider = CountingPreparationCredentialProvider()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil
        )

        do {
            _ = try await resolver.prepareSpeechInput(mode: .voiceActivated)
            XCTFail("Expected missing voice-activated factory to fail closed")
        } catch let failure as ConversationPreparationFailure {
            XCTAssertEqual(
                failure,
                ConversationPreparationFailure(
                    userSafeMessage: ConversationPresentationCopy.singleGreenDemo.voiceActivatedUnavailable,
                    failureCode: .configurationMissing
                )
            )
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }

        let credentialRequestCount = await provider.requestCount
        XCTAssertEqual(credentialRequestCount, 0)
    }

    func testSuccessfulVoiceActivatedFactoryReturnsInactiveCompatibleSession() async throws {
        let settings = voiceActivatedSettings()
        let provider = CountingPreparationCredentialProvider()
        let session = PreparationVoiceActivatedSession()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: { configuration in
                XCTAssertEqual(configuration.apiKey, "fixture-speech-key")
                XCTAssertEqual(configuration.resourceID, settings.asrResourceID)
                return session
            }
        )

        let prepared = try await resolver.prepareSpeechInput(mode: .voiceActivated)

        let armCountBeforeExplicitArm = await session.armCount
        let credentialRequestCount = await provider.requestCount
        XCTAssertEqual(prepared.mode, .voiceActivated)
        XCTAssertEqual(armCountBeforeExplicitArm, 0)
        XCTAssertEqual(credentialRequestCount, 1)
        guard case .voiceActivated(let returnedSession) = prepared else {
            return XCTFail("Expected a voice-activated session")
        }
        try await returnedSession.arm()
        let armCountAfterExplicitArm = await session.armCount
        XCTAssertEqual(armCountAfterExplicitArm, 1)
    }

    func testPushToTalkPreparationDoesNotInvokeVoiceActivatedFactory() async throws {
        let settings = voiceActivatedSettings()
        let provider = CountingPreparationCredentialProvider()
        let factoryCount = ThreadSafeFactoryCounter()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: { _ in
                factoryCount.increment()
                throw PreparationFixtureError.sensitiveDetectorFailure
            }
        )

        let prepared = try await resolver.prepareSpeechInput(mode: .pushToTalk)

        XCTAssertEqual(prepared.mode, .pushToTalk)
        XCTAssertEqual(factoryCount.value, 0)
        let credentialRequestCount = await provider.requestCount
        XCTAssertEqual(credentialRequestCount, 1)
        await prepared.cancel()
    }

    func testAgentContextIdentitySurvivesCredentialRotationButChangesWithStableScope() async throws {
        let settings = AISettings(buildPolicy: .serverManaged)
        let originalModel = settings.llmModel
        let originalSearch = settings.enableSearch
        defer {
            settings.llmModel = originalModel
            settings.enableSearch = originalSearch
        }
        settings.llmModel = "fixture-model-a"
        settings.enableSearch = false
        let provider = SequentialPreparationCredentialProvider(leases: [
            .fixture(llmCredential: "credential-version-one", account: "account-a"),
            .fixture(llmCredential: "credential-version-two", account: "account-a"),
            .fixture(llmCredential: "credential-version-three", account: "account-b")
        ])
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil
        )

        let first = try await resolver.prepareAgent()
        let rotatedCredential = try await resolver.prepareAgent()
        XCTAssertEqual(first.contextIdentity, rotatedCredential.contextIdentity)

        let changedAccount = try await resolver.prepareAgent()
        XCTAssertNotEqual(rotatedCredential.contextIdentity, changedAccount.contextIdentity)
    }

    func testAgentContextIdentityChangesWithModelAndToolConfiguration() async throws {
        let settings = AISettings(buildPolicy: .serverManaged)
        let originalModel = settings.llmModel
        let originalSearch = settings.enableSearch
        defer {
            settings.llmModel = originalModel
            settings.enableSearch = originalSearch
        }
        settings.llmModel = "fixture-model-a"
        settings.enableSearch = false
        let provider = StaticPreparationCredentialProvider()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil
        )

        let first = try await resolver.prepareAgent()

        settings.llmModel = "fixture-model-b"
        let changedModel = try await resolver.prepareAgent()
        XCTAssertNotEqual(first.contextIdentity, changedModel.contextIdentity)

        settings.enableSearch = true
        let changedToolConfiguration = try await resolver.prepareAgent()
        XCTAssertNotEqual(changedModel.contextIdentity, changedToolConfiguration.contextIdentity)
    }

    func testRefreshingTransportUsesLatestCredentialWithinBoundAccountScope() async throws {
        let provider = SequentialPreparationCredentialProvider(leases: [
            .fixture(llmCredential: "credential-version-one", account: "account-a"),
            .fixture(llmCredential: "credential-version-two", account: "account-a")
        ])
        let recorder = TransportCredentialRecorder()
        let transport = CredentialRefreshingLLMChatTransport(
            scope: .fixture(account: "account-a"),
            credentialProvider: provider,
            makeTransport: { credential, _ in
                RecordingChatTransport(credentialMarker: credential, recorder: recorder)
            }
        )

        _ = try await transport.completeMessage(
            messages: [.init(role: .user, content: "first")],
            temperature: nil,
            maxTokens: nil,
            tools: nil
        )
        for try await _ in transport.completeMessageStreaming(
            messages: [.init(role: .user, content: "second")],
            temperature: nil,
            maxTokens: nil,
            tools: nil
        ) {}

        let observed = await recorder.values
        XCTAssertEqual(observed, ["credential-version-one", "credential-version-two"])
    }

    func testRefreshingTransportRejectsChangedAccountBeforeCreatingProviderTransport() async {
        let provider = SequentialPreparationCredentialProvider(leases: [
            .fixture(llmCredential: "credential-version-two", account: "account-b")
        ])
        let factoryRecorder = ThreadSafeFactoryCounter()
        let transport = CredentialRefreshingLLMChatTransport(
            scope: .fixture(account: "account-a"),
            credentialProvider: provider,
            makeTransport: { _, _ in
                factoryRecorder.increment()
                return RecordingChatTransport(
                    credentialMarker: "unused",
                    recorder: TransportCredentialRecorder()
                )
            }
        )

        do {
            _ = try await transport.completeMessage(
                messages: [.init(role: .user, content: "must fail closed")],
                temperature: nil,
                maxTokens: nil,
                tools: nil
            )
            XCTFail("Expected account-scope isolation")
        } catch let failure as AgentCredentialRefreshFailure {
            XCTAssertEqual(failure, .accountScopeChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(factoryRecorder.value, 0)
    }

    func testCancelledRefreshingLLMStreamDoesNotCreateOrStartProviderTransportAfterLeaseResolution() async {
        let provider = SuspendedPreparationCredentialProvider()
        let factoryCounter = ThreadSafeFactoryCounter()
        let networkCounter = ThreadSafeFactoryCounter()
        let finishedCounter = ThreadSafeFactoryCounter()
        let transport = CredentialRefreshingLLMChatTransport(
            scope: .fixture(account: "account-fixture"),
            credentialProvider: provider,
            makeTransport: { _, _ in
                factoryCounter.increment()
                return InvocationCountingChatTransport(networkCounter: networkCounter)
            },
            onStreamingOperationFinished: { finishedCounter.increment() }
        )

        let consumer = Task {
            do {
                for try await _ in transport.completeMessageStreaming(
                    messages: [.init(role: .user, content: "cancelled")],
                    temperature: nil,
                    maxTokens: nil,
                    tools: nil
                ) {}
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        await waitUntil { await provider.requestCount == 1 }

        consumer.cancel()
        await provider.resolve(with: .fixture)
        await waitUntil { finishedCounter.value == 1 }
        await consumer.value

        XCTAssertEqual(factoryCounter.value, 0)
        XCTAssertEqual(networkCounter.value, 0)
    }

    func testCancelledRefreshingSearchDoesNotCreateOrStartProviderExecutorAfterLeaseResolution() async throws {
        let provider = SuspendedPreparationCredentialProvider()
        let factoryCounter = ThreadSafeFactoryCounter()
        let networkCounter = ThreadSafeFactoryCounter()
        let executor = CredentialRefreshingSearchToolExecutor(
            scope: .fixture(account: "account-fixture"),
            credentialProvider: provider,
            makeExecutor: { _ in
                factoryCounter.increment()
                return InvocationCountingToolExecutor(networkCounter: networkCounter)
            }
        )
        let call = try JSONDecoder().decode(
            LLMToolCall.self,
            from: Data(
                #"{"id":"call-fixture","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"fixture\"}"}}"#.utf8
            )
        )

        let execution = Task {
            try await executor.execute(call)
        }
        await waitUntil { await provider.requestCount == 1 }

        execution.cancel()
        await provider.resolve(with: .fixture)
        do {
            _ = try await execution.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(factoryCounter.value, 0)
        XCTAssertEqual(networkCounter.value, 0)
    }

    func testLiveAdapterMapsRawSearchToolToSemanticCoreActivity() {
        XCTAssertEqual(
            LLMKitConversationAgent.toolActivity(for: "web_search"),
            .externalInformationLookup
        )
        XCTAssertNil(LLMKitConversationAgent.toolActivity(for: "unrelated_tool"))
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic preparation state")
    }

    private func voiceActivatedSettings() -> AISettings {
        AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: AISpeechInputAvailability(
                voiceActivatedIsAvailable: true,
                voiceActivatedDetail: "Test-only available detector"
            )
        )
    }
}

private actor CountingPreparationCredentialProvider: ConversationCredentialProvider {
    private(set) var requestCount = 0

    func lease() async throws -> ConversationCredentialLease {
        requestCount += 1
        return .fixture
    }
}

private struct StaticPreparationCredentialProvider: ConversationCredentialProvider {
    func lease() async throws -> ConversationCredentialLease { .fixture }
}

private actor SequentialPreparationCredentialProvider: ConversationCredentialProvider {
    private var leases: [ConversationCredentialLease]

    init(leases: [ConversationCredentialLease]) {
        self.leases = leases
    }

    func lease() async throws -> ConversationCredentialLease {
        guard !leases.isEmpty else { throw PreparationFixtureError.exhausted }
        return leases.removeFirst()
    }
}

private actor SuspendedPreparationCredentialProvider: ConversationCredentialProvider {
    private var continuation: CheckedContinuation<ConversationCredentialLease, Error>?
    private(set) var requestCount = 0

    func lease() async throws -> ConversationCredentialLease {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with lease: ConversationCredentialLease) {
        continuation?.resume(returning: lease)
        continuation = nil
    }
}

private enum PreparationFixtureError: LocalizedError {
    case exhausted
    case sensitiveDetectorFailure

    static let sentinel = "SENSITIVE_DETECTOR_PROVIDER_PAYLOAD"

    var errorDescription: String? {
        switch self {
        case .exhausted:
            "Fixture exhausted"
        case .sensitiveDetectorFailure:
            Self.sentinel
        }
    }
}

private actor PreparationVoiceActivatedSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events = AsyncStream<VoiceActivatedRecognitionEvent> { _ in }
    private(set) var armCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    func arm() async throws {
        armCount += 1
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }
}

private actor TransportCredentialRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private struct RecordingChatTransport: LLMChatTransport {
    let credentialMarker: String
    let recorder: TransportCredentialRecorder

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        await recorder.record(credentialMarker)
        return LLMMessage(role: .assistant, content: "fixture")
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(credentialMarker)
                continuation.yield(.completed(.init(role: .assistant, content: "fixture")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct InvocationCountingChatTransport: LLMChatTransport {
    let networkCounter: ThreadSafeFactoryCounter

    func completeMessage(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) async throws -> LLMMessage {
        networkCounter.increment()
        return .init(role: .assistant, content: "fixture")
    }

    func completeMessageStreaming(
        messages: [LLMMessage],
        temperature: Double?,
        maxTokens: Int?,
        tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        networkCounter.increment()
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(.init(role: .assistant, content: "fixture")))
            continuation.finish()
        }
    }
}

private struct InvocationCountingToolExecutor: LLMToolExecutor {
    let networkCounter: ThreadSafeFactoryCounter
    let toolDefinitions: [LLMTool] = []

    func execute(_ call: LLMToolCall) async throws -> String {
        networkCounter.increment()
        return "fixture"
    }
}

private final class ThreadSafeFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

private extension ConversationCredentialLease {
    static let fixture = Self(
        speechAPIKey: "fixture-speech-key",
        llmAPIKey: "fixture-llm-key",
        searchAPIKey: "fixture-search-key",
        agentAccountScope: .init(opaqueID: "account-fixture"),
        expiresAt: .distantFuture
    )

    static func fixture(
        llmCredential: String,
        account: String
    ) -> Self {
        Self(
            speechAPIKey: "fixture-speech-key",
            llmAPIKey: llmCredential,
            searchAPIKey: "fixture-search-key",
            agentAccountScope: .init(opaqueID: account),
            expiresAt: .distantFuture
        )
    }
}

private extension AgentProviderScope {
    static func fixture(account: String) -> Self {
        Self(
            providerID: "provider-fixture",
            account: .init(opaqueID: account),
            model: "model-fixture",
            externalInformationLookupEnabled: false
        )
    }
}
