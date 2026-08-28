import Foundation
import StreamingTextKit

struct DisplayFailureResult: Equatable {
    let visibleText: String
    let preservesPartial: Bool
}

enum ConversationDisplaySchedulerError: LocalizedError {
    case inconsistentStream

    var errorDescription: String? {
        switch self {
        case .inconsistentStream: "模型流的增量与完整回答不一致"
        }
    }
}

@MainActor
final class ConversationDisplayScheduler {
    private let sleep: (Duration) async throws -> Void
    private let reduceMotion: () -> Bool
    private let policy: TypewriterPolicy
    private var buffer: TypewriterTextBuffer
    private var typingTask: Task<Void, Never>?
    private var activeOperation: ReplyOperation?
    private var upstreamCompletedOperation: ReplyOperation?

    var onVisibleTextChanged: @MainActor (ReplyOperation, String) -> Void = { _, _ in }
    var onCaughtUp: @MainActor (ReplyOperation) async -> Void = { _ in }

    private(set) var visibleText = ""
    var targetText: String { buffer.targetText }

    init(
        policy: TypewriterPolicy,
        sleep: @escaping (Duration) async throws -> Void,
        reduceMotion: @escaping () -> Bool
    ) {
        self.policy = policy
        self.sleep = sleep
        self.reduceMotion = reduceMotion
        self.buffer = TypewriterTextBuffer(policy: policy)
    }

    deinit {
        typingTask?.cancel()
    }

    func begin(_ operation: ReplyOperation) {
        cancelTyping()
        buffer.reset()
        visibleText = ""
        activeOperation = operation
        upstreamCompletedOperation = nil
    }

    func append(_ delta: String, for operation: ReplyOperation) {
        guard activeOperation == operation, !delta.isEmpty else { return }
        buffer.append(delta)
        startTyping(for: operation)
    }

    func reconcileAndMarkUpstreamCompleted(
        answer: String,
        accumulated: String,
        for operation: ReplyOperation
    ) throws -> String? {
        guard activeOperation == operation else { return nil }
        var suffix: String?
        if accumulated != answer {
            guard let reconciledSuffix = StreamingTextReconciler.suffix(in: answer, after: accumulated) else {
                throw ConversationDisplaySchedulerError.inconsistentStream
            }
            suffix = reconciledSuffix
            append(reconciledSuffix, for: operation)
        }
        upstreamCompletedOperation = operation
        startTyping(for: operation)
        return suffix
    }

    func settleFailure(
        discardPartial: Bool,
        for operation: ReplyOperation
    ) -> DisplayFailureResult? {
        guard activeOperation == operation else { return nil }
        cancelTyping()
        upstreamCompletedOperation = nil
        let preservesPartial = !discardPartial && !buffer.targetText.trimmed.isEmpty
        if preservesPartial {
            _ = buffer.flush()
            visibleText = buffer.visibleText
        } else {
            buffer.reset()
            visibleText = ""
        }
        return DisplayFailureResult(
            visibleText: visibleText,
            preservesPartial: preservesPartial
        )
    }

    func reset() {
        cancelTyping()
        activeOperation = nil
        upstreamCompletedOperation = nil
        buffer.reset()
        visibleText = ""
    }

    private func startTyping(for operation: ReplyOperation) {
        guard activeOperation == operation, typingTask == nil else { return }
        let sleep = sleep
        let tickInterval = policy.tickIntervalMilliseconds
        typingTask = Task { [weak self] in
            while !Task.isCancelled {
                let step: TypingStep
                if let scheduler = self {
                    step = scheduler.performTypingStep(for: operation)
                } else {
                    return
                }

                switch step {
                case .stopped:
                    return
                case .caughtUp(let callback):
                    await callback(operation)
                    return
                case .continueTyping:
                    break
                }

                do {
                    try await sleep(.milliseconds(tickInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func performTypingStep(for operation: ReplyOperation) -> TypingStep {
        guard activeOperation == operation else { return .stopped }

        let changed: Bool
        if reduceMotion() {
            changed = buffer.flush()
        } else {
            changed = buffer.advance(maxCharacters: buffer.suggestedBatchSize())
        }
        if changed {
            visibleText = buffer.visibleText
            onVisibleTextChanged(operation, visibleText)
        }

        if buffer.isCaughtUp, upstreamCompletedOperation == operation {
            upstreamCompletedOperation = nil
            typingTask = nil
            return .caughtUp(onCaughtUp)
        }
        return .continueTyping
    }

    private func cancelTyping() {
        typingTask?.cancel()
        typingTask = nil
    }

    private enum TypingStep {
        case continueTyping
        case caughtUp(@MainActor (ReplyOperation) async -> Void)
        case stopped
    }
}
