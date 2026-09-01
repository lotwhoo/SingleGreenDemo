import Foundation
import LLMCore

/// 轻量 token 估算器。
/// 不引入 tiktoken 等重依赖，用近似估算：
/// - 中文字符（CJK + 中文标点）≈ 1 token/字
/// - ASCII ≈ 0.25 token/字符（4 字符/token）
/// - 其他 ≈ 0.5 token/字符
/// 用于上下文预算裁剪（留出余量即可，无需精确）。
public enum LLMTokenEstimator {

    public static func estimate(_ text: String) -> Int {
        var chinese = 0
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,     // CJK 统一汉字
                 0x3000...0x303F,     // 中文标点
                 0xFF00...0xFFEF:     // 全角字符
                chinese += 1
            case 0x00...0x7F:
                ascii += 1
            default:
                other += 1
            }
        }
        return chinese + Int((Double(ascii) / 4.0).rounded(.up)) + Int((Double(other) / 2.0).rounded(.up))
    }
}
