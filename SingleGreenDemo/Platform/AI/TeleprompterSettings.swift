import Foundation
import SingleGreenGlassesKit

enum TeleprompterScriptRepositoryRejection: Equatable, Sendable {
    case empty
    case exceedsCharacterLimit(maximum: Int)
}

enum TeleprompterScriptRepositoryResult: Equatable, Sendable {
    case applied
    case duplicate
    case rejected(TeleprompterScriptRepositoryRejection)
}

/// App-side draft and script-management boundary. File URLs, security-scoped
/// access, and decoders stay outside this protocol; Core receives only a
/// normalized source string and the repository's stable identity.
@MainActor
protocol TeleprompterScriptRepository: AnyObject {
    var scriptDraft: String { get set }
    var loadedScriptSource: String { get }
    var scriptIdentity: TeleprompterScriptIdentity { get }
    var scriptConfigurationRevision: Int { get }

    @discardableResult
    func applyScriptDraft() -> TeleprompterScriptRepositoryResult

    @discardableResult
    func replaceScript(with normalizedSource: String) -> TeleprompterScriptRepositoryResult
}

/// One local record owns the draft plus every derived artifact. Replacing this
/// record is the atomic boundary used by script deletion.
struct TeleprompterLocalArtifactEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var scriptIdentity: TeleprompterScriptIdentity
    var scriptSource: String
    var checkpointData: Data?
    var normalizedIndexCache: Data?
    var evaluationCache: Data?

    static func empty(
        identity: TeleprompterScriptIdentity = .init(rawValue: UUID().uuidString)
    ) -> Self {
        Self(
            scriptIdentity: identity,
            scriptSource: "",
            checkpointData: nil,
            normalizedIndexCache: nil,
            evaluationCache: nil
        )
    }
}

