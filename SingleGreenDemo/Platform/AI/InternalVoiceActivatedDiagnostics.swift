#if INTERNAL_DIAGNOSTICS
import Foundation
import SingleGreenGlassesKit
import VoiceChatCore
import WebRTCVoiceActivityDetection

@MainActor
protocol InternalDiagnosticsLineSink: AnyObject, Sendable {
    func record(category: String, message: String)
    func registerDiagnosticsBarrierFactory(
        _ factory: @escaping @Sendable () -> InternalDiagnosticsBarrierHandle
    )
}

struct InternalVADPolicySnapshot: Equatable, Sendable {
    let aggressivenessMode: Int
    let preRollFrameCount: Int
    let onsetWindowFrameCount: Int
    let onsetRequiredSpeechFrameCount: Int
    let endpointSilenceFrameCount: Int
    let maximumSegmentFrameCount: Int
    let noSpeechFrameLimit: Int
    let maximumPendingUploadFrameCount: Int
    let uploadBatchFrameCount: Int

    init(
        policy: VoiceActivatedASRPolicy,
        aggressiveness: WebRTCVADAggressiveness
    ) {
        aggressivenessMode = aggressiveness.rawValue
        preRollFrameCount = policy.segmentation.preRollFrameCount
        onsetWindowFrameCount = policy.segmentation.onsetWindowFrameCount
        onsetRequiredSpeechFrameCount = policy.segmentation.onsetRequiredSpeechFrameCount
        endpointSilenceFrameCount = policy.segmentation.endpointSilenceFrameCount
        maximumSegmentFrameCount = policy.segmentation.maximumSegmentFrameCount
        noSpeechFrameLimit = policy.noSpeechFrameLimit
        maximumPendingUploadFrameCount = policy.maximumPendingUploadFrameCount
        uploadBatchFrameCount = policy.uploadBatchFrameCount
    }
}

struct InternalVADRunContext: Sendable {
    let core: VoiceActivatedASRDiagnosticContext

    var runOrdinal: UInt64 { core.runOrdinal }
    var originNanoseconds: UInt64 { core.originNanoseconds }
}

enum InternalVADDiagnosticMilestone: Equatable, Sendable {
    case configured(InternalVADPolicySnapshot)
    case armRequested
    case armReturned(durationMilliseconds: UInt64)
    case armFailed(durationMilliseconds: UInt64, code: SpeechRecognitionFailure.Code)
    case armed
    case speechStarted(armedToOnset: InternalVADDiagnosticInterval)
    case finalizing(
        VoiceEndpointReason,
        speechToEndpoint: InternalVADDiagnosticInterval
    )
    case noSpeech
    case finished(endpointToFinished: InternalVADDiagnosticInterval)
    case failed(SpeechRecognitionFailure.Code)
    case finishRequested
    case finishReturned(durationMilliseconds: UInt64)
    case cancelRequested
    case cancelReturned(durationMilliseconds: UInt64)
    case sourceClosedWithoutTerminal(cancelRequested: Bool)
    case core(VoiceActivatedASRDiagnosticEvent)

    fileprivate var eventName: String {
        switch self {
        case .configured: "configured"
        case .armRequested: "arm_requested"
        case .armReturned: "arm_returned"
        case .armFailed: "arm_failed"
        case .armed: "armed"
        case .speechStarted: "speech_started"
        case .finalizing: "finalizing"
        case .noSpeech: "no_speech"
        case .finished: "finished"
        case .failed: "failed"
        case .finishRequested: "finish_requested"
        case .finishReturned: "finish_returned"
        case .cancelRequested: "cancel_requested"
        case .cancelReturned: "cancel_returned"
        case .sourceClosedWithoutTerminal: "source_closed_without_terminal"
        case .core(let event): event.internalDiagnosticEventName
        }
    }

