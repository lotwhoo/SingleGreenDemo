import Foundation
import ASRDomain
import VoiceActivityDetectionKit

enum VoiceActivatedASRFinishWorkerWaitPhase: Equatable, Sendable {
    case directFinalizationSelected
    case willAwaitWorker
    case didAwaitWorker
}

enum VoiceActivatedASRCancelRetiringWorkerWaitPhase: Equatable, Sendable {
    case willAwaitWorker
    case didAwaitWorker
}

enum VoiceActivatedASRWorkerRetirementWaitPhase: Equatable, Sendable {
    case willAwait
    case didAwait
}

/// A one-shot local-VAD-gated ASR session. Capture and VAD run locally while armed; the transport is
/// not opened until onset is confirmed. All accepted upload batches are awaited in strict FIFO order.
public actor VoiceActivatedASRSession {
    private struct CleanupBarrier {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private struct WorkerRetirementBarrier {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private struct WorkerHandle {
        let id: UInt64
        let generation: UInt64
        let task: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<VoiceActivatedASREvent>

    public private(set) var state: VoiceActivatedASRState = .idle

    private let frameSource: any PCMFrameSource
    private let transport: any StreamingASRTransport
    private let pipeline: VoiceActivityDetectionPipeline
    private let policy: VoiceActivatedASRPolicy
    private let frameLivenessClock: VoiceActivatedASRMonotonicClock
    private let frameLivenessInterval: Duration
    private let frameLivenessIntervalMilliseconds: UInt64
    private let diagnostics: VoiceActivatedASRDiagnosticsObserver?
    private let diagnosticsDetector: VoiceActivatedASRDiagnosticsDetector?
    private let eventContinuation: AsyncStream<VoiceActivatedASREvent>.Continuation
    private let cleanupWaitHook: (
        @Sendable (UInt64, VoiceActivatedASRCleanupWaitPhase) async -> Void
    )?
    private let finishWorkerWaitHook: (
        @Sendable (UInt64, VoiceActivatedASRFinishWorkerWaitPhase) async -> Void
    )?
    private let cancelRetiringWorkerWaitHook: (
        @Sendable (UInt64, VoiceActivatedASRCancelRetiringWorkerWaitPhase) async -> Void
    )?
    private let workerRetirementWaitHook: (
        @Sendable (UInt64, VoiceActivatedASRWorkerRetirementWaitPhase) async -> Void
    )?
    private let workerExitHook: (@Sendable (UInt64, UInt64) async -> Void)?

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var runState = VoiceActivatedASRRunState()

    private var sourceFrameTask: Task<Void, Never>?
    private var sourceLevelTask: Task<Void, Never>?
    private var transportEventTask: Task<Void, Never>?
    private var nextWorkerID: UInt64 = 0
    private var workerHandle: WorkerHandle?
    private var frameLivenessTask: Task<Void, Never>?
    private var frameLivenessDeadline: Duration?
    private var frameLivenessEpoch: UInt64 = 0
    private var nextCleanupID: UInt64 = 0
    private var cleanupBarrier: CleanupBarrier?
    private var nextWorkerRetirementID: UInt64 = 0
    private var workerRetirementBarrier: WorkerRetirementBarrier?

    public init(
        config: ASRSession.Config,
        detector: any VoiceActivityDetecting,
        policy: VoiceActivatedASRPolicy = .standard
    ) {
        let frameSource = AudioCapturePCMFrameSource(
            maximumBufferedFrameCount: policy.maximumPendingUploadFrameCount
        )
        let transport = ASRClient(config: ASRClient.Config(
            apiKey: config.apiKey,
            resourceID: config.resourceID,
            host: config.host,
            path: config.path,
            language: config.language,
            enableITN: config.enableITN,
            enablePunc: config.enablePunc,
            showUtterances: config.showUtterances,
            hotwords: config.hotwords,
            timeoutInterval: config.timeoutInterval
        ))
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation
        self.frameSource = frameSource
        self.transport = transport
        self.pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: policy.segmentation
        )
        self.policy = policy
        self.frameLivenessClock = .continuous
        self.frameLivenessInterval = Self.frameLivenessInterval(for: policy)
        self.frameLivenessIntervalMilliseconds = Self.frameLivenessIntervalMilliseconds(for: policy)
        self.diagnostics = nil
        self.diagnosticsDetector = nil
        self.cleanupWaitHook = nil
        self.finishWorkerWaitHook = nil
        self.cancelRetiringWorkerWaitHook = nil
        self.workerRetirementWaitHook = nil
        self.workerExitHook = nil
    }

    public init(
        config: ASRSession.Config,
        detector: any VoiceActivityDetecting,
        policy: VoiceActivatedASRPolicy,
        diagnostics: VoiceActivatedASRDiagnosticsObserver?
    ) {
        let frameSource = AudioCapturePCMFrameSource(
            maximumBufferedFrameCount: policy.maximumPendingUploadFrameCount
        )
        let transport = ASRClient(config: ASRClient.Config(
            apiKey: config.apiKey,
            resourceID: config.resourceID,
            host: config.host,
            path: config.path,
            language: config.language,
            enableITN: config.enableITN,
            enablePunc: config.enablePunc,
            showUtterances: config.showUtterances,
            hotwords: config.hotwords,
            timeoutInterval: config.timeoutInterval
        ))
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation
        self.frameSource = frameSource
        self.transport = transport
        let diagnosticsDetector = diagnostics.map {
            _ in VoiceActivatedASRDiagnosticsDetector(base: detector)
        }
        self.pipeline = VoiceActivityDetectionPipeline(
            detector: diagnosticsDetector ?? detector,
            policy: policy.segmentation
        )
        self.policy = policy
        self.frameLivenessClock = .continuous
        self.frameLivenessInterval = Self.frameLivenessInterval(for: policy)
        self.frameLivenessIntervalMilliseconds = Self.frameLivenessIntervalMilliseconds(for: policy)
        self.diagnostics = diagnostics
        self.diagnosticsDetector = diagnosticsDetector
        self.cleanupWaitHook = nil
        self.finishWorkerWaitHook = nil
        self.cancelRetiringWorkerWaitHook = nil
        self.workerRetirementWaitHook = nil
        self.workerExitHook = nil
    }

    init(
        frameSource: any PCMFrameSource,
        detector: any VoiceActivityDetecting,
        transport: any StreamingASRTransport,
        policy: VoiceActivatedASRPolicy,
        frameLivenessClock: VoiceActivatedASRMonotonicClock = .continuous,
        diagnostics: VoiceActivatedASRDiagnosticsObserver? = nil,
        cleanupWaitHook: (
            @Sendable (UInt64, VoiceActivatedASRCleanupWaitPhase) async -> Void
        )? = nil,
        finishWorkerWaitHook: (
            @Sendable (UInt64, VoiceActivatedASRFinishWorkerWaitPhase) async -> Void
        )? = nil,
        cancelRetiringWorkerWaitHook: (
            @Sendable (UInt64, VoiceActivatedASRCancelRetiringWorkerWaitPhase) async -> Void
        )? = nil,
        workerRetirementWaitHook: (
            @Sendable (UInt64, VoiceActivatedASRWorkerRetirementWaitPhase) async -> Void
        )? = nil,
        workerExitHook: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation
        self.frameSource = frameSource
        self.transport = transport
        let diagnosticsDetector = diagnostics.map {
            _ in VoiceActivatedASRDiagnosticsDetector(base: detector)
        }
        self.pipeline = VoiceActivityDetectionPipeline(
            detector: diagnosticsDetector ?? detector,
            policy: policy.segmentation
        )
        self.policy = policy
        self.frameLivenessClock = frameLivenessClock
        self.frameLivenessInterval = Self.frameLivenessInterval(for: policy)
        self.frameLivenessIntervalMilliseconds = Self.frameLivenessIntervalMilliseconds(for: policy)
        self.diagnostics = diagnostics
        self.diagnosticsDetector = diagnosticsDetector
        self.cleanupWaitHook = cleanupWaitHook
        self.finishWorkerWaitHook = finishWorkerWaitHook
        self.cancelRetiringWorkerWaitHook = cancelRetiringWorkerWaitHook
        self.workerRetirementWaitHook = workerRetirementWaitHook
        self.workerExitHook = workerExitHook
    }

    deinit {
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        transportEventTask?.cancel()
        workerHandle?.task.cancel()
        frameLivenessTask?.cancel()
        cleanupBarrier?.task.cancel()
        workerRetirementBarrier?.task.cancel()
        eventContinuation.finish()
    }

    public func arm() async throws {
        while true {
            guard canArm else { throw VoiceActivatedASRSessionError.busy }
            if let cleanupBarrier {
                if let cleanupWaitHook {
                    await cleanupWaitHook(cleanupBarrier.id, .willAwait)
                }
                await cleanupBarrier.task.value
                if let cleanupWaitHook {
                    await cleanupWaitHook(cleanupBarrier.id, .didAwait)
                }
                clearCleanupBarrier(ifMatching: cleanupBarrier.id)
                continue
            }
            if let workerRetirementBarrier {
                await awaitWorkerRetirement(workerRetirementBarrier)
                continue
            }
            break
        }

        // No suspension is allowed between this final admission check and reserving the generation.
        guard canArm, cleanupBarrier == nil, workerRetirementBarrier == nil else {
            throw VoiceActivatedASRSessionError.busy
        }
        generation &+= 1
        let runGeneration = generation
        activeGeneration = runGeneration
        resetRunState()
        transition(to: .arming)

        await diagnosticsDetector?.beginRun(generation: runGeneration)
        await pipeline.reset()
        guard activeGeneration == runGeneration else { throw CancellationError() }

        do {
            observeDiagnostic(.sourceStartRequested(generation: runGeneration))
            let streams = try await frameSource.start()
            guard activeGeneration == runGeneration else {
                await frameSource.stop()
                throw CancellationError()
            }
            runState.acceptingFrames = true
            observeDiagnostic(.sourceStarted(
                generation: runGeneration,
                watchdogIntervalMilliseconds: frameLivenessIntervalMilliseconds
            ))
            await startFrameLivenessWatchdog(generation: runGeneration)
            guard activeGeneration == runGeneration, runState.acceptingFrames else {
                throw CancellationError()
            }
            startSourceTasks(streams: streams, generation: runGeneration)
            transition(to: .armed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = ASRFailure.transport(error)
            observeDiagnostic(.sourceFailed(generation: runGeneration, origin: .sourceStart))
            await fail(failure, generation: runGeneration, origin: .sourceStart)
            throw failure
        }
    }

    public func finish() async {
        guard let runGeneration = activeGeneration else { return }
        switch state {
        case .arming, .armed:
            if !runState.speechStarted {
                await completeNoSpeech(generation: runGeneration)
                return
            }
        case .openingRecognizer, .streaming:
            break
        case .idle, .draining, .finalizing, .finished, .failed:
            return
        }

        runState.manualFinishRequested = true
        transition(to: .draining(.manual))
        runState.sourceStopExpected = true
        cancelFrameLivenessWatchdog()
        let finishingSourceTask = sourceFrameTask
        await frameSource.stop()
        await finishingSourceTask?.value
        guard activeGeneration == runGeneration else { return }
        runState.acceptingFrames = false
        if !runState.hasQueuedFrames, workerHandle == nil {
            let finalizer = startDirectFinalizer(generation: runGeneration)
            if let finishWorkerWaitHook {
                await finishWorkerWaitHook(runGeneration, .directFinalizationSelected)
            }
            await finalizer.task.value
            return
        }
        let worker = workerHandle
        startWorkerIfNeeded(generation: runGeneration)
        let workerToAwait = worker ?? workerHandle
        if let finishWorkerWaitHook {
            await finishWorkerWaitHook(runGeneration, .willAwaitWorker)
        }
        await workerToAwait?.task.value
        if let finishWorkerWaitHook {
            await finishWorkerWaitHook(runGeneration, .didAwaitWorker)
        }
    }

    public func cancel() async {
        guard activeGeneration != nil else {
            if state != .idle { transition(to: .idle) }
            while cleanupBarrier != nil || workerRetirementBarrier != nil {
                if let cleanupBarrier {
                    await cleanupBarrier.task.value
                    clearCleanupBarrier(ifMatching: cleanupBarrier.id)
                }
                if let workerRetirementBarrier {
                    await awaitWorkerRetirement(workerRetirementBarrier)
                }
            }
            return
        }
        let retiringWorker = workerHandle?.task
        let shouldCancelTransport = runState.transportAttempted
        let terminalStage = diagnosticTerminalStage
        observeDiagnostic(.terminal(
            generation: activeGeneration ?? generation,
            stage: terminalStage,
            outcome: .cancelled
        ))
        let workerRetirement = startWorkerRetirement(for: retiringWorker)
        invalidateActiveRun(terminalState: .idle)
        let cleanup = startCleanup(
            cancelTransport: shouldCancelTransport,
            retiringWorker: retiringWorker
        )
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
        if let workerRetirement {
            await awaitWorkerRetirement(workerRetirement)
        }
    }

    private var canArm: Bool {
        activeGeneration == nil && {
            switch state {
            case .idle, .finished, .failed:
                true
            default:
                false
            }
        }()
    }

    private func resetRunState() {
        cancelFrameLivenessWatchdog()
        runState.reset()
        sourceFrameTask = nil
        sourceLevelTask = nil
        transportEventTask = nil
        workerHandle = nil
    }

    private static func frameLivenessInterval(for policy: VoiceActivatedASRPolicy) -> Duration {
        let boundedMilliseconds = frameLivenessIntervalMilliseconds(for: policy)
        return .milliseconds(Int64(boundedMilliseconds))
    }

    private static func frameLivenessIntervalMilliseconds(
        for policy: VoiceActivatedASRPolicy
    ) -> UInt64 {
        let frameCount = UInt64(policy.noSpeechFrameLimit)
        let frameDuration = UInt64(VADPCMFrame.durationMilliseconds)
        let (milliseconds, overflowed) = frameCount.multipliedReportingOverflow(by: frameDuration)
        let maximumMilliseconds = UInt64(Int64.max)
        return overflowed ? maximumMilliseconds : min(milliseconds, maximumMilliseconds)
    }

    private func startFrameLivenessWatchdog(generation runGeneration: UInt64) async {
        cancelFrameLivenessWatchdog()
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }

        let now = await frameLivenessClock.now()
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }

        frameLivenessEpoch &+= 1
        let watchdogEpoch = frameLivenessEpoch
        frameLivenessDeadline = now + frameLivenessInterval
        let clock = frameLivenessClock
        frameLivenessTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let deadline = await self?.currentFrameLivenessDeadline(
                    generation: runGeneration,
                    epoch: watchdogEpoch
                ) else { return }
                await clock.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                guard let shouldContinue = await self?.frameLivenessWatchdogWoke(
                    generation: runGeneration,
                    epoch: watchdogEpoch
                ), shouldContinue else { return }
            }
        }
    }

    private func currentFrameLivenessDeadline(
        generation runGeneration: UInt64,
        epoch watchdogEpoch: UInt64
    ) -> Duration? {
        guard activeGeneration == runGeneration,
              runState.acceptingFrames,
              frameLivenessEpoch == watchdogEpoch else { return nil }
        return frameLivenessDeadline
    }

    private func frameLivenessWatchdogWoke(
        generation runGeneration: UInt64,
        epoch watchdogEpoch: UInt64
    ) async -> Bool {
        guard activeGeneration == runGeneration,
              runState.acceptingFrames,
              frameLivenessEpoch == watchdogEpoch,
              let deadline = frameLivenessDeadline else { return false }

        let now = await frameLivenessClock.now()
        guard activeGeneration == runGeneration,
              runState.acceptingFrames,
              frameLivenessEpoch == watchdogEpoch,
              frameLivenessDeadline == deadline else { return true }
        guard now >= deadline else { return true }

        observeDiagnostic(.watchdogExpired(
            generation: runGeneration,
            intervalMilliseconds: frameLivenessIntervalMilliseconds,
            progress: runState.diagnosticProgress
        ))
        await fail(
            .categorized(.audioUnavailable),
            generation: runGeneration,
            origin: .frameWatchdog
        )
        return false
    }

    private func cancelFrameLivenessWatchdog() {
        frameLivenessEpoch &+= 1
        frameLivenessDeadline = nil
        frameLivenessTask?.cancel()
        frameLivenessTask = nil
    }

    private func startSourceTasks(
        streams: PCMFrameSourceStreams,
        generation runGeneration: UInt64
    ) {
        sourceFrameTask = Task { [weak self] in
            do {
                for try await frame in streams.frames {
                    guard let self else { return }
                    await self.receive(frame: frame, generation: runGeneration)
                }
                guard let self else { return }
                await self.sourceEnded(generation: runGeneration)
            } catch {
                guard let self else { return }
                await self.sourceFailed(error, generation: runGeneration)
            }
        }
        sourceLevelTask = Task { [weak self] in
            for await level in streams.levels {
                guard let self else { return }
                await self.receive(level: level, generation: runGeneration)
            }
        }
    }

    private func receive(frame: VADPCMFrame, generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }
        guard runState.canAcceptFrame(
            maximumPendingFrameCount: policy.maximumPendingUploadFrameCount
        ) else {
            await fail(
                .categorized(.uploadBackpressureExceeded),
                generation: runGeneration,
                origin: .uploadBackpressure
            )
            return
        }

        let acceptedAt = await frameLivenessClock.now()
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }
        guard runState.canAcceptFrame(
            maximumPendingFrameCount: policy.maximumPendingUploadFrameCount
        ) else {
            await fail(
                .categorized(.uploadBackpressureExceeded),
                generation: runGeneration,
                origin: .uploadBackpressure
            )
            return
        }
        if let currentDeadline = frameLivenessDeadline {
            guard acceptedAt < currentDeadline else {
                await fail(
                    .categorized(.audioUnavailable),
                    generation: runGeneration,
                    origin: .frameWatchdog
                )
                return
            }
            frameLivenessDeadline = acceptedAt + frameLivenessInterval
        } else {
            guard isDrainingManualCapture else {
                await fail(
                    .categorized(.audioUnavailable),
                    generation: runGeneration,
                    origin: .frameWatchdog
                )
                return
            }
        }
        runState.enqueueFrame(frame)
        observeDiagnostic(.progress(
            generation: runGeneration,
            trigger: .frameAccepted,
            progress: runState.diagnosticProgress
        ))
        startWorkerIfNeeded(generation: runGeneration)
    }

    private var isDrainingManualCapture: Bool {
        guard runState.manualFinishRequested, runState.sourceStopExpected else { return false }
        if case .draining(.manual) = state { return true }
        return false
    }

    private func receive(level: Float, generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }
        eventContinuation.yield(.level(min(max(level, 0), 1)))
    }

    private func sourceEnded(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration, runState.acceptingFrames else { return }
        if runState.sourceStopExpected { return }
        observeDiagnostic(.sourceFailed(generation: runGeneration, origin: .sourceEnded))
        await fail(
            .categorized(.audioUnavailable),
            generation: runGeneration,
            origin: .sourceEnded
        )
    }

    private func sourceFailed(_ error: any Error, generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration else { return }
        let failure: ASRFailure
        if let typedFailure = error as? ASRFailure {
            failure = typedFailure
        } else if let sourceFailure = error as? PCMFrameSourceFailure {
            failure = switch sourceFailure {
            case .bufferOverflow: .categorized(.audioCaptureOverrun)
            case .invalidFrame: .categorized(.voiceActivityUnavailable)
            case .audioUnavailable: .categorized(.audioUnavailable)
            case .audioSystemEvent(let event):
                ASRFailure.audioSystemEvent(event) ?? .categorized(.audioUnavailable)
            }
        } else {
            failure = .categorized(.audioUnavailable)
        }
        observeDiagnostic(.sourceFailed(generation: runGeneration, origin: .sourceStream))
        await fail(failure, generation: runGeneration, origin: .sourceStream)
    }

    private func startWorkerIfNeeded(generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration,
              workerHandle == nil,
              runState.hasQueuedFrames else { return }
        nextWorkerID &+= 1
        let workerID = nextWorkerID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runWorker(generation: runGeneration)
            await self.workerDidExit(id: workerID, generation: runGeneration)
        }
        workerHandle = WorkerHandle(id: workerID, generation: runGeneration, task: task)
    }

    private func startDirectFinalizer(generation runGeneration: UInt64) -> WorkerHandle {
        nextWorkerID &+= 1
        let workerID = nextWorkerID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runDirectFinalizer(generation: runGeneration)
            await self.workerDidExit(id: workerID, generation: runGeneration)
        }
        let handle = WorkerHandle(id: workerID, generation: runGeneration, task: task)
        workerHandle = handle
        return handle
    }

    private func runDirectFinalizer(generation runGeneration: UInt64) async {
        await finalize(
            reason: .manual,
            diagnosticEndpoint: .manual,
            generation: runGeneration
        )
    }

    private func runWorker(generation runGeneration: UInt64) async {
        while activeGeneration == runGeneration, !Task.isCancelled {
            guard let frame = runState.dequeueFrame() else { break }
            let segmentationEvents: [VADSegmentationEvent]
            do {
                segmentationEvents = try await pipeline.process(frame)
            } catch is CancellationError {
                return
            } catch {
                await fail(
                    .categorized(.voiceActivityProcessingFailed),
                    generation: runGeneration,
                    origin: .detectorProcessing
                )
                return
            }

            guard activeGeneration == runGeneration, !Task.isCancelled else { return }
            if let isSpeech = await diagnosticsDetector?.takeClassification(
                sequence: frame.sequence,
                generation: runGeneration
            ) {
                runState.recordProcessedFrame(isSpeech: isSpeech)
                observeDiagnostic(.progress(
                    generation: runGeneration,
                    trigger: .detectorProcessed,
                    progress: runState.diagnosticProgress
                ))
            }
            if !runState.speechStarted { runState.processedBeforeOnset += 1 }
            do {
                for event in segmentationEvents {
                    try await handle(event, generation: runGeneration)
                    guard activeGeneration == runGeneration, !Task.isCancelled else { return }
                }
                if !runState.speechStarted,
                   runState.processedBeforeOnset >= policy.noSpeechFrameLimit {
                    await completeNoSpeech(generation: runGeneration)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                let failure: ASRFailure
                if let typedFailure = error as? ASRFailure {
                    failure = typedFailure
                } else if error is PCMFrameSourceFailure {
                    failure = .categorized(.uploadBackpressureExceeded)
                } else {
                    failure = ASRFailure.transport(error)
                }
                let origin: VoiceActivatedASRDiagnosticFailureOrigin =
                    error is PCMFrameSourceFailure ? .uploadBackpressure : .transport
                await fail(failure, generation: runGeneration, origin: origin)
                return
            }
        }

        guard activeGeneration == runGeneration else { return }
        if runState.manualFinishRequested {
            await finalize(
                reason: .manual,
                diagnosticEndpoint: .manual,
                generation: runGeneration
            )
        }
    }

    private func workerDidExit(id: UInt64, generation: UInt64) async {
        guard workerHandle?.id == id, workerHandle?.generation == generation else { return }
        workerHandle = nil
        if let workerExitHook { await workerExitHook(id, generation) }
    }

    private func handle(
        _ event: VADSegmentationEvent,
        generation runGeneration: UInt64
    ) async throws {
        switch event {
        case .segmentStarted:
            runState.beginSpeechSegment()
            observeDiagnostic(.segmentStarted(
                generation: runGeneration,
                onsetWindowFrameCount: policy.segmentation.onsetWindowFrameCount,
                onsetRequiredSpeechFrameCount: policy.segmentation.onsetRequiredSpeechFrameCount
            ))
            runState.speechStarted = true
            runState.transportAttempted = true
            transition(to: .openingRecognizer)
            let transportEvents = try await transport.openStream()
            guard activeGeneration == runGeneration else { throw CancellationError() }
            startTransportEvents(transportEvents, generation: runGeneration)
            if runState.manualFinishRequested {
                transition(to: .draining(.manual))
            } else {
                transition(to: .streaming)
            }
        case .frames(_, let frames):
            guard runState.appendUploadFrames(
                frames,
                maximumPendingFrameCount: policy.maximumPendingUploadFrameCount
            ) else {
                throw PCMFrameSourceFailure.bufferOverflow
            }
            try await sendFullBatches(generation: runGeneration)
        case .speechResumed(_, let afterSilentFrameCount):
            observeDiagnostic(.speechResumed(
                generation: runGeneration,
                afterSilentFrameCount: afterSilentFrameCount,
                endpointSilenceFrameCount: policy.segmentation.endpointSilenceFrameCount
            ))
        case .segmentEnded(_, let reason):
            let endpointReason: VoiceActivatedEndpointReason = switch reason {
            case .silence: .silence
            case .maximumDuration: .maximumDuration
            }
            let diagnosticEndpoint: VoiceActivatedASRDiagnosticEndpoint = switch reason {
            case .silence(let count):
                .silence(
                    observedFrameCount: count,
                    thresholdFrameCount: policy.segmentation.endpointSilenceFrameCount
                )
            case .maximumDuration(let count):
                .maximumDuration(
                    observedFrameCount: count,
                    thresholdFrameCount: policy.segmentation.maximumSegmentFrameCount
                )
            }
            let effectiveReason: VoiceActivatedEndpointReason
            let effectiveDiagnosticEndpoint: VoiceActivatedASRDiagnosticEndpoint
            if runState.manualFinishRequested {
                effectiveReason = .manual
                effectiveDiagnosticEndpoint = .manual
            } else {
                effectiveReason = endpointReason
                effectiveDiagnosticEndpoint = diagnosticEndpoint
            }
            await finalize(
                reason: effectiveReason,
                diagnosticEndpoint: effectiveDiagnosticEndpoint,
                generation: runGeneration
            )
        }
    }

    private func sendFullBatches(generation runGeneration: UInt64) async throws {
        while let batch = runState.takeFullUploadBatch(
            frameCount: policy.uploadBatchFrameCount
        ) {
            runState.beginUpload(frameCount: batch.count)
            defer { runState.completeUpload() }
            try await transport.send(frames: batch)
            guard activeGeneration == runGeneration else { throw CancellationError() }
        }
    }

    private func flushPendingUpload(generation runGeneration: UInt64) async throws {
        let pendingFrameCount = runState.pendingUploadFrames.count
        observeDiagnostic(.tailFlushStarted(
            generation: runGeneration,
            pendingFrameCount: pendingFrameCount
        ))
        guard let batch = runState.takePendingUploadFrames() else {
            observeDiagnostic(.tailFlushFinished(generation: runGeneration, flushedFrameCount: 0))
            return
        }
        runState.beginUpload(frameCount: batch.count)
        defer { runState.completeUpload() }
        try await transport.send(frames: batch)
        guard activeGeneration == runGeneration else { throw CancellationError() }
        observeDiagnostic(.tailFlushFinished(
            generation: runGeneration,
            flushedFrameCount: batch.count
        ))
    }

    private func finalize(
        reason: VoiceActivatedEndpointReason,
        diagnosticEndpoint: VoiceActivatedASRDiagnosticEndpoint,
        generation runGeneration: UInt64
    ) async {
        guard activeGeneration == runGeneration, !runState.finalizationStarted else { return }
        runState.finalizationStarted = true
        observeDiagnostic(.segmentEnded(
            generation: runGeneration,
            endpoint: diagnosticEndpoint
        ))
        runState.acceptingFrames = false
        cancelFrameLivenessWatchdog()
        runState.manualFinishRequested = false
        transition(to: .draining(reason))
        await frameSource.stop()
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        runState.clearFrameQueue()

        do {
            try await flushPendingUpload(generation: runGeneration)
            guard activeGeneration == runGeneration else { return }
            transition(to: .finalizing(reason))
            observeDiagnostic(.finishStreamRequested(generation: runGeneration))
            try await transport.finishStream()
            guard activeGeneration == runGeneration else { return }
            observeDiagnostic(.finishStreamReturned(generation: runGeneration))
        } catch is CancellationError {
            return
        } catch {
            await fail(
                ASRFailure.transport(error),
                generation: runGeneration,
                origin: .transport
            )
        }
    }

    private func startTransportEvents(
        _ stream: AsyncStream<StreamingASRTransportEvent>,
        generation runGeneration: UInt64
    ) {
        guard transportEventTask == nil else { return }
        transportEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receive(transportEvent: event, generation: runGeneration)
            }
            guard let self else { return }
            await self.transportEventStreamEnded(generation: runGeneration)
        }
    }

    private func transportEventStreamEnded(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration else { return }
        observeDiagnostic(.transportStreamClosed(
            generation: runGeneration,
            stage: diagnosticTerminalStage
        ))
        await fail(
            .categorized(.connectionLost),
            generation: runGeneration,
            origin: .transport
        )
    }

    private func receive(
        transportEvent: StreamingASRTransportEvent,
        generation runGeneration: UInt64
    ) async {
        guard activeGeneration == runGeneration else { return }
        switch transportEvent {
        case .transcript(let text):
            eventContinuation.yield(.transcript(text))
        case .utterance(let text):
            eventContinuation.yield(.utterance(text))
        case .finished:
            guard case .finalizing = state else { return }
            observeDiagnostic(.transportTerminal(generation: runGeneration, terminal: .finished))
            completeSuccessfully(generation: runGeneration)
        case .failed(let failure):
            observeDiagnostic(.transportTerminal(generation: runGeneration, terminal: .failed))
            await fail(failure, generation: runGeneration, origin: .transport)
        }
    }

    private func completeNoSpeech(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration else { return }
        observeDiagnostic(.terminal(
            generation: runGeneration,
            stage: diagnosticTerminalStage,
            outcome: .noSpeech
        ))
        eventContinuation.yield(.noSpeech)
        await completeLocallyWithoutOpeningTransport(generation: runGeneration)
    }

    private func completeLocallyWithoutOpeningTransport(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration, !runState.transportAttempted else { return }
        _ = startWorkerRetirement(for: workerHandle?.task)
        invalidateActiveRun(terminalState: .finished)
        let cleanup = startCleanup(cancelTransport: false)
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
    }

    private func completeSuccessfully(generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration else { return }
        observeDiagnostic(.terminal(
            generation: runGeneration,
            stage: diagnosticTerminalStage,
            outcome: .finished
        ))
        _ = startWorkerRetirement(for: workerHandle?.task)
        activeGeneration = nil
        runState.acceptingFrames = false
        cancelFrameLivenessWatchdog()
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        transportEventTask?.cancel()
        workerHandle?.task.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        transportEventTask = nil
        workerHandle = nil
        runState.clearBufferedFrames()
        runState.transportAttempted = false
        transition(to: .finished)
    }

    private func fail(
        _ failure: ASRFailure,
        generation runGeneration: UInt64,
        origin: VoiceActivatedASRDiagnosticFailureOrigin
    ) async {
        guard activeGeneration == runGeneration else { return }
        observeDiagnostic(.terminal(
            generation: runGeneration,
            stage: diagnosticTerminalStage,
            outcome: .failed(origin: origin)
        ))
        let shouldCancelTransport = runState.transportAttempted
        _ = startWorkerRetirement(for: workerHandle?.task)
        invalidateActiveRun(terminalState: .failed(failure))
        let cleanup = startCleanup(cancelTransport: shouldCancelTransport)
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
    }

    private func invalidateActiveRun(terminalState: VoiceActivatedASRState) {
        generation &+= 1
        activeGeneration = nil
        runState.acceptingFrames = false
        cancelFrameLivenessWatchdog()
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        workerHandle?.task.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        workerHandle = nil
        runState.clearBufferedFrames()
        runState.manualFinishRequested = false
        transition(to: terminalState)
    }

    @discardableResult
    private func startCleanup(
        cancelTransport: Bool,
        retiringWorker: Task<Void, Never>? = nil
    ) -> CleanupBarrier {
        let frameSource = frameSource
        let pipeline = pipeline
        let transport = transport
        let transportEventTask = transportEventTask
        let cancelRetiringWorkerWaitHook = cancelRetiringWorkerWaitHook
        self.transportEventTask = nil
        nextCleanupID &+= 1
        let cleanupID = nextCleanupID
        let cleanup = Task {
            await frameSource.stop()
            await pipeline.reset()
            if cancelTransport { await transport.cancelStream() }
            await Self.awaitRetiringWorker(
                retiringWorker,
                cleanupID: cleanupID,
                hook: cancelRetiringWorkerWaitHook
            )
            transportEventTask?.cancel()
        }
        let barrier = CleanupBarrier(id: cleanupID, task: cleanup)
        cleanupBarrier = barrier
        runState.transportAttempted = false
        return barrier
    }

    private nonisolated static func awaitRetiringWorker(
        _ retiringWorker: Task<Void, Never>?,
        cleanupID: UInt64,
        hook: (@Sendable (UInt64, VoiceActivatedASRCancelRetiringWorkerWaitPhase) async -> Void)?
    ) async {
        guard let retiringWorker else { return }
        if let hook { await hook(cleanupID, .willAwaitWorker) }
        await retiringWorker.value
        if let hook { await hook(cleanupID, .didAwaitWorker) }
    }

    @discardableResult
    private func startWorkerRetirement(
        for worker: Task<Void, Never>?
    ) -> WorkerRetirementBarrier? {
        guard let worker else { return nil }
        if let workerRetirementBarrier { return workerRetirementBarrier }
        nextWorkerRetirementID &+= 1
        let barrier = WorkerRetirementBarrier(
            id: nextWorkerRetirementID,
            task: worker
        )
        workerRetirementBarrier = barrier
        return barrier
    }

    private func awaitWorkerRetirement(_ barrier: WorkerRetirementBarrier) async {
        if let workerRetirementWaitHook {
            await workerRetirementWaitHook(barrier.id, .willAwait)
        }
        await barrier.task.value
        if let workerRetirementWaitHook {
            await workerRetirementWaitHook(barrier.id, .didAwait)
        }
        clearWorkerRetirementBarrier(ifMatching: barrier.id)
    }

    private func clearWorkerRetirementBarrier(ifMatching id: UInt64) {
        guard workerRetirementBarrier?.id == id else { return }
        workerRetirementBarrier = nil
    }

    private func clearCleanupBarrier(ifMatching id: UInt64) {
        guard cleanupBarrier?.id == id else { return }
        cleanupBarrier = nil
    }

    private func transition(to newState: VoiceActivatedASRState) {
        guard state != newState else { return }
        state = newState
        eventContinuation.yield(.state(newState))
    }

    private func observeDiagnostic(_ event: VoiceActivatedASRDiagnosticEvent) {
        diagnostics?.observe(event)
    }

    private var diagnosticTerminalStage: VoiceActivatedASRDiagnosticTerminalStage {
        switch state {
        case .idle, .arming:
            .arming
        case .armed:
            .armed
        case .openingRecognizer:
            .openingRecognizer
        case .streaming:
            .streaming
        case .draining:
            .draining
        case .finalizing, .finished, .failed:
            .finalizing
        }
    }
}
