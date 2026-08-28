import Foundation
import VoiceActivityDetectionKit

enum StreamingASRTransportEvent: Equatable, Sendable {
    case transcript(String)
    case utterance(String)
    case finished
    case failed(ASRFailure)
}

/// Provider-neutral one-shot streaming boundary used by local-VAD-gated recognition.
/// Calls are awaited by the session so accepted frame batches remain strictly FIFO.
protocol StreamingASRTransport: Actor {
    func openStream() async throws -> AsyncStream<StreamingASRTransportEvent>
    func send(frames: [VADPCMFrame]) async throws
    func finishStream() async throws
    func cancelStream() async
}

extension ASRClient: StreamingASRTransport {
    func openStream() async throws -> AsyncStream<StreamingASRTransportEvent> {
        try await startDirectStream()
    }

    func send(frames: [VADPCMFrame]) async throws {
        try await sendDirectAudioFrames(frames)
    }

    func finishStream() async throws {
        try await finishDirectStream()
    }

    func cancelStream() async {
        await cancelDirectStream()
    }
}