    fileprivate var fields: [String] {
        switch self {
        case .configured(let policy):
            return [
                "aggressiveness_mode=\(policy.aggressivenessMode)",
                "pre_roll_frames=\(policy.preRollFrameCount)",
                "onset_window_frames=\(policy.onsetWindowFrameCount)",
                "onset_required_speech_frames=\(policy.onsetRequiredSpeechFrameCount)",
                "endpoint_silence_frames=\(policy.endpointSilenceFrameCount)",
                "maximum_segment_frames=\(policy.maximumSegmentFrameCount)",
                "no_speech_frames=\(policy.noSpeechFrameLimit)",
                "maximum_pending_upload_frames=\(policy.maximumPendingUploadFrameCount)",
                "upload_batch_frames=\(policy.uploadBatchFrameCount)"
            ]
        case .armReturned(let durationMilliseconds),
             .finishReturned(let durationMilliseconds),
             .cancelReturned(let durationMilliseconds):
            return ["duration_ms=\(durationMilliseconds)"]
        case .armFailed(let durationMilliseconds, let code):
            return ["duration_ms=\(durationMilliseconds)", "failure=\(code.rawValue)"]
        case .speechStarted(let armedToOnset):
            return ["armed_to_onset_ms=\(armedToOnset.exportValue)"]
        case .finalizing(let reason, let speechToEndpoint):
            return [
                "endpoint=\(reason.diagnosticName)",
                "speech_to_endpoint_ms=\(speechToEndpoint.exportValue)"
            ]
        case .finished(let endpointToFinished):
            return ["endpoint_to_finished_ms=\(endpointToFinished.exportValue)"]
        case .failed(let code):
            return ["failure=\(code.rawValue)"]
        case .sourceClosedWithoutTerminal(let cancelRequested):
            return ["cancel_requested=\(cancelRequested)"]
        case .core(let event):
            return event.internalDiagnosticFields
        case .armRequested, .armed, .noSpeech,
             .finishRequested, .cancelRequested:
            return []
        }
    }
}

enum InternalVADDiagnosticInterval: Equatable, Sendable {
    case milliseconds(UInt64)
    case unavailable

    fileprivate var exportValue: String {
        switch self {
        case .milliseconds(let value): String(value)
        case .unavailable: "unavailable"
        }
    }
}

struct InternalVADDiagnosticRecord: Equatable, Sendable {
    static let schemaVersion = 2

    let runOrdinal: UInt64
    let elapsedMilliseconds: UInt64
    let milestone: InternalVADDiagnosticMilestone

    var exportLine: String {
        ([
            "schema=v\(Self.schemaVersion)",
            "run=\(runOrdinal)",
            "event=\(milestone.eventName)",
            "elapsed_ms=\(elapsedMilliseconds)"
        ] + milestone.fields).joined(separator: " ")
    }
}

protocol InternalVADDiagnosticsWriting: Sendable {
    func submit(_ record: InternalVADDiagnosticRecord)
}

final class InternalDiagnosticsBarrierHandle: @unchecked Sendable {
    private struct State {
        var isReached = false
        var isReleased = false
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !state.isReached else { return true }
                state.reachedWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !state.isReleased else { return [] }
            state.isReleased = true
            let waiters = state.releaseWaiters
            state.releaseWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    fileprivate func reach() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !state.isReached else { return [] }
            state.isReached = true
            let waiters = state.reachedWaiters
            state.reachedWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    fileprivate func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !state.isReleased else { return true }
                state.releaseWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    fileprivate func close() {
        reach()
        release()
    }
}

private final class InternalVADRunOrdinalSource: @unchecked Sendable {
    static let process = InternalVADRunOrdinalSource()

    private let lock = NSLock()
    private var lastOrdinal: UInt64 = 0

    private init() {}

