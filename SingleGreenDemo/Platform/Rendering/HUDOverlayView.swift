import Foundation
import SingleGreenGlassesKit
import SwiftUI
import UIKit

struct HUDOverlayView: View {
    let scene: HUDScene
    let profile: DisplayProfile
    let intensity: Double
    let showsSafeArea: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    let rect = element.frame.rect(in: safeRect)
                    elementView(element)
                        .frame(
                            width: rect.width,
                            height: rect.height,
                            alignment: alignment(for: element.alignment)
                        )
                        .position(
                            x: rect.midX,
                            y: rect.midY
                        )
                        .opacity(element.opacity)
                        .scaleEffect(element.scale)
                        .animation(
                            reduceMotion ? nil : animation(for: element.content),
                            value: element
                        )
                        .accessibilityHidden(element.semanticRole == .decorative)
                        .accessibilityAddTraits(
                            element.semanticRole == .status ? .updatesFrequently : []
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
        .accessibilityHidden(
            scene.sceneID != "ai_conversation"
                && scene.sceneID != "text_adventure.green_signal"
                && scene.sceneID != "teleprompter.asr"
        )
    }

    @ViewBuilder
    private func elementView(_ element: HUDElement) -> some View {
        switch element.content {
        case let .text(value, style):
            Text(value)
                .font(font(for: style))
                .minimumScaleFactor(0.62)
                .lineLimit(lineLimit(for: style))
                .multilineTextAlignment(textAlignment(for: element.alignment))
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: alignment(for: element.alignment)
                )
                .contentTransition(.opacity)

        case let .flowingText(value, isStreaming, footer):
            HUDFlowingTextView(
                text: value,
                textRuns: nil,
                isStreaming: isStreaming,
                footer: footer,
                font: .system(size: 17 * profile.textScale, weight: .medium, design: .rounded),
                cursorColor: profile.tintColor.opacity(intensity),
                visibleLineCount: nil,
                lineHeight: nil,
                platformFont: nil,
                usesCompleteLineTail: false,
                alignsCompleteLinesToTop: false,
                completeLineFocusUTF16Offset: nil
            )

        case let .styledFlowingText(value, isStreaming, footer, style):
            HUDFlowingTextView(
                text: value,
                textRuns: nil,
                isStreaming: isStreaming,
                footer: footer,
                font: font(for: style),
                cursorColor: profile.tintColor.opacity(intensity),
                visibleLineCount: style == .answer
                    ? HUDFlowingTextViewportPolicy.answerVisibleLineCount
                    : teleprompterVisibleLineCount(for: element.id),
                lineHeight: style == .answer
                    ? answerLineHeight
                    : gameNarrativeLineHeight,
                platformFont: uiFont(for: style),
                usesCompleteLineTail: HUDFlowingTextViewportPolicy.usesCompleteLineTail(
                    sceneID: scene.sceneID,
                    elementID: element.id
                ),
                alignsCompleteLinesToTop: HUDFlowingTextViewportPolicy.alignsCompleteLinesToTop(
                    sceneID: scene.sceneID,
                    elementID: element.id
                ),
                completeLineFocusUTF16Offset: HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                    text: value,
                    sceneID: scene.sceneID,
                    elementID: element.id
                )
            )

        case let .styledFlowingTextRuns(runs, isStreaming, footer, style):
            let value = runs.map(\.text).joined()
            HUDFlowingTextView(
                text: value,
                textRuns: runs,
                isStreaming: isStreaming,
                footer: footer,
                font: font(for: style),
                cursorColor: profile.tintColor.opacity(intensity),
                visibleLineCount: style == .answer
                    ? HUDFlowingTextViewportPolicy.answerVisibleLineCount
                    : teleprompterVisibleLineCount(for: element.id),
                lineHeight: style == .answer
                    ? answerLineHeight
                    : gameNarrativeLineHeight,
                platformFont: uiFont(for: style),
                usesCompleteLineTail: HUDFlowingTextViewportPolicy.usesCompleteLineTail(
                    sceneID: scene.sceneID,
                    elementID: element.id
                ),
                alignsCompleteLinesToTop: HUDFlowingTextViewportPolicy.alignsCompleteLinesToTop(
                    sceneID: scene.sceneID,
                    elementID: element.id
                ),
                completeLineFocusUTF16Offset: HUDFlowingTextViewportPolicy.completeLineFocusUTF16Offset(
                    runs: runs,
                    sceneID: scene.sceneID,
                    elementID: element.id
                )
            )

