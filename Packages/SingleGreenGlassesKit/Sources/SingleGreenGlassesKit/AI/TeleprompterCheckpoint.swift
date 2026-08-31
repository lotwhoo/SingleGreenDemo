import Foundation

/// Versioned, text-free reading position. The offset is measured in UTF-16
/// within the authored sentence used by TeleprompterState and HUD selection.
public struct TeleprompterPositionCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let scriptIdentity: TeleprompterScriptIdentity
    public let contentVersion: TeleprompterScriptVersion
    public let sentenceIndex: Int
    public let originalUTF16Offset: Int

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        scriptIdentity: TeleprompterScriptIdentity,
        contentVersion: TeleprompterScriptVersion,
        sentenceIndex: Int,
        originalUTF16Offset: Int
    ) {
        self.schemaVersion = schemaVersion
        self.scriptIdentity = scriptIdentity
        self.contentVersion = contentVersion
        self.sentenceIndex = sentenceIndex
        self.originalUTF16Offset = originalUTF16Offset
    }
}

public enum TeleprompterCheckpointRejectionReason: Equatable, Sendable {
    case corruptData
    case unsupportedSchema(Int)
    case scriptIdentityMismatch
    case contentVersionMismatch
    case invalidPosition
}

public enum TeleprompterCheckpointLoadResult: Equatable, Sendable {
    case missing
    case loaded(TeleprompterPositionCheckpoint)
    case rejected(TeleprompterCheckpointRejectionReason)
}

public enum TeleprompterCheckpointRestoreResult: Equatable, Sendable {
    case noCheckpoint
    case restored(ReadingPositionAnchor)
    case rejected(TeleprompterCheckpointRejectionReason)
}

public enum TeleprompterCheckpointWriteResult: Equatable, Sendable {
    case saved
    case unchanged
    case failed
}

public enum TeleprompterScriptDeletionResult: Equatable, Sendable {
    case deleted
    case alreadyDeleted
    case rejectedIdentity
    case failed
}

/// Controller-facing persistence boundary. Concrete local storage, envelope
/// layout, migrations, and atomic replacement remain in the App adapter.
@MainActor
public protocol TeleprompterCheckpointStore: AnyObject {
    func loadCheckpoint(for script: TeleprompterScript) -> TeleprompterCheckpointLoadResult
    func saveCheckpoint(_ checkpoint: TeleprompterPositionCheckpoint) -> TeleprompterCheckpointWriteResult
    func deleteScriptArtifacts(
        for identity: TeleprompterScriptIdentity
    ) -> TeleprompterScriptDeletionResult
}

@MainActor
public final class NoopTeleprompterCheckpointStore: TeleprompterCheckpointStore {
    public init() {}

    public func loadCheckpoint(
        for script: TeleprompterScript
    ) -> TeleprompterCheckpointLoadResult {
        .missing
    }

    public func saveCheckpoint(
        _ checkpoint: TeleprompterPositionCheckpoint
    ) -> TeleprompterCheckpointWriteResult {
        .unchanged
    }

    public func deleteScriptArtifacts(
        for identity: TeleprompterScriptIdentity
    ) -> TeleprompterScriptDeletionResult {
        .alreadyDeleted
    }
}

public enum TeleprompterCheckpointCodec {
    public static func encode(
        _ checkpoint: TeleprompterPositionCheckpoint
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(checkpoint)
    }

    public static func decode(_ data: Data) -> TeleprompterCheckpointLoadResult {
        do {
            return .loaded(try JSONDecoder().decode(
                TeleprompterPositionCheckpoint.self,
                from: data
            ))
        } catch {
            return .rejected(.corruptData)
        }
    }
}

/// Pure compatibility and bounds policy. No storage or lifecycle dependency is
/// needed to decide whether a checkpoint can be restored.
public enum TeleprompterCheckpointResolver {
    public static func makeCheckpoint(
        script: TeleprompterScript,
        anchor: ReadingPositionAnchor
    ) -> TeleprompterPositionCheckpoint? {
        guard isValid(anchor, in: script) else { return nil }
        return TeleprompterPositionCheckpoint(
            scriptIdentity: script.identity,
            contentVersion: script.version,
            sentenceIndex: anchor.sentenceIndex,
            originalUTF16Offset: anchor.utf16Offset
        )
    }

    public static func resolve(
        _ loadResult: TeleprompterCheckpointLoadResult,
        for script: TeleprompterScript
    ) -> TeleprompterCheckpointRestoreResult {
        switch loadResult {
        case .missing:
            return .noCheckpoint
        case .rejected(let reason):
            return .rejected(reason)
        case .loaded(let checkpoint):
            guard checkpoint.schemaVersion == TeleprompterPositionCheckpoint.currentSchemaVersion else {
                return .rejected(.unsupportedSchema(checkpoint.schemaVersion))
            }
            guard checkpoint.scriptIdentity == script.identity else {
                return .rejected(.scriptIdentityMismatch)
            }
            guard checkpoint.contentVersion == script.version else {
                return .rejected(.contentVersionMismatch)
            }
            let anchor = ReadingPositionAnchor(
                sentenceIndex: checkpoint.sentenceIndex,
                utf16Offset: checkpoint.originalUTF16Offset
            )
            guard isValidRaw(
                sentenceIndex: checkpoint.sentenceIndex,
                utf16Offset: checkpoint.originalUTF16Offset,
                in: script
            ) else {
                return .rejected(.invalidPosition)
            }
            return .restored(anchor)
        }
    }

    private static func isValid(
        _ anchor: ReadingPositionAnchor,
        in script: TeleprompterScript
    ) -> Bool {
        isValidRaw(
            sentenceIndex: anchor.sentenceIndex,
            utf16Offset: anchor.utf16Offset,
            in: script
        )
    }

    private static func isValidRaw(
        sentenceIndex: Int,
        utf16Offset: Int,
        in script: TeleprompterScript
    ) -> Bool {
        guard script.sentences.indices.contains(sentenceIndex), utf16Offset >= 0 else {
            return false
        }
        return utf16Offset <= (script.sentences[sentenceIndex] as NSString).length
    }
}
