import Foundation
import SingleGreenGlassesKit

@MainActor
final class TeleprompterSettings: ObservableObject {
    @Published private(set) var scriptConfigurationRevision = 0
    @Published var scriptDraft: String {
        didSet {
            let limited = String(scriptDraft.prefix(TeleprompterLimits.maximumScriptCharacters))
            if limited != scriptDraft {
                scriptDraft = limited
            }
            defaults.set(limited, forKey: scriptStorageKey)
        }
    }
    @Published var allowsCloudSpeechRecognition: Bool {
        didSet {
            defaults.set(allowsCloudSpeechRecognition, forKey: consentStorageKey)
        }
    }

    private let defaults: UserDefaults
    private let scriptStorageKey: String
    private let consentStorageKey: String

    init(
        defaults: UserDefaults = .standard,
        scriptStorageKey: String = "teleprompter.script",
        consentStorageKey: String = "teleprompter.cloudASRConsent"
    ) {
        self.defaults = defaults
        self.scriptStorageKey = scriptStorageKey
        self.consentStorageKey = consentStorageKey
        self.scriptDraft = defaults.string(forKey: scriptStorageKey) ?? ""
        self.allowsCloudSpeechRecognition = defaults.bool(forKey: consentStorageKey)
    }

    func applyScriptDraft() {
        scriptConfigurationRevision &+= 1
    }
}
