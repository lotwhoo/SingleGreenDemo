import SingleGreenGlassesKit
import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var cameraController: CameraSessionController
    @EnvironmentObject private var runtime: ExperienceRuntime
    @EnvironmentObject private var profileStore: DisplayProfileStore
    @State private var debugMode = true
    @State private var showsAISettings = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PreviewPane(debugMode: $debugMode)
                    .ignoresSafeArea()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.10), location: 0.60),
                        .init(color: .black.opacity(0.72), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    FloatingHeaderView(
                        debugMode: $debugMode,
                        showsAISettings: $showsAISettings
                    )

                    Spacer(minLength: 24)

                    if debugMode {
                        diagnostics
                    }

                    ControlPanelView(debugMode: $debugMode)
                }
                .padding(.horizontal, 14)
                .padding(.top, proxy.safeAreaInsets.top + 8)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10))
                .zIndex(10)
            }
            .background(.black)
        }
        .tint(profileStore.activeProfile.tintColor)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsAISettings) {
            AISettingsView()
        }
    }

    private var diagnostics: some View {
        HStack(spacing: 7) {
            Image(systemName: runtime.selectedDescriptor.systemImageName)
            Text(runtime.selectedDescriptor.displayName)
            Text("·")
            Text(runtime.lastEventDescription)
                .lineLimit(1)
            if let startupDuration = cameraController.startupDuration {
                Text("·")
                Text("相机 \(startupDuration, format: .number.precision(.fractionLength(2)))s")
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            Text("r\(runtime.scene.revision)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        }
    }

}

private struct PreviewPane: View {
    @EnvironmentObject private var runtime: ExperienceRuntime
    @EnvironmentObject private var profileStore: DisplayProfileStore
    @Binding var debugMode: Bool

    var body: some View {
        GeometryReader { proxy in
            let projection = HUDPreviewProjection(profile: profileStore.activeProfile)
            let surfaceSize = projection.surfaceSize(in: proxy.size)

            ZStack {
                CameraEnvironmentView()

                if profileStore.hudEnabled {
                    HUDOverlayView(
                        scene: runtime.scene,
                        profile: profileStore.activeProfile,
                        intensity: profileStore.intensity,
                        showsSafeArea: debugMode
                    )
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: projection.alignment)
                    .offset(y: projection.verticalOffset(in: proxy.size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct FloatingHeaderView: View {
    @Binding var debugMode: Bool
    @Binding var showsAISettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("单绿显示实验室")
                    .font(.headline)

                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("VST 实时预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }

            Spacer()

            Button {
                showsAISettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .accessibilityLabel("打开 AI 对话设置")
            .accessibilityIdentifier("ai_settings_button")

            Button {
                debugMode.toggle()
            } label: {
                Image(systemName: debugMode ? "ladybug.fill" : "ladybug")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .accessibilityLabel(debugMode ? "关闭调试模式" : "打开调试模式")
            .accessibilityIdentifier("debug_toggle_button")
        }
    }
}

private struct CameraEnvironmentView: View {
    @EnvironmentObject private var cameraController: CameraSessionController

    @ViewBuilder
    var body: some View {
        if cameraController.authorizationState == .authorized {
            ZStack {
                CameraPreviewView(session: cameraController.session)
                    .ignoresSafeArea()

                if !cameraController.isConfigured {
                    CameraStartingView()
                }
            }
        } else {
            CameraFallbackView()
                .environmentObject(cameraController)
        }
    }
}

private struct CameraStartingView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.88)

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text("正在启动后置相机")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 160)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在启动后置相机")
    }
}

private struct CameraFallbackView: View {
    @EnvironmentObject private var cameraController: CameraSessionController

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .darkGray),
                    Color(uiColor: .black)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 12) {
                Image(systemName: cameraController.authorizationState.systemImage)
                    .font(.system(size: 34, weight: .medium))

                Text(cameraController.authorizationState.title)
                    .font(.headline)

                Text(cameraController.authorizationState.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)

                if cameraController.authorizationState == .denied ||
                    cameraController.authorizationState == .restricted {
                    Button("打开系统设置") {
                        cameraController.openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if cameraController.authorizationState != .authorized {
                    Button("重新检查相机") {
                        Task { await cameraController.prepare() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .foregroundStyle(.white)
        }
    }
}
