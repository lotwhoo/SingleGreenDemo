import Foundation
import VoiceActivityDetectionKit

public struct VoiceActivatedASRPolicy: Equatable, Sendable {
    public let segmentation: VADSegmentationPolicy
    public let noSpeechFrameLimit: Int
    public let maximumPendingUploadFrameCount: Int
    public let uploadBatchFrameCount: Int

    public init(
        segmentation: VADSegmentationPolicy,
        noSpeechFrameLimit: Int,
        maximumPendingUploadFrameCount: Int,
        uploadBatchFrameCount: Int
    ) throws {
        guard noSpeechFrameLimit >= segmentation.onsetWindowFrameCount else {
            throw VoiceActivatedASRPolicyError.noSpeechFrameLimitTooSmall
        }
        guard maximumPendingUploadFrameCount >= segmentation.preRollFrameCount else {
            throw VoiceActivatedASRPolicyError.pendingUploadLimitTooSmall
        }
        guard (1 ... maximumPendingUploadFrameCount).contains(uploadBatchFrameCount) else {
            throw VoiceActivatedASRPolicyError.uploadBatchFrameCountOutOfRange
        }
        self.segmentation = segmentation
        self.noSpeechFrameLimit = noSpeechFrameLimit
        self.maximumPendingUploadFrameCount = maximumPendingUploadFrameCount
        self.uploadBatchFrameCount = uploadBatchFrameCount
    }

    public static let standard: VoiceActivatedASRPolicy = {
        let segmentation = try! VADSegmentationPolicy(
            preRollFrameCount: 15,
            onsetWindowFrameCount: 5,
            onsetRequiredSpeechFrameCount: 3,
            endpointSilenceFrameCount: 40,
            maximumSegmentFrameCount: 1_000
        )
        return try! VoiceActivatedASRPolicy(
            segmentation: segmentation,
            noSpeechFrameLimit: 750,
            maximumPendingUploadFrameCount: 250,
            uploadBatchFrameCount: 10
        )
    }()
}

public enum VoiceActivatedASRPolicyError: Error, Equatable, Sendable {
    case noSpeechFrameLimitTooSmall
    case pendingUploadLimitTooSmall
    case uploadBatchFrameCountOutOfRange
}

public enum VoiceActivatedEndpointReason: Equatable, Sendable {
    case silence
    case maximumDuration
    case manual
}

public enum VoiceActivatedASRState: Equatable, Sendable {
    case idle
    case arming
    case armed
    case openingRecognizer
    case streaming
    case draining(VoiceActivatedEndpointReason)
    case finalizing(VoiceActivatedEndpointReason)
    case finished
    case failed(ASRFailure)
}

public enum VoiceActivatedASREvent: Equatable, Sendable {
    case state(VoiceActivatedASRState)
    case transcript(String)
    case utterance(String)
    case level(Float)
    case noSpeech
}

public enum VoiceActivatedASRSessionError: Error, Equatable, Sendable {
    case busy
}

enum VoiceActivatedASRCleanupWaitPhase: Equatable, Sendable {
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

    public nonisolated let events: AsyncStream<VoiceActivatedASREvent>

    public private(set) var state: VoiceActivatedASRState = .idle

    private let frameSource: any PCMFrameSource
    private let transport: any StreamingASRTransport
    private let pipeline: VoiceActivityDetectionPipeline
    private let policy: VoiceActivatedASRPolicy
    private let eventContinuation: AsyncStream<VoiceActivatedASREvent>.Continuation
    private let cleanupWaitHook: (
        @Sendable (UInt64, VoiceActivatedASRCleanupWaitPhase) async -> Void
    )?

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var acceptingFrames = false
    private var speechStarted = false
    private var transportAttempted = false
    private var sourceStopExpected = false
    private var processedBeforeOnset = 0
    private var frameQueue: [VADPCMFrame] = []
    private var pendingUploadFrames: [VADPCMFrame] = []
    private var inFlightUploadFrameCount = 0
    private var manualFinishRequested = false
    private var finalizationStarted = false

