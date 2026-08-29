import VoiceActivityDetectionKit

/// Pure per-run buffering and lifecycle facts for `VoiceActivatedASRSession`.
/// The owning actor retains every Task, transport, detector, watchdog, and generation boundary.
struct VoiceActivatedASRRunState: Equatable, Sendable {
    var acceptingFrames = false
    var speechStarted = false
    var transportAttempted = false
    var sourceStopExpected = false
    var processedBeforeOnset = 0
    private(set) var frameQueue: [VADPCMFrame] = []
    private(set) var pendingUploadFrames: [VADPCMFrame] = []
    private(set) var inFlightUploadFrameCount = 0
    var manualFinishRequested = false
    var finalizationStarted = false

    var pendingFrameCount: Int {
        frameQueue.count + pendingUploadFrames.count + inFlightUploadFrameCount
    }

    var hasQueuedFrames: Bool {
        !frameQueue.isEmpty
    }

    mutating func reset() {
        acceptingFrames = false
        speechStarted = false
        transportAttempted = false
        sourceStopExpected = false
        processedBeforeOnset = 0
        frameQueue.removeAll(keepingCapacity: true)
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = 0
        manualFinishRequested = false
        finalizationStarted = false
    }

    func canAcceptFrame(maximumPendingFrameCount: Int) -> Bool {
        pendingFrameCount < maximumPendingFrameCount
    }

    mutating func enqueueFrame(_ frame: VADPCMFrame) {
        frameQueue.append(frame)
    }

    mutating func dequeueFrame() -> VADPCMFrame? {
        guard !frameQueue.isEmpty else { return nil }
        return frameQueue.removeFirst()
    }

    /// Appends emitted segment frames and reports whether the pending upload buffer remains valid.
    /// A rejected append intentionally remains buffered until the actor fails and clears the run.
    mutating func appendUploadFrames(
        _ frames: [VADPCMFrame],
        maximumPendingFrameCount: Int
    ) -> Bool {
        pendingUploadFrames.append(contentsOf: frames)
        return pendingUploadFrames.count <= maximumPendingFrameCount
    }

    mutating func takeFullUploadBatch(frameCount: Int) -> [VADPCMFrame]? {
        guard pendingUploadFrames.count >= frameCount else { return nil }
        let batch = Array(pendingUploadFrames.prefix(frameCount))
        pendingUploadFrames.removeFirst(batch.count)
        return batch
    }

    mutating func takePendingUploadFrames() -> [VADPCMFrame]? {
        guard !pendingUploadFrames.isEmpty else { return nil }
        let batch = pendingUploadFrames
        pendingUploadFrames.removeAll(keepingCapacity: true)
        return batch
    }

    mutating func beginUpload(frameCount: Int) {
        inFlightUploadFrameCount = frameCount
    }

    mutating func completeUpload() {
        inFlightUploadFrameCount = 0
    }

    mutating func clearFrameQueue() {
        frameQueue.removeAll(keepingCapacity: true)
    }

    mutating func clearBufferedFrames() {
        frameQueue.removeAll(keepingCapacity: true)
        pendingUploadFrames.removeAll(keepingCapacity: true)
        inFlightUploadFrameCount = 0
    }
}
