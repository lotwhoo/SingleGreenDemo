#if INTERNAL_DIAGNOSTICS
import Combine
import Foundation
import SingleGreenGlassesKit

enum InternalTeleprompterASRDiagnosticMilestone: Equatable, Sendable {
    case consentChecked(allowed: Bool)
    case permissionRequested
    case permissionReturned(allowed: Bool)
    case preparationRequested
    case preparationReturned
    case preparationFailed(code: ConversationFailureCode)
    case startRequested
    case startReturned
    case startFailed(code: SpeechRecognitionFailure.Code)
    case firstLevelObserved
    case transcriptObserved(sequence: UInt64)
    case utteranceObserved(sequence: UInt64)
    case finished
    case failed(code: SpeechRecognitionFailure.Code)
    case finishRequested
    case finishReturned
    case cancelRequested
    case cancelReturned
    case sourceClosedWithoutTerminal(cancelRequested: Bool)
    case phaseChanged(phase: TeleprompterPhase)
    case alignmentProgressed
    case sentenceAdvanced(sequence: UInt64)

    fileprivate var eventName: String {
        switch self {
        case .consentChecked: "consent_checked"
        case .permissionRequested: "permission_requested"
        case .permissionReturned: "permission_returned"
        case .preparationRequested: "preparation_requested"
        case .preparationReturned: "preparation_returned"
        case .preparationFailed: "preparation_failed"
        case .startRequested: "start_requested"
        case .startReturned: "start_returned"
        case .startFailed: "start_failed"
        case .firstLevelObserved: "first_level_observed"
        case .transcriptObserved: "transcript_observed"
        case .utteranceObserved: "utterance_observed"
        case .finished: "finished"
        case .failed: "failed"
        case .finishRequested: "finish_requested"
        case .finishReturned: "finish_returned"
        case .cancelRequested: "cancel_requested"
        case .cancelReturned: "cancel_returned"
        case .sourceClosedWithoutTerminal: "source_closed_without_terminal"
        case .phaseChanged: "phase_changed"
        case .alignmentProgressed: "alignment_progressed"
        case .sentenceAdvanced: "sentence_advanced"
        }
    }

    fileprivate var fields: [String] {
        switch self {
        case .consentChecked(let allowed), .permissionReturned(let allowed):
            return ["allowed=\(allowed)"]
        case .preparationFailed(let code):
            return ["failure=\(code.rawValue)"]
        case .startFailed(let code), .failed(let code):
            return ["failure=\(code.rawValue)"]
        case .transcriptObserved(let sequence), .utteranceObserved(let sequence),
             .sentenceAdvanced(let sequence):
            return ["sequence=\(sequence)"]
        case .sourceClosedWithoutTerminal(let cancelRequested):
            return ["cancel_requested=\(cancelRequested)"]
        case .phaseChanged(let phase):
            return ["phase=\(phase.diagnosticName)"]
        case .permissionRequested, .preparationRequested, .preparationReturned,
             .startRequested, .startReturned, .firstLevelObserved, .finished,
             .finishRequested, .finishReturned, .cancelRequested, .cancelReturned,
             .alignmentProgressed:
            return []
        }
    }
}

struct InternalTeleprompterASRDiagnosticRecord: Equatable, Sendable {
    static let schemaVersion = 1

    let runOrdinal: UInt64?
    let milestone: InternalTeleprompterASRDiagnosticMilestone

    var exportLine: String {
        var components = ["schema=v\(Self.schemaVersion)"]
        if let runOrdinal { components.append("run=\(runOrdinal)") }
        components.append("event=\(milestone.eventName)")
        components.append(contentsOf: milestone.fields)
        return components.joined(separator: " ")
    }
}

private final class InternalTeleprompterRunOrdinalSource: @unchecked Sendable {
    static let process = InternalTeleprompterRunOrdinalSource()

    private let lock = NSLock()
    private var ordinal: UInt64 = 0

    private init() {}

    func next() -> UInt64 {
        lock.withLock {
            ordinal &+= 1
            return ordinal
        }
    }
}

