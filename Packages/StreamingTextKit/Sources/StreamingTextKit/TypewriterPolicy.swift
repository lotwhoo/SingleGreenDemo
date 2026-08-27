import Foundation

/// 流式文本的显示节奏。业务层可注入新策略，无需改动缓冲或 HUD。
public struct TypewriterPolicy: Equatable, Sendable {
    public let tickIntervalMilliseconds: Int
    public let shortBacklogLimit: Int
    public let mediumBacklogLimit: Int
    public let mediumBatchSize: Int
    public let minimumLargeBatchSize: Int
    public let catchUpTickBudget: Int

    public init(
        tickIntervalMilliseconds: Int = 33,
        shortBacklogLimit: Int = 12,
        mediumBacklogLimit: Int = 30,
        mediumBatchSize: Int = 2,
        minimumLargeBatchSize: Int = 3,
        catchUpTickBudget: Int = 15
    ) {
        let normalizedShortBacklogLimit = max(1, shortBacklogLimit)
        self.tickIntervalMilliseconds = max(1, tickIntervalMilliseconds)
        self.shortBacklogLimit = normalizedShortBacklogLimit
        self.mediumBacklogLimit = max(normalizedShortBacklogLimit, mediumBacklogLimit)
        self.mediumBatchSize = max(1, mediumBatchSize)
        self.minimumLargeBatchSize = max(1, minimumLargeBatchSize)
        self.catchUpTickBudget = max(1, catchUpTickBudget)
    }

    public static let standard = TypewriterPolicy()

    func batchSize(for pendingCount: Int) -> Int {
        if pendingCount <= 0 {
            return 0
        }
        if pendingCount <= shortBacklogLimit {
            return 1
        }
        if pendingCount <= mediumBacklogLimit {
            return mediumBatchSize
        }
        return max(
            minimumLargeBatchSize,
            Int(ceil(Double(pendingCount) / Double(catchUpTickBudget)))
        )
    }
}
