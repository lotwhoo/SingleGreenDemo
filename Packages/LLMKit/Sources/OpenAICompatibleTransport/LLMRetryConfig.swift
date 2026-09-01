import Foundation
import LLMCore

/// OpenAI-compatible 请求重试配置（指数退避）。
/// 参考 open-agent-sdk-swift 的 RetryConfig 标准做法。
public struct LLMRetryConfig: Sendable, Equatable {
    /// 最大重试次数（不含首次调用）。
    public var maxRetries: Int
    /// 指数退避基础延迟（毫秒）。
    public var baseDelayMs: Int
    /// 退避延迟上限（毫秒）。
    public var maxDelayMs: Int
    /// 可自动重试的 HTTP 状态码（瞬时错误）。
    public var retryableStatusCodes: Set<Int>

    public init(maxRetries: Int = 3,
                baseDelayMs: Int = 800,
                maxDelayMs: Int = 10000,
                retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 529]) {
        precondition(maxRetries >= 0, "maxRetries 不能为负")
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
        self.retryableStatusCodes = retryableStatusCodes
    }

    /// 该错误是否值得重试：可重试状态码或网络层错误。
    func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? LLMAPIError {
            return retryableStatusCodes.contains(apiError.statusCode)
        }
        if let urlError = error as? URLError {
            // 网络中断 / 超时 / 连接失败等瞬时错误
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .dataNotAllowed,
                 .secureConnectionFailed, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// 第 attempt 次重试前的延迟（attempt 从 0 开始）。
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exp = Double(min(1 << attempt, 64))  // 1,2,4,8... 封顶 64
        let base = Double(baseDelayMs) / 1000.0
        let capped = min(base * exp, Double(maxDelayMs) / 1000.0)
        // 加 20% 随机抖动避免 thundering herd
        let jitter = Double.random(in: 0.8...1.2)
        return capped * jitter
    }
}
