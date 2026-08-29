import StreamingTextKit
import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class VoiceConversationDependenciesTests: XCTestCase {
    func testGroupedInitializerForwardsEveryDependencyWithoutCrossWiring() async throws {
        let speechSession = FakeSpeechSession()
        let conversationAgent = FakeConversationAgent()
        let telemetry = RecordingTelemetry()
        let contextIdentity = ConversationAgentContextIdentity()
        let policy = TypewriterPolicy(
            tickIntervalMilliseconds: 81,
            shortBacklogLimit: 9,
            mediumBacklogLimit: 27,
            mediumBatchSize: 3,
            minimumLargeBatchSize: 5,
            catchUpTickBudget: 11
        )
        var preparedMode: SpeechInputMode?
        var sleptFor: Duration?

        let dependencies = VoiceConversationDependencies(
            input: VoiceConversationInputDependencies(
                inputMode: { .pushToTalk },
                voiceActivatedInputAvailable: { true },
                prepareSpeechInput: { mode in
                    preparedMode = mode
                    return .pushToTalk(speechSession)
                },
                requestMicrophonePermission: { false }
            ),
            agent: VoiceConversationAgentDependencies(
                prepareAgent: {
                    PreparedConversationAgent(
                        contextIdentity: contextIdentity,
                        agent: conversationAgent
                    )
                }
            ),
            presentation: VoiceConversationPresentationDependencies(
                sleep: { duration in sleptFor = duration },
                reduceMotion: { true },
                streamingTextPolicy: policy,
                copy: .dependencyFixture
            ),
            observability: VoiceConversationObservabilityDependencies(
                telemetry: telemetry,
                monotonicNow: { 42 }
            )
        )

        XCTAssertEqual(dependencies.inputMode(), .pushToTalk)
        XCTAssertTrue(dependencies.voiceActivatedInputAvailable())
        let preparedInput = try await dependencies.prepareSpeechInput(.pushToTalk)
        XCTAssertEqual(preparedMode, .pushToTalk)
        XCTAssertEqual(preparedInput.mode, .pushToTalk)
        let permissionGranted = await dependencies.requestMicrophonePermission()
        XCTAssertFalse(permissionGranted)

        let preparedAgent = try await dependencies.prepareAgent()
        XCTAssertEqual(preparedAgent.contextIdentity, contextIdentity)
        XCTAssertTrue((preparedAgent.agent as AnyObject) === conversationAgent)

        try await dependencies.sleep(.milliseconds(17))
        XCTAssertEqual(sleptFor, .milliseconds(17))
        XCTAssertTrue(dependencies.reduceMotion())
        XCTAssertEqual(dependencies.streamingTextPolicy, policy)
        XCTAssertEqual(dependencies.presentationCopy, .dependencyFixture)
        XCTAssertTrue((dependencies.telemetry as AnyObject) === telemetry)
        XCTAssertEqual(dependencies.monotonicNow(), 42)
    }

    func testFlatInitializerStillCompilesWhenAllExistingDefaultsAreOmitted() {
        let dependencies = VoiceConversationDependencies(
            inputMode: { .pushToTalk },
            voiceActivatedInputAvailable: { false },
            prepareSpeechInput: { _ in
                throw DependencyFixtureError.unused
            },
            prepareAgent: {
                throw DependencyFixtureError.unused
            },
            requestMicrophonePermission: { true },
            sleep: { _ in },
            presentationCopy: .dependencyFixture
        )

        XCTAssertFalse(dependencies.reduceMotion())
        XCTAssertEqual(dependencies.streamingTextPolicy, .comfortableReading)
        XCTAssertTrue(dependencies.telemetry is NoopConversationTelemetry)
        XCTAssertGreaterThan(dependencies.monotonicNow(), 0)
        XCTAssertEqual(dependencies.presentationCopy, .dependencyFixture)
    }

    func testGroupedInitializersPreservePresentationAndObservabilityDefaults() {
        let presentation = VoiceConversationPresentationDependencies(
            sleep: { _ in },
            copy: .dependencyFixture
        )
        let dependencies = VoiceConversationDependencies(
            input: VoiceConversationInputDependencies(
                inputMode: { .voiceActivated },
                voiceActivatedInputAvailable: { false },
                prepareSpeechInput: { _ in throw DependencyFixtureError.unused },
                requestMicrophonePermission: { false }
            ),
            agent: VoiceConversationAgentDependencies(
                prepareAgent: { throw DependencyFixtureError.unused }
            ),
            presentation: presentation
        )

        XCTAssertFalse(presentation.reduceMotion())
        XCTAssertEqual(presentation.streamingTextPolicy, .comfortableReading)
        XCTAssertTrue(dependencies.observability.telemetry is NoopConversationTelemetry)
        XCTAssertGreaterThan(dependencies.observability.monotonicNow(), 0)
    }
}

private enum DependencyFixtureError: Error {
    case unused
}

private extension ConversationPresentationCopy {
    static let dependencyFixture = Self(
        voiceActivatedUnavailable: "Voice activation unavailable",
        microphonePermissionDenied: "Microphone permission denied",
        speechRecognitionUnavailable: "Speech recognition unavailable",
        noSpeech: "No speech",
        replyPreparationUnavailable: "Reply preparation unavailable",
        emptyReply: "Empty reply",
        inconsistentReplyStream: "Inconsistent reply stream",
        incompleteReplyStream: "Incomplete reply stream",
        unexpectedReplyFailure: "Unexpected reply failure",
        interruptedReplyPrefix: "Interrupted: ",
        failedReplyPrefix: "Failed: ",
        contextCommitFailed: "Context commit failed"
    )
}
