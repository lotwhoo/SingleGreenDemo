import SwiftUI

@MainActor
final class AISettings: ObservableObject {
    @AppStorage("ai.asr.resourceID") var asrResourceID = "volc.seedasr.sauc.duration"
    @AppStorage("ai.asr.language") var asrLanguage = "zh-CN"
    @AppStorage("ai.asr.hotwords") var hotwordsText = ""
    @AppStorage("ai.asr.handsFree") var handsFree = false
    @AppStorage("ai.llm.model") var llmModel = "deepseek-v4-flash"
    @AppStorage("ai.llm.enableSearch") var enableSearch = true

    var speechAPIKey: String {
        get { KeychainHelper.load("asr.apiKey") ?? "" }
        set { storeSecret(newValue, key: "asr.apiKey") }
    }

    var llmAPIKey: String {
        get { KeychainHelper.load("llm.apiKey") ?? "" }
        set { storeSecret(newValue, key: "llm.apiKey") }
    }

    var bochaAPIKey: String {
        get { KeychainHelper.load("llm.bochaKey") ?? "" }
        set { storeSecret(newValue, key: "llm.bochaKey") }
    }

    var hotwords: [String] {
        hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var speechAPIKeyBinding: Binding<String> {
        Binding(get: { self.speechAPIKey }, set: { self.speechAPIKey = $0 })
    }

    var llmAPIKeyBinding: Binding<String> {
        Binding(get: { self.llmAPIKey }, set: { self.llmAPIKey = $0 })
    }

    var bochaAPIKeyBinding: Binding<String> {
        Binding(get: { self.bochaAPIKey }, set: { self.bochaAPIKey = $0 })
    }

    var isASRConfigured: Bool {
        !speechAPIKey.trimmed.isEmpty && !asrResourceID.trimmed.isEmpty
    }

    var isLLMConfigured: Bool {
        !llmAPIKey.trimmed.isEmpty && !llmModel.trimmed.isEmpty
    }

    var isSearchConfigured: Bool {
        !enableSearch || !bochaAPIKey.trimmed.isEmpty
    }

    private func storeSecret(_ value: String, key: String) {
        objectWillChange.send()
        let trimmed = value.trimmed
        if trimmed.isEmpty {
            KeychainHelper.delete(key)
        } else {
            KeychainHelper.save(trimmed, forKey: key)
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
