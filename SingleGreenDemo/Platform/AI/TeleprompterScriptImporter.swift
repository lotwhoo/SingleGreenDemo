import Foundation
import SingleGreenGlassesKit

enum TeleprompterScriptImportKind: Equatable, Sendable {
    case plainText
    case markdown
    case unsupported
}

enum TeleprompterScriptImportRejection: Equatable, Sendable {
    case unsupportedType
    case invalidUTF8
    case empty
    case exceedsCharacterLimit(maximum: Int)
    case unreadable
}

enum TeleprompterScriptImportResult: Equatable, Sendable {
    case imported(source: String)
    case duplicate
    case rejected(TeleprompterScriptImportRejection)
}

/// Infrastructure parser that deliberately accepts bytes and a reviewed kind,
/// not file names or paths. Those values therefore cannot cross into Feature
/// state, checkpoints, or telemetry by construction.
enum TeleprompterScriptImporter {
    static func parse(
        data: Data,
        kind: TeleprompterScriptImportKind,
        existingSource: String
    ) -> TeleprompterScriptImportResult {
        guard kind != .unsupported else {
            return .rejected(.unsupportedType)
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            return .rejected(.invalidUTF8)
        }
        let source = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .rejected(.empty) }
        guard source.count <= TeleprompterLimits.maximumScriptCharacters else {
            return .rejected(.exceedsCharacterLimit(
                maximum: TeleprompterLimits.maximumScriptCharacters
            ))
        }
        guard source != existingSource.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .duplicate
        }
        return .imported(source: source)
    }
}

extension TeleprompterScriptImportResult {
    var userMessage: String {
        switch self {
        case .imported:
            return "稿件已导入。"
        case .duplicate:
            return "这份稿件已经载入，无需重复导入。"
        case .rejected(.unsupportedType):
            return "仅支持 TXT 或 Markdown 文件。"
        case .rejected(.invalidUTF8):
            return "文件不是有效的 UTF-8 文本。"
        case .rejected(.empty):
            return "文件中没有可用文字。"
        case .rejected(.exceedsCharacterLimit(let maximum)):
            return "稿件超过 \(maximum) 字，请精简后重试。"
        case .rejected(.unreadable):
            return "无法读取文件，请检查权限后重试。"
        }
    }
}
