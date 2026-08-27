import SwiftUI

struct HUDOverlayView: View {
    let scene: HUDScene
    let profile: DisplayProfile
    let intensity: Double
    let showsSafeArea: Bool

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let viewport = profile.viewport.rect(in: bounds)
            let safeRect = profile.safeArea.inset(viewport)

            ZStack {
                if showsSafeArea {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(
                            profile.tintColor.opacity(0.72),
                            style: StrokeStyle(
                                lineWidth: max(1, profile.lineScale),
                                dash: [5, 4]
                            )
                        )
                        .frame(width: safeRect.width, height: safeRect.height)
                        .position(x: safeRect.midX, y: safeRect.midY)
                }

                ForEach(scene.elements) { element in
                    elementView(element)
                        .frame(
                            width: element.frame.rect(in: safeRect).width,
                            height: element.frame.rect(in: safeRect).height
                        )
                        .position(
                            x: element.frame.rect(in: safeRect).midX,
                            y: element.frame.rect(in: safeRect).midY
                        )
                }
            }
            .foregroundStyle(profile.tintColor.opacity(intensity))
            .shadow(
                color: profile.tintColor.opacity(0.16 * intensity),
                radius: 3
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func elementView(_ element: HUDElement) -> some View {
        switch element.content {
        case let .text(value, style):
            Text(value)
                .font(font(for: style))
                .minimumScaleFactor(0.62)
                .lineLimit(style == .detail ? 2 : 1)
                .multilineTextAlignment(.center)

        case let .symbol(name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)

        case let .progress(value):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(profile.tintColor.opacity(intensity))
        }
    }

    private func font(for style: HUDTextStyle) -> Font {
        switch style {
        case .title:
            .system(size: 22 * profile.textScale, weight: .semibold, design: .rounded)
        case .value:
            .system(size: 38 * profile.textScale, weight: .bold, design: .rounded)
        case .detail:
            .system(size: 17 * profile.textScale, weight: .medium, design: .rounded)
        }
    }
}