    func next() -> UInt64 {
        lock.withLock {
            lastOrdinal &+= 1
            return lastOrdinal
        }
    }
}

/// Coalesces frame-rate Core observations into bounded progress snapshots.
/// Lifecycle and endpoint facts remain immediate, while progress is exported
/// at most every 25 accepted/processed frames or 500 ms.
final class InternalVADCoreDiagnosticsRecorder: @unchecked Sendable {
    private struct State {
        var activeGeneration: UInt64?
        var latestProgress: VoiceActivatedASRDiagnosticEvent?
        var lastExportedProgress: VoiceActivatedASRDiagnosticProgress?
        var lastProgressExportNanoseconds: UInt64?
    }

    private let context: InternalVADRunContext
    private let writer: any InternalVADDiagnosticsWriting
    private let monotonicNow: InternalVoiceActivatedDiagnosticsSession.MonotonicNow
    private let lock = NSLock()
    private var state = State()

    init(
        context: InternalVADRunContext,
        writer: any InternalVADDiagnosticsWriting,
        monotonicNow: @escaping InternalVoiceActivatedDiagnosticsSession.MonotonicNow
    ) {
        self.context = context
        self.writer = writer
        self.monotonicNow = monotonicNow
    }

    func observe(_ event: VoiceActivatedASRDiagnosticEvent) {
        let observedAt = monotonicNow()
        let eventsToWrite: [VoiceActivatedASRDiagnosticEvent] = lock.withLock {
            let generation = event.internalDiagnosticGeneration
            if case .sourceStartRequested = event {
                state.activeGeneration = generation
                state.latestProgress = nil
                state.lastExportedProgress = nil
                state.lastProgressExportNanoseconds = nil
            }
            guard state.activeGeneration == generation else { return [] }

            if case .progress(_, _, let progress) = event {
                state.latestProgress = event
                guard shouldExport(progress: progress, observedAt: observedAt) else { return [] }
                markProgressExported(progress, observedAt: observedAt)
                return [event]
            }

            var result: [VoiceActivatedASRDiagnosticEvent] = []
            if let progressEvent = state.latestProgress,
               case .progress(_, _, let progress) = progressEvent,
               progress != state.lastExportedProgress {
                markProgressExported(progress, observedAt: observedAt)
                result.append(progressEvent)
            }
            result.append(event)
            return result
        }

        for item in eventsToWrite {
            writer.submit(InternalVADDiagnosticRecord(
                runOrdinal: context.runOrdinal,
                elapsedMilliseconds: Self.milliseconds(
                    from: context.originNanoseconds,
                    to: observedAt
                ),
                milestone: .core(item)
            ))
        }
    }

    private func shouldExport(
        progress: VoiceActivatedASRDiagnosticProgress,
        observedAt: UInt64
    ) -> Bool {
        guard let previous = state.lastExportedProgress,
              let previousTime = state.lastProgressExportNanoseconds else { return true }
        let acceptedDelta = progress.acceptedFrameCount - previous.acceptedFrameCount
        let processedDelta = progress.processedFrameCount - previous.processedFrameCount
        return acceptedDelta >= 25
            || processedDelta >= 25
            || Self.milliseconds(from: previousTime, to: observedAt) >= 500
    }

    private func markProgressExported(
        _ progress: VoiceActivatedASRDiagnosticProgress,
        observedAt: UInt64
    ) {
        state.lastExportedProgress = progress
        state.lastProgressExportNanoseconds = observedAt
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }
}

/// A bounded, single-consumer writer. Submission never waits for the UI or IO.
final class InternalDiagnosticsOrderedLineWriter: @unchecked Sendable {
    typealias Sink = @Sendable (String) async -> Void