@MainActor
final class TeleprompterSettings: ObservableObject,
    TeleprompterCheckpointStore,
    TeleprompterScriptRepository {
    @Published private(set) var scriptConfigurationRevision = 0
    @Published var scriptDraft: String {
        didSet { scriptDraftDidChange() }
    }
    @Published var allowsCloudSpeechRecognition: Bool {
        didSet {
            defaults.set(allowsCloudSpeechRecognition, forKey: consentStorageKey)
        }
    }

    var scriptIdentity: TeleprompterScriptIdentity { envelope.scriptIdentity }

    private let defaults: UserDefaults
    private let legacyScriptStorageKey: String
    private let envelopeStorageKey: String
    private let consentStorageKey: String
    private var envelope: TeleprompterLocalArtifactEnvelope
    private var envelopeLoadFailure: TeleprompterCheckpointRejectionReason?
    private var isApplyingEnvelope = false
    private(set) var loadedScriptSource = ""

    init(
        defaults: UserDefaults = .standard,
        scriptStorageKey: String = "teleprompter.script",
        envelopeStorageKey: String = "teleprompter.localArtifactEnvelope",
        consentStorageKey: String = "teleprompter.cloudASRConsent"
    ) {
        self.defaults = defaults
        self.legacyScriptStorageKey = scriptStorageKey
        self.envelopeStorageKey = envelopeStorageKey
        self.consentStorageKey = consentStorageKey

        let decoded = Self.decodeEnvelope(defaults.data(forKey: envelopeStorageKey))
        switch decoded {
        case .loaded(let value):
            envelope = value
            envelopeLoadFailure = nil
        case .missing:
            var migrated = TeleprompterLocalArtifactEnvelope.empty()
            migrated.scriptSource = String(
                (defaults.string(forKey: scriptStorageKey) ?? "")
                    .prefix(TeleprompterLimits.maximumScriptCharacters)
            )
            envelope = migrated
            envelopeLoadFailure = nil
        case .rejected(let reason):
            envelope = .empty()
            envelopeLoadFailure = reason
        }
        scriptDraft = envelope.scriptSource
        loadedScriptSource = envelope.scriptSource
        allowsCloudSpeechRecognition = defaults.bool(forKey: consentStorageKey)

        if defaults.data(forKey: envelopeStorageKey) == nil {
            _ = persistEnvelope()
            defaults.removeObject(forKey: legacyScriptStorageKey)
        }
    }

    @discardableResult
    func applyScriptDraft() -> TeleprompterScriptRepositoryResult {
        let normalized = scriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .rejected(.empty) }
        guard normalized.count <= TeleprompterLimits.maximumScriptCharacters else {
            return .rejected(.exceedsCharacterLimit(
                maximum: TeleprompterLimits.maximumScriptCharacters
            ))
        }
        guard normalized != loadedScriptSource else { return .duplicate }
        if normalized != scriptDraft { scriptDraft = normalized }
        loadedScriptSource = normalized
        scriptConfigurationRevision &+= 1
        return .applied
    }

    @discardableResult
    func replaceScript(
        with normalizedSource: String
    ) -> TeleprompterScriptRepositoryResult {
        let normalized = normalizedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .rejected(.empty) }
        guard normalized.count <= TeleprompterLimits.maximumScriptCharacters else {
            return .rejected(.exceedsCharacterLimit(
                maximum: TeleprompterLimits.maximumScriptCharacters
            ))
        }
        guard normalized != loadedScriptSource else { return .duplicate }
        scriptDraft = normalized
        return applyScriptDraft()
    }

    func loadCheckpoint(
        for script: TeleprompterScript
    ) -> TeleprompterCheckpointLoadResult {
        if let envelopeLoadFailure { return .rejected(envelopeLoadFailure) }
        guard let checkpointData = envelope.checkpointData else { return .missing }
        return TeleprompterCheckpointCodec.decode(checkpointData)
    }

    func saveCheckpoint(
        _ checkpoint: TeleprompterPositionCheckpoint
    ) -> TeleprompterCheckpointWriteResult {
        guard envelopeLoadFailure == nil,
              !envelope.scriptSource.isEmpty,
              checkpoint.scriptIdentity == envelope.scriptIdentity,
              let data = try? TeleprompterCheckpointCodec.encode(checkpoint) else {
            return .failed
        }
        guard envelope.checkpointData != data else { return .unchanged }
        envelope.checkpointData = data
        return persistEnvelope() ? .saved : .failed
    }

    func deleteScriptArtifacts(
        for identity: TeleprompterScriptIdentity
    ) -> TeleprompterScriptDeletionResult {
        if envelope.scriptSource.isEmpty,
           envelope.checkpointData == nil,
           envelope.normalizedIndexCache == nil,
           envelope.evaluationCache == nil {
            if envelopeLoadFailure != nil, !persistEnvelope() { return .failed }
            envelopeLoadFailure = nil
            return .alreadyDeleted
        }
        guard identity == envelope.scriptIdentity else { return .rejectedIdentity }

        let previous = envelope
        envelope = .empty()
        guard persistEnvelope() else {
            envelope = previous
            return .failed
        }
        envelopeLoadFailure = nil
        isApplyingEnvelope = true
        scriptDraft = ""
        isApplyingEnvelope = false
        loadedScriptSource = ""
        return .deleted
    }

    /// Test seam for proving that atomic deletion clears future derived stores
    /// even before production indexing and evaluation cache writers exist.
    func replaceDerivedArtifactsForTesting(
        normalizedIndexCache: Data?,
        evaluationCache: Data?
    ) {
        envelope.normalizedIndexCache = normalizedIndexCache
        envelope.evaluationCache = evaluationCache
        _ = persistEnvelope()
    }

    private func scriptDraftDidChange() {
        guard !isApplyingEnvelope else { return }
        let limited = String(scriptDraft.prefix(TeleprompterLimits.maximumScriptCharacters))
        if limited != scriptDraft {
            isApplyingEnvelope = true
            scriptDraft = limited
            isApplyingEnvelope = false
        }
        guard limited != envelope.scriptSource || envelopeLoadFailure != nil else { return }
        envelopeLoadFailure = nil
        envelope.scriptSource = limited
        // Any authored-content revision invalidates every derived position.
        envelope.checkpointData = nil
        envelope.normalizedIndexCache = nil
        envelope.evaluationCache = nil
        _ = persistEnvelope()
    }

    private func persistEnvelope() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(envelope), forKey: envelopeStorageKey)
            return true
        } catch {
            return false
        }
    }

    private static func decodeEnvelope(
        _ data: Data?
    ) -> TeleprompterCheckpointLoadResultEnvelope {
        guard let data else { return .missing }
        do {
            let envelope = try JSONDecoder().decode(
                TeleprompterLocalArtifactEnvelope.self,
                from: data
            )
            guard envelope.schemaVersion == TeleprompterLocalArtifactEnvelope.currentSchemaVersion else {
                return .rejected(.unsupportedSchema(envelope.schemaVersion))
            }
            return .loaded(envelope)
        } catch {
            return .rejected(.corruptData)
        }
    }
}

private enum TeleprompterCheckpointLoadResultEnvelope {
    case missing
    case loaded(TeleprompterLocalArtifactEnvelope)
    case rejected(TeleprompterCheckpointRejectionReason)
}
