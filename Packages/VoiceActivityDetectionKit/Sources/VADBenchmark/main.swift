import VADBenchmarkSupport
import VoiceActivityDetectionKit

@main
struct VADBenchmark {
    static func main() async throws {
        let policy = try VADSegmentationPolicy(
            preRollFrameCount: 15,
            onsetWindowFrameCount: 5,
            onsetRequiredSpeechFrameCount: 3,
            endpointSilenceFrameCount: 25,
            maximumSegmentFrameCount: 750
        )
        let pipeline = VoiceActivityDetectionPipeline(
            detector: EnergyVoiceActivityDetector(),
            policy: policy
        )
        let frameCount = 10_000
        let clock = ContinuousClock()
        let start = clock.now
        var segmentCount = 0
        var endpointCount = 0

        for sequence in 0 ..< frameCount {
            let phase = sequence % 200
            let amplitude: Int16 = phase >= 50 && phase < 125 ? 1_500 : 0
            let frame = try VADPCMFrame(
                sequence: UInt64(sequence),
                samples: Array(repeating: amplitude, count: VADPCMFrame.sampleCount)
            )
            for event in try await pipeline.process(frame) {
                switch event {
                case .segmentStarted:
                    segmentCount += 1
                case .segmentEnded:
                    endpointCount += 1
                case .frames, .speechResumed:
                    break
                }
            }
        }

        let elapsed = start.duration(to: clock.now).components
        let elapsedNanoseconds = elapsed.seconds * 1_000_000_000
            + elapsed.attoseconds / 1_000_000_000
        print(
            "vad_benchmark frame_count=\(frameCount) segment_count=\(segmentCount) "
                + "endpoint_count=\(endpointCount) elapsed_nanoseconds=\(elapsedNanoseconds)"
        )
    }
}
