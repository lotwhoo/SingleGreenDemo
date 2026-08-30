#if INTERNAL_DIAGNOSTICS
import SwiftUI
import UIKit

struct DiagnosticsPanelView: View {
    @EnvironmentObject private var diagnostics: ConversationTelemetryStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportItem: DiagnosticsExportItem?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("运行状态") {
                    LabeledContent("日志数量", value: "\(diagnostics.diagnosticLines.count)")
                    Text("日志只记录阶段、耗时、错误码和生命周期，不记录对话正文、提词稿、音频或 API Key。")
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
                        diagnostics.removeAllDiagnostics()
                    } label: {
                        Image(systemName: "trash")
                    }
                    Button {
                        do {
                            exportItem = DiagnosticsExportItem(url: try diagnostics.makeExportURL())
                        } catch {
                            exportError = "日志导出失败"
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