final class InternalTeleprompterASRDiagnosticsRecorder: @unchecked Sendable {
    private let writer: InternalDiagnosticsOrderedLineWriter

    init(writer: InternalDiagnosticsOrderedLineWriter) {
        self.writer = writer
    }

    func submit(
        _ milestone: InternalTeleprompterASRDiagnosticMilestone,
        runOrdinal: UInt64? = nil
    ) {
        writer.submit(InternalTeleprompterASRDiagnosticRecord(
            runOrdinal: runOrdinal,
            milestone: milestone
        ).exportLine)
    }
}

@MainActor
enum InternalTeleprompterASRDiagnosticsLiveComposition {
    static let wiringMarker = "teleprompter-asr-diagnostics-live-wiring-v1"

    struct Wiring {
        let marker: String
        let dependencies: TeleprompterDependencies
        let makeStateObserver: @MainActor (TeleprompterController) -> InternalTeleprompterStateDiagnosticsObserver
    }

    static func make(
        diagnosticSink: (any InternalDiagnosticsLineSink)?,
        base: TeleprompterDependencies
    ) -> Wiring {
        let writer = InternalDiagnosticsOrderedLineWriter(capacity: 256) { [weak diagnosticSink] line in
            await diagnosticSink?.record(category: "teleprompter_asr", message: line)
        }
        diagnosticSink?.registerDiagnosticsBarrierFactory {
            writer.makeBarrier()
        }
        let recorder = InternalTeleprompterASRDiagnosticsRecorder(writer: writer)
        let dependencies = TeleprompterDependencies(
            prepareSpeechSession: {
                recorder.submit(.preparationRequested)
                do {
                    let session = try await base.prepareSpeechSession()
                    recorder.submit(.preparationReturned)
                    return InternalTeleprompterASRDiagnosticsSession(
                        base: session,
                        runOrdinal: InternalTeleprompterRunOrdinalSource.process.next(),
                        recorder: recorder
                    )
                } catch {
                    recorder.submit(.preparationFailed(code: preparationFailureCode(error)))
                    throw error
                }
            },
            requestMicrophonePermission: {
                recorder.submit(.permissionRequested)
                let allowed = await base.requestMicrophonePermission()
                recorder.submit(.permissionReturned(allowed: allowed))
                return allowed
            },
            cloudSpeechRecognitionAllowed: {
                let allowed = base.cloudSpeechRecognitionAllowed()
                recorder.submit(.consentChecked(allowed: allowed))
                return allowed
            }
        )
        return Wiring(
            marker: wiringMarker,
            dependencies: dependencies,
            makeStateObserver: { controller in
                InternalTeleprompterStateDiagnosticsObserver(
                    controller: controller,
                    recorder: recorder
                )
            }
        )
    }

    private static func preparationFailureCode(_ error: Error) -> ConversationFailureCode {
        (error as? ConversationPreparationFailure)?.failureCode ?? .unknown
    }
}

/// Internal-only decorator that is the sole consumer of the provider-neutral
/// teleprompter ASR stream. It relays every event unchanged and records only
/// typed, content-free milestones.
final class InternalTeleprompterASRDiagnosticsSession: SpeechRecognitionSession, @unchecked Sendable {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>

