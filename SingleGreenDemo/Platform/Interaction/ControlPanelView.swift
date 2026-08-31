import SingleGreenGlassesKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @EnvironmentObject private var runtime: ExperienceRuntime
    @EnvironmentObject private var profileStore: DisplayProfileStore
    @EnvironmentObject private var teleprompterSettings: TeleprompterSettings
    @EnvironmentObject private var teleprompterController: TeleprompterController
    @State private var isConfirmingTeleprompterDeletion = false
    @State private var isConfirmingTeleprompterCompletion = false
    @State private var isImportingTeleprompterScript = false
    @State private var teleprompterImportMessage: String?
    #if INTERNAL_DIAGNOSTICS
    @Binding var debugMode: Bool
    #endif

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                experienceMenu
                if runtime.selectedKind == TeleprompterExperience.kind {
                    teleprompterScriptEditor
                }
                if TeleprompterUndoControlPolicy.isVisible(
                    selectedKind: runtime.selectedKind,
                    canUndoAutomaticJump: teleprompterController.canUndoAutomaticJump
                ) {
                    teleprompterUndoControl
                }
                if let controlState = runtime.controlState {
                    VStack(spacing: 12) {
                        experienceStatus(controlState)
                        if let action = primaryAction {
                            actionButton(action, minimumHeight: 54)
                        }
                    }
                } else if let action = primaryAction {
                    actionButton(action, minimumHeight: 52)
                }
                if !secondaryActions.isEmpty {
                    secondaryActionControls
                }
                displayControls
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("control_panel_scroll_view")
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }

    private var experienceMenu: some View {
        Menu {
            Picker(
                "体验场景",
                selection: Binding(
                    get: { runtime.selectedKind },
                    set: { kind in
                        let expectedKind = runtime.selectedKind
                        Task {
                            await runtime.activate(kind, expectedKind: expectedKind)
                        }
                    }
                )
            ) {
                ForEach(runtime.availableDescriptors) { descriptor in
                    Label(descriptor.displayName, systemImage: descriptor.systemImageName)
                        .tag(descriptor.kind)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: runtime.selectedDescriptor.systemImageName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(profileStore.activeProfile.tintColor)
                    .frame(width: 34, height: 34)
                    .background(
                        profileStore.activeProfile.tintColor.opacity(0.13),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.selectedDescriptor.displayName)
                        .font(.headline)
                    Text(runtime.selectedDescriptor.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func experienceStatus(_ controlState: ExperienceControlState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(controlState.errorMessage == nil ? profileStore.activeProfile.tintColor : .red)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controlState.statusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(controlState.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)

            if let error = controlState.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Text(error)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = error
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("复制完整错误")
                }
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

        }
    }

    private func actionButton(
        _ action: ResolvedExperienceAction,
        minimumHeight: CGFloat
    ) -> some View {
        Button {
            let expectedKind = runtime.selectedKind
            let actionID = action.id
            Task {
                await runtime.performAction(id: actionID, expectedKind: expectedKind)
            }
        } label: {
                Label(action.title, systemImage: action.systemImageName)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular
                .tint(profileStore.activeProfile.tintColor.opacity(0.82))
                .interactive(),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.68)
        .accessibilityLabel(action.accessibilityLabel)
    }

    private var secondaryActionControls: some View {
        ViewThatFits(in: .horizontal) {
            secondaryActionGrid(
                columnCount: SecondaryActionGridPolicy.preferredColumnCount(
                    actionCount: secondaryActions.count
                )
            )
            secondaryActionGrid(columnCount: min(2, secondaryActions.count))
            secondaryActionGrid(columnCount: 1)
        }
    }

    private func secondaryActionGrid(columnCount: Int) -> some View {
        let rows = SecondaryActionGridPolicy.rows(
            secondaryActions,
            columnCount: columnCount
        )
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { action in
                        secondaryActionButton(action)
                            .frame(minWidth: SecondaryActionGridPolicy.minimumButtonWidth)
                    }
                }
            }
        }
    }

    private func secondaryActionButton(_ action: ResolvedExperienceAction) -> some View {
        Button {
            let expectedKind = runtime.selectedKind
            let actionID = action.id
            Task {
                await runtime.performAction(id: actionID, expectedKind: expectedKind)
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: action.systemImageName)
                    .font(.system(size: 17, weight: .semibold))
                Text(action.title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .disabled(!action.isEnabled)
        .accessibilityLabel(action.accessibilityLabel)
    }

    private var displayControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("HUD 显示", systemImage: "viewfinder")
                    .font(.subheadline.weight(.medium))

                Text(profileStore.activeProfile.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("HUD 显示", isOn: $profileStore.hudEnabled)
                    .labelsHidden()
            }

            #if INTERNAL_DIAGNOSTICS
            if debugMode {
                Picker(
                    "显示配置",
                    selection: Binding(
                        get: { profileStore.activeProfileID },
                        set: { profileID in
                            do {
                                try profileStore.selectProfile(id: profileID)
                            } catch {
                                assertionFailure("Catalog picker returned an unknown display profile: \(error)")
                            }
                        }
                    )
                ) {
                    ForEach(profileStore.catalog.profiles, id: \.id) { profile in
                        Text(profile.displayName)
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("display_profile_picker")
            }
            #endif

            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)

                Slider(value: $profileStore.intensity, in: 0.20...1.00)
                    .accessibilityLabel("模拟显示强度")

                Text(profileStore.intensity, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            #if INTERNAL_DIAGNOSTICS
            if debugMode {
                Button(role: .destructive) {
                    let expectedKind = runtime.selectedKind
                    Task { await runtime.handle(.reset, expectedKind: expectedKind) }
                } label: {
                    Label("重置当前体验", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
        }
        .padding(.horizontal, 2)
    }

    private var primaryAction: ResolvedExperienceAction? {
        runtime.activeActions.first { $0.placement == .primary }
    }

    private var teleprompterScriptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("提词稿", systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(teleprompterSettings.scriptDraft.count)/\(TeleprompterLimits.maximumScriptCharacters)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $teleprompterSettings.scriptDraft)
                .font(.callout)
                .frame(minHeight: 88, maxHeight: 132)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("teleprompter_script_editor")

            Button {
                let result = teleprompterSettings.applyScriptDraft()
                teleprompterImportMessage = result.userMessage
            } label: {
                Label("载入稿件", systemImage: "arrow.down.doc.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("teleprompter_load_script_button")

            Button {
                isImportingTeleprompterScript = true
            } label: {
                Label("导入 TXT / Markdown", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("teleprompter_import_script_button")
            .fileImporter(
                isPresented: $isImportingTeleprompterScript,
                allowedContentTypes: [
                    .plainText,
                    UTType(filenameExtension: "md") ?? .plainText
                ],
                allowsMultipleSelection: false
            ) { result in
                handleTeleprompterImport(result)
            }

            if let teleprompterImportMessage {
                Text(teleprompterImportMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("teleprompter_import_result_message")
            }

            if TeleprompterCompletionControlPolicy.isVisible(
                hasLoadedScript: teleprompterController.state.script != nil,
                phase: teleprompterController.state.phase
            ) {
                Button {
                    isConfirmingTeleprompterCompletion = true
                } label: {
                    Label("完成本次提词", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("teleprompter_complete_script_button")
                .confirmationDialog(
                    "完成本次提词？",
                    isPresented: $isConfirmingTeleprompterCompletion,
                    titleVisibility: .visible
                ) {
                    Button("标记为已完成") {
                        Task { await teleprompterController.complete() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("阅读位置会保存到稿件末尾，之后仍可从头重新开始。")
                }
            }

            if TeleprompterDeleteControlPolicy.isVisible(
                hasDraft: !teleprompterSettings.scriptDraft.isEmpty,
                hasLoadedScript: teleprompterController.state.script != nil
            ) {
                Button(role: .destructive) {
                    isConfirmingTeleprompterDeletion = true
                } label: {
                    Label("删除稿件和阅读位置", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("teleprompter_delete_script_button")
                .confirmationDialog(
                    "删除这份稿件？",
                    isPresented: $isConfirmingTeleprompterDeletion,
                    titleVisibility: .visible
                ) {
                    Button("删除稿件和阅读位置", role: .destructive) {
                        Task { await teleprompterController.deleteScript() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("稿件、阅读位置和本地派生缓存会一起删除，无法撤销。")
                }
            }

            Toggle(
                "允许云端语音跟随",
                isOn: $teleprompterSettings.allowsCloudSpeechRecognition
            )
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("teleprompter_cloud_asr_consent_toggle")

            Text("默认关闭。开启后，麦克风中的朗读音频会发送到设置中配置的云端语音识别服务；稿件正文不会作为文本上传。关闭后仍可用左右键手动提词。下键短按用于重对齐或切换手动模式。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var teleprompterUndoControl: some View {
        Button {
            Task { await teleprompterController.undoLastAutomaticJump() }
        } label: {
            Label("撤销刚才的自动跳转", systemImage: "arrow.uturn.backward")
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("teleprompter_undo_automatic_jump_button")
    }

    private func handleTeleprompterImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            teleprompterImportMessage = TeleprompterScriptImportResult
                .rejected(.unreadable)
                .userMessage
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let kind: TeleprompterScriptImportKind
        switch url.pathExtension.lowercased() {
        case "txt":
            kind = .plainText
        case "md", "markdown":
            kind = .markdown
        default:
            teleprompterImportMessage = TeleprompterScriptImportResult
                .rejected(.unsupportedType)
                .userMessage
            return
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            teleprompterImportMessage = TeleprompterScriptImportResult
                .rejected(.unreadable)
                .userMessage
            return
        }
        let importResult = TeleprompterScriptImporter.parse(
            data: data,
            kind: kind,
            existingSource: teleprompterSettings.loadedScriptSource
        )
        if case .imported(let source) = importResult {
            let repositoryResult = teleprompterSettings.replaceScript(with: source)
            teleprompterImportMessage = repositoryResult.userMessage
            return
        }
        teleprompterImportMessage = importResult.userMessage
    }

    private var secondaryActions: [ResolvedExperienceAction] {
        runtime.activeActions.filter { $0.placement == .secondary }
    }
}

@MainActor
enum TeleprompterUndoControlPolicy {
    static func isVisible(
        selectedKind: ExperienceKind,
        canUndoAutomaticJump: Bool
    ) -> Bool {
        selectedKind == TeleprompterExperience.kind && canUndoAutomaticJump
    }
}

@MainActor
enum TeleprompterDeleteControlPolicy {
    static func isVisible(hasDraft: Bool, hasLoadedScript: Bool) -> Bool {
        hasDraft || hasLoadedScript
    }
}

@MainActor
enum TeleprompterCompletionControlPolicy {
    static func isVisible(
        hasLoadedScript: Bool,
        phase: TeleprompterPhase
    ) -> Bool {
        hasLoadedScript && phase != .completed
    }
}

extension TeleprompterScriptRepositoryResult {
    var userMessage: String {
        switch self {
        case .applied:
            return "稿件已载入。"
        case .duplicate:
            return "这份稿件已经载入，无需重复操作。"
        case .rejected(.empty):
            return "稿件中没有可用文字。"
        case .rejected(.exceedsCharacterLimit(let maximum)):
            return "稿件超过 \(maximum) 字，请精简后重试。"
        }
    }
}

enum SecondaryActionGridPolicy {
    static let maximumColumnCount = 3
    static let minimumButtonWidth: CGFloat = 84

    static func preferredColumnCount(actionCount: Int) -> Int {
        if actionCount == 4 { return 2 }
        return min(max(actionCount, 1), maximumColumnCount)
    }

    static func rows<Element>(
        _ elements: [Element],
        columnCount: Int
    ) -> [[Element]] {
        let safeColumnCount = max(columnCount, 1)
        return stride(from: 0, to: elements.count, by: safeColumnCount).map { start in
            Array(elements[start..<min(start + safeColumnCount, elements.count)])
        }
    }
}
