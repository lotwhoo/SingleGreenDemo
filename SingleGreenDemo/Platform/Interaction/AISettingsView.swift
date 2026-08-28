import SingleGreenGlassesKit
import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                credentialModeSection

                Section {
                    #if DEBUG
                    if settings.buildPolicy.allowsDemoCredentialStorage {
                        SecureField("ASR API Key", text: settings.speechAPIKeyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("demo_asr_api_key_field")
                    }
                    #endif

                    Picker("资源 ID", selection: $settings.asrResourceID) {
                        Text("按量 · duration").tag("volc.seedasr.sauc.duration")
                        Text("并发 · concurrent").tag("volc.seedasr.sauc.concurrent")
                    }

                    Picker("识别语言", selection: $settings.asrLanguage) {
                        Text("中文").tag("zh-CN")
                        Text("英文").tag("en-US")
                        Text("粤语").tag("yue-CN")
                        Text("日语").tag("ja-JP")
                        Text("韩语").tag("ko-KR")
                    }

                    speechInputModeRow(
                        title: "按住说话",
                        detail: "手动开始和结束录音",
                        mode: .pushToTalk,
                        isAvailable: true
                    )
                    speechInputModeRow(
                        title: "免按对话",
                        detail: "本地检测说话，静音后自动结束",
                        mode: .voiceActivated,
                        isAvailable: settings.speechInputAvailability.voiceActivatedIsAvailable
                    )

                    Text(settings.speechInputAvailability.voiceActivatedDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice_activated_unavailable_explanation")
                } header: {
                    Label("豆包流式语音识别 2.0", systemImage: "waveform")
                } footer: {
                    #if DEBUG
                    credentialFooter(
                        demoText: "API Key 存入系统 Keychain，并作为 X-Api-Key 发送；不是 Access Token 或 Secret Key。"
                    )
                    #else
                    serverCredentialFooter
                    #endif
                }

                Section {
                    TextField("例如：单绿眼镜, 产品名称", text: $settings.hotwordsText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                } header: {
                    Text("识别热词")
                } footer: {
                    Text("使用逗号、空格或换行分隔，可提高专有名词的识别准确率。")
                }

                Section {
                    #if DEBUG
                    if settings.buildPolicy.allowsDemoCredentialStorage {
                        SecureField("DeepSeek API Key", text: settings.llmAPIKeyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("demo_llm_api_key_field")
                    }
                    #endif

                    TextField("模型", text: $settings.llmModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Label("DeepSeek AI 回答", systemImage: "sparkles")
                } footer: {
                    #if DEBUG
                    credentialFooter(
                        demoText: "通过 LLMKit 调用 OpenAI 兼容接口，并保留多轮上下文。API Key 存入系统 Keychain。"
                    )
                    #else
                    serverCredentialFooter
                    #endif
                }

                Section {
                    Toggle("模型自主联网搜索", isOn: $settings.enableSearch)
                    #if DEBUG
                    if settings.buildPolicy.allowsDemoCredentialStorage {
                        SecureField("博查搜索 API Key", text: settings.bochaAPIKeyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(!settings.enableSearch)
                            .accessibilityIdentifier("demo_search_api_key_field")
                    }
                    #endif
                } header: {
                    Label("联网搜索", systemImage: "globe")
                } footer: {
                    Text("模型判断问题需要实时信息时调用 web_search，再根据搜索结果作答。")
                }

                configurationStatusSection
            }
            .navigationTitle("AI 对话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var credentialModeSection: some View {
        let status = settings.buildPolicy.credentialStatus
        return Section("凭证模式") {
            Label(status.title, systemImage: status.systemImage)
                .foregroundStyle(status.isAvailable ? .orange : .secondary)
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func speechInputModeRow(
        title: String,
        detail: String,
        mode: SpeechInputMode,
        isAvailable: Bool
    ) -> some View {
        Button {
            settings.requestSpeechInputMode(mode)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isAvailable {
                    Text("尚不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: settings.requestedSpeechInputMode == mode
                    ? "checkmark.circle.fill"
                    : "circle")
                    .foregroundStyle(settings.requestedSpeechInputMode == mode ? .green : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityIdentifier(
            mode == .pushToTalk ? "push_to_talk_mode_option" : "voice_activated_mode_option"
        )
    }

    #if DEBUG
    @ViewBuilder
    private func credentialFooter(demoText: String) -> some View {
        if settings.buildPolicy.allowsDemoCredentialStorage {
            Text(demoText)
        } else {
            serverCredentialFooter
        }
    }
    #endif

    private var serverCredentialFooter: some View {
        Text("发布版仅接受服务端签发的短期凭证；当前未接入服务端，功能会安全停用。")
    }

    @ViewBuilder
    private var configurationStatusSection: some View {
        #if DEBUG
        if settings.buildPolicy.allowsDemoCredentialStorage {
            Section("演示凭证状态") {
                configurationRow("语音识别", configured: settings.isASRConfigured)
                configurationRow("AI 回答", configured: settings.isLLMConfigured)
                configurationRow("联网搜索", configured: settings.isSearchConfigured)
            }
        } else {
            serverCredentialStatusSection
        }
        #else
        serverCredentialStatusSection
        #endif
    }

    private var serverCredentialStatusSection: some View {
        Section("服务端凭证状态") {
            configurationRow("对话服务", configured: false)
            Text("未取得可用凭证时不会发起提供商请求。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func configurationRow(_ title: String, configured: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(configured ? "已配置" : "未配置", systemImage: configured ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(configured ? .green : .orange)
        }
    }
}
