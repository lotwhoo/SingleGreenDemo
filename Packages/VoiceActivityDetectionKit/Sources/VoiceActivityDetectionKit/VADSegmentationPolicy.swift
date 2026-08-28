public struct VADSegmentationPolicy: Equatable, Sendable {
    public static let maximumPreRollFrameCount = 250
    public static let maximumOnsetWindowFrameCount = 50
    public static let maximumEndpointSilenceFrameCount = 500
    public static let maximumSegmentFrameCount = 18_000

    public let preRollFrameCount: Int
    public let onsetWindowFrameCount: Int
    public let onsetRequiredSpeechFrameCount: Int
    public let endpointSilenceFrameCount: Int
    public let maximumSegmentFrameCount: Int

    public init(
        preRollFrameCount: Int,
        onsetWindowFrameCount: Int,
        onsetRequiredSpeechFrameCount: Int,
        endpointSilenceFrameCount: Int,
        maximumSegmentFrameCount: Int
    ) throws {
        guard (1 ... Self.maximumPreRollFrameCount).contains(preRollFrameCount) else {
            throw VADSegmentationPolicyError.preRollFrameCountOutOfRange(
                actual: preRollFrameCount,
                maximum: Self.maximumPreRollFrameCount
            )
        }
        guard (1 ... Self.maximumOnsetWindowFrameCount).contains(onsetWindowFrameCount) else {
            throw VADSegmentationPolicyError.onsetWindowFrameCountOutOfRange(
                actual: onsetWindowFrameCount,
                maximum: Self.maximumOnsetWindowFrameCount
            )
        }
        guard preRollFrameCount >= onsetWindowFrameCount else {
            throw VADSegmentationPolicyError.preRollShorterThanOnsetWindow(
                preRoll: preRollFrameCount,
                onsetWindow: onsetWindowFrameCount
            )
        }
        guard (1 ... onsetWindowFrameCount).contains(onsetRequiredSpeechFrameCount) else {
            throw VADSegmentationPolicyError.onsetRequiredSpeechFrameCountOutOfRange(
                actual: onsetRequiredSpeechFrameCount,
                onsetWindow: onsetWindowFrameCount
            )
        }
        guard (1 ... Self.maximumEndpointSilenceFrameCount).contains(endpointSilenceFrameCount) else {
            throw VADSegmentationPolicyError.endpointSilenceFrameCountOutOfRange(
                actual: endpointSilenceFrameCount,
                maximum: Self.maximumEndpointSilenceFrameCount
            )
        }
        guard (preRollFrameCount ... Self.maximumSegmentFrameCount).contains(maximumSegmentFrameCount) else {
            throw VADSegmentationPolicyError.maximumSegmentFrameCountOutOfRange(
                actual: maximumSegmentFrameCount,
                minimum: preRollFrameCount,
                maximum: Self.maximumSegmentFrameCount
            )
        }

        self.preRollFrameCount = preRollFrameCount
        self.onsetWindowFrameCount = onsetWindowFrameCount
        self.onsetRequiredSpeechFrameCount = onsetRequiredSpeechFrameCount
        self.endpointSilenceFrameCount = endpointSilenceFrameCount
        self.maximumSegmentFrameCount = maximumSegmentFrameCount
    }
}

public enum VADSegmentationPolicyError: Error, Equatable, Sendable {
    case preRollFrameCountOutOfRange(actual: Int, maximum: Int)
    case onsetWindowFrameCountOutOfRange(actual: Int, maximum: Int)
    case preRollShorterThanOnsetWindow(preRoll: Int, onsetWindow: Int)
    case onsetRequiredSpeechFrameCountOutOfRange(actual: Int, onsetWindow: Int)
    case endpointSilenceFrameCountOutOfRange(actual: Int, maximum: Int)
    case maximumSegmentFrameCountOutOfRange(actual: Int, minimum: Int, maximum: Int)
}