    private var sourceFrameTask: Task<Void, Never>?
    private var sourceLevelTask: Task<Void, Never>?
    private var transportEventTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var nextCleanupID: UInt64 = 0
    private var cleanupBarrier: CleanupBarrier?

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
        self.cleanupWaitHook = nil
    }

    init(
        frameSource: any PCMFrameSource,
        detector: any VoiceActivityDetecting,
        transport: any StreamingASRTransport,
        policy: VoiceActivatedASRPolicy,
        cleanupWaitHook: (
            @Sendable (UInt64, VoiceActivatedASRCleanupWaitPhase) async -> Void
        )? = nil
    ) {
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
        self.cleanupWaitHook = cleanupWaitHook
    }

    deinit {
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        transportEventTask?.cancel()
        workerTask?.cancel()
        cleanupBarrier?.task.cancel()
        eventContinuation.finish()
    }

    public func arm() async throws {
        while true {
            guard canArm else { throw VoiceActivatedASRSessionError.busy }
            guard let cleanupBarrier else { break }
            if let cleanupWaitHook {
                await cleanupWaitHook(cleanupBarrier.id, .willAwait)
            }
            await cleanupBarrier.task.value
            if let cleanupWaitHook {
                await cleanupWaitHook(cleanupBarrier.id, .didAwait)
            }
            clearCleanupBarrier(ifMatching: cleanupBarrier.id)
        }

        // No suspension is allowed between this final admission check and reserving the generation.
        guard canArm, cleanupBarrier == nil else {
            throw VoiceActivatedASRSessionError.busy
        }
        generation &+= 1
        let runGeneration = generation
        activeGeneration = runGeneration
        resetRunState()
        transition(to: .arming)

        await pipeline.reset()
        guard activeGeneration == runGeneration else { throw CancellationError() }

        do {
            let streams = try await frameSource.start()
            guard activeGeneration == runGeneration else {
                await frameSource.stop()
                throw CancellationError()
            }
            acceptingFrames = true
            startSourceTasks(streams: streams, generation: runGeneration)
            transition(to: .armed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = ASRFailure.transport(error)
            await fail(failure, generation: runGeneration)
            throw failure
        }
    }

    public func finish() async {
        guard let runGeneration = activeGeneration else { return }
        switch state {
        case .arming, .armed:
            if !speechStarted {
                await completeLocallyWithoutOpeningTransport(generation: runGeneration)
                return
            }
        case .openingRecognizer, .streaming:
            break
        case .idle, .draining, .finalizing, .finished, .failed:
            return
        }

        manualFinishRequested = true
        transition(to: .draining(.manual))
        sourceStopExpected = true
        await frameSource.stop()
        await sourceFrameTask?.value
        acceptingFrames = false

        if frameQueue.isEmpty, workerTask == nil {
            await finalize(reason: .manual, generation: runGeneration)
            return
        }
        let worker = workerTask
        startWorkerIfNeeded(generation: runGeneration)
        await (worker ?? workerTask)?.value
    }

    public func cancel() async {
        guard activeGeneration != nil else {
            if state != .idle { transition(to: .idle) }
            while let cleanupBarrier {
                await cleanupBarrier.task.value
                clearCleanupBarrier(ifMatching: cleanupBarrier.id)
            }
            return
        }
        invalidateActiveRun(terminalState: .idle)
        let cleanup = startCleanup(cancelTransport: transportAttempted)
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
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
        acceptingFrames = false
        speechStarted = false
        transportAttempted = false
        sourceStopExpected = false
        processedBeforeOnset = 0
        frameQueue.removeAll(keepingCapacity: true)
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = 0
        manualFinishRequested = false
        finalizationStarted = false
        sourceFrameTask = nil
        sourceLevelTask = nil
        transportEventTask = nil
        workerTask = nil
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
        guard activeGeneration == runGeneration, acceptingFrames else { return }
        let pendingCount = frameQueue.count + pendingUploadFrames.count + inFlightUploadFrameCount
        guard pendingCount < policy.maximumPendingUploadFrameCount else {
            await fail(.categorized(.uploadBackpressureExceeded), generation: runGeneration)
            return
        }
        frameQueue.append(frame)
        startWorkerIfNeeded(generation: runGeneration)
    }

    private func receive(level: Float, generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration, acceptingFrames else { return }
        eventContinuation.yield(.level(min(max(level, 0), 1)))
    }

    private func sourceEnded(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration, acceptingFrames else { return }
        if sourceStopExpected { return }
        await fail(.categorized(.audioUnavailable), generation: runGeneration)
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
        await fail(failure, generation: runGeneration)
    }

    private func startWorkerIfNeeded(generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration,
              workerTask == nil,
              !frameQueue.isEmpty else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker(generation: runGeneration)
        }
    }

    private func runWorker(generation runGeneration: UInt64) async {
        while activeGeneration == runGeneration, !Task.isCancelled {
            guard !frameQueue.isEmpty else { break }
            let frame = frameQueue.removeFirst()
            let segmentationEvents: [VADSegmentationEvent]
            do {
                segmentationEvents = try await pipeline.process(frame)
            } catch is CancellationError {
                return
            } catch {
                await fail(
                    .categorized(.voiceActivityProcessingFailed),
                    generation: runGeneration
                )
                return
            }

            guard activeGeneration == runGeneration, !Task.isCancelled else { return }
            if !speechStarted { processedBeforeOnset += 1 }
            do {
                for event in segmentationEvents {
                    try await handle(event, generation: runGeneration)
                    guard activeGeneration == runGeneration, !Task.isCancelled else { return }
                }
                if !speechStarted,
                   processedBeforeOnset >= policy.noSpeechFrameLimit {
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
                await fail(failure, generation: runGeneration)
                return
            }
        }

        guard activeGeneration == runGeneration else { return }
        workerTask = nil
        if manualFinishRequested {
            await finalize(reason: .manual, generation: runGeneration)
        }
    }

    private func handle(
        _ event: VADSegmentationEvent,
        generation runGeneration: UInt64
    ) async throws {
        switch event {
        case .segmentStarted:
            speechStarted = true
            transportAttempted = true
            transition(to: .openingRecognizer)
            let transportEvents = try await transport.openStream()
            guard activeGeneration == runGeneration else { throw CancellationError() }
            startTransportEvents(transportEvents, generation: runGeneration)
            if manualFinishRequested {
                transition(to: .draining(.manual))
            } else {
                transition(to: .streaming)
            }
        case .frames(_, let frames):
            pendingUploadFrames.append(contentsOf: frames)
            guard pendingUploadFrames.count <= policy.maximumPendingUploadFrameCount else {
                throw PCMFrameSourceFailure.bufferOverflow
            }
            try await sendFullBatches(generation: runGeneration)
        case .speechResumed:
            break
        case .segmentEnded(_, let reason):
            let endpointReason: VoiceActivatedEndpointReason = switch reason {
            case .silence: .silence
            case .maximumDuration: .maximumDuration
            }
            await finalize(
                reason: manualFinishRequested ? .manual : endpointReason,
                generation: runGeneration
            )
        }
    }

    private func sendFullBatches(generation runGeneration: UInt64) async throws {
        while pendingUploadFrames.count >= policy.uploadBatchFrameCount {
            let batch = Array(pendingUploadFrames.prefix(policy.uploadBatchFrameCount))
            pendingUploadFrames.removeFirst(batch.count)
            inFlightUploadFrameCount = batch.count
            defer { inFlightUploadFrameCount = 0 }
            try await transport.send(frames: batch)
            guard activeGeneration == runGeneration else { throw CancellationError() }
        }
    }

    private func flushPendingUpload(generation runGeneration: UInt64) async throws {
        guard !pendingUploadFrames.isEmpty else { return }
        let batch = pendingUploadFrames
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = batch.count
        defer { inFlightUploadFrameCount = 0 }
        try await transport.send(frames: batch)
        guard activeGeneration == runGeneration else { throw CancellationError() }
    }

    private func finalize(
        reason: VoiceActivatedEndpointReason,
        generation runGeneration: UInt64
    ) async {
        guard activeGeneration == runGeneration, !finalizationStarted else { return }
        finalizationStarted = true
        acceptingFrames = false
        manualFinishRequested = false
        transition(to: .draining(reason))
        await frameSource.stop()
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        frameQueue.removeAll(keepingCapacity: true)

        do {
            try await flushPendingUpload(generation: runGeneration)
            guard activeGeneration == runGeneration else { return }
            transition(to: .finalizing(reason))
            try await transport.finishStream()
        } catch is CancellationError {
            return
        } catch {
            await fail(ASRFailure.transport(error), generation: runGeneration)
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
        await fail(.categorized(.connectionLost), generation: runGeneration)
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
            completeSuccessfully(generation: runGeneration)
        case .failed(let failure):
            await fail(failure, generation: runGeneration)
        }
    }

    private func completeNoSpeech(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration else { return }
        eventContinuation.yield(.noSpeech)
        await completeLocallyWithoutOpeningTransport(generation: runGeneration)
    }

    private func completeLocallyWithoutOpeningTransport(generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration, !transportAttempted else { return }
        invalidateActiveRun(terminalState: .finished)
        let cleanup = startCleanup(cancelTransport: false)
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
    }

    private func completeSuccessfully(generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration else { return }
        activeGeneration = nil
        acceptingFrames = false
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        transportEventTask?.cancel()
        workerTask?.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        transportEventTask = nil
        workerTask = nil
        frameQueue.removeAll(keepingCapacity: true)
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = 0
        transportAttempted = false
        transition(to: .finished)
    }

    private func fail(_ failure: ASRFailure, generation runGeneration: UInt64) async {
        guard activeGeneration == runGeneration else { return }
        let shouldCancelTransport = transportAttempted
        invalidateActiveRun(terminalState: .failed(failure))
        let cleanup = startCleanup(cancelTransport: shouldCancelTransport)
        await cleanup.task.value
        clearCleanupBarrier(ifMatching: cleanup.id)
    }

    private func invalidateActiveRun(terminalState: VoiceActivatedASRState) {
        generation &+= 1
        activeGeneration = nil
        acceptingFrames = false
        sourceFrameTask?.cancel()
        sourceLevelTask?.cancel()
        workerTask?.cancel()
        sourceFrameTask = nil
        sourceLevelTask = nil
        workerTask = nil
        frameQueue.removeAll(keepingCapacity: true)
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = 0
        manualFinishRequested = false
        transition(to: terminalState)
    }

    @discardableResult
    private func startCleanup(cancelTransport: Bool) -> CleanupBarrier {
        let frameSource = frameSource
        let pipeline = pipeline
        let transport = transport
        let transportEventTask = transportEventTask
        self.transportEventTask = nil
        let cleanup = Task {
            await frameSource.stop()
            await pipeline.reset()
            if cancelTransport { await transport.cancelStream() }
            transportEventTask?.cancel()
        }
        nextCleanupID &+= 1
        let barrier = CleanupBarrier(id: nextCleanupID, task: cleanup)
        cleanupBarrier = barrier
        transportAttempted = false
        return barrier
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
}
