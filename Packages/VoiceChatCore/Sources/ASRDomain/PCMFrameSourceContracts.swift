import Foundation
import VoiceActivityDetectionKit

/// Provider-neutral audio lifecycle signal. It intentionally carries no route name,
/// device identifier, framework payload, or captured audio.
public enum ASRAudioSystemEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged
    case mediaServicesReset
}

package enum PCMFrameSourceFailure: Error, Equatable, Sendable {
    case bufferOverflow
    case invalidFrame
    case audioUnavailable
    case audioSystemEvent(ASRAudioSystemEvent)
}

package struct PCMFrameSourceStreams: Sendable {
    package let frames: AsyncThrowingStream<VADPCMFrame, any Error>
    package let levels: AsyncStream<Float>

    package init(
        frames: AsyncThrowingStream<VADPCMFrame, any Error>,
        levels: AsyncStream<Float>
    ) {
        self.frames = frames
        self.levels = levels
    }
}

package struct PCMFrameSourceRun: Sendable {
    package let token: UInt64
    package let streams: PCMFrameSourceStreams

    package init(token: UInt64, streams: PCMFrameSourceStreams) {
        self.token = token
        self.streams = streams
    }
}

package protocol PCMFrameSource: Actor {
    func start() async throws -> PCMFrameSourceStreams
    func stop() async
}
