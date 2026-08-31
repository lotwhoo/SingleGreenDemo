import VoiceActivityDetectionKit

/// Correlation supplied by the composition root. Neither value identifies a
/// provider, device, route, or captured utterance.
public struct VoiceActivatedASRDiagnosticContext: Equatable, Sendable {
    public let runOrdinal: UInt64
    public let originNanoseconds: UInt64

    public init(runOrdinal: UInt64, originNanoseconds: UInt64) {
        self.runOrdinal = runOrdinal
        self.originNanoseconds = originNanoseconds
    }
}

/// A synchronous, content-free diagnostics port. Implementations must return
/// promptly; production capture never awaits diagnostics persistence or UI.
public struct VoiceActivatedASRDiagnosticsObserver: Sendable {
    public let context: VoiceActivatedASRDiagnosticContext
    private let handler: @Sendable (VoiceActivatedASRDiagnosticEvent) -> Void

    public init(
        context: VoiceActivatedASRDiagnosticContext,
        handler: @escaping @Sendable (VoiceActivatedASRDiagnosticEvent) -> Void
    ) {
        self.context = context
        self.handler = handler
    }

    public func observe(_ event: VoiceActivatedASRDiagnosticEvent) {
        handler(event)
    }
}

public enum VoiceActivatedASRDiagnosticProgressTrigger: String, Equatable, Sendable {
    case frameAccepted
    case detectorProcessed
}

public struct VoiceActivatedASRDiagnosticProgress: Equatable, Sendable {
    public let acceptedFrameCount: Int
    public let processedFrameCount: Int
    public let speechFrameCount: Int
    public let silenceFrameCount: Int
    public let currentSilenceStreak: Int
    public let maximumSilenceStreak: Int
    public let pendingFrameCount: Int

    public init(
        acceptedFrameCount: Int,
        processedFrameCount: Int,
        speechFrameCount: Int,
        silenceFrameCount: Int,
        currentSilenceStreak: Int,
        maximumSilenceStreak: Int,
        pendingFrameCount: Int
    ) {
        self.acceptedFrameCount = acceptedFrameCount
        self.processedFrameCount = processedFrameCount
        self.speechFrameCount = speechFrameCount
        self.silenceFrameCount = silenceFrameCount
        self.currentSilenceStreak = currentSilenceStreak
        self.maximumSilenceStreak = maximumSilenceStreak
        self.pendingFrameCount = pendingFrameCount
    }
}

public enum VoiceActivatedASRDiagnosticFailureOrigin: String, Equatable, Sendable {
    case sourceStart
    case sourceEnded
    case sourceStream
    case frameWatchdog
    case detectorProcessing
    case uploadBackpressure
    case transport
}

public enum VoiceActivatedASRDiagnosticTerminalStage: String, Equatable, Sendable {
    case arming
    case armed
    case openingRecognizer
    case streaming
    case draining
    case finalizing
}

public enum VoiceActivatedASRDiagnosticTerminalOutcome: Equatable, Sendable {
    case finished
    case noSpeech
    case cancelled
    case failed(origin: VoiceActivatedASRDiagnosticFailureOrigin)
}

public enum VoiceActivatedASRDiagnosticTransportTerminal: String, Equatable, Sendable {
    case finished
    case failed
}

public enum VoiceActivatedASRDiagnosticEndpoint: Equatable, Sendable {
    case silence(observedFrameCount: Int, thresholdFrameCount: Int)
    case maximumDuration(observedFrameCount: Int, thresholdFrameCount: Int)
    case manual
}

public enum VoiceActivatedASRDiagnosticEvent: Equatable, Sendable {
    case sourceStartRequested(generation: UInt64)
    case sourceStarted(generation: UInt64, watchdogIntervalMilliseconds: UInt64)
    case sourceFailed(generation: UInt64, origin: VoiceActivatedASRDiagnosticFailureOrigin)
    case watchdogExpired(
        generation: UInt64,
        intervalMilliseconds: UInt64,
        progress: VoiceActivatedASRDiagnosticProgress
    )
    case progress(
        generation: UInt64,
        trigger: VoiceActivatedASRDiagnosticProgressTrigger,
        progress: VoiceActivatedASRDiagnosticProgress
    )
    case segmentStarted(
        generation: UInt64,
        onsetWindowFrameCount: Int,
        onsetRequiredSpeechFrameCount: Int
    )
    case speechResumed(
        generation: UInt64,
        afterSilentFrameCount: Int,
        endpointSilenceFrameCount: Int
    )
    case segmentEnded(generation: UInt64, endpoint: VoiceActivatedASRDiagnosticEndpoint)
    case tailFlushStarted(generation: UInt64, pendingFrameCount: Int)
    case tailFlushFinished(generation: UInt64, flushedFrameCount: Int)
    case finishStreamRequested(generation: UInt64)
    case finishStreamReturned(generation: UInt64)
    case transportTerminal(generation: UInt64, terminal: VoiceActivatedASRDiagnosticTransportTerminal)
    case transportStreamClosed(generation: UInt64, stage: VoiceActivatedASRDiagnosticTerminalStage)
    case terminal(
        generation: UInt64,
        stage: VoiceActivatedASRDiagnosticTerminalStage,
        outcome: VoiceActivatedASRDiagnosticTerminalOutcome
    )
}

/// Captures detector classification without exposing probability, PCM, or
/// framework/provider payloads. Results are consumed only by the matching run.
actor VoiceActivatedASRDiagnosticsDetector: VoiceActivityDetecting {
    private let base: any VoiceActivityDetecting
    private var activeGeneration: UInt64?
    private var classifications: [UInt64: Bool] = [:]

    init(base: any VoiceActivityDetecting) {
        self.base = base
    }

    func beginRun(generation: UInt64) {
        activeGeneration = generation
        classifications.removeAll(keepingCapacity: true)
    }

    func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        let generation = activeGeneration
        let observation = try await base.observation(for: frame)
        guard activeGeneration == generation, generation != nil else { return observation }
        classifications[frame.sequence] = observation.isSpeech
        return observation
    }

    func takeClassification(sequence: UInt64, generation: UInt64) -> Bool? {
        guard activeGeneration == generation else { return nil }
        return classifications.removeValue(forKey: sequence)
    }

    func reset() async {
        classifications.removeAll(keepingCapacity: true)
        await base.reset()
    }
}
