import Foundation
import os
import ASRDomain
import VoiceActivityDetectionKit

/// Bridges `AudioCapture` into exact, bounded 20 ms VAD frames. The relay is lock based because
/// AVAudioEngine invokes capture callbacks on its real-time thread; it never logs or persists PCM.
actor AudioCapturePCMFrameSource: PCMFrameSource {
    private let relay: PCMFrameSourceRelay
    private let capture: AudioCapture
    private var activeRunToken: UInt64?

    init(maximumBufferedFrameCount: Int) {
        self.init(
            maximumBufferedFrameCount: maximumBufferedFrameCount,
            audioSystemEventSource: PlatformAudioSystemEventSource()
        )
    }

    init(
        maximumBufferedFrameCount: Int,
        audioSystemEventSource: any AudioSystemEventSource
    ) {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: maximumBufferedFrameCount)
        self.relay = relay
        self.capture = AudioCapture(
            audioSystemEventSource: audioSystemEventSource,
            runDiagnosticHandler: { runToken, diagnostic in
                relay.handle(diagnostic, runToken: runToken)
            }
        )
    }

    func start() async throws -> PCMFrameSourceStreams {
        let run = relay.beginRun()
        activeRunToken = run.token
        do {
            try capture.startRun(
                callbackToken: run.token,
                chunkByteCount: VADPCMFrame.byteCount,
                chunkHandler: { [relay] token, bytes in
                    relay.yieldFrame(bytes, runToken: token)
                },
                levelHandler: { [relay] token, level in
                    relay.yieldLevel(level, runToken: token)
                }
            )
            return run.streams
        } catch {
            if activeRunToken == run.token { activeRunToken = nil }
            relay.finish(
                runToken: run.token,
                throwing: PCMFrameSourceFailure.audioUnavailable
            )
            throw error
        }
    }

    func stop() async {
        capture.stop(flushRemainder: false)
        guard let runToken = activeRunToken else { return }
        activeRunToken = nil
        relay.finish(runToken: runToken)
    }
}

/// AVAudioEngine callbacks and async stream consumers can race. The complete stream identity,
/// sequence and continuation state is guarded by `state`; continuations are never logged or stored.
final class PCMFrameSourceRelay: @unchecked Sendable {
    private struct State {
        var nextRunToken: UInt64 = 0
        var activeRunToken: UInt64?
        var nextSequence: UInt64 = 0
        var frameContinuation: AsyncThrowingStream<VADPCMFrame, any Error>.Continuation?
        var levelContinuation: AsyncStream<Float>.Continuation?
    }

    private let maximumBufferedFrameCount: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumBufferedFrameCount: Int) {
        precondition(maximumBufferedFrameCount > 0)
        self.maximumBufferedFrameCount = maximumBufferedFrameCount
    }

    func beginRun() -> PCMFrameSourceRun {
        let (frames, frameContinuation) = AsyncThrowingStream<VADPCMFrame, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedFrameCount)
        )
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let runToken = state.withLock { state in
            state.frameContinuation?.finish()
            state.levelContinuation?.finish()
            state.nextRunToken &+= 1
            let runToken = state.nextRunToken
            state.activeRunToken = runToken
            state.nextSequence = 0
            state.frameContinuation = frameContinuation
            state.levelContinuation = levelContinuation
            return runToken
        }
        return PCMFrameSourceRun(
            token: runToken,
            streams: PCMFrameSourceStreams(frames: frames, levels: levels)
        )
    }

    func yieldFrame(_ data: Data, runToken: UInt64) {
        let result: AsyncThrowingStream<VADPCMFrame, any Error>.Continuation.YieldResult? = state.withLock {
            state in
            guard state.activeRunToken == runToken,
                  let continuation = state.frameContinuation else { return nil }
            let sequence = state.nextSequence
            state.nextSequence &+= 1
            guard let frame = try? VADPCMFrame(
                sequence: sequence,
                littleEndianBytes: Array(data)
            ) else {
                continuation.finish(throwing: PCMFrameSourceFailure.invalidFrame)
                state.activeRunToken = nil
                state.frameContinuation = nil
                state.levelContinuation?.finish()
                state.levelContinuation = nil
                return nil
            }
            return continuation.yield(frame)
        }

        if case .dropped? = result {
            finish(runToken: runToken, throwing: PCMFrameSourceFailure.bufferOverflow)
        }
    }

    func yieldLevel(_ level: Float, runToken: UInt64) {
        state.withLock { state in
            guard state.activeRunToken == runToken else { return }
            _ = state.levelContinuation?.yield(min(max(level, 0), 1))
        }
    }

    func handle(_ diagnostic: AudioCapture.Diagnostic, runToken: UInt64) {
        switch diagnostic {
        case .conversionFailed:
            finish(runToken: runToken, throwing: PCMFrameSourceFailure.invalidFrame)
        case .audioSystemEvent(let event):
            if event != .interruptionEnded {
                finish(
                    runToken: runToken,
                    throwing: PCMFrameSourceFailure.audioSystemEvent(event)
                )
            }
        }
    }

    func finish(runToken: UInt64, throwing error: (any Error)? = nil) {
        state.withLock { state in
            guard state.activeRunToken == runToken else { return }
            if let error {
                state.frameContinuation?.finish(throwing: error)
            } else {
                state.frameContinuation?.finish()
            }
            state.levelContinuation?.finish()
            state.activeRunToken = nil
            state.frameContinuation = nil
            state.levelContinuation = nil
        }
    }
}

package enum ApplePCMFrameSourceFactory {
    package static func make(
        maximumBufferedFrameCount: Int
    ) -> any PCMFrameSource {
        AudioCapturePCMFrameSource(
            maximumBufferedFrameCount: maximumBufferedFrameCount
        )
    }
}
