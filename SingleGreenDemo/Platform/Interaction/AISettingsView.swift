import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ASR API Key", text: settings.speechAPIKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

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

                    Toggle("免按对话（静音后自动结束）", isOn: $settings.handsFree)
                } header: {
                    Label("豆包流式语音识别 2.0", systemImage: "waveform")
                } footer: {
                    Text("API Key 存入系统 Keychain，并作为 X-Api-Key 发送；不是 Access Token 或 Secret Key。")
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
                    SecureField("DeepSeek API Key", text: settings.llmAPIKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("模型", text: $settings.llmModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Label("DeepSeek AI 回答", systemImage: "sparkles")
                } footer: {
                    Text("通过 AiiOSStudy 的 LLMKit 调用 OpenAI 兼容接口，并保留多轮上下文。API Key 存入系统 Keychain。")
                }

                Section {
                    Toggle("模型自主联网搜索", isOn: $settings.enableSearch)
                    SecureField("博查搜索 API Key", text: settings.bochaAPIKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!settings.enableSearch)
                } header: {
                    Label("联网搜索", systemImage: "globe")
                } footer: {
                    Text("模型判断问题需要实时信息时调用 web_search，再根据搜索结果作答。")
                }

                Section("配置状态") {
                    configurationRow("语音识别", configured: settings.isASRConfigured)
                    configurationRow("AI 回答", configured: settings.isLLMConfigured)
                    configurationRow("联网搜索", configured: settings.isSearchConfigured)
                }
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