    private let queue: InternalDiagnosticsOrderedLineQueue
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    init(capacity: Int = 128, sink: @escaping Sink) {
        let queue = InternalDiagnosticsOrderedLineQueue(capacity: max(1, capacity))
        self.queue = queue
        let (signals, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        signalContinuation = continuation
        worker = Task {
            for await _ in signals {
                while let item = queue.popFirst() {
                    switch item {
                    case .line(let line):
                        await sink(line)
                    case .barrier(let handle):
                        handle.reach()
                        await handle.waitUntilReleased()
                        queue.completeBarrier(handle)
                    }
                }
            }
        }
    }

    deinit {
        let pendingBarriers = queue.close()
        pendingBarriers.forEach { $0.close() }
        signalContinuation.finish()
        worker.cancel()
    }

    func submit(_ line: String) {
        guard queue.append(line) else { return }
        signalContinuation.yield(())
    }

    func makeBarrier() -> InternalDiagnosticsBarrierHandle {
        let handle = InternalDiagnosticsBarrierHandle()
        guard queue.appendBarrier(handle) else {
            handle.close()
            return handle
        }
        signalContinuation.yield(())
        return handle
    }
}

/// VAD-specific facade retained so call sites cannot accidentally submit an
/// unstructured line while the ordered queue remains reusable by other
/// internal-only diagnostics.
final class InternalVADDiagnosticsSerialWriter: InternalVADDiagnosticsWriting, @unchecked Sendable {
    typealias Sink = InternalDiagnosticsOrderedLineWriter.Sink

    private let writer: InternalDiagnosticsOrderedLineWriter

    init(capacity: Int = 128, sink: @escaping Sink) {
        writer = InternalDiagnosticsOrderedLineWriter(capacity: capacity, sink: sink)
    }

    func submit(_ record: InternalVADDiagnosticRecord) {
        writer.submit(record.exportLine)
    }

    func makeBarrier() -> InternalDiagnosticsBarrierHandle {
        writer.makeBarrier()
    }
}

private final class InternalDiagnosticsOrderedLineQueue: @unchecked Sendable {
    enum Item: Sendable {
        case line(String)
        case barrier(InternalDiagnosticsBarrierHandle)
    }

    private struct State {
        var items: [Item] = []
        var lineCount = 0
        var isClosed = false
        var activeBarriers: [ObjectIdentifier: InternalDiagnosticsBarrierHandle] = [:]
    }

    private let capacity: Int
    private let lock = NSLock()
    private var state = State()

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ line: String) -> Bool {
        lock.withLock {
            guard !state.isClosed else { return false }
            if state.lineCount >= capacity {
                // Preserve every record captured by a pending barrier. Within
                // the post-barrier segment, retain the newest bounded records;
                // if only snapshot-protected records remain, drop this new one.
                let startIndex = state.items.lastIndex(where: { item in
                    if case .barrier = item { return true }
                    return false
                }).map { state.items.index(after: $0) } ?? state.items.startIndex
                guard let index = state.items[startIndex...].firstIndex(where: { item in
                    if case .line = item { return true }
                    return false
                }) else {
                    // A later record must not evict an earlier flush snapshot.
                    return false
                }
                state.items.remove(at: index)
                state.lineCount -= 1
            }
            state.items.append(.line(line))
            state.lineCount += 1
            return true
        }
    }

    func appendBarrier(_ handle: InternalDiagnosticsBarrierHandle) -> Bool {
        lock.withLock {
            guard !state.isClosed else { return false }
            state.items.append(.barrier(handle))
            return true
        }
    }

    func popFirst() -> Item? {
        lock.withLock {
            guard !state.items.isEmpty else { return nil }
            let item = state.items.removeFirst()
            if case .line = item { state.lineCount -= 1 }
            if case .barrier(let handle) = item {
                state.activeBarriers[ObjectIdentifier(handle)] = handle
            }
            return item
        }
    }

    func completeBarrier(_ handle: InternalDiagnosticsBarrierHandle) {
        _ = lock.withLock {
            state.activeBarriers.removeValue(forKey: ObjectIdentifier(handle))
        }
    }