    private let base: any SpeechRecognitionSession
    private let runOrdinal: UInt64
    private let recorder: InternalTeleprompterASRDiagnosticsRecorder
    private var relayTask: Task<Void, Never>?
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var payloadSequence: UInt64 = 0
        var firstLevelObserved = false
        var terminalObserved = false
        var cancelRequested = false
        var sourceCloseObserved = false
    }

    init(
        base: any SpeechRecognitionSession,
        runOrdinal: UInt64,
        recorder: InternalTeleprompterASRDiagnosticsRecorder
    ) {
        self.base = base
        self.runOrdinal = runOrdinal
        self.recorder = recorder
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        let sourceEvents = base.events
        relayTask = Task {
            for await event in sourceEvents {
                guard !Task.isCancelled else { break }
                continuation.yield(event)
                self.observe(event)
            }
            continuation.finish()
            if !Task.isCancelled { self.sourceClosed() }
        }
    }

    deinit {
        relayTask?.cancel()
    }

    func start() async throws {
        recorder.submit(.startRequested, runOrdinal: runOrdinal)
        do {
            try await base.start()
            recorder.submit(.startReturned, runOrdinal: runOrdinal)
        } catch {
            let code = (error as? SpeechRecognitionFailure)?.code ?? .unknown
            recorder.submit(.startFailed(code: code), runOrdinal: runOrdinal)
            throw error
        }
    }

    func finish() async {
        recorder.submit(.finishRequested, runOrdinal: runOrdinal)
        await base.finish()
        recorder.submit(.finishReturned, runOrdinal: runOrdinal)
    }

    func cancel() async {
        lock.withLock { state.cancelRequested = true }
        recorder.submit(.cancelRequested, runOrdinal: runOrdinal)
        await base.cancel()
        recorder.submit(.cancelReturned, runOrdinal: runOrdinal)
    }

    private func observe(_ event: SpeechRecognitionEvent) {
        let milestone: InternalTeleprompterASRDiagnosticMilestone? = lock.withLock {
            switch event {
            case .transcript:
                state.payloadSequence &+= 1
                return .transcriptObserved(sequence: state.payloadSequence)
            case .utterance:
                state.payloadSequence &+= 1
                return .utteranceObserved(sequence: state.payloadSequence)
            case .level:
                guard !state.firstLevelObserved else { return nil }
                state.firstLevelObserved = true
                return .firstLevelObserved
            case .finished:
                guard !state.terminalObserved else { return nil }
                state.terminalObserved = true
                return .finished
            case .failed(let failure):
                guard !state.terminalObserved else { return nil }
                state.terminalObserved = true
                return .failed(code: failure.code)
            }
        }
        if let milestone { recorder.submit(milestone, runOrdinal: runOrdinal) }
    }

    private func sourceClosed() {
        let cancelRequested: Bool? = lock.withLock {
            guard !state.sourceCloseObserved else { return nil }
            state.sourceCloseObserved = true
            guard !state.terminalObserved else { return nil }
            return state.cancelRequested
        }
        if let cancelRequested {
            recorder.submit(
                .sourceClosedWithoutTerminal(cancelRequested: cancelRequested),
                runOrdinal: runOrdinal
            )
        }
    }
}

@MainActor
final class InternalTeleprompterStateDiagnosticsObserver {
    private let recorder: InternalTeleprompterASRDiagnosticsRecorder
    private var previousState: TeleprompterState?
    private var sentenceAdvanceSequence: UInt64 = 0
    private var cancellable: AnyCancellable?

    init(
        controller: TeleprompterController,
        recorder: InternalTeleprompterASRDiagnosticsRecorder
    ) {
        self.recorder = recorder
        cancellable = controller.$state.sink { [weak self] state in
            self?.observe(state)
        }
    }

    func observe(_ state: TeleprompterState) {
        defer { previousState = state }
        guard let previousState else {
            recorder.submit(.phaseChanged(phase: state.phase))
            return
        }
        if previousState.phase != state.phase {
            recorder.submit(.phaseChanged(phase: state.phase))
        }
        if state.sentenceIndex > previousState.sentenceIndex {
            sentenceAdvanceSequence &+= 1
            recorder.submit(.sentenceAdvanced(sequence: sentenceAdvanceSequence))
            return
        }
        let publicStateUnchanged = previousState.script == state.script
            && previousState.sentenceIndex == state.sentenceIndex
            && previousState.phase == state.phase
            && previousState.userSafeError == state.userSafeError
        if publicStateUnchanged, previousState != state {
            recorder.submit(.alignmentProgressed)
        }
    }
}

private extension TeleprompterPhase {
    var diagnosticName: String {
        switch self {
        case .ready: "ready"
        case .preparing: "preparing"
        case .listening: "listening"
        case .paused: "paused"
        case .manualFallback: "manual_fallback"
        case .completed: "completed"
        }
    }
}
#endif
