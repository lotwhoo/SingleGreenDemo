import ASRDomain
import Foundation

/// A fresh one-utterance voice-activated provider session used for one supervised attempt.
/// Implementations must keep capture and transport inactive until `arm()` is called.
public protocol SupervisedVoiceActivatedASRSession: AnyObject, Sendable {
    var events: AsyncStream<VoiceActivatedASREvent> { get }
    func arm() async throws
    func finish() async
    func cancel() async
}

public typealias VoiceActivatedASRSessionSupervisorFactory =
    @Sendable () async throws -> any SupervisedVoiceActivatedASRSession

public enum VoiceActivatedASRSessionSupervisorError: Error, Equatable, Sendable {
    case busy
}

/// Supervises one logical voice-activated recognition run. A replacement session is admitted only
/// before speech onset, before content publication, and before finalization. Once local VAD accepts
/// onset, restarting would lose the utterance pre-roll, so recovery fails closed even if the provider
/// has not published text yet.
public actor VoiceActivatedASRSessionSupervisor {
    private struct Retirement {
        let id: UInt64
        let task: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<VoiceActivatedASREvent>
    public private(set) var state: ASRSessionSupervisorState = .idle

    private let policy: ASRSessionRecoveryPolicy
    private let factory: VoiceActivatedASRSessionSupervisorFactory
    private let continuation: AsyncStream<VoiceActivatedASREvent>.Continuation

    private var initialSession: (any SupervisedVoiceActivatedASRSession)?
    private var runGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var activeSessionGeneration: UInt64?
    private var activeSession: (any SupervisedVoiceActivatedASRSession)?
    private var observationTask: Task<Void, Never>?
    private var retirementGeneration: UInt64 = 0
    private var pendingRetirement: Retirement?
    private var isCancelling = false
    private var recoveryAttemptCount = 0
    private var hasPublishedContent = false
    private var hasAcceptedSpeechOnset = false
    private var isFinalizing = false

    public init(
        policy: ASRSessionRecoveryPolicy,
        factory: @escaping VoiceActivatedASRSessionSupervisorFactory
    ) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.policy = policy
        self.factory = factory
        self.initialSession = nil
    }

    /// Preserves eager preparation validation while still requiring a fresh instance for recovery.
    public init(
        initialSession: any SupervisedVoiceActivatedASRSession,
        policy: ASRSessionRecoveryPolicy,
        recoveryFactory: @escaping VoiceActivatedASRSessionSupervisorFactory
    ) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.policy = policy
        self.factory = recoveryFactory
        self.initialSession = initialSession
    }

    deinit {
        observationTask?.cancel()
        continuation.finish()
    }

    public func arm() async throws {
        guard canArm else { throw VoiceActivatedASRSessionSupervisorError.busy }
        runGeneration &+= 1
        let generation = runGeneration
        recoveryAttemptCount = 0
        hasPublishedContent = false
        hasAcceptedSpeechOnset = false
        isFinalizing = false
        transition(to: .preparing(recoveryAttempt: 0))
        try await prepareSession(runGeneration: generation)
    }

    public func finish() async {
        let sessionToFinish: (any SupervisedVoiceActivatedASRSession)?
        switch state {
        case .active:
            sessionToFinish = activeSession
        case .preparing, .recovering:
            sessionToFinish = nil
        case .idle, .finalizing, .completed, .degraded, .failed:
            return
        }
        isFinalizing = true
        transition(to: .finalizing(recoveryAttempt: recoveryAttemptCount))
        await sessionToFinish?.finish()
    }

    public func cancel() async {
        guard !isCancelling else { return }
        guard state != .idle || activeSession != nil || pendingRetirement != nil else { return }
        isCancelling = true
        runGeneration &+= 1
        let cancellationGeneration = runGeneration
        let retirement = retireActiveSession()
        await awaitRetirement(retirement)
        guard runGeneration == cancellationGeneration else { return }
        recoveryAttemptCount = 0
        hasPublishedContent = false
        hasAcceptedSpeechOnset = false
        isFinalizing = false
        isCancelling = false
        transition(to: .idle)
    }

    private var canArm: Bool {
        guard !isCancelling, pendingRetirement == nil else { return false }
        return switch state {
        case .idle, .completed, .degraded, .failed:
            true
        case .preparing, .active, .finalizing, .recovering:
            false
        }
    }

    private func prepareSession(runGeneration generation: UInt64) async throws {
        guard generation == runGeneration else { throw CancellationError() }
        let candidate: any SupervisedVoiceActivatedASRSession
        do {
            if let eagerSession = initialSession {
                initialSession = nil
                candidate = eagerSession
            } else {
                candidate = try await factory()
            }
        } catch {
            try await recoverOrTerminate(
                (error as? ASRFailure) ?? ASRFailure(code: .unknown),
                runGeneration: generation
            )
            return
        }
        guard generation == runGeneration else {
            await candidate.cancel()
            throw CancellationError()
        }

        sessionGeneration &+= 1
        let concreteGeneration = sessionGeneration
        activeSessionGeneration = concreteGeneration
        activeSession = candidate

        do {
            try await candidate.arm()
        } catch {
            guard isCurrent(
                runGeneration: generation,
                sessionGeneration: concreteGeneration
            ) else {
                throw CancellationError()
            }
            try await recoverOrTerminate(
                (error as? ASRFailure) ?? ASRFailure(code: .unknown),
                runGeneration: generation
            )
            return
        }
        observe(
            candidate,
            runGeneration: generation,
            sessionGeneration: concreteGeneration
        )

        guard isCurrent(
            runGeneration: generation,
            sessionGeneration: concreteGeneration
        ) else {
            if generation != runGeneration { throw CancellationError() }
            return
        }
        if isFinalizing {
            transition(to: .finalizing(recoveryAttempt: recoveryAttemptCount))
            await candidate.finish()
            return
        }
        switch state {
        case .preparing, .recovering:
            transition(to: .active(recoveryAttempt: recoveryAttemptCount))
        case .idle, .active, .finalizing, .completed, .degraded, .failed:
            break
        }
    }

    private func observe(
        _ session: any SupervisedVoiceActivatedASRSession,
        runGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                await self?.receive(
                    event,
                    runGeneration: runGeneration,
                    sessionGeneration: sessionGeneration
                )
            }
        }
    }

    private func receive(
        _ event: VoiceActivatedASREvent,
        runGeneration: UInt64,
        sessionGeneration: UInt64
    ) async {
        guard isCurrent(
            runGeneration: runGeneration,
            sessionGeneration: sessionGeneration
        ) else { return }
        switch event {
        case .state(.arming):
            continuation.yield(event)
        case .state(.armed):
            if !isFinalizing {
                transition(to: .active(recoveryAttempt: recoveryAttemptCount))
            }
            continuation.yield(event)
        case .state(.openingRecognizer), .state(.streaming):
            hasAcceptedSpeechOnset = true
            if !isFinalizing {
                transition(to: .active(recoveryAttempt: recoveryAttemptCount))
            }
            continuation.yield(event)
        case .state(.draining), .state(.finalizing):
            isFinalizing = true
            transition(to: .finalizing(recoveryAttempt: recoveryAttemptCount))
            continuation.yield(event)
        case .state(.finished):
            continuation.yield(event)
            complete(
                runGeneration: runGeneration,
                sessionGeneration: sessionGeneration
            )
        case .state(.failed(let failure)):
            do {
                try await recoverOrTerminate(failure, runGeneration: runGeneration)
            } catch {
                // The typed terminal state and provider-neutral failure event are already emitted.
            }
        case .state(.idle):
            continuation.yield(event)
        case .transcript(let text):
            if !text.isEmpty { hasPublishedContent = true }
            continuation.yield(event)
        case .utterance(let text):
            if !text.isEmpty { hasPublishedContent = true }
            continuation.yield(event)
        case .level:
            continuation.yield(event)
        case .noSpeech:
            continuation.yield(event)
            complete(
                runGeneration: runGeneration,
                sessionGeneration: sessionGeneration
            )
        }
    }

    private func recoverOrTerminate(
        _ failure: ASRFailure,
        runGeneration generation: UInt64
    ) async throws {
        guard generation == runGeneration else { throw CancellationError() }
        let mayRecover = !hasAcceptedSpeechOnset && policy.permitsRecovery(
            from: failure,
            recoveryAttemptCount: recoveryAttemptCount,
            hasPublishedContent: hasPublishedContent,
            isFinalizing: isFinalizing
        )
        let retirement = retireActiveSession()

        if mayRecover {
            let nextRecoveryAttempt = recoveryAttemptCount + 1
            transition(to: .recovering(
                nextRecoveryAttempt: nextRecoveryAttempt,
                failure: failure
            ))
            await awaitRetirement(retirement)
            guard generation == runGeneration else { throw CancellationError() }
            if isFinalizing {
                try terminate(with: failure)
            }
            recoveryAttemptCount = nextRecoveryAttempt
            try await prepareSession(runGeneration: generation)
            return
        }

        await awaitRetirement(retirement)
        guard generation == runGeneration else { throw CancellationError() }
        try terminate(with: failure)
    }

    private func terminate(with failure: ASRFailure) throws -> Never {
        continuation.yield(.state(.failed(failure)))
        if policy.shouldDegrade(from: failure) {
            let degradation = ASRSessionDegradation(
                failure: failure,
                disposition: policy.exhaustedDisposition,
                recoveryAttemptCount: recoveryAttemptCount
            )
            transition(to: .degraded(degradation))
            throw degradation
        }
        transition(to: .failed(failure))
        throw failure
    }

    private func complete(
        runGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        guard isCurrent(
            runGeneration: runGeneration,
            sessionGeneration: sessionGeneration
        ) else { return }
        observationTask = nil
        activeSession = nil
        activeSessionGeneration = nil
        isFinalizing = false
        transition(to: .completed)
    }

    private func retireActiveSession() -> Retirement? {
        observationTask?.cancel()
        observationTask = nil
        activeSessionGeneration = nil
        guard let session = activeSession else { return pendingRetirement }
        activeSession = nil
        retirementGeneration &+= 1
        let retirement = Retirement(
            id: retirementGeneration,
            task: Task { await session.cancel() }
        )
        pendingRetirement = retirement
        return retirement
    }

    private func awaitRetirement(_ retirement: Retirement?) async {
        guard let retirement else { return }
        await retirement.task.value
        if pendingRetirement?.id == retirement.id {
            pendingRetirement = nil
        }
    }

    private func isCurrent(
        runGeneration: UInt64,
        sessionGeneration: UInt64
    ) -> Bool {
        self.runGeneration == runGeneration
            && activeSessionGeneration == sessionGeneration
    }

    private func transition(to next: ASRSessionSupervisorState) {
        guard state != next else { return }
        state = next
    }
}