    func close() -> [InternalDiagnosticsBarrierHandle] {
        lock.withLock {
            guard !state.isClosed else { return [] }
            state.isClosed = true
            let queuedBarriers = state.items.compactMap { item in
                if case .barrier(let handle) = item { return handle }
                return nil
            }
            let barriers = queuedBarriers + Array(state.activeBarriers.values)
            state.items.removeAll()
            state.lineCount = 0
            state.activeBarriers.removeAll()
            return Array(barriers)
        }
    }
}

@MainActor
enum InternalVADDiagnosticsLiveComposition {
    static let wiringMarker = "vad-diagnostics-live-wiring-v2"

    struct Wiring {
        let marker: String
        let makeVoiceActivatedSession: ConversationPreparationResolver.VoiceActivatedFactory
    }

    static func make(
        diagnosticSink: (any InternalDiagnosticsLineSink)?,
        monotonicNow: @escaping InternalVoiceActivatedDiagnosticsSession.MonotonicNow,
        makeAdaptedSession: ConversationPreparationResolver.VoiceActivatedFactory? = nil
    ) -> Wiring {
        let writer = InternalVADDiagnosticsSerialWriter(
            capacity: 256,
            sink: { [weak diagnosticSink] line in
                await diagnosticSink?.record(category: "vad", message: line)
            }
        )
        diagnosticSink?.registerDiagnosticsBarrierFactory {
            writer.makeBarrier()
        }
        let factory: ConversationPreparationResolver.VoiceActivatedFactory = { configuration in
            let context = InternalVADRunContext(core: VoiceActivatedASRDiagnosticContext(
                runOrdinal: InternalVADRunOrdinalSource.process.next(),
                originNanoseconds: monotonicNow()
            ))
            let coreRecorder = InternalVADCoreDiagnosticsRecorder(
                context: context,
                writer: writer,
                monotonicNow: monotonicNow
            )
            let observer = VoiceActivatedASRDiagnosticsObserver(context: context.core) { event in
                coreRecorder.observe(event)
            }
            let adaptedSession: any VoiceActivatedSpeechRecognitionSession
            if let makeAdaptedSession {
                adaptedSession = try makeAdaptedSession(configuration)
            } else {
                adaptedSession = try ProductionVoiceActivatedSessionFactory.make(
                    configuration: configuration,
                    diagnostics: observer
                )
            }
            return InternalVoiceActivatedDiagnosticsSession(
                base: adaptedSession,
                policySnapshot: InternalVADPolicySnapshot(
                    policy: ProductionVoiceActivatedSessionFactory.policy,
                    aggressiveness: ProductionVoiceActivatedSessionFactory.aggressiveness
                ),
                context: context,
                writer: writer,
                monotonicNow: monotonicNow
            )
        }
        return Wiring(
            marker: wiringMarker,
            makeVoiceActivatedSession: factory
        )
    }
}

/// Internal-only decorator around the already-adapted glasses ASR contract.
/// It is the sole consumer of the wrapped event stream and never synthesizes a
/// recognition event or records content-bearing payloads.
final class InternalVoiceActivatedDiagnosticsSession:
    VoiceActivatedSpeechRecognitionSession,
    @unchecked Sendable {
    typealias MonotonicNow = @Sendable () -> UInt64

    let events: AsyncStream<VoiceActivatedRecognitionEvent>

    private let base: any VoiceActivatedSpeechRecognitionSession
    private let recorder: InternalVADDiagnosticsRecorder
    private let relayTask: Task<Void, Never>
    private let cancelLock = NSLock()
    private var cancelTask: Task<Void, Never>?

    init(
        base: any VoiceActivatedSpeechRecognitionSession,
        policySnapshot: InternalVADPolicySnapshot,
        context: InternalVADRunContext,
        writer: any InternalVADDiagnosticsWriting,
        monotonicNow: @escaping MonotonicNow
    ) {
        self.base = base
        let recorder = InternalVADDiagnosticsRecorder(
            context: context,
            writer: writer,
            monotonicNow: monotonicNow
        )
        self.recorder = recorder

        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        let sourceEvents = base.events
        relayTask = Task {
            for await event in sourceEvents {
                guard !Task.isCancelled else { break }
                continuation.yield(event)
                recorder.observe(event)
            }
            continuation.finish()
            if !Task.isCancelled {
                recorder.sourceClosed()
            }
        }
        recorder.submit(.configured(policySnapshot))
    }

    convenience init(
        base: any VoiceActivatedSpeechRecognitionSession,
        policySnapshot: InternalVADPolicySnapshot,
        runOrdinal: UInt64,
        writer: any InternalVADDiagnosticsWriting,
        monotonicNow: @escaping MonotonicNow
    ) {
        self.init(
            base: base,
            policySnapshot: policySnapshot,
            context: InternalVADRunContext(core: VoiceActivatedASRDiagnosticContext(
                runOrdinal: runOrdinal,
                originNanoseconds: monotonicNow()
            )),
            writer: writer,
            monotonicNow: monotonicNow
        )
    }

    deinit {
        relayTask.cancel()
    }

    func arm() async throws {
        let startedAt = recorder.now()
        recorder.submit(.armRequested)
        do {
            try await base.arm()
            recorder.submit(.armReturned(
                durationMilliseconds: recorder.elapsedMilliseconds(since: startedAt)
            ))
        } catch {
            recorder.submit(.armFailed(
                durationMilliseconds: recorder.elapsedMilliseconds(since: startedAt),
                code: (error as? SpeechRecognitionFailure)?.code ?? .unknown
            ))
            throw error
        }
    }

    func finish() async {
        let startedAt = recorder.now()
        recorder.submit(.finishRequested)
        await base.finish()
        recorder.submit(.finishReturned(
            durationMilliseconds: recorder.elapsedMilliseconds(since: startedAt)
        ))
    }

    func cancel() async {
        let (task, ownsDiagnostics, startedAt) = cancelLock.withLock {
            if let cancelTask {
                return (cancelTask, false, UInt64.zero)
            }
            let startedAt = recorder.now()
            recorder.markCancelRequested()
            recorder.submit(.cancelRequested)
            let base = base
            let task = Task { await base.cancel() }
            cancelTask = task
            return (task, true, startedAt)
        }
        await task.value
        if ownsDiagnostics {
            recorder.submit(.cancelReturned(
                durationMilliseconds: recorder.elapsedMilliseconds(since: startedAt)
            ))
        }
    }
}

private final class InternalVADDiagnosticsRecorder: @unchecked Sendable {
    private struct State {
        var terminalObserved = false
        var cancelRequested = false
        var sourceCloseObserved = false
        var armedAt: UInt64?
        var speechStartedAt: UInt64?
        var endpointAt: UInt64?
    }

