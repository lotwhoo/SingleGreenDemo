import ASRDomain
import Foundation

/// A fresh provider session used for one supervisor attempt. Implementations must finish their
/// event stream only when that concrete session is retired; a recovery attempt receives a new
/// instance from `ASRSessionSupervisorFactory`.
public protocol SupervisedASRSession: AnyObject, Sendable {
    var events: AsyncStream<ASRSessionEvent> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

public typealias ASRSessionSupervisorFactory =
    @Sendable () async throws -> any SupervisedASRSession

public enum ASRSessionDegradationDisposition: Equatable, Sendable {
    /// The feature keeps its authored/manual controls active and does not present an automatic retry.
    case manualControl
    /// The feature presents a user-initiated retry without attempting to preserve partial content.
    case retryableFailure
}

public struct ASRSessionDegradation: Error, Equatable, Sendable {
    public let failure: ASRFailure
    public let disposition: ASRSessionDegradationDisposition
    public let recoveryAttemptCount: Int

    public init(
        failure: ASRFailure,
        disposition: ASRSessionDegradationDisposition,
        recoveryAttemptCount: Int
    ) {
        self.failure = failure
        self.disposition = disposition
        self.recoveryAttemptCount = recoveryAttemptCount
    }
}

public enum ASRSessionRecoveryPolicyError: Error, Equatable, Sendable {
    case negativeMaximumRecoveryAttempts
}

/// Recovery counts are intentionally caller supplied. There is no guessed production default until
/// the real route/network fault matrix establishes retry and backoff values.
public struct ASRSessionRecoveryPolicy: Equatable, Sendable {
    public let maximumRecoveryAttempts: Int
    public let exhaustedDisposition: ASRSessionDegradationDisposition

    public init(
        maximumRecoveryAttempts: Int,
        exhaustedDisposition: ASRSessionDegradationDisposition
    ) throws {
        guard maximumRecoveryAttempts >= 0 else {
            throw ASRSessionRecoveryPolicyError.negativeMaximumRecoveryAttempts
        }
        self.maximumRecoveryAttempts = maximumRecoveryAttempts
        self.exhaustedDisposition = exhaustedDisposition
    }

    public static func disabled(
        disposition: ASRSessionDegradationDisposition
    ) -> ASRSessionRecoveryPolicy {
        try! ASRSessionRecoveryPolicy(
            maximumRecoveryAttempts: 0,
            exhaustedDisposition: disposition
        )
    }

    func permitsRecovery(
        from failure: ASRFailure,
        recoveryAttemptCount: Int,
        hasPublishedContent: Bool,
        isFinalizing: Bool
    ) -> Bool {
        guard recoveryAttemptCount < maximumRecoveryAttempts,
              !hasPublishedContent,
              !isFinalizing else { return false }
        return switch failure.code {
        case .networkUnavailable, .timeout, .connectionLost:
            true
        case .unauthorized, .protocolFailure, .audioInterrupted, .audioUnavailable,
             .voiceActivityUnavailable, .voiceActivityProcessingFailed,
             .audioCaptureOverrun, .uploadBackpressureExceeded, .unknown:
            false
        }
    }

