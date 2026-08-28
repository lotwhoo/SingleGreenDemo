import VoiceActivityDetectionKit

public actor EnergyVoiceActivityDetector: VoiceActivityDetecting {
    private let speechMeanAbsoluteAmplitude: UInt64

    public init(speechMeanAbsoluteAmplitude: UInt64 = 800) {
        self.speechMeanAbsoluteAmplitude = max(1, speechMeanAbsoluteAmplitude)
    }

    public func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        let amplitudeSum = frame.samples.reduce(into: UInt64(0)) { result, sample in
            result += UInt64(sample.magnitude)
        }
        let meanAmplitude = amplitudeSum / UInt64(VADPCMFrame.sampleCount)
        let probability = min(
            1,
            Double(meanAmplitude) / Double(speechMeanAbsoluteAmplitude)
        )
        return try VoiceActivityObservation(
            speechProbability: probability,
            isSpeech: meanAmplitude >= speechMeanAbsoluteAmplitude
        )
    }

    public func reset() async {}
}
