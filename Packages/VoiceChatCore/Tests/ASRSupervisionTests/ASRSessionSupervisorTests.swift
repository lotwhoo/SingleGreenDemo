import ASRDomain
import XCTest
@testable import ASRSupervision

final class ASRSessionSupervisorTests: XCTestCase {
    func testPolicyRejectsNegativeRecoveryBudget() {
        XCTAssertThrowsError(try ASRSessionRecoveryPolicy(
            maximumRecoveryAttempts: -1,
            exhaustedDisposition: .retryableFailure
        )) { error in
            XCTAssertEqual(
                error as? ASRSessionRecoveryPolicyError,
                .negativeMaximumRecoveryAttempts
            )
        }
    }

    func testStartFailureRecoversWithFreshSessionWithinExplicitBudget() async throws {
        let first = TestSupervisedASRSession(startFailure: ASRFailure(code: .timeout))
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)

        try await supervisor.start()

        let state = await supervisor.state
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(state, .active(recoveryAttempt: 1))
        XCTAssertEqual(factoryCallCount, 2)
        XCTAssertEqual(first.operations, [.start, .cancel])
        XCTAssertEqual(second.operations, [.start])
    }

    func testRecoverableFailureBeforePublishedContentRejectsRetiredSessionEvents() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        let recorder = SupervisorEventRecorder()
        let observation = Task {
            for await event in supervisor.events { await recorder.record(event) }
        }
        defer { observation.cancel() }
        try await supervisor.start()

        first.emit(.state(.failed(ASRFailure(code: .connectionLost))))
        await waitUntil { await factory.callCount == 2 }
        first.emit(.transcript("stale"))
        second.emit(.transcript("fresh"))
        await waitUntil { await recorder.transcripts == ["fresh"] }

        let state = await supervisor.state
        XCTAssertEqual(state, .active(recoveryAttempt: 1))
        XCTAssertEqual(first.operations, [.start, .cancel])
    }

    func testPublishedTranscriptForbidsAutomaticRecovery() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(
            maximumRecoveryAttempts: 2,
            disposition: .manualControl,
            factory: factory
        )
        try await supervisor.start()

        first.emit(.transcript("已经上屏"))
        await waitUntil {
            if case .active = await supervisor.state { return true }
            return false
        }
        first.emit(.state(.failed(ASRFailure(code: .networkUnavailable))))
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .degraded(ASRSessionDegradation(
            failure: ASRFailure(code: .networkUnavailable),
            disposition: .manualControl,
            recoveryAttemptCount: 0
        )))
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 1)
    }

    func testFinalizingForbidsAutomaticRecovery() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 2, factory: factory)
        try await supervisor.start()

        await supervisor.finish()
        first.emit(.state(.failed(ASRFailure(code: .timeout))))
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .degraded(ASRSessionDegradation(
            failure: ASRFailure(code: .timeout),
            disposition: .retryableFailure,
            recoveryAttemptCount: 0
        )))
        XCTAssertEqual(first.operations, [.start, .finish, .cancel])
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 1)
    }

    func testRecoveryExhaustionReturnsTypedDegradation() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.start()

        first.emit(.state(.failed(ASRFailure(code: .networkUnavailable))))
        await waitUntil { await factory.callCount == 2 }
        second.emit(.state(.failed(ASRFailure(code: .connectionLost))))
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .degraded(ASRSessionDegradation(
            failure: ASRFailure(code: .connectionLost),
            disposition: .retryableFailure,
            recoveryAttemptCount: 1
        )))
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 2)
    }

    func testNonRecoverableFailureFailsWithoutConsumingBudget() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 2, factory: factory)
        try await supervisor.start()

        first.emit(.state(.failed(ASRFailure(code: .unauthorized))))
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .failed(ASRFailure(code: .unauthorized)))
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 1)
    }

    func testCancelIsIdempotentAndRejectsLateEvents() async throws {
        let session = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [session])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        let recorder = SupervisorEventRecorder()
        let observation = Task {
            for await event in supervisor.events { await recorder.record(event) }
        }
        defer { observation.cancel() }
        try await supervisor.start()

        await supervisor.cancel()
        await supervisor.cancel()
        session.emit(.transcript("late"))
        await Task.yield()

        let state = await supervisor.state
        let transcripts = await recorder.transcripts
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(session.operations, [.start, .cancel])
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testCompletedSupervisorCanStartFreshRunWithIndependentRecoveryState() async throws {
        let first = TestSupervisedASRSession()
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.start()
        first.emit(.state(.finished))
        _ = await waitForTerminal(supervisor)

        try await supervisor.start()

        let state = await supervisor.state
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(state, .active(recoveryAttempt: 0))
        XCTAssertEqual(factoryCallCount, 2)
    }

    func testCancelDuringGatedRetirementPreventsRecoverySessionOverlap() async throws {
        let retirementGate = TestSupervisorGate()
        let first = TestSupervisedASRSession(cancelGate: retirementGate)
        let second = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, second])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.start()

        first.emit(.state(.failed(ASRFailure(code: .connectionLost))))
        await waitUntil { first.operations.contains(.cancel) }
        let cancellation = Task { await supervisor.cancel() }
        for _ in 0..<10 { await Task.yield() }

        let stateWhileRetiring = await supervisor.state
        let callsWhileRetiring = await factory.callCount
        XCTAssertEqual(
            stateWhileRetiring,
            .recovering(
                nextRecoveryAttempt: 1,
                failure: ASRFailure(code: .connectionLost)
            )
        )
        XCTAssertEqual(callsWhileRetiring, 1)

        await retirementGate.open()
        await cancellation.value
        let stateAfterCancellation = await supervisor.state
        XCTAssertEqual(stateAfterCancellation, .idle)

        try await supervisor.start()
        let restartedState = await supervisor.state
        XCTAssertEqual(restartedState, .active(recoveryAttempt: 0))
        let finalFactoryCallCount = await factory.callCount
        XCTAssertEqual(finalFactoryCallCount, 2)
    }

    func testFinishDuringGatedRecoveryDoesNotOpenReplacementSession() async throws {
        let retirementGate = TestSupervisorGate()
        let first = TestSupervisedASRSession(cancelGate: retirementGate)
        let replacement = TestSupervisedASRSession()
        let factory = TestSupervisorFactory(sessions: [first, replacement])
        let supervisor = makeSupervisor(maximumRecoveryAttempts: 1, factory: factory)
        try await supervisor.start()

        first.emit(.state(.failed(ASRFailure(code: .timeout))))
        await waitUntil { first.operations.contains(.cancel) }
        await supervisor.finish()
        await retirementGate.open()
        let terminal = await waitForTerminal(supervisor)

        XCTAssertEqual(terminal, .degraded(ASRSessionDegradation(
            failure: ASRFailure(code: .timeout),
            disposition: .retryableFailure,
            recoveryAttemptCount: 0
        )))
        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertTrue(replacement.operations.isEmpty)
    }

    private func makeSupervisor(
        maximumRecoveryAttempts: Int,
        disposition: ASRSessionDegradationDisposition = .retryableFailure,
        factory: TestSupervisorFactory
    ) -> ASRSessionSupervisor {
        let policy = try! ASRSessionRecoveryPolicy(
            maximumRecoveryAttempts: maximumRecoveryAttempts,
            exhaustedDisposition: disposition
        )
        return ASRSessionSupervisor(policy: policy) {
            try await factory.makeSession()
        }
    }

    private func waitForTerminal(
        _ supervisor: ASRSessionSupervisor
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

private final class TestSupervisedASRSession: SupervisedASRSession, @unchecked Sendable {
    enum Operation: Equatable {
        case start
        case finish
        case cancel
    }

    let events: AsyncStream<ASRSessionEvent>
    private let continuation: AsyncStream<ASRSessionEvent>.Continuation
    private let startFailure: ASRFailure?
    private let cancelGate: TestSupervisorGate?
    private let storage = NSLock()
    private var recordedOperations: [Operation] = []

    init(
        startFailure: ASRFailure? = nil,
        cancelGate: TestSupervisorGate? = nil
    ) {
        let (events, continuation) = AsyncStream<ASRSessionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.startFailure = startFailure
        self.cancelGate = cancelGate
    }

    var operations: [Operation] {
        storage.withLock { recordedOperations }
    }

    func start() async throws {
        storage.withLock { recordedOperations.append(.start) }
        if let startFailure { throw startFailure }
    }

    func finish() async {
        storage.withLock { recordedOperations.append(.finish) }
    }

    func cancel() async {
        storage.withLock { recordedOperations.append(.cancel) }
        await cancelGate?.wait()
    }

    func emit(_ event: ASRSessionEvent) {
        continuation.yield(event)
    }
}

private actor TestSupervisorGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor TestSupervisorFactory {
    private var sessions: [TestSupervisedASRSession]
    private(set) var callCount = 0

    init(sessions: [TestSupervisedASRSession]) {
        self.sessions = sessions
    }

    func makeSession() throws -> any SupervisedASRSession {
        callCount += 1
        guard !sessions.isEmpty else { throw ASRFailure(code: .unknown) }
        return sessions.removeFirst()
    }
}

private actor SupervisorEventRecorder {
    private var values: [ASRSessionSupervisorEvent] = []

    var transcripts: [String] {
        values.compactMap { event in
            guard case .transcript(let text) = event else { return nil }
            return text
        }
    }

    func record(_ event: ASRSessionSupervisorEvent) {
        values.append(event)
    }
}
