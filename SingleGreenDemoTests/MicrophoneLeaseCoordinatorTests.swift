import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class MicrophoneLeaseCoordinatorTests: XCTestCase {
    func testActivePushToTalkLeaseRejectsVoiceActivatedArmUntilTerminal() async throws {
        let coordinator = MicrophoneLeaseCoordinator()
        let pushToTalkBase = LeaseTestSpeechSession()
        let voiceActivatedBase = LeaseTestVoiceActivatedSession()
        let pushToTalk = MicrophoneLeasedSpeechRecognitionSession(
            base: pushToTalkBase,
            coordinator: coordinator
        )
        let voiceActivated = MicrophoneLeasedVoiceActivatedSpeechRecognitionSession(
            base: voiceActivatedBase,
            coordinator: coordinator
        )

        try await pushToTalk.start()
        await assertAudioUnavailable { try await voiceActivated.arm() }

        await pushToTalkBase.emit(.finished)
        await waitUntil { await coordinator.hasActiveLease == false }
        try await voiceActivated.arm()

        let counts = await voiceActivatedBase.counts
        XCTAssertEqual(counts.arm, 1)
        await voiceActivated.cancel()
    }

    func testStartFailureReleasesLeaseForAnotherFeature() async throws {
        let coordinator = MicrophoneLeaseCoordinator()
        let failedBase = LeaseTestSpeechSession(
            startError: SpeechRecognitionFailure(code: .networkUnavailable)
        )
        let failed = MicrophoneLeasedSpeechRecognitionSession(
            base: failedBase,
            coordinator: coordinator
        )
        let nextBase = LeaseTestVoiceActivatedSession()
        let next = MicrophoneLeasedVoiceActivatedSpeechRecognitionSession(
            base: nextBase,
            coordinator: coordinator
        )

        do {
            try await failed.start()
            XCTFail("Expected configured start failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechRecognitionFailure,
                SpeechRecognitionFailure(code: .networkUnavailable)
            )
        }
        try await next.arm()

        let failedCounts = await failedBase.counts
        XCTAssertEqual(failedCounts.cancel, 1)
        let hasActiveLease = await coordinator.hasActiveLease
        XCTAssertTrue(hasActiveLease)
        await next.cancel()
    }

    func testCancelHoldsLeaseUntilUnderlyingResourceRetires() async throws {
        let coordinator = MicrophoneLeaseCoordinator()
        let cancelGate = LeaseTestGate()
        let firstBase = LeaseTestSpeechSession(cancelGate: cancelGate)
        let first = MicrophoneLeasedSpeechRecognitionSession(
            base: firstBase,
            coordinator: coordinator
        )
        let secondBase = LeaseTestVoiceActivatedSession()
        let second = MicrophoneLeasedVoiceActivatedSpeechRecognitionSession(
            base: secondBase,
            coordinator: coordinator
        )
        try await first.start()

        let cancellation = Task { await first.cancel() }
        await waitUntil { await cancelGate.waiterCount == 1 }
        await assertAudioUnavailable { try await second.arm() }

        await cancelGate.open()
        await cancellation.value
        try await second.arm()
        await second.cancel()
    }

    func testNoSpeechReleasesVoiceActivatedLease() async throws {
        let coordinator = MicrophoneLeaseCoordinator()
        let voiceBase = LeaseTestVoiceActivatedSession()
        let voice = MicrophoneLeasedVoiceActivatedSpeechRecognitionSession(
            base: voiceBase,
            coordinator: coordinator
        )
        let nextBase = LeaseTestSpeechSession()
        let next = MicrophoneLeasedSpeechRecognitionSession(
            base: nextBase,
            coordinator: coordinator
        )

        try await voice.arm()
        await voiceBase.emit(.noSpeech)
        await waitUntil { await coordinator.hasActiveLease == false }
        try await next.start()

        await next.cancel()
    }

    private func assertAudioUnavailable(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected microphone lease contention")
        } catch {
            XCTAssertEqual(
                error as? SpeechRecognitionFailure,
                SpeechRecognitionFailure(code: .audioUnavailable)
            )
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private actor LeaseTestSpeechSession: SpeechRecognitionSession {
    struct Counts: Sendable {
        let start: Int
        let finish: Int
        let cancel: Int
    }

    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private let startError: (any Error)?
    private let cancelGate: LeaseTestGate?
    private var startCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(
        startError: (any Error)? = nil,
        cancelGate: LeaseTestGate? = nil
    ) {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.startError = startError
        self.cancelGate = cancelGate
    }

    var counts: Counts {
        Counts(start: startCount, finish: finishCount, cancel: cancelCount)
    }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
        await cancelGate?.wait()
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }
}

private actor LeaseTestVoiceActivatedSession: VoiceActivatedSpeechRecognitionSession {
    struct Counts: Sendable {
        let arm: Int
        let finish: Int
        let cancel: Int
    }

    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation
    private var armCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    var counts: Counts {
        Counts(arm: armCount, finish: finishCount, cancel: cancelCount)
    }

    func arm() async throws {
        armCount += 1
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }

    func emit(_ event: VoiceActivatedRecognitionEvent) {
        continuation.yield(event)
    }
}

private actor LeaseTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

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
