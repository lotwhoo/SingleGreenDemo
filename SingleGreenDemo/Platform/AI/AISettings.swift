import Foundation
import SingleGreenGlassesKit
import SwiftUI

struct AISettingsBuildPolicy: Equatable, Sendable {
    enum CredentialMode: Equatable, Sendable {
        #if DEBUG
        case internalDemo
        #endif
        case serverManaged
    }

    let credentialMode: CredentialMode

    static let current: Self = {
        #if DEBUG
        Self(credentialMode: .internalDemo)
        #else
        Self(credentialMode: .serverManaged)
        #endif
    }()

    static let serverManaged = Self(credentialMode: .serverManaged)

    #if DEBUG
    static let internalDemo = Self(credentialMode: .internalDemo)
    #endif

    var allowsDemoCredentialStorage: Bool {
        #if DEBUG
        credentialMode == .internalDemo
        #else
        false
        #endif
    }

    var credentialStatus: AICredentialStatusPresentation {
        #if DEBUG
        if allowsDemoCredentialStorage {
            return AICredentialStatusPresentation(
                title: "内部演示模式",
                detail: "使用本机 Keychain 中的测试凭证",
                systemImage: "wrench.and.screwdriver.fill",
                isAvailable: true
            )
        }
        #endif
        return AICredentialStatusPresentation(
            title: "服务端凭证未接入",
            detail: "AI 对话已安全停用，不会回退到本机提供商密钥",
            systemImage: "lock.shield.fill",
            isAvailable: false
        )
    }
}

struct AICredentialStatusPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let systemImage: String
    let isAvailable: Bool
}

struct AISpeechInputAvailability: Equatable, Sendable {
    let voiceActivatedIsAvailable: Bool
    let voiceActivatedDetail: String

    /// App-composition capability exposed only by builds that link the
    /// production WebRTC detector product.
    static let productionDetectorAvailable = Self(
        voiceActivatedIsAvailable: true,
        voiceActivatedDetail: "本地 VAD 已就绪：检测到说话后才上传语音，静音后自动结束。"
    )

    static let productionDetectorPending = Self(
        voiceActivatedIsAvailable: false,
        voiceActivatedDetail: "本地 VAD 生产检测器尚未接入，当前不会启动免按录音或回退到立即上传。"
    )
}

#if DEBUG
@MainActor
protocol DemoCredentialStore {
    func load(_ key: String) -> String?
    @discardableResult func save(_ value: String, forKey key: String) -> Bool
    @discardableResult func delete(_ key: String) -> Bool
}

struct KeychainDemoCredentialStore: DemoCredentialStore {
    func load(_ key: String) -> String? {
        KeychainHelper.load(key)
    }

    func save(_ value: String, forKey key: String) -> Bool {
        KeychainHelper.save(value, forKey: key)
    }

    func delete(_ key: String) -> Bool {
        KeychainHelper.delete(key)
    }
}

enum DemoCredentialRevisionError: Error, Equatable {
    case unavailable
}
#endif

@MainActor
final class AISettings: ObservableObject {
    let buildPolicy: AISettingsBuildPolicy
    let speechInputAvailability: AISpeechInputAvailability

    @AppStorage("ai.asr.resourceID") var asrResourceID = "volc.seedasr.sauc.duration"
    @AppStorage("ai.asr.language") var asrLanguage = "zh-CN"
    @AppStorage("ai.asr.hotwords") var hotwordsText = ""
    @AppStorage("ai.asr.handsFree") var handsFree = false
    @AppStorage("ai.llm.model") var llmModel = "deepseek-v4-flash"
    @AppStorage("ai.llm.enableSearch") var enableSearch = true

    #if DEBUG
    private let demoCredentialStore: any DemoCredentialStore
    private let makeCredentialRevision: () -> String

    private static let llmCredentialKey = "llm.apiKey"
    private static let llmAccountRevisionKey = "llm.accountRevision"

    init(
        buildPolicy: AISettingsBuildPolicy = .current,
        speechInputAvailability: AISpeechInputAvailability = .productionDetectorPending,
        demoCredentialStore: any DemoCredentialStore = KeychainDemoCredentialStore(),
        makeCredentialRevision: @escaping () -> String = { UUID().uuidString }
    ) {
        self.buildPolicy = buildPolicy
        self.speechInputAvailability = speechInputAvailability
        self.demoCredentialStore = demoCredentialStore
        self.makeCredentialRevision = makeCredentialRevision
    }

