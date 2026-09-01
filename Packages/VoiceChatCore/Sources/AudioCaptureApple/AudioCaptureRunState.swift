import Foundation
import os

/// Mutable callback state shared by the caller and AVAudioEngine's real-time callback. Every access
/// is guarded by `state`; user callbacks are copied out and invoked after the lock is released.
final class AudioCaptureRunState: @unchecked Sendable {
    struct StoppedRun: Sendable {
        let callbackToken: UInt64
        let chunkHandler: @Sendable (UInt64, Data) -> Void
        let remainder: Data?
    }

    private struct ActiveRun: Sendable {
        let captureRunID: UInt64
        let callbackToken: UInt64
        let chunkByteCount: Int
        let chunkHandler: @Sendable (UInt64, Data) -> Void
        let levelHandler: (@Sendable (UInt64, Float) -> Void)?
        var pending = Data()
    }

    private struct State: Sendable {
        var nextCaptureRunID: UInt64 = 0
        var activeRun: ActiveRun?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isRunning: Bool {
        state.withLock { $0.activeRun != nil }
    }

    func begin(
        callbackToken: UInt64?,
        chunkByteCount: Int,
        chunkHandler: @escaping @Sendable (UInt64, Data) -> Void,
        levelHandler: (@Sendable (UInt64, Float) -> Void)?
    ) -> UInt64? {
        state.withLock { state in
            guard state.activeRun == nil else { return nil }
            state.nextCaptureRunID &+= 1
            let captureRunID = state.nextCaptureRunID
            state.activeRun = ActiveRun(
                captureRunID: captureRunID,
                callbackToken: callbackToken ?? captureRunID,
                chunkByteCount: chunkByteCount,
                chunkHandler: chunkHandler,
                levelHandler: levelHandler
            )
            return captureRunID
        }
    }

    func isActive(captureRunID: UInt64) -> Bool {
        state.withLock { $0.activeRun?.captureRunID == captureRunID }
    }

    func callbackToken(captureRunID: UInt64) -> UInt64? {
        state.withLock { state in
            guard state.activeRun?.captureRunID == captureRunID else { return nil }
            return state.activeRun?.callbackToken
        }
    }

    func append(_ data: Data, captureRunID: UInt64) {
        let emission: (UInt64, @Sendable (UInt64, Data) -> Void, [Data])? = state.withLock { state in
            guard var activeRun = state.activeRun,
                  activeRun.captureRunID == captureRunID else { return nil }
            activeRun.pending.append(data)
            var chunks: [Data] = []
            while activeRun.pending.count >= activeRun.chunkByteCount {
                chunks.append(Data(activeRun.pending.prefix(activeRun.chunkByteCount)))
                activeRun.pending.removeFirst(activeRun.chunkByteCount)
            }
            state.activeRun = activeRun
            return (activeRun.callbackToken, activeRun.chunkHandler, chunks)
        }
        guard let emission else { return }
        for chunk in emission.2 {
            emission.1(emission.0, chunk)
        }
    }

    func emitLevel(_ level: Float, captureRunID: UInt64) {
        let emission: (UInt64, @Sendable (UInt64, Float) -> Void)? = state.withLock { state in
            guard let activeRun = state.activeRun,
                  activeRun.captureRunID == captureRunID,
                  let levelHandler = activeRun.levelHandler else { return nil }
            return (activeRun.callbackToken, levelHandler)
        }
        if let (callbackToken, levelHandler) = emission {
            levelHandler(callbackToken, level)
        }
    }

    func stop(
        captureRunID: UInt64? = nil,
        flushRemainder: Bool
    ) -> StoppedRun? {
        state.withLock { state in
            guard let activeRun = state.activeRun,
                  captureRunID == nil || activeRun.captureRunID == captureRunID else { return nil }
            state.activeRun = nil
            return StoppedRun(
                callbackToken: activeRun.callbackToken,
                chunkHandler: activeRun.chunkHandler,
                remainder: flushRemainder && !activeRun.pending.isEmpty ? activeRun.pending : nil
            )
        }
    }
}
