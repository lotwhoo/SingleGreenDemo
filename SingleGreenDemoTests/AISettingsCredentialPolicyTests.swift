import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class AISettingsCredentialPolicyTests: XCTestCase {
    func testServerManagedPolicyPublishesFailClosedStatus() {
        let policy = AISettingsBuildPolicy.serverManaged

        XCTAssertFalse(policy.allowsDemoCredentialStorage)
        XCTAssertEqual(policy.credentialStatus.title, "服务端凭证未接入")
        XCTAssertFalse(policy.credentialStatus.isAvailable)
    }

    func testPersistedHandsFreeRequestIsPreservedButHasNoEffectiveModeWithoutDetector() {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorPending
        )
        let original = settings.handsFree
        defer { settings.handsFree = original }

        settings.handsFree = true
        let dependencies = VoiceConversationDependencies.live(settings: settings)

        XCTAssertEqual(settings.requestedSpeechInputMode, .voiceActivated)
        XCTAssertNil(settings.effectiveSpeechInputMode)
        XCTAssertEqual(dependencies.inputMode(), .voiceActivated)
        XCTAssertFalse(dependencies.voiceActivatedInputAvailable())
        XCTAssertTrue(settings.speechInputAvailability.voiceActivatedDetail.contains("不会"))
    }

    func testLiveCompositionPublishesVoiceActivationAvailabilityWithoutReadingCredentials() {
        #if DEBUG
        let store = RecordingDemoCredentialStore()
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorAvailable,
            demoCredentialStore: store
        )
        #else
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorAvailable
        )
        #endif
        let dependencies = VoiceConversationDependencies.live(settings: settings)

        XCTAssertTrue(settings.speechInputAvailability.voiceActivatedIsAvailable)
        XCTAssertTrue(dependencies.voiceActivatedInputAvailable())
        XCTAssertFalse(settings.speechInputAvailability.voiceActivatedDetail.contains("WebRTC"))
        #if DEBUG
        XCTAssertEqual(store.operations, [])
        #endif
    }

    func testProductionAppCompositionOptsIntoLinkedDetectorCapability() {
        let settings = SingleGreenDemoApp.makeAISettings()
        let dependencies = VoiceConversationDependencies.live(settings: settings)

        XCTAssertTrue(settings.speechInputAvailability.voiceActivatedIsAvailable)
        XCTAssertTrue(dependencies.voiceActivatedInputAvailable())
    }

    func testPersistedHandsFreeRequestBecomesEffectiveWhenProductionDetectorIsAvailable() {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorAvailable
        )
        let original = settings.handsFree
        defer { settings.handsFree = original }

        settings.handsFree = true
        let reloadedSettings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorAvailable
        )
        let dependencies = VoiceConversationDependencies.live(settings: reloadedSettings)

        XCTAssertEqual(reloadedSettings.requestedSpeechInputMode, .voiceActivated)
        XCTAssertEqual(reloadedSettings.effectiveSpeechInputMode, .voiceActivated)
        XCTAssertEqual(dependencies.inputMode(), .voiceActivated)
        XCTAssertTrue(dependencies.voiceActivatedInputAvailable())
    }

    func testUnavailableVoiceActivatedModeCannotBeNewlySelected() {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorPending
        )
        let original = settings.handsFree
        defer { settings.handsFree = original }

        settings.handsFree = false

        XCTAssertFalse(settings.requestSpeechInputMode(.voiceActivated))
        XCTAssertEqual(settings.requestedSpeechInputMode, .pushToTalk)
        XCTAssertEqual(settings.effectiveSpeechInputMode, .pushToTalk)
    }

    func testPushToTalkRemainsSelectableFromMigratedUnavailablePreference() {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorPending
        )
        let original = settings.handsFree
        defer { settings.handsFree = original }

        settings.handsFree = true

        XCTAssertTrue(settings.requestSpeechInputMode(.pushToTalk))
        XCTAssertEqual(settings.requestedSpeechInputMode, .pushToTalk)
        XCTAssertEqual(settings.effectiveSpeechInputMode, .pushToTalk)
        XCTAssertEqual(
            VoiceConversationDependencies.live(settings: settings).inputMode(),
            .pushToTalk
        )
    }

    #if DEBUG
    func testInternalBuildPolicyMakesDemoModeExplicit() {
        let policy = AISettingsBuildPolicy.internalDemo

        XCTAssertTrue(policy.allowsDemoCredentialStorage)
        XCTAssertEqual(policy.credentialStatus.title, "内部演示模式")
        XCTAssertTrue(policy.credentialStatus.isAvailable)
    }

    func testServerManagedSettingsNeverReadOrWriteDemoCredentialStore() {
        let store = RecordingDemoCredentialStore()
        let settings = AISettings(
            buildPolicy: .serverManaged,
            demoCredentialStore: store
        )

        settings.speechAPIKey = "fixture-value"
        settings.llmAPIKey = "fixture-value"
        settings.bochaAPIKey = "fixture-value"

        XCTAssertEqual(settings.speechAPIKey, "")
        XCTAssertEqual(settings.llmAPIKey, "")
        XCTAssertEqual(settings.bochaAPIKey, "")
        XCTAssertEqual(store.operations, [])
    }

    func testServerManagedCompositionFailsClosedDuringHostPreparation() async {
        let store = RecordingDemoCredentialStore()
        let settings = AISettings(
            buildPolicy: .serverManaged,
            demoCredentialStore: store
        )
        let dependencies = VoiceConversationDependencies.live(settings: settings)

        XCTAssertEqual(store.operations, [])

        do {
            _ = try await dependencies.prepareSpeechInput(.pushToTalk)
            XCTFail("Expected server-managed preparation to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ConversationPreparationFailure,
                ConversationPreparationFailure(
                    userSafeMessage: "暂时无法准备对话服务，请稍后重试。",
                    failureCode: .preparationUnavailable
                )
            )
        }
        XCTAssertEqual(store.operations, [])
    }

    func testInternalDemoSettingsUseInjectedCredentialStore() {
        let store = RecordingDemoCredentialStore()
        let settings = AISettings(
            buildPolicy: .internalDemo,
            demoCredentialStore: store
        )

        settings.speechAPIKey = "  fixture-value  "

        XCTAssertEqual(settings.speechAPIKey, "fixture-value")
        XCTAssertEqual(
            store.operations,
            [.save("asr.apiKey", "fixture-value"), .load("asr.apiKey")]
        )
    }

    func testDemoLLMRevisionPreservesSameAndSearchCredentialScopeButIsolatesChangedLLMKey() async throws {
        let store = RecordingDemoCredentialStore()
        let revisions = RevisionSequence([
            "revision-one", "revision-two", "revision-three"
        ])
        let settings = AISettings(
            buildPolicy: .internalDemo,
            demoCredentialStore: store,
            makeCredentialRevision: { revisions.next() }
        )
        let originalModel = settings.llmModel
        let originalSearch = settings.enableSearch
        defer {
            settings.llmModel = originalModel
            settings.enableSearch = originalSearch
        }
        settings.llmModel = "fixture-model"
        settings.enableSearch = true
        settings.speechAPIKey = "speech-fixture"
        settings.bochaAPIKey = "search-version-one"
        settings.llmAPIKey = "llm-version-one"

        let provider = DemoKeychainCredentialProvider(settings: settings)
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: provider,
            makeVoiceActivatedSession: nil
        )
        let first = try await resolver.prepareAgent()
        let firstLease = try await provider.lease()

        settings.llmAPIKey = "llm-version-one"
        let sameSavedKey = try await resolver.prepareAgent()
        let sameSavedKeyLease = try await provider.lease()
        XCTAssertEqual(first.contextIdentity, sameSavedKey.contextIdentity)
        XCTAssertEqual(firstLease.agentAccountScope, sameSavedKeyLease.agentAccountScope)

        settings.bochaAPIKey = "search-version-two"
        let changedSearchCredential = try await resolver.prepareAgent()
        let changedSearchLease = try await provider.lease()
        XCTAssertEqual(sameSavedKey.contextIdentity, changedSearchCredential.contextIdentity)
        XCTAssertEqual(sameSavedKeyLease.agentAccountScope, changedSearchLease.agentAccountScope)

        settings.llmAPIKey = "llm-version-two"
        let changedLLMKey = try await resolver.prepareAgent()
        let changedLLMLease = try await provider.lease()
        XCTAssertNotEqual(changedSearchCredential.contextIdentity, changedLLMKey.contextIdentity)
        XCTAssertNotEqual(changedSearchLease.agentAccountScope, changedLLMLease.agentAccountScope)

        settings.llmAPIKey = ""
        let deletedLease = try await provider.lease()
        settings.llmAPIKey = ""
        let repeatedDeleteLease = try await provider.lease()
        XCTAssertNotEqual(changedLLMLease.agentAccountScope, deletedLease.agentAccountScope)
        XCTAssertEqual(deletedLease.agentAccountScope, repeatedDeleteLease.agentAccountScope)
        XCTAssertEqual(revisions.consumedCount, 3)
    }
    #endif
}

#if DEBUG
@MainActor
private final class RecordingDemoCredentialStore: DemoCredentialStore {
    enum Operation: Equatable {
        case load(String)
        case save(String, String)
        case delete(String)
    }

    private var values: [String: String] = [:]
    private(set) var operations: [Operation] = []

    func load(_ key: String) -> String? {
        operations.append(.load(key))
        return values[key]
    }

    func save(_ value: String, forKey key: String) -> Bool {
        operations.append(.save(key, value))
        values[key] = value
        return true
    }

    func delete(_ key: String) -> Bool {
        operations.append(.delete(key))
        values[key] = nil
        return true
    }
}

@MainActor
private final class RevisionSequence {
    private var values: [String]
    private(set) var consumedCount = 0

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        consumedCount += 1
        return values.isEmpty ? "unexpected-extra-revision" : values.removeFirst()
    }
}
#endif