    var speechAPIKey: String {
        get {
            guard buildPolicy.allowsDemoCredentialStorage else { return "" }
            return demoCredentialStore.load("asr.apiKey") ?? ""
        }
        set { storeSecret(newValue, key: "asr.apiKey") }
    }

    var llmAPIKey: String {
        get {
            guard buildPolicy.allowsDemoCredentialStorage else { return "" }
            return demoCredentialStore.load(Self.llmCredentialKey) ?? ""
        }
        set { storeLLMCredential(newValue) }
    }

    var bochaAPIKey: String {
        get {
            guard buildPolicy.allowsDemoCredentialStorage else { return "" }
            return demoCredentialStore.load("llm.bochaKey") ?? ""
        }
        set { storeSecret(newValue, key: "llm.bochaKey") }
    }
    #else
    init(
        buildPolicy: AISettingsBuildPolicy = .current,
        speechInputAvailability: AISpeechInputAvailability = .productionDetectorPending
    ) {
        self.buildPolicy = buildPolicy
        self.speechInputAvailability = speechInputAvailability
    }
    #endif

    /// The persisted request is retained during the VAD migration. An
    /// unavailable voice-activated request must not be rewritten to manual
    /// input behind the user's back.
    var requestedSpeechInputMode: SpeechInputMode {
        handsFree ? .voiceActivated : .pushToTalk
    }

    /// `nil` means the requested mode cannot currently be composed. Callers
    /// must fail closed instead of silently selecting push-to-talk.
    var effectiveSpeechInputMode: SpeechInputMode? {
        if requestedSpeechInputMode == .voiceActivated,
           !speechInputAvailability.voiceActivatedIsAvailable {
            return nil
        }
        return requestedSpeechInputMode
    }

    /// Returns false when a UI attempts to select an unavailable mode. Manual
    /// input always remains selectable, including from a migrated stored
    /// voice-activated preference.
    @discardableResult
    func requestSpeechInputMode(_ mode: SpeechInputMode) -> Bool {
        guard mode != .voiceActivated || speechInputAvailability.voiceActivatedIsAvailable else {
            return false
        }
        handsFree = mode == .voiceActivated
        return true
    }

    var hotwords: [String] {
        hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    #if DEBUG
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

    /// Returns a persisted, non-secret revision for the currently saved demo
    /// LLM credential. The revision is never derived from credential material.
    func demoLLMAccountScope() throws -> ConversationAgentAccountScope {
        guard buildPolicy.allowsDemoCredentialStorage else {
            throw DemoCredentialRevisionError.unavailable
        }
        if let stored = demoCredentialStore.load(Self.llmAccountRevisionKey)?.trimmed,
           !stored.isEmpty {
            return ConversationAgentAccountScope(opaqueID: stored)
        }
        let revision = makeCredentialRevision().trimmed
        guard !revision.isEmpty,
              demoCredentialStore.save(revision, forKey: Self.llmAccountRevisionKey) else {
            throw DemoCredentialRevisionError.unavailable
        }
        return ConversationAgentAccountScope(opaqueID: revision)
    }

    private func storeLLMCredential(_ value: String) {
        guard buildPolicy.allowsDemoCredentialStorage else { return }
        let current = (demoCredentialStore.load(Self.llmCredentialKey) ?? "").trimmed
        let next = value.trimmed
        guard current != next else { return }

        // Advance the non-secret revision first. If the subsequent credential
        // mutation fails, the conservative result is context isolation rather
        // than reusing context under uncertain account ownership.
        let revision = makeCredentialRevision().trimmed
        guard !revision.isEmpty,
              demoCredentialStore.save(revision, forKey: Self.llmAccountRevisionKey) else {
            return
        }

        objectWillChange.send()
        if next.isEmpty {
            demoCredentialStore.delete(Self.llmCredentialKey)
        } else {
            demoCredentialStore.save(next, forKey: Self.llmCredentialKey)
        }
    }

    private func storeSecret(_ value: String, key: String) {
        guard buildPolicy.allowsDemoCredentialStorage else { return }
        objectWillChange.send()
        let trimmed = value.trimmed
        if trimmed.isEmpty {
            demoCredentialStore.delete(key)
        } else {
            demoCredentialStore.save(trimmed, forKey: key)
        }
    }
    #endif
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
