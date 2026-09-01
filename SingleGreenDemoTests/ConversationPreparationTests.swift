import Foundation
import AgentCore
import BochaSearchAdapter
import LLMCore
import OpenAICompatibleTransport
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

    func testTypedCompositionsKeepResolversServicesAndPoliciesIsolated() async throws {
        let settingsA = voiceActivatedSettings()
        let settingsB = voiceActivatedSettings()

        let providerA = CountingPreparationCredentialProvider()
        let providerB = CountingPreparationCredentialProvider()
        let sessionA = PreparationVoiceActivatedSession()
        let sessionB = PreparationVoiceActivatedSession()
        let agentA = PreparationConversationAgent(marker: "agent-a")
        let agentB = PreparationConversationAgent(marker: "agent-b")
        let resolverA = ConversationPreparationResolver(
            settings: settingsA,
            credentialProvider: providerA,
            makeVoiceActivatedSession: { _ in sessionA },
            makeAgent: { _ in agentA }
        )
        let resolverB = ConversationPreparationResolver(
            settings: settingsB,
            credentialProvider: providerB,
            makeVoiceActivatedSession: { _ in sessionB },
            makeAgent: { _ in agentB }
        )
        let telemetryA = RecordingPreparationTelemetry()
        let telemetryB = RecordingPreparationTelemetry()
        let dependenciesA = VoiceConversationComposition(
            resolver: resolverA,
            requestMicrophonePermission: { true },
            sleep: { _ in },
            reduceMotion: { false },
            telemetry: telemetryA,
            presentationCopy: compositionCopy(marker: "A"),
            monotonicNow: { 101 }
        ).dependencies
        let dependenciesB = VoiceConversationComposition(
            resolver: resolverB,
            requestMicrophonePermission: { false },
            sleep: { _ in },
            reduceMotion: { true },
            telemetry: telemetryB,
            presentationCopy: compositionCopy(marker: "B"),
            monotonicNow: { 202 }
        ).dependencies

        XCTAssertTrue(dependenciesA.voiceActivatedInputAvailable())
        XCTAssertTrue(dependenciesB.voiceActivatedInputAvailable())
        let preparedInputA = try await dependenciesA.prepareSpeechInput(.voiceActivated)
        let preparedInputB = try await dependenciesB.prepareSpeechInput(.voiceActivated)
        guard case .voiceActivated(let returnedSessionA) = preparedInputA,
              case .voiceActivated(let returnedSessionB) = preparedInputB else {
            return XCTFail("Expected isolated voice-activated sessions")
        }
        XCTAssertTrue((returnedSessionA as AnyObject) === sessionA)
        XCTAssertTrue((returnedSessionB as AnyObject) === sessionB)

        let preparedAgentA = try await dependenciesA.prepareAgent()
        let preparedAgentB = try await dependenciesB.prepareAgent()
        XCTAssertTrue((preparedAgentA.agent as AnyObject) === agentA)
        XCTAssertTrue((preparedAgentB.agent as AnyObject) === agentB)
        XCTAssertFalse((preparedAgentA.agent as AnyObject) === agentB)
        XCTAssertFalse((preparedAgentB.agent as AnyObject) === agentA)

        let permissionA = await dependenciesA.requestMicrophonePermission()
        let permissionB = await dependenciesB.requestMicrophonePermission()
        XCTAssertTrue(permissionA)
        XCTAssertFalse(permissionB)
        XCTAssertFalse(dependenciesA.reduceMotion())
        XCTAssertTrue(dependenciesB.reduceMotion())
        XCTAssertTrue((dependenciesA.telemetry as AnyObject) === telemetryA)
        XCTAssertTrue((dependenciesB.telemetry as AnyObject) === telemetryB)
        XCTAssertEqual(dependenciesA.presentationCopy.noSpeech, "A-no-speech")
        XCTAssertEqual(dependenciesB.presentationCopy.noSpeech, "B-no-speech")
        XCTAssertEqual(dependenciesA.monotonicNow(), 101)
        XCTAssertEqual(dependenciesB.monotonicNow(), 202)
        let providerARequestCount = await providerA.requestCount
        let providerBRequestCount = await providerB.requestCount
        XCTAssertEqual(providerARequestCount, 2)
        XCTAssertEqual(providerBRequestCount, 2)
        await preparedInputA.cancel()
        await preparedInputB.cancel()
    }

    func testCompositionUsesResolverModeAndCreatesFreshVoiceSessionsAcrossModeSwitches() async throws {
        let settings = voiceActivatedSettings()
        let originalHandsFree = settings.handsFree
        defer { settings.handsFree = originalHandsFree }
        settings.handsFree = true
        var createdVoiceSessions: [PreparationVoiceActivatedSession] = []
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: StaticPreparationCredentialProvider(),
            makeVoiceActivatedSession: { _ in
                let session = PreparationVoiceActivatedSession()
                createdVoiceSessions.append(session)
                return session
            }
        )
        let dependencies = VoiceConversationComposition(
            resolver: resolver,
            requestMicrophonePermission: { true },
            sleep: { _ in },
            reduceMotion: { false },
            telemetry: RecordingPreparationTelemetry(),
            presentationCopy: .singleGreenDemo,
            monotonicNow: { 0 }
        ).dependencies

        XCTAssertEqual(dependencies.inputMode(), resolver.requestedInputMode)
        XCTAssertEqual(dependencies.inputMode(), .voiceActivated)
        let first = try await dependencies.prepareSpeechInput(dependencies.inputMode())
        guard case .voiceActivated(let firstSession) = first else {
            return XCTFail("Expected the initial voice-activated session")
        }
        XCTAssertTrue((firstSession as AnyObject) === createdVoiceSessions[0])
        XCTAssertEqual(createdVoiceSessions.count, 1)

        XCTAssertTrue(settings.requestSpeechInputMode(.pushToTalk))
        XCTAssertEqual(dependencies.inputMode(), resolver.requestedInputMode)
        XCTAssertEqual(dependencies.inputMode(), .pushToTalk)
        let second = try await dependencies.prepareSpeechInput(dependencies.inputMode())
        XCTAssertEqual(second.mode, .pushToTalk)
        XCTAssertEqual(createdVoiceSessions.count, 1)

        XCTAssertTrue(settings.requestSpeechInputMode(.voiceActivated))
        XCTAssertEqual(dependencies.inputMode(), resolver.requestedInputMode)
        XCTAssertEqual(dependencies.inputMode(), .voiceActivated)
        let third = try await dependencies.prepareSpeechInput(dependencies.inputMode())
        guard case .voiceActivated(let thirdSession) = third else {
            return XCTFail("Expected a fresh voice-activated session after switching back")
        }
        XCTAssertEqual(createdVoiceSessions.count, 2)
        XCTAssertTrue((thirdSession as AnyObject) === createdVoiceSessions[1])
        XCTAssertFalse((firstSession as AnyObject) === (thirdSession as AnyObject))

        let firstArmCount = await createdVoiceSessions[0].armCount
        let firstCancelCount = await createdVoiceSessions[0].cancelCount
        let thirdArmCount = await createdVoiceSessions[1].armCount
        XCTAssertEqual(firstArmCount, 0)
        XCTAssertEqual(firstCancelCount, 0)
        XCTAssertEqual(thirdArmCount, 0)

        await first.cancel()
        await second.cancel()
        await third.cancel()
        let explicitlyCancelledFirstCount = await createdVoiceSessions[0].cancelCount
        let explicitlyCancelledThirdCount = await createdVoiceSessions[1].cancelCount
        XCTAssertEqual(explicitlyCancelledFirstCount, 1)
        XCTAssertEqual(explicitlyCancelledThirdCount, 1)
    }

    func testInjectedAgentFactoryObservesConfigurationAndCachesOnlyMatchingScope() async throws {
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
            .fixture(llmCredential: "credential-one", account: "account-a"),
            .fixture(llmCredential: "credential-two", account: "account-a"),
            .fixture(llmCredential: "credential-three", account: "account-b"),
            .fixture(llmCredential: "credential-four", account: "account-b"),
            .fixture(llmCredential: "credential-five", account: "account-b")
        ])
        let recorder = PreparationAgentFactoryRecorder()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil,
            makeAgent: { configuration in recorder.make(configuration: configuration) }
        )

        let first = try await resolver.prepareAgent()
        let sameScope = try await resolver.prepareAgent()
        XCTAssertEqual(first.contextIdentity, sameScope.contextIdentity)
        XCTAssertTrue((first.agent as AnyObject) === (sameScope.agent as AnyObject))
        XCTAssertEqual(recorder.configurations.count, 1)

        let changedAccount = try await resolver.prepareAgent()
        XCTAssertNotEqual(sameScope.contextIdentity, changedAccount.contextIdentity)

        settings.llmModel = "fixture-model-b"
        let changedModel = try await resolver.prepareAgent()
        XCTAssertNotEqual(changedAccount.contextIdentity, changedModel.contextIdentity)

        settings.enableSearch = true
        let changedToolScope = try await resolver.prepareAgent()
        XCTAssertNotEqual(changedModel.contextIdentity, changedToolScope.contextIdentity)

        XCTAssertEqual(
            recorder.configurations.map(\.scope),
            [
                AgentProviderScope(
                    providerID: "openai-compatible",
                    account: .init(opaqueID: "account-a"),
                    model: "fixture-model-a",
                    externalInformationLookupEnabled: false
                ),
                AgentProviderScope(
                    providerID: "openai-compatible",
                    account: .init(opaqueID: "account-b"),
                    model: "fixture-model-a",
                    externalInformationLookupEnabled: false
                ),
                AgentProviderScope(
                    providerID: "openai-compatible",
                    account: .init(opaqueID: "account-b"),
                    model: "fixture-model-b",
                    externalInformationLookupEnabled: false
                ),
                AgentProviderScope(
                    providerID: "openai-compatible",
                    account: .init(opaqueID: "account-b"),
                    model: "fixture-model-b",
                    externalInformationLookupEnabled: true
                )
            ]
        )
        XCTAssertTrue(recorder.configurations.allSatisfy {
            ($0.credentialProvider as AnyObject) === provider
                && !$0.systemPrompt.isEmpty
        })
        XCTAssertEqual(recorder.agents.count, 4)
        XCTAssertTrue((first.agent as AnyObject) === recorder.agents[0])
        XCTAssertTrue((changedAccount.agent as AnyObject) === recorder.agents[1])
        XCTAssertTrue((changedModel.agent as AnyObject) === recorder.agents[2])
        XCTAssertTrue((changedToolScope.agent as AnyObject) === recorder.agents[3])
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

    func testRefreshingTransportDoesNotRequireSpeechCredential() async throws {
        let lease = ConversationCredentialLease(
            speechAPIKey: "",
            llmAPIKey: "llm-only-credential",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "account-a"),
            expiresAt: .distantFuture
        )
        let provider = SequentialPreparationCredentialProvider(leases: [lease])
        let recorder = TransportCredentialRecorder()
        let transport = CredentialRefreshingLLMChatTransport(
            scope: .fixture(account: "account-a"),
            credentialProvider: provider,
            makeTransport: { credential, _ in
                RecordingChatTransport(credentialMarker: credential, recorder: recorder)
            }
        )

        _ = try await transport.completeMessage(
            messages: [.init(role: .user, content: "llm only")],
            temperature: nil,
            maxTokens: nil,
            tools: nil
        )

        let observed = await recorder.values
        XCTAssertEqual(observed, ["llm-only-credential"])
    }

    func testSpeechPreparationDoesNotRequireLLMCredential() async throws {
        let settings = AISettings(buildPolicy: .serverManaged)
        let lease = ConversationCredentialLease(
            speechAPIKey: "speech-only-credential",
            llmAPIKey: "",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "account-a"),
            expiresAt: .distantFuture
        )
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: SequentialPreparationCredentialProvider(leases: [lease]),
            makeVoiceActivatedSession: nil
        )

        let prepared = try await resolver.prepareSpeechInput(mode: .pushToTalk)

        XCTAssertEqual(prepared.mode, .pushToTalk)
        await prepared.cancel()
    }

    func testAgentPreparationDoesNotRequireSpeechCredential() async throws {
        let settings = AISettings(buildPolicy: .serverManaged)
        settings.enableSearch = false
        let lease = ConversationCredentialLease(
            speechAPIKey: "",
            llmAPIKey: "llm-only-credential",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "account-a"),
            expiresAt: .distantFuture
        )
        let recorder = PreparationAgentFactoryRecorder()
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: SequentialPreparationCredentialProvider(leases: [lease]),
            makeVoiceActivatedSession: nil,
            makeAgent: recorder.make
        )

        _ = try await resolver.prepareAgent()

        XCTAssertEqual(recorder.configurations.count, 1)
        XCTAssertEqual(recorder.configurations.first?.scope.account.opaqueID, "account-a")
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

    func testRefreshingSearchDoesNotRequireSpeechOrLLMCredentials() async throws {
        let lease = ConversationCredentialLease(
            speechAPIKey: "",
            llmAPIKey: "",
            searchAPIKey: "fixture-search-only-key",
            agentAccountScope: .init(opaqueID: "account-fixture"),
            expiresAt: .distantFuture
        )
        let factoryCounter = ThreadSafeFactoryCounter()
        let networkCounter = ThreadSafeFactoryCounter()
        let executor = CredentialRefreshingSearchToolExecutor(
            scope: .fixture(account: "account-fixture"),
            credentialProvider: FixedPreparationCredentialProvider(lease: lease),
            makeExecutor: { credential in
                XCTAssertEqual(credential, "fixture-search-only-key")
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

        _ = try await executor.execute(call)

        XCTAssertEqual(factoryCounter.value, 1)
        XCTAssertEqual(networkCounter.value, 1)
    }

    func testLiveAdapterMapsRawSearchToolToSemanticCoreActivity() {
        XCTAssertEqual(
            ProductionConversationAgentFactory.toolActivity(for: "web_search"),
            .externalInformationLookup
        )
        XCTAssertNil(
            ProductionConversationAgentFactory.toolActivity(for: "unrelated_tool")
        )
    }

    func testLiveAdapterPolicyMapsTypedErrorsToReviewedCopyOnly() {
        XCTAssertEqual(
            ProductionConversationAgentFactory.streamError(
                for: LLMStreamingError.incompleteStream
            ),
            .failed("模型流未正常完成。", .incompleteStream)
        )
        XCTAssertEqual(
            ProductionConversationAgentFactory.streamError(
                for: LLMAgentStreamError.discardPartialMixedContentAndToolCall
            ),
            .discardPartial("模型同时返回正文和工具调用，已丢弃不可信的部分正文")
        )
        XCTAssertEqual(
            ProductionConversationAgentFactory.streamError(
                for: BochaSearchClient.BochaError.apiError(
                    statusCode: 401,
                    message: PreparationFixtureError.sentinel
                )
            ),
            .failed("搜索服务凭证未通过验证。", .unauthorized)
        )

        let unknown = ProductionConversationAgentFactory.streamError(
            for: PreparationFixtureError.sensitiveDetectorFailure
        )
        XCTAssertEqual(unknown, .failed("回答流程暂时中断。", .interrupted))
        XCTAssertFalse(unknown.localizedDescription.contains(PreparationFixtureError.sentinel))
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

    private func compositionCopy(marker: String) -> ConversationPresentationCopy {
        ConversationPresentationCopy(
            voiceActivatedUnavailable: "\(marker)-voice-unavailable",
            microphonePermissionDenied: "\(marker)-permission-denied",
            speechRecognitionUnavailable: "\(marker)-speech-unavailable",
            noSpeech: "\(marker)-no-speech",
            replyPreparationUnavailable: "\(marker)-reply-unavailable",
            emptyReply: "\(marker)-empty-reply",
            inconsistentReplyStream: "\(marker)-inconsistent-stream",
            incompleteReplyStream: "\(marker)-incomplete-stream",
            unexpectedReplyFailure: "\(marker)-unexpected-failure",
            interruptedReplyPrefix: "\(marker)-interrupted:",
            failedReplyPrefix: "\(marker)-failed:",
            contextCommitFailed: "\(marker)-commit-failed"
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

private struct FixedPreparationCredentialProvider: ConversationCredentialProvider {
    let leaseValue: ConversationCredentialLease

    init(lease: ConversationCredentialLease) {
        leaseValue = lease
    }

    func lease() async throws -> ConversationCredentialLease { leaseValue }
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

@MainActor
private final class PreparationConversationAgent: ConversationAgent {
    let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(marker))
            continuation.finish()
        }
    }

    func clearContext() async {}
}

@MainActor
private final class PreparationAgentFactoryRecorder {
    private(set) var configurations: [AgentProviderConfiguration] = []
    private(set) var agents: [PreparationConversationAgent] = []

    func make(configuration: AgentProviderConfiguration) -> any ConversationAgent {
        configurations.append(configuration)
        let agent = PreparationConversationAgent(marker: "agent-\(agents.count)")
        agents.append(agent)
        return agent
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

@MainActor
private final class RecordingPreparationTelemetry: ConversationTelemetrySink {
    private(set) var events: [ConversationTelemetryEvent] = []

    func record(_ event: ConversationTelemetryEvent) {
        events.append(event)
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