    func shouldDegrade(from failure: ASRFailure) -> Bool {
        switch failure.code {
        case .networkUnavailable, .timeout, .connectionLost:
            true
        case .unauthorized, .protocolFailure, .audioInterrupted, .audioUnavailable,
             .voiceActivityUnavailable, .voiceActivityProcessingFailed,
             .audioCaptureOverrun, .uploadBackpressureExceeded, .unknown:
            false
        }
    }
}

public enum ASRSessionSupervisorState: Equatable, Sendable {
    case idle
    case preparing(recoveryAttempt: Int)
    case active(recoveryAttempt: Int)
    case finalizing(recoveryAttempt: Int)
    case recovering(nextRecoveryAttempt: Int, failure: ASRFailure)
    case completed
    case degraded(ASRSessionDegradation)
    case failed(ASRFailure)
}

public enum ASRSessionSupervisorEvent: Equatable, Sendable {
    case state(ASRSessionSupervisorState)
    case transcript(String)
    case utterance(String)
    case level(Float)
}

public enum ASRSessionSupervisorError: Error, Equatable, Sendable {
    case busy
}

/// Owns one logical recognition run and replaces concrete provider sessions only while retrying is
/// lossless: before any transcript/utterance is published and before finalization begins.
public actor ASRSessionSupervisor {
    private struct Retirement {
        let id: UInt64
        let task: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<ASRSessionSupervisorEvent>
    public private(set) var state: ASRSessionSupervisorState = .idle

    private let policy: ASRSessionRecoveryPolicy
    private let factory: ASRSessionSupervisorFactory
    private let continuation: AsyncStream<ASRSessionSupervisorEvent>.Continuation

    private var runGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var activeSessionGeneration: UInt64?
    private var activeSession: (any SupervisedASRSession)?
    private var observationTask: Task<Void, Never>?
    private var retirementGeneration: UInt64 = 0
    private var pendingRetirement: Retirement?
    private var isCancelling = false
    private var recoveryAttemptCount = 0
    private var hasPublishedContent = false
    private var isFinalizing = false

    public init(
        policy: ASRSessionRecoveryPolicy,
        factory: @escaping ASRSessionSupervisorFactory
    ) {
        let (events, continuation) = AsyncStream<ASRSessionSupervisorEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.policy = policy
        self.factory = factory
    }

    deinit {
        observationTask?.cancel()
        continuation.finish()
    }

    public func start() async throws {
        guard canStart else { throw ASRSessionSupervisorError.busy }
        runGeneration &+= 1
        let generation = runGeneration
        recoveryAttemptCount = 0
        hasPublishedContent = false
        isFinalizing = false
        transition(to: .preparing(recoveryAttempt: 0))
        try await prepareSession(runGeneration: generation)
    }

    public func finish() async {
        let sessionToFinish: (any SupervisedASRSession)?
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
        isFinalizing = false
        isCancelling = false
        transition(to: .idle)
    }

    private var canStart: Bool {
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
        let candidate: any SupervisedASRSession
        do {
            candidate = try await factory()
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
            try await candidate.start()
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
        _ session: any SupervisedASRSession,
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
        _ event: ASRSessionEvent,
        runGeneration: UInt64,
        sessionGeneration: UInt64
    ) async {
        guard isCurrent(
            runGeneration: runGeneration,
            sessionGeneration: sessionGeneration
        ) else { return }
        switch event {
        case .state(.recording):
            if !isFinalizing {
                transition(to: .active(recoveryAttempt: recoveryAttemptCount))
            }
        case .state(.finalizing):
            isFinalizing = true
            transition(to: .finalizing(recoveryAttempt: recoveryAttemptCount))
        case .state(.finished):
            complete(
                runGeneration: runGeneration,
                sessionGeneration: sessionGeneration
            )
        case .state(.failed(let failure)), .error(let failure):
            do {
                try await recoverOrTerminate(failure, runGeneration: runGeneration)
            } catch {
                // The typed terminal state is already emitted. Start-time callers receive the same
                // error synchronously; asynchronous event consumers observe it through `events`.
            }
        case .state(.idle), .state(.starting):
            break
        case .transcript(let text):
            if !text.isEmpty { hasPublishedContent = true }
            continuation.yield(.transcript(text))
        case .utterance(let text):
            if !text.isEmpty { hasPublishedContent = true }
            continuation.yield(.utterance(text))
        case .level(let level):
            continuation.yield(.level(level))
        }
    }

    private func recoverOrTerminate(
        _ failure: ASRFailure,
        runGeneration generation: UInt64
    ) async throws {
        guard generation == runGeneration else { throw CancellationError() }
        let mayRecover = policy.permitsRecovery(
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
        continuation.yield(.state(next))
    }
}
