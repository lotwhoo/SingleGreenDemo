#if INTERNAL_DIAGNOSTICS
import SwiftUI
import UIKit

struct DiagnosticsPanelView: View {
    @EnvironmentObject private var diagnostics: ConversationTelemetryStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportItem: DiagnosticsExportItem?
    @State private var exportError: String?
    @State private var offlineSpeechSnapshot: OfflineSpeechCapabilitySnapshot?
    @State private var isCheckingOfflineSpeech = false

    var body: some View {
        NavigationStack {
            List {
                Section("运行状态") {
                    LabeledContent("日志数量", value: "\(diagnostics.diagnosticLines.count)")
                    Text("日志只记录阶段、耗时、错误码、生命周期，以及内部 VAD 和提词器 ASR 的无内容里程碑；不记录对话正文、识别文字、提词稿、音频、音量值或 API Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("离线 ASR Spike") {
                    if let snapshot = offlineSpeechSnapshot {
                        LabeledContent("中文支持", value: snapshot.resolvedLocaleIdentifier ?? "不支持")
                        LabeledContent("模型资产", value: snapshot.assetStatus.rawValue)
                        LabeledContent(
                            "音频格式",
                            value: audioFormatDescription(snapshot)
                        )
                        LabeledContent(
                            "首次准备",
                            value: preparationDescription(snapshot)
                        )
                    } else {
                        Text("尚未检查系统离线语音能力")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        runOfflineSpeechCapabilityCheck()
                    } label: {
                        if isCheckingOfflineSpeech {
                            ProgressView()
                        } else {
                            Label("检查中文离线语音能力", systemImage: "waveform.badge.magnifyingglass")
                        }
                    }
                    .disabled(isCheckingOfflineSpeech)
                    .accessibilityIdentifier("offline_asr_capability_check_button")

                    Text("只查询中文 locale、模型资产状态和兼容格式；仅当资产已安装时测量模型准备耗时。不自动下载模型、不录音、不保存转写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("最近日志") {
                    if diagnostics.diagnosticLines.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(diagnostics.diagnosticLines.suffix(100).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Debug 与日志")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(role: .destructive) {
                        Task { await diagnostics.removeAllDiagnostics() }
                    } label: {
                        Image(systemName: "trash")
                    }
                    Button {
                        Task {
                            do {
                                exportItem = DiagnosticsExportItem(
                                    url: try await diagnostics.makeExportURL()
                                )
                            } catch {
                                exportError = "日志导出失败"
                            }
                        }
                    } label: {
                        Label("导出全部日志", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("diagnostics_export_button")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ActivityShareView(items: [item.url])
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "未知错误")
        }
    }

    private func runOfflineSpeechCapabilityCheck() {
        guard !isCheckingOfflineSpeech else { return }
        isCheckingOfflineSpeech = true
        Task {
            let snapshot = await AppleOfflineSpeechCapabilityChecker().check()
            offlineSpeechSnapshot = snapshot
            diagnostics.record(category: "offline_asr_spike", message: snapshot.diagnosticLine)
            isCheckingOfflineSpeech = false
        }
    }

    private func audioFormatDescription(_ snapshot: OfflineSpeechCapabilitySnapshot) -> String {
        guard let sampleRate = snapshot.sampleRate,
              let channelCount = snapshot.channelCount else {
            return "未取得"
        }
        return "\(Int(sampleRate.rounded())) Hz / \(channelCount) ch"
    }

    private func preparationDescription(_ snapshot: OfflineSpeechCapabilitySnapshot) -> String {
        switch snapshot.preparationStatus {
        case .notAttempted:
            return "未执行"
        case .succeeded:
            return snapshot.preparationMilliseconds.map { "\($0) ms" } ?? "成功"
        case .failed:
            return "失败"
        }
    }
}

private struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DiagnosticsExportItem: Identifiable {
    let id = UUID()
    let url: URL
}
#endif