        case let .symbol(name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .contentTransition(.symbolEffect(.replace))

        case let .voiceWaveform(level, isActive):
            HUDVoiceWaveformView(
                level: level,
                isActive: isActive
            )

        case let .progress(value):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(profile.tintColor.opacity(intensity))

        case let .rule(orientation, progress):
            HUDRuleView(
                orientation: orientation,
                progress: progress,
                lineWidth: max(1, profile.lineScale)
            )

        case .activityIndicator:
            HUDActivityIndicatorView(
                dotDiameter: 4.5 * profile.lineScale,
                spacing: 9 * profile.lineScale
            )
            .accessibilityHidden(true)
        }
    }

    private func font(for style: HUDTextStyle) -> Font {
        Font(uiFont(for: style))
    }

    private func uiFont(for style: HUDTextStyle) -> UIFont {
        switch style {
        case .title:
            roundedFont(size: 22 * profile.textScale, weight: .semibold)
        case .answer:
            roundedFont(size: 20 * profile.textScale, weight: .semibold)
        case .value:
            roundedFont(size: 38 * profile.textScale, weight: .bold)
        case .detail:
            roundedFont(size: 17 * profile.textScale, weight: .medium)
        case .caption:
            roundedFont(size: 13.5 * profile.textScale, weight: .semibold)
        case .question:
            roundedFont(size: 15.5 * profile.textScale, weight: .medium)
        }
    }

    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemDescriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        let descriptor = systemDescriptor.withDesign(.rounded) ?? systemDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }

    private var answerLineHeight: CGFloat {
        24 * profile.textScale
    }

    private var gameNarrativeLineHeight: CGFloat {
        uiFont(for: .detail).lineHeight
    }

    private func teleprompterVisibleLineCount(for elementID: String) -> Int? {
        guard scene.sceneID == "teleprompter.asr",
              elementID == "teleprompter_body" else { return nil }
        return HUDFlowingTextViewportPolicy.teleprompterVisibleLineCount
    }

    private func lineLimit(for style: HUDTextStyle) -> Int {
        switch style {
        case .detail, .question: 2
        case .title, .answer, .value, .caption: 1
        }
    }

    private func alignment(for value: HUDContentAlignment) -> Alignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(for value: HUDContentAlignment) -> TextAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func animation(for content: HUDElementContent) -> Animation {
        let transition = HUDMotionPolicy.transition(for: content)
        return switch transition.curve {
        case .linear: .linear(duration: transition.duration)
        case .easeOut: .easeOut(duration: transition.duration)
        case .easeInOut: .easeInOut(duration: transition.duration)
        }
    }
}

private struct HUDVoiceWaveformView: View {
    let level: Double
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clampedLevel = min(max(level, 0), 1)
        Group {
            if isActive && !reduceMotion {
                waveform
                    .symbolEffect(
                        .variableColor.iterative.reversing,
                        options: .repeating
                    )
                    .scaleEffect(0.94 + 0.12 * clampedLevel)
            } else {
                waveform
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: clampedLevel
        )
    }

    private var waveform: some View {
        Image(systemName: "waveform")
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
    }
}

enum HUDMotionPolicy {
    enum TransitionCurve: Equatable {
        case linear
        case easeOut
        case easeInOut
    }

    struct Transition: Equatable {
        let duration: TimeInterval
        let curve: TransitionCurve
    }

    static let thinkingCycleDuration: TimeInterval = 0.96
    static let thinkingPhaseOffset: TimeInterval = 0.16
    static let thinkingLoopStartDelay: TimeInterval = 0.22
    static let thinkingEntryDelay: TimeInterval = 0.10
    static let thinkingEntryDuration: TimeInterval = 0.12
    static let cursorCycleDuration: TimeInterval = 0.60

    static func transition(for content: HUDElementContent) -> Transition {
        switch content {
        case .rule:
            Transition(duration: 0.20, curve: .linear)
        case .text(_, .caption):
            Transition(duration: 0.12, curve: .easeInOut)
        case .styledFlowingText, .styledFlowingTextRuns:
            Transition(duration: 0.12, curve: .easeOut)
        default:
            Transition(duration: 0.16, curve: .easeOut)
        }
    }

    static func thinkingDotOpacities(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> [Double] {
        guard !reduceMotion else { return [0.70, 0.70, 0.70] }
        let loopElapsed = max(0, elapsed - thinkingLoopStartDelay)
        return (0..<3).map { index in
            let delayed = loopElapsed - Double(index) * thinkingPhaseOffset
            guard delayed >= 0 else { return 0.35 }
            let phase = delayed.truncatingRemainder(dividingBy: thinkingCycleDuration)
                / thinkingCycleDuration
            let wave = 0.5 - 0.5 * cos(2 * .pi * phase)
            return 0.35 + 0.55 * wave
        }
    }

    static func thinkingGroupOpacity(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 1 }
        let progress = min(
            max((elapsed - thinkingEntryDelay) / thinkingEntryDuration, 0),
            1
        )
        return 1 - pow(1 - progress, 2)
    }

    static func cursorOpacity(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 0.75 }
        let phase = elapsed.truncatingRemainder(dividingBy: cursorCycleDuration)
            / cursorCycleDuration
        let wave = 0.5 - 0.5 * cos(2 * .pi * phase)
        return 0.45 + 0.40 * wave
    }
}

private struct HUDRuleView: View {
    let orientation: HUDRuleOrientation
    let progress: Double
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(max(progress, 0), 1)
            let width = orientation == .horizontal
                ? proxy.size.width * clampedProgress
                : lineWidth
            let height = orientation == .vertical
                ? proxy.size.height * clampedProgress
                : lineWidth
            Capsule()
                .frame(width: width, height: height)
                .position(x: width / 2, y: height / 2)
        }
    }
}

private struct HUDActivityIndicatorView: View {
    let dotDiameter: CGFloat
    let spacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let opacities = HUDMotionPolicy.thinkingDotOpacities(
                elapsed: elapsed,
                reduceMotion: reduceMotion
            )
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: dotDiameter, height: dotDiameter)
                        .opacity(opacities[index])
                }
            }
            .opacity(HUDMotionPolicy.thinkingGroupOpacity(
                elapsed: elapsed,
                reduceMotion: reduceMotion
            ))
        }
    }
}
