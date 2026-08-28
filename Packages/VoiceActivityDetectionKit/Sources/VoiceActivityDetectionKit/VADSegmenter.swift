public enum VADEndpointReason: Equatable, Sendable {
    case silence(silentFrameCount: Int)
    case maximumDuration(frameCount: Int)
}

public enum VADSegmentationEvent: Equatable, Sendable {
    case segmentStarted(segmentID: UInt64)
    case frames(segmentID: UInt64, frames: [VADPCMFrame])
    case speechResumed(segmentID: UInt64, afterSilentFrameCount: Int)
    case segmentEnded(segmentID: UInt64, reason: VADEndpointReason)
}

public enum VADSegmentationError: Error, Equatable, Sendable {
    case sequenceNotIncreasing(previous: UInt64, current: UInt64)
}

public struct VADSegmenter: Sendable {
    public let policy: VADSegmentationPolicy

    private var lastSequence: UInt64?
    private var preRollFrames: [VADPCMFrame] = []
    private var onsetHistory: [Bool] = []
    private var activeSegmentID: UInt64?
    private var forwardedFrameCount = 0
    private var trailingSilentFrameCount = 0

    public init(policy: VADSegmentationPolicy) {
        self.policy = policy
    }

    public var isSegmentActive: Bool {
        activeSegmentID != nil
    }

    public var bufferedPreRollFrameCount: Int {
        preRollFrames.count
    }

    public mutating func consume(
        _ frame: VADPCMFrame,
        observation: VoiceActivityObservation
    ) throws -> [VADSegmentationEvent] {
        try validateSequence(frame)
        lastSequence = frame.sequence

        if let activeSegmentID {
            return consumeActiveFrame(
                frame,
                observation: observation,
                segmentID: activeSegmentID
            )
        }
        return consumeIdleFrame(frame, observation: observation)
    }

    public mutating func reset() {
        lastSequence = nil
        preRollFrames.removeAll(keepingCapacity: true)
        onsetHistory.removeAll(keepingCapacity: true)
        activeSegmentID = nil
        forwardedFrameCount = 0
        trailingSilentFrameCount = 0
    }

    func validateSequence(_ frame: VADPCMFrame) throws {
        if let lastSequence, frame.sequence <= lastSequence {
            throw VADSegmentationError.sequenceNotIncreasing(
                previous: lastSequence,
                current: frame.sequence
            )
        }
    }

    private mutating func consumeIdleFrame(
        _ frame: VADPCMFrame,
        observation: VoiceActivityObservation
    ) -> [VADSegmentationEvent] {
        preRollFrames.append(frame)
        trimPrefix(of: &preRollFrames, to: policy.preRollFrameCount)

        onsetHistory.append(observation.isSpeech)
        trimPrefix(of: &onsetHistory, to: policy.onsetWindowFrameCount)

        let hasCompleteOnsetWindow = onsetHistory.count == policy.onsetWindowFrameCount
        let speechFrameCount = onsetHistory.lazy.filter { $0 }.count
        guard hasCompleteOnsetWindow,
              speechFrameCount >= policy.onsetRequiredSpeechFrameCount else {
            return []
        }

        let segmentID = frame.sequence
        let startingFrames = preRollFrames
        activeSegmentID = segmentID
        forwardedFrameCount = startingFrames.count
        trailingSilentFrameCount = onsetHistory.reversed().prefix { !$0 }.count
        preRollFrames.removeAll(keepingCapacity: true)
        onsetHistory.removeAll(keepingCapacity: true)

        var events: [VADSegmentationEvent] = [
            .segmentStarted(segmentID: segmentID),
            .frames(segmentID: segmentID, frames: startingFrames)
        ]
        if let reason = endpointReasonIfReached() {
            events.append(.segmentEnded(segmentID: segmentID, reason: reason))
            finishActiveSegment()
        }
        return events
    }

    private mutating func consumeActiveFrame(
        _ frame: VADPCMFrame,
        observation: VoiceActivityObservation,
        segmentID: UInt64
    ) -> [VADSegmentationEvent] {
        var events: [VADSegmentationEvent] = []
        if observation.isSpeech {
            if trailingSilentFrameCount > 0 {
                events.append(
                    .speechResumed(
                        segmentID: segmentID,
                        afterSilentFrameCount: trailingSilentFrameCount
                    )
                )
            }
            trailingSilentFrameCount = 0
        } else {
            trailingSilentFrameCount += 1
        }

        forwardedFrameCount += 1
        events.append(.frames(segmentID: segmentID, frames: [frame]))

        if let reason = endpointReasonIfReached() {
            events.append(.segmentEnded(segmentID: segmentID, reason: reason))
            finishActiveSegment()
        }
        return events
    }

    private func endpointReasonIfReached() -> VADEndpointReason? {
        if trailingSilentFrameCount >= policy.endpointSilenceFrameCount {
            return .silence(silentFrameCount: trailingSilentFrameCount)
        }
        if forwardedFrameCount >= policy.maximumSegmentFrameCount {
            return .maximumDuration(frameCount: forwardedFrameCount)
        }
        return nil
    }

    private mutating func finishActiveSegment() {
        activeSegmentID = nil
        forwardedFrameCount = 0
        trailingSilentFrameCount = 0
        preRollFrames.removeAll(keepingCapacity: true)
        onsetHistory.removeAll(keepingCapacity: true)
    }

    private func trimPrefix<Element>(of values: inout [Element], to maximumCount: Int) {
        let overflow = values.count - maximumCount
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}