    private let runOrdinal: UInt64
    private let writer: any InternalVADDiagnosticsWriting
    private let monotonicNow: InternalVoiceActivatedDiagnosticsSession.MonotonicNow
    private let originNanoseconds: UInt64
    private let lock = NSLock()
    private var state = State()

    init(
        context: InternalVADRunContext,
        writer: any InternalVADDiagnosticsWriting,
        monotonicNow: @escaping InternalVoiceActivatedDiagnosticsSession.MonotonicNow
    ) {
        self.runOrdinal = context.runOrdinal
        self.writer = writer
        self.monotonicNow = monotonicNow
        originNanoseconds = context.originNanoseconds
    }

    func now() -> UInt64 {
        monotonicNow()
    }

    func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        Self.milliseconds(from: startNanoseconds, to: now())
    }

    func submit(_ milestone: InternalVADDiagnosticMilestone) {
        submit(milestone, observedAt: now())
    }

    private func submit(
        _ milestone: InternalVADDiagnosticMilestone,
        observedAt: UInt64
    ) {
        writer.submit(InternalVADDiagnosticRecord(
            runOrdinal: runOrdinal,
            elapsedMilliseconds: Self.milliseconds(
                from: originNanoseconds,
                to: observedAt
            ),
            milestone: milestone
        ))
    }

