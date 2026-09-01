import ASRDomain
import VoiceActivityDetectionKit

extension ASRClient: StreamingASRTransport {
    package func openStream() async throws -> AsyncStream<StreamingASRTransportEvent> {
        try await startDirectStream()
    }

    package func send(frames: [VADPCMFrame]) async throws {
        try await sendDirectAudioFrames(frames)
    }

    package func finishStream() async throws {
        try await finishDirectStream()
    }

    package func cancelStream() async {
        await cancelDirectStream()
    }
}
