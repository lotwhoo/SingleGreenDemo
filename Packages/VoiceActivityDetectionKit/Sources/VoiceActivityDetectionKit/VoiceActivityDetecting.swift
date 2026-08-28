public struct VoiceActivityObservation: Equatable, Sendable {
    public let speechProbability: Double
    public let isSpeech: Bool

    public init(speechProbability: Double, isSpeech: Bool) throws {
        guard speechProbability.isFinite else {
            throw VoiceActivityObservationError.nonFiniteProbability
        }
        guard (0 ... 1).contains(speechProbability) else {
            throw VoiceActivityObservationError.probabilityOutOfRange(speechProbability)
        }
        self.speechProbability = speechProbability
        self.isSpeech = isSpeech
    }
}

public enum VoiceActivityObservationError: Error, Equatable, Sendable {
    case nonFiniteProbability
    case probabilityOutOfRange(Double)
}

public protocol VoiceActivityDetecting: Actor {
    func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation
    func reset() async
}
