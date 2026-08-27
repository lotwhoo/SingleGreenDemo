import SwiftUI
import UIKit

struct ControlPanelView: View {
    @EnvironmentObject private var runtime: ExperienceRuntime
    @EnvironmentObject private var profileStore: DisplayProfileStore
    @EnvironmentObject private var conversationController: VoiceConversationController
    @Binding var debugMode: Bool

    var body: some View {
        VStack(spacing: 14) {
            experienceMenu
            if runtime.selectedKind == .conversation {
                conversationControls
            } else {
                primaryAction
                gestureControls
            }
            displayControls
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }

    private var experienceMenu: some View {
        Menu {
            Picker(
                "体验场景",
                selection: Binding(
                    get: { runtime.selectedKind },
                    set: { kind in
                        Task { await runtime.activate(kind) }
                    }
                )
            ) {
                ForEach(runtime.availableKinds) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: runtime.selectedKind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(profileStore.activeProfile.tintColor)
                    .frame(width: 34, height: 34)
                    .background(
                        profileStore.activeProfile.tintColor.opacity(0.13),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.selectedKind.displayName)
                        .font(.headline)
                    Text(runtime.selectedKind == .conversation ? "豆包 ASR → DeepSeek Agent → 博查搜索" : "体验场景 · 本地样例")
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

    private var conversationControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(conversationController.state == .failed ? .red : profileStore.activeProfile.tintColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversationController.state.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(conversationStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)

            if let error = conversationController.lastError {
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

            Button {
                Task { await runtime.handle(.tap) }
            } label: {
                Label(
                    runtime.primaryActionTitle,
                    systemImage: conversationController.primaryActionSystemImage
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular
                    .tint(profileStore.activeProfile.tintColor.opacity(0.82))
                    .interactive(),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .disabled(!conversationController.allowsPrimaryAction)
            .opacity(conversationController.allowsPrimaryAction ? 1 : 0.68)
        }
    }

    private var primaryAction: some View {
        Button {
            Task {
                await runtime.handle(runtime.selectedKind == .notification ? .triggerAlert : .tap)
            }
        } label: {
            Label(runtime.primaryActionTitle, systemImage: primaryActionSystemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular
                .tint(profileStore.activeProfile.tintColor.opacity(0.82))
                .interactive(),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var gestureControls: some View {
        HStack(spacing: 10) {
            gestureButton(title: "上滑", systemImage: "arrow.up", event: .swipeUp)
            gestureButton(title: "点击", systemImage: "hand.tap", event: .tap)
            gestureButton(title: "下滑", systemImage: "arrow.down", event: .swipeDown)
        }
    }

    private func gestureButton(
        title: String,
        systemImage: String,
        event: DemoEvent
    ) -> some View {
        Button {
            Task { await runtime.handle(event) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
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

            if debugMode {
                Button(role: .destructive) {
                    Task { await runtime.handle(.reset) }
                } label: {
                    Label("重置当前体验", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
    }

    private var conversationStatusDetail: String {
        if let error = conversationController.lastError {
            return error
        }
        if !conversationController.transcript.isEmpty {
            if !conversationController.assistantReply.isEmpty {
                return conversationController.assistantReply
            }
            return conversationController.transcript
        }
        return "语音识别 → 多轮 Agent → 按需联网搜索"
    }

    private var primaryActionSystemImage: String {
        switch runtime.selectedKind {
        case .conversation: "waveform"
        case .systemStatus: "arrow.clockwise"
        case .navigation: "location.fill"
        case .notification: "bell.badge.fill"
        case .caption: "text.bubble.fill"
        }
    }
}
