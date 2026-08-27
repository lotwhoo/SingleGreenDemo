import Foundation

/// 用于对齐 SSE 增量前缀与最终完整文本。
public enum StreamingTextReconciler {
    /// 按 Unicode scalar 比较，避免 base character 和 combining mark 分属不同 delta 时误判。
    public static func suffix(in fullText: String, after prefix: String) -> String? {
        let fullScalars = Array(fullText.unicodeScalars)
        let prefixScalars = Array(prefix.unicodeScalars)
        guard fullScalars.starts(with: prefixScalars) else { return nil }
        return fullScalars
            .dropFirst(prefixScalars.count)
            .map(String.init)
            .joined()
    }
}
