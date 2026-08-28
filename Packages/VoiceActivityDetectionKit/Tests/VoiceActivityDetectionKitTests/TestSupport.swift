import VoiceActivityDetectionKit

enum SyntheticPCMFixture {
    static func frame(sequence: UInt64, amplitude: Int16 = 0) throws -> VADPCMFrame {
        try VADPCMFrame(
            sequence: sequence,
            samples: Array(repeating: amplitude, count: VADPCMFrame.sampleCount)
        )
    }

    static func observation(isSpeech: Bool) throws -> VoiceActivityObservation {
        try VoiceActivityObservation(
            speechProbability: isSpeech ? 1 : 0,
            isSpeech: isSpeech
        )
    }

    static func policy(
        preRoll: Int = 5,
        onsetWindow: Int = 3,
        onsetRequired: Int = 2,
        endpointSilence: Int = 3,
        maximumSegment: Int = 20
    ) throws -> VADSegmentationPolicy {
        try VADSegmentationPolicy(
            preRollFrameCount: preRoll,
            onsetWindowFrameCount: onsetWindow,
            onsetRequiredSpeechFrameCount: onsetRequired,
            endpointSilenceFrameCount: endpointSilence,
            maximumSegmentFrameCount: maximumSegment
        )
    }
}

enum ScriptedDetectorError: Error, Equatable, Sendable {
    case injected
    case exhausted
}

actor ScriptedVoiceActivityDetector: VoiceActivityDetecting {
    private var script: [Result<VoiceActivityObservation, ScriptedDetectorError>]
    private(set) var observedSequences: [UInt64] = []
    private(set) var resetCount = 0

    init(script: [Result<VoiceActivityObservation, ScriptedDetectorError>]) {
        self.script = script
    }

    func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        observedSequences.append(frame.sequence)
        guard !script.isEmpty else {
            throw ScriptedDetectorError.exhausted
        }
        return try script.removeFirst().get()
    }

    func reset() async {
        resetCount += 1
    }
}

actor GatedVoiceActivityDetector: VoiceActivityDetecting {
    private struct CountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let observations: [UInt64: VoiceActivityObservation]
    private let fallbackObservation: VoiceActivityObservation
    private var gatedSequences: Set<UInt64>
    private var suspendNextReset: Bool
    private var suspendedObservations: [UInt64: CheckedContinuation<VoiceActivityObservation, Never>] = [:]
    private var suspendedReset: CheckedContinuation<Void, Never>?
    private var observationWaiters: [CountWaiter] = []
    private var resetWaiters: [CountWaiter] = []
    private(set) var observedSequences: [UInt64] = []
    private(set) var resetCount = 0

    init(
        observations: [UInt64: VoiceActivityObservation],
        gatedSequences: Set<UInt64>,
        fallbackObservation: VoiceActivityObservation,
        suspendNextReset: Bool = false
    ) {
        self.observations = observations
        self.gatedSequences = gatedSequences
        self.fallbackObservation = fallbackObservation
        self.suspendNextReset = suspendNextReset
    }

    func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        observedSequences.append(frame.sequence)
        resumeSatisfiedObservationWaiters()
        guard gatedSequences.remove(frame.sequence) != nil else {
            return observations[frame.sequence] ?? fallbackObservation
        }
        return await withCheckedContinuation { continuation in
            suspendedObservations[frame.sequence] = continuation
        }
    }

    func reset() async {
        resetCount += 1
        resumeSatisfiedResetWaiters()
        let suspended = suspendedObservations.values
        suspendedObservations.removeAll(keepingCapacity: true)
        for continuation in suspended {
            continuation.resume(returning: fallbackObservation)
        }
        if suspendNextReset {
            suspendNextReset = false
            await withCheckedContinuation { continuation in
                suspendedReset = continuation
            }
        }
    }

    func release(sequence: UInt64) {
        let continuation = suspendedObservations.removeValue(forKey: sequence)
        continuation?.resume(returning: observations[sequence] ?? fallbackObservation)
    }

    func waitUntilObservedCount(_ count: Int) async {
        guard observedSequences.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            observationWaiters.append(
                CountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func waitUntilResetCount(_ count: Int) async {
        guard resetCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            resetWaiters.append(
                CountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func releaseReset() {
        let continuation = suspendedReset
        suspendedReset = nil
        continuation?.resume()
    }

    private func resumeSatisfiedObservationWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in observationWaiters {
            if observedSequences.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        observationWaiters = remaining
    }

    private func resumeSatisfiedResetWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in resetWaiters {
            if resetCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        resetWaiters = remaining
    }
}

struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextBool() -> Bool {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 61 >= 5
    }
}
