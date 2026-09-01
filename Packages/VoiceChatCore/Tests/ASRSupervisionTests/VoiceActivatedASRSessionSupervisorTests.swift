import ASRDomain
import XCTest
@testable import ASRSupervision

final class VoiceActivatedASRSessionSupervisorTests: XCTestCase {
    func testArmFailureRecoversWithFreshSessionBeforeSpeechOnset() async throws {
        let first = TestSupervisedVoiceActivatedSession(
            armFailure: ASRFailure(code: .timeout)
        )
        let second = TestSupervisedVoiceActivatedSession()
        let factory = TestVoiceActivatedSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)

        try await supervisor.arm()

        let state = await supervisor.state
        let callCount = await factory.callCount
        XCTAssertEqual(state, .active(recoveryAttempt: 1))
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(first.operations, [.arm, .cancel])
        XCTAssertEqual(second.operations, [.arm])
    }

    func testFailureBeforeOnsetRecoversAndRejectsRetiredSessionEvents() async throws {
        let first = TestSupervisedVoiceActivatedSession()
        let second = TestSupervisedVoiceActivatedSession()
        let factory = TestVoiceActivatedSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        let recorder = VoiceActivatedSupervisorEventRecorder()
        let observation = Task {
            for await event in supervisor.events { await recorder.record(event) }
        }
        defer { observation.cancel() }
        try await supervisor.arm()

        first.emit(.state(.failed(ASRFailure(code: .connectionLost))))
        await waitUntil { await factory.callCount == 2 }
        first.emit(.transcript("stale"))
        second.emit(.state(.armed))
        second.emit(.transcript("fresh"))
        await waitUntil { await recorder.transcripts == ["fresh"] }

        let state = await supervisor.state
        XCTAssertEqual(state, .active(recoveryAttempt: 1))
        XCTAssertEqual(first.operations, [.arm, .cancel])
    }

    func testAcceptedSpeechOnsetForbidsRecoveryBeforeTranscript() async throws {
        let first = TestSupervisedVoiceActivatedSession()
        let replacement = TestSupervisedVoiceActivatedSession()
        let factory = TestVoiceActivatedSupervisorFactory(sessions: [first, replacement])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.arm()

        first.emit(.state(.openingRecognizer))
        await waitUntil { await supervisor.state == .active(recoveryAttempt: 0) }
        first.emit(.state(.failed(ASRFailure(code: .networkUnavailable))))
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .degraded(ASRSessionDegradation(
            failure: ASRFailure(code: .networkUnavailable),
            disposition: .retryableFailure,
            recoveryAttemptCount: 0
        )))
        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(replacement.operations.isEmpty)
    }

    func testNoSpeechCompletesWithoutOpeningRecoverySession() async throws {
        let session = TestSupervisedVoiceActivatedSession()
        let replacement = TestSupervisedVoiceActivatedSession()
        let factory = TestVoiceActivatedSupervisorFactory(sessions: [session, replacement])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.arm()

        session.emit(.state(.armed))
        session.emit(.noSpeech)

        let terminal = await waitForTerminal(supervisor)
        let callCount = await factory.callCount
        XCTAssertEqual(terminal, .completed)
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(replacement.operations.isEmpty)
    }

    func testEagerInitialSessionIsUsedBeforeRecoveryFactory() async throws {
        let initial = TestSupervisedVoiceActivatedSession()
        let replacement = TestSupervisedVoiceActivatedSession()
        let factory = TestVoiceActivatedSupervisorFactory(sessions: [replacement])
        let policy = try! ASRSessionRecoveryPolicy(
            maximumRecoveryAttempts: 1,
            exhaustedDisposition: .retryableFailure
        )
        let supervisor = VoiceActivatedASRSessionSupervisor(
            initialSession: initial,
            policy: policy,
            recoveryFactory: { try await factory.makeSession() }
        )

        try await supervisor.arm()
        let initialFactoryCallCount = await factory.callCount
        XCTAssertEqual(initialFactoryCallCount, 0)
        initial.emit(.state(.failed(ASRFailure(code: .timeout))))
        await waitUntil {
            let callCount = await factory.callCount
            let state = await supervisor.state
            return callCount == 1 && state == .active(recoveryAttempt: 1)
        }

        let state = await supervisor.state
        XCTAssertEqual(state, .active(recoveryAttempt: 1))
        XCTAssertEqual(initial.operations, [.arm, .cancel])
        XCTAssertEqual(replacement.operations, [.arm])
    }

    private func makeSupervisor(
        maximumRecoveryAttempts: Int,
        factory: TestVoiceActivatedSupervisorFactory
    ) -> VoiceActivatedASRSessionSupervisor {
        let policy = try! ASRSessionRecoveryPolicy(
            maximumRecoveryAttempts: maximumRecoveryAttempts,
            exhaustedDisposition: .retryableFailure
        )
        return VoiceActivatedASRSessionSupervisor(policy: policy) {
            try await factory.makeSession()
        }
    }

    private func waitForTerminal(
        _ supervisor: VoiceActivatedASRSessionSupervisor
    ) async -> ASRSessionSupervisorState {
        var last = await supervisor.state
        for _ in 0..<1_000 {
            switch last {
            case .completed, .degraded, .failed:
                return last
            case .idle, .preparing, .active, .finalizing, .recovering:
                await Task.yield()
                last = await supervisor.state
            }
        }
        XCTFail("Supervisor did not reach a terminal state; last state: \(last)")
        return last
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private final class TestSupervisedVoiceActivatedSession:
    SupervisedVoiceActivatedASRSession,
    @unchecked Sendable {
    enum Operation: Equatable {
        case arm
        case finish
        case cancel
    }

    let events: AsyncStream<VoiceActivatedASREvent>
    private let continuation: AsyncStream<VoiceActivatedASREvent>.Continuation
    private let armFailure: ASRFailure?
    private let lock = NSLock()
    private var recordedOperations: [Operation] = []

    init(armFailure: ASRFailure? = nil) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.armFailure = armFailure
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func arm() async throws {
        lock.withLock { recordedOperations.append(.arm) }
        if let armFailure { throw armFailure }
    }

    func finish() async {
        lock.withLock { recordedOperations.append(.finish) }
    }

    func cancel() async {
        lock.withLock { recordedOperations.append(.cancel) }
    }

    func emit(_ event: VoiceActivatedASREvent) {
        continuation.yield(event)
    }
}

private actor TestVoiceActivatedSupervisorFactory {
    private var sessions: [TestSupervisedVoiceActivatedSession]
    private(set) var callCount = 0

    init(sessions: [TestSupervisedVoiceActivatedSession]) {
        self.sessions = sessions
    }

    func makeSession() throws -> any SupervisedVoiceActivatedASRSession {
        callCount += 1
        guard !sessions.isEmpty else { throw ASRFailure(code: .unknown) }
        return sessions.removeFirst()
    }
}

private actor VoiceActivatedSupervisorEventRecorder {
    private(set) var transcripts: [String] = []

    func record(_ event: VoiceActivatedASREvent) {
        if case .transcript(let text) = event { transcripts.append(text) }
    }
}
