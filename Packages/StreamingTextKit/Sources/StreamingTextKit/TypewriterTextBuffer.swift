import Foundation

/// 将上游累计文本与当前可见文本分离的纯值缓冲。
///
/// 所有帧都按 Swift `Character` 边界生成，不拆分 emoji、ZWJ 序列或组合字符。
public struct TypewriterTextBuffer: Equatable, Sendable {
    public private(set) var targetText = ""
    public private(set) var visibleText = ""

    public let policy: TypewriterPolicy
    private var catchUpBatchSize = 1

    public init(policy: TypewriterPolicy = .standard) {
        self.policy = policy
    }

    public var isCaughtUp: Bool { visibleText == targetText }

    public var pendingCharacterCount: Int {
        guard visibleText != targetText else { return 0 }
        // 新 scalar 可能与最后一个可见 Character 重新组合，此时 count 差为 0。
        return max(1, targetText.count - visibleText.count)
    }

    public mutating func append(_ delta: String) {
        let wasCaughtUp = isCaughtUp
        targetText += delta
        let requiredBatch = policy.batchSize(for: pendingCharacterCount)
        catchUpBatchSize = wasCaughtUp ? requiredBatch : max(catchUpBatchSize, requiredBatch)
    }

    public mutating func reset() {
        targetText = ""
        visibleText = ""
        catchUpBatchSize = 1
    }

    @discardableResult
    public mutating func flush() -> Bool {
        guard visibleText != targetText else { return false }
        visibleText = targetText
        catchUpBatchSize = 1
        return true
    }

    @discardableResult
    public mutating func advance(maxCharacters: Int) -> Bool {
        guard maxCharacters > 0, visibleText != targetText else { return false }
        let targetCharacters = Array(targetText)
        let visibleCount = Array(visibleText).count

        if visibleCount >= targetCharacters.count {
            visibleText = targetText
            catchUpBatchSize = 1
            return true
        }

        let nextCount = min(targetCharacters.count, visibleCount + maxCharacters)
        visibleText = String(targetCharacters.prefix(nextCount))
        if visibleText == targetText { catchUpBatchSize = 1 }
        return true
    }

    /// 小积压保留打字感；大积压在 policy 的目标 tick 数内追平。
    public func suggestedBatchSize() -> Int {
        guard pendingCharacterCount > 0 else { return 0 }
        return min(pendingCharacterCount, catchUpBatchSize)
    }
}
