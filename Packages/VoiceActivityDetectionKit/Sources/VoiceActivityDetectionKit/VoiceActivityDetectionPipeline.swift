public actor VoiceActivityDetectionPipeline {
    private struct Operation {
        let id: UInt64
        let generation: UInt64
        let frame: VADPCMFrame
        let continuation: CheckedContinuation<[VADSegmentationEvent], any Error>
    }

    private let detector: any VoiceActivityDetecting
    private var segmenter: VADSegmenter
    private var generation: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var lastEnqueuedSequence: UInt64?
    private var pendingOperations: [Operation] = []
    private var activeOperation: Operation?
    private var workerTask: Task<Void, Never>?
    private var outstandingResetCount = 0

    public init(
        detector: any VoiceActivityDetecting,
        policy: VADSegmentationPolicy
    ) {
        self.detector = detector
        segmenter = VADSegmenter(policy: policy)
    }

    public func process(_ frame: VADPCMFrame) async throws -> [VADSegmentationEvent] {
        try validateEnqueueSequence(frame)
        let operationID = nextOperationID
        nextOperationID = incrementing(nextOperationID)
        let operationGeneration = generation
        lastEnqueuedSequence = frame.sequence

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingOperations.append(
                    Operation(
                        id: operationID,
                        generation: operationGeneration,
                        frame: frame,
                        continuation: continuation
                    )
                )
                startWorkerIfNeeded()
            }
        } onCancel: {
            Task {
                await self.cancelOperation(
                    id: operationID,
                    generation: operationGeneration
                )
            }
        }
    }

    public func reset() async {
        generation = incrementing(generation)
        outstandingResetCount += 1
        workerTask?.cancel()
        workerTask = nil

        let invalidatedOperations = pendingOperations + (activeOperation.map { [$0] } ?? [])
        pendingOperations.removeAll(keepingCapacity: true)
        activeOperation = nil
        lastEnqueuedSequence = nil
        segmenter.reset()
        for operation in invalidatedOperations {
            operation.continuation.resume(throwing: CancellationError())
        }

        await detector.reset()
        outstandingResetCount -= 1
        startWorkerIfNeeded()
    }

    private func validateEnqueueSequence(_ frame: VADPCMFrame) throws {
        if let lastEnqueuedSequence, frame.sequence <= lastEnqueuedSequence {
            throw VADSegmentationError.sequenceNotIncreasing(
                previous: lastEnqueuedSequence,
                current: frame.sequence
            )
        }
    }

    private func startWorkerIfNeeded() {
        guard outstandingResetCount == 0,
              workerTask == nil,
              !pendingOperations.isEmpty else {
            return
        }
        let workerGeneration = generation
        workerTask = Task {
            await runWorker(generation: workerGeneration)
        }
    }

    private func runWorker(generation workerGeneration: UInt64) async {
        while !Task.isCancelled, generation == workerGeneration {
            guard activeOperation == nil, !pendingOperations.isEmpty else {
                break
            }

            let operation = pendingOperations.removeFirst()
            guard operation.generation == workerGeneration else {
                operation.continuation.resume(throwing: CancellationError())
                continue
            }
            activeOperation = operation

            do {
                let observation = try await detector.observation(for: operation.frame)
                guard generation == workerGeneration,
                      activeOperation?.id == operation.id else {
                    continue
                }
                let events = try segmenter.consume(
                    operation.frame,
                    observation: observation
                )
                activeOperation = nil
                operation.continuation.resume(returning: events)
            } catch {
                guard generation == workerGeneration,
                      activeOperation?.id == operation.id else {
                    continue
                }
                activeOperation = nil
                operation.continuation.resume(throwing: error)
            }
        }

        if generation == workerGeneration {
            workerTask = nil
            startWorkerIfNeeded()
        }
    }

    private func cancelOperation(id: UInt64, generation operationGeneration: UInt64) {
        guard operationGeneration == generation else {
            return
        }

        if let pendingIndex = pendingOperations.firstIndex(where: { $0.id == id }) {
            let operation = pendingOperations.remove(at: pendingIndex)
            operation.continuation.resume(throwing: CancellationError())
            return
        }

        if activeOperation?.id == id {
            let operation = activeOperation
            activeOperation = nil
            operation?.continuation.resume(throwing: CancellationError())
        }
    }

    private func incrementing(_ value: UInt64) -> UInt64 {
        value == .max ? 0 : value + 1
    }
}