    func observe(_ event: VoiceActivatedRecognitionEvent) {
        let observedAt = now()
        switch event {
        case .phase(.armed):
            lock.withLock {
                if state.armedAt == nil { state.armedAt = observedAt }
            }
            submit(.armed, observedAt: observedAt)
        case .phase(.speechStarted):
            let armedToOnset = lock.withLock {
                if state.speechStartedAt == nil { state.speechStartedAt = observedAt }
                return Self.interval(from: state.armedAt, to: observedAt)
            }
            submit(.speechStarted(armedToOnset: armedToOnset), observedAt: observedAt)
        case .phase(.finalizing(let reason)):
            let speechToEndpoint = lock.withLock {
                if state.endpointAt == nil { state.endpointAt = observedAt }
                return Self.interval(from: state.speechStartedAt, to: observedAt)
            }
            submit(
                .finalizing(reason, speechToEndpoint: speechToEndpoint),
                observedAt: observedAt
            )
        case .noSpeech:
            if markTerminalObserved() {
                submit(.noSpeech, observedAt: observedAt)
            }
        case .finished:
            let endpointToFinished: InternalVADDiagnosticInterval? = lock.withLock {
                guard !state.terminalObserved else { return nil }
                state.terminalObserved = true
                return Self.interval(from: state.endpointAt, to: observedAt)
            }
            if let endpointToFinished {
                submit(
                    .finished(endpointToFinished: endpointToFinished),
                    observedAt: observedAt
                )
            }
        case .failed(let failure):
            if markTerminalObserved() {
                submit(.failed(failure.code), observedAt: observedAt)
            }
        case .transcript, .utterance, .level:
            break
        }
    }

    func markCancelRequested() {
        lock.withLock {
            state.cancelRequested = true
        }
    }

    func sourceClosed() {
        let cancellationState: Bool? = lock.withLock {
            guard !state.sourceCloseObserved else { return nil }
            state.sourceCloseObserved = true
            guard !state.terminalObserved else { return nil }
            return state.cancelRequested
        }
        if let cancellationState {
            submit(.sourceClosedWithoutTerminal(cancelRequested: cancellationState))
        }
    }

    private func markTerminalObserved() -> Bool {
        lock.withLock {
            guard !state.terminalObserved else { return false }
            state.terminalObserved = true
            return true
        }
    }

    private static func interval(from start: UInt64?, to end: UInt64) -> InternalVADDiagnosticInterval {
        guard let start, end >= start else { return .unavailable }
        return .milliseconds(milliseconds(from: start, to: end))
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }
}

private extension VoiceEndpointReason {
    var diagnosticName: String {
        switch self {
        case .silence: "silence"
        case .maximumDuration: "maximum_duration"
        case .manual: "manual"
        }
    }
}

private extension VoiceActivatedASRDiagnosticEvent {
    var internalDiagnosticGeneration: UInt64 {
        switch self {
        case .sourceStartRequested(let generation),
             .sourceStarted(let generation, _),
             .sourceFailed(let generation, _),
             .watchdogExpired(let generation, _, _),
             .progress(let generation, _, _),
             .segmentStarted(let generation, _, _),
             .speechResumed(let generation, _, _),
             .segmentEnded(let generation, _),
             .tailFlushStarted(let generation, _),
             .tailFlushFinished(let generation, _),
             .finishStreamRequested(let generation),
             .finishStreamReturned(let generation),
             .transportTerminal(let generation, _),
             .transportStreamClosed(let generation, _),
             .terminal(let generation, _, _):
            generation
        }
    }

