import Foundation
import SingleGreenGlassesKit

struct MicrophoneLeaseToken: Hashable, Sendable {
    fileprivate let id: UUID
}

enum MicrophoneLeaseCoordinatorError: Error, Equatable, Sendable {
    case busy
}

/// App-process arbitration for features that can independently prepare microphone sessions.
/// The coordinator is non-preemptive: a second feature fails closed instead of stopping the owner.
actor MicrophoneLeaseCoordinator {
    private var activeLease: MicrophoneLeaseToken?

    func acquire() throws -> MicrophoneLeaseToken {
        guard activeLease == nil else { throw MicrophoneLeaseCoordinatorError.busy }
        let lease = MicrophoneLeaseToken(id: UUID())
        activeLease = lease
        return lease
    }

    func release(_ lease: MicrophoneLeaseToken) {
        guard activeLease == lease else { return }
        activeLease = nil
    }

    var hasActiveLease: Bool {
        activeLease != nil
    }
}

actor MicrophoneLeasedSpeechRecognitionSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>

    private let base: any SpeechRecognitionSession
    private let coordinator: MicrophoneLeaseCoordinator
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private var observationTask: Task<Void, Never>?
    private var lease: MicrophoneLeaseToken?
    private var isStarting = false
    private var isCancelled = false

    init(
        base: any SpeechRecognitionSession,
        coordinator: MicrophoneLeaseCoordinator
    ) {
        self.base = base
        self.coordinator = coordinator
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    deinit {
        observationTask?.cancel()
        continuation.finish()
        let base = base
        let coordinator = coordinator
        let lease = lease
        Task {
            await base.cancel()
            if let lease { await coordinator.release(lease) }
        }
    }

    func start() async throws {
        guard !isCancelled, lease == nil, !isStarting else {
            throw SpeechRecognitionFailure(code: .audioUnavailable)
        }
        isStarting = true
        let acquiredLease: MicrophoneLeaseToken
        do {
            acquiredLease = try await coordinator.acquire()
        } catch {
            isStarting = false
            throw SpeechRecognitionFailure(code: .audioUnavailable)
        }
        guard !isCancelled, lease == nil else {
            isStarting = false
            await coordinator.release(acquiredLease)
            throw CancellationError()
        }
        lease = acquiredLease
        startObservingIfNeeded()

        do {
            try await base.start()
        } catch {
            isStarting = false
            await base.cancel()
            await release(ifMatching: acquiredLease)
            throw error
        }
        isStarting = false
        guard !isCancelled, lease == acquiredLease else {
            await base.cancel()
            await coordinator.release(acquiredLease)
            throw CancellationError()
        }
    }

    func finish() async {
        guard !isCancelled, lease != nil else { return }
        await base.finish()
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        observationTask?.cancel()
        observationTask = nil
        let leaseToRelease = lease
        lease = nil
        await base.cancel()
        if let leaseToRelease { await coordinator.release(leaseToRelease) }
        continuation.finish()
    }

    private func receive(_ event: SpeechRecognitionEvent) async -> Bool {
        guard !isCancelled else { return false }
        continuation.yield(event)
        switch event {
        case .finished, .failed:
            await releaseCurrentLease()
            continuation.finish()
            observationTask = nil
            return false
        case .transcript, .utterance, .level:
            return true
        }
    }

    private func startObservingIfNeeded() {
        guard observationTask == nil else { return }
        let base = base
        observationTask = Task { [weak self, base] in
            for await event in base.events {
                guard !Task.isCancelled else { return }
                guard await self?.receive(event) == true else { return }
            }
            await self?.sourceClosed()
        }
    }

    private func sourceClosed() async {
        await releaseCurrentLease()
        continuation.finish()
        observationTask = nil
    }

    private func releaseCurrentLease() async {
        guard let lease else { return }
        self.lease = nil
        await coordinator.release(lease)
    }

    private func release(ifMatching candidate: MicrophoneLeaseToken) async {
        if lease == candidate { lease = nil }
        await coordinator.release(candidate)
    }
}

actor MicrophoneLeasedVoiceActivatedSpeechRecognitionSession:
    VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>

    private let base: any VoiceActivatedSpeechRecognitionSession
    private let coordinator: MicrophoneLeaseCoordinator
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation
    private var observationTask: Task<Void, Never>?
    private var lease: MicrophoneLeaseToken?
    private var isArming = false
    private var isCancelled = false

    init(
        base: any VoiceActivatedSpeechRecognitionSession,
        coordinator: MicrophoneLeaseCoordinator
    ) {
        self.base = base
        self.coordinator = coordinator
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    deinit {
        observationTask?.cancel()
        continuation.finish()
        let base = base
        let coordinator = coordinator
        let lease = lease
        Task {
            await base.cancel()
            if let lease { await coordinator.release(lease) }
        }
    }

    func arm() async throws {
        guard !isCancelled, lease == nil, !isArming else {
            throw SpeechRecognitionFailure(code: .audioUnavailable)
        }
        isArming = true
        let acquiredLease: MicrophoneLeaseToken
        do {
            acquiredLease = try await coordinator.acquire()
        } catch {
            isArming = false
            throw SpeechRecognitionFailure(code: .audioUnavailable)
        }
        guard !isCancelled, lease == nil else {
            isArming = false
            await coordinator.release(acquiredLease)
            throw CancellationError()
        }
        lease = acquiredLease
        startObservingIfNeeded()

        do {
            try await base.arm()
        } catch {
            isArming = false
            await base.cancel()
            await release(ifMatching: acquiredLease)
            throw error
        }
        isArming = false
        guard !isCancelled, lease == acquiredLease else {
            await base.cancel()
            await coordinator.release(acquiredLease)
            throw CancellationError()
        }
    }

    func finish() async {
        guard !isCancelled, lease != nil else { return }
        await base.finish()
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        observationTask?.cancel()
        observationTask = nil
        let leaseToRelease = lease
        lease = nil
        await base.cancel()
        if let leaseToRelease { await coordinator.release(leaseToRelease) }
        continuation.finish()
    }

    private func receive(_ event: VoiceActivatedRecognitionEvent) async -> Bool {
        guard !isCancelled else { return false }
        continuation.yield(event)
        switch event {
        case .noSpeech, .finished, .failed:
            await releaseCurrentLease()
            continuation.finish()
            observationTask = nil
            return false
        case .phase, .transcript, .utterance, .level:
            return true
        }
    }

    private func startObservingIfNeeded() {
        guard observationTask == nil else { return }
        let base = base
        observationTask = Task { [weak self, base] in
            for await event in base.events {
                guard !Task.isCancelled else { return }
                guard await self?.receive(event) == true else { return }
            }
            await self?.sourceClosed()
        }
    }

    private func sourceClosed() async {
        await releaseCurrentLease()
        continuation.finish()
        observationTask = nil
    }

    private func releaseCurrentLease() async {
        guard let lease else { return }
        self.lease = nil
        await coordinator.release(lease)
    }

    private func release(ifMatching candidate: MicrophoneLeaseToken) async {
        if lease == candidate { lease = nil }
        await coordinator.release(candidate)
    }
}