    var internalDiagnosticEventName: String {
        switch self {
        case .sourceStartRequested: "core_source_start_requested"
        case .sourceStarted: "core_source_started"
        case .sourceFailed: "core_source_failed"
        case .watchdogExpired: "core_watchdog_expired"
        case .progress: "core_progress"
        case .segmentStarted: "core_segment_started"
        case .speechResumed: "core_speech_resumed"
        case .segmentEnded: "core_segment_ended"
        case .tailFlushStarted: "core_tail_flush_started"
        case .tailFlushFinished: "core_tail_flush_finished"
        case .finishStreamRequested: "core_finish_stream_requested"
        case .finishStreamReturned: "core_finish_stream_returned"
        case .transportTerminal: "core_transport_terminal"
        case .transportStreamClosed: "core_transport_stream_closed"
        case .terminal: "core_terminal"
        }
    }

    var internalDiagnosticFields: [String] {
        var fields = ["generation=\(internalDiagnosticGeneration)"]
        switch self {
        case .sourceStarted(_, let interval):
            fields.append("watchdog_interval_ms=\(interval)")
        case .sourceFailed(_, let origin):
            fields.append("origin=\(origin.rawValue)")
        case .watchdogExpired(_, let interval, let progress):
            fields.append("watchdog_interval_ms=\(interval)")
            fields.append(contentsOf: progress.internalDiagnosticFields)
        case .progress(_, let trigger, let progress):
            fields.append("trigger=\(trigger.rawValue)")
            fields.append(contentsOf: progress.internalDiagnosticFields)
        case .segmentStarted(_, let window, let required):
            fields.append("onset_window_frames=\(window)")
            fields.append("onset_required_speech_frames=\(required)")
        case .speechResumed(_, let interruptedSilence, let threshold):
            fields.append("interrupted_silence_frames=\(interruptedSilence)")
            fields.append("endpoint_silence_frames=\(threshold)")
        case .segmentEnded(_, let endpoint):
            fields.append(contentsOf: endpoint.internalDiagnosticFields)
        case .tailFlushStarted(_, let count):
            fields.append("pending_frames=\(count)")
        case .tailFlushFinished(_, let count):
            fields.append("flushed_frames=\(count)")
        case .transportTerminal(_, let terminal):
            fields.append("terminal=\(terminal.rawValue)")
        case .transportStreamClosed(_, let stage):
            fields.append("stage=\(stage.rawValue)")
        case .terminal(_, let stage, let outcome):
            fields.append("stage=\(stage.rawValue)")
            fields.append(contentsOf: outcome.internalDiagnosticFields)
        case .sourceStartRequested, .finishStreamRequested, .finishStreamReturned:
            break
        }
        return fields
    }
}

private extension VoiceActivatedASRDiagnosticProgress {
    var internalDiagnosticFields: [String] {
        [
            "accepted_frames=\(acceptedFrameCount)",
            "processed_frames=\(processedFrameCount)",
            "speech_frames=\(speechFrameCount)",
            "silence_frames=\(silenceFrameCount)",
            "current_silence_streak=\(currentSilenceStreak)",
            "maximum_silence_streak=\(maximumSilenceStreak)",
            "pending_frames=\(pendingFrameCount)"
        ]
    }
}

private extension VoiceActivatedASRDiagnosticEndpoint {
    var internalDiagnosticFields: [String] {
        switch self {
        case .silence(let observed, let threshold):
            [
                "endpoint=silence",
                "observed_frames=\(observed)",
                "threshold_frames=\(threshold)"
            ]
        case .maximumDuration(let observed, let threshold):
            [
                "endpoint=maximum_duration",
                "observed_frames=\(observed)",
                "threshold_frames=\(threshold)"
            ]
        case .manual:
            ["endpoint=manual"]
        }
    }
}

private extension VoiceActivatedASRDiagnosticTerminalOutcome {
    var internalDiagnosticFields: [String] {
        switch self {
        case .finished: ["outcome=finished"]
        case .noSpeech: ["outcome=no_speech"]
        case .cancelled: ["outcome=cancelled"]
        case .failed(let origin): ["outcome=failed", "origin=\(origin.rawValue)"]
        }
    }
}
#endif
