import Foundation
import SingleGreenGlassesKit
import SwiftUI
import UIKit

/// The teleprompter has its own rendering surface so its typography, color
/// depth, line count, and motion can evolve without adding feature branches to
/// the shared HUD renderer.
struct TeleprompterHUDView: View {
    let scene: HUDScene
    let profile: DisplayProfile
    let intensity: Double
    let showsSafeArea: Bool
    let tuning: TeleprompterHUDTuning

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        scene: HUDScene,
        profile: DisplayProfile,
        intensity: Double,
        showsSafeArea: Bool,
        tuning: TeleprompterHUDTuning = .standard
    ) {
        self.scene = scene
        self.profile = profile
        self.intensity = intensity
        self.showsSafeArea = showsSafeArea
        self.tuning = tuning
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let viewport = profile.viewport.rect(in: bounds)
            let safeRect = profile.safeArea.inset(viewport)

            ZStack {
                if showsSafeArea {
                    safeAreaOutline(safeRect)
                }

                ForEach(scene.elements) { element in
                    let rect = element.frame.rect(in: safeRect)
                    elementView(element)
                        .frame(
                            width: rect.width,
                            height: rect.height,
                            alignment: alignment(for: element.alignment)
                        )
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(element.opacity)
                        .scaleEffect(element.scale)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: TeleprompterHUDStyle.contentTransitionDuration),
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
                color: profile.tintColor.opacity(
                    tuning.glowOpacity * intensity
                ),
                radius: tuning.glowRadius
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func safeAreaOutline(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(
                profile.tintColor.opacity(0.72),
                style: StrokeStyle(
                    lineWidth: max(1, profile.lineScale),
                    dash: [5, 4]
                )
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func elementView(_ element: HUDElement) -> some View {
        switch element.content {
        case let .text(value, style):
            Text(value)
                .font(Font(TeleprompterHUDStyle.uiFont(
                    for: style,
                    textScale: profile.textScale
                )))
                .minimumScaleFactor(TeleprompterHUDStyle.minimumTextScaleFactor)
                .lineLimit(TeleprompterHUDStyle.lineLimit(for: style))
                .multilineTextAlignment(textAlignment(for: element.alignment))
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: alignment(for: element.alignment)
                )
                .contentTransition(.opacity)

        case let .styledFlowingText(value, isStreaming, footer, _):
            flowingBody(
                text: value,
                runs: nil,
                isStreaming: isStreaming,
                footer: footer,
                focusUTF16Offset: TeleprompterHUDStyle.focusUTF16Offset(in: value)
            )

        case let .styledFlowingTextRuns(runs, isStreaming, footer, _):
            flowingBody(
                text: runs.map(\.text).joined(),
                runs: runs,
                isStreaming: isStreaming,
                footer: footer,
                focusUTF16Offset: TeleprompterHUDStyle.focusUTF16Offset(in: runs)
            )

        default:
            EmptyView()
        }
    }

    private func flowingBody(
        text: String,
        runs: [HUDTextRun]?,
        isStreaming: Bool,
        footer: String?,
        focusUTF16Offset: Int?
    ) -> some View {
        let platformFont = TeleprompterHUDStyle.bodyUIFont(
            textScale: profile.textScale,
            fontSize: tuning.bodyFontSize
        )
        return HUDFlowingTextView(
            text: text,
            textRuns: runs,
            isStreaming: isStreaming,
            footer: footer,
            font: Font(platformFont),
            cursorColor: profile.tintColor.opacity(intensity),
            visibleLineCount: TeleprompterHUDStyle.visibleLineCount,
            lineHeight: platformFont.lineHeight,
            platformFont: platformFont,
            usesCompleteLineTail: true,
            alignsCompleteLinesToTop: true,
            completeLineFocusUTF16Offset: focusUTF16Offset,
            completeLineTransitionDuration: tuning.followAnimationDuration,
            completeLineRunResolver: { fullText, lineRanges, focusOffset in
                HUDTeleprompterLineRunPolicy.visibleRuns(
                    fullText: fullText,
                    selectedLineUTF16Ranges: lineRanges,
                    focusUTF16Offset: focusOffset,
                    tuning: tuning
                )
            }
        )
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
}

struct TeleprompterHUDTuning: Equatable {
    var bodyFontSize: CGFloat
    var readOpacity: Double
    var currentOpacity: Double
    var unreadOpacity: Double
    var followAnimationDuration: TimeInterval
    var glowOpacity: Double
    var glowRadius: CGFloat

    static let standard = TeleprompterHUDTuning(
        bodyFontSize: 14,
        readOpacity: 0.32,
        currentOpacity: 1,
        unreadOpacity: 0.68,
        followAnimationDuration: 0.18,
        glowOpacity: 0.16,
        glowRadius: 3
    )
}

/// Visual tuning values for the teleprompter. Keep UI experiments here; the
/// parser, ASR alignment, and experience state machine should not depend on it.
enum TeleprompterHUDStyle {
    static let sceneID = "teleprompter.asr"
    static let visibleLineCount = 3
    static let bodyFontSize = TeleprompterHUDTuning.standard.bodyFontSize
    static let readOpacity = TeleprompterHUDTuning.standard.readOpacity
    static let currentOpacity = TeleprompterHUDTuning.standard.currentOpacity
    static let unreadOpacity = TeleprompterHUDTuning.standard.unreadOpacity
    static let minimumTextScaleFactor = 0.62
    static let followAnimationDuration = TeleprompterHUDTuning.standard.followAnimationDuration
    static let contentTransitionDuration: TimeInterval = 0.12
    static let glowOpacity = TeleprompterHUDTuning.standard.glowOpacity
    static let glowRadius = TeleprompterHUDTuning.standard.glowRadius

    static func bodyUIFont(
        textScale: CGFloat,
        fontSize: CGFloat = bodyFontSize
    ) -> UIFont {
        roundedFont(
            size: fontSize * textScale,
            weight: .medium
        )
    }

    static func uiFont(for style: HUDTextStyle, textScale: CGFloat) -> UIFont {
        switch style {
        case .title:
            roundedFont(size: 22 * textScale, weight: .semibold)
        case .answer:
            roundedFont(size: 20 * textScale, weight: .semibold)
        case .value:
            roundedFont(size: 38 * textScale, weight: .bold)
        case .detail:
            roundedFont(size: 17 * textScale, weight: .medium)
        case .caption:
            roundedFont(size: 13.5 * textScale, weight: .semibold)
        case .question:
            roundedFont(size: 15.5 * textScale, weight: .medium)
        }
    }

    static func lineLimit(for style: HUDTextStyle) -> Int {
        switch style {
        case .detail, .question: 2
        case .title, .answer, .value, .caption: 1
        }
    }

    static func focusUTF16Offset(in text: String) -> Int {
        let firstParagraphBreak = (text as NSString).range(of: "\n")
        guard firstParagraphBreak.location != NSNotFound else { return 0 }
        return NSMaxRange(firstParagraphBreak)
    }

    static func focusUTF16Offset(in runs: [HUDTextRun]) -> Int? {
        var offset = 0
        for run in runs {
            if run.isFocused { return offset }
            offset += (run.text as NSString).length
        }
        return nil
    }

    private static func roundedFont(
        size: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        let systemDescriptor = UIFont.systemFont(
            ofSize: size,
            weight: weight
        ).fontDescriptor
        let descriptor = systemDescriptor.withDesign(.rounded) ?? systemDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Converts the three measured TextKit rows into read/current/unread visual
/// depth. A long sentence may wrap, so this is deliberately based on rendered
/// line fragments rather than source sentence boundaries.
enum HUDTeleprompterLineRunPolicy {
    static func visibleRuns(
        fullText: String,
        selectedLineUTF16Ranges: [NSRange],
        focusUTF16Offset: Int,
        tuning: TeleprompterHUDTuning = .standard
    ) -> [HUDTextRun] {
        guard selectedLineUTF16Ranges.count == TeleprompterHUDStyle.visibleLineCount else {
            return []
        }
        let focusLineIndex = selectedLineUTF16Ranges.firstIndex {
            focusUTF16Offset >= $0.location
                && focusUTF16Offset < NSMaxRange($0)
        } ?? 1

        return selectedLineUTF16Ranges.enumerated().compactMap { index, lineRange in
            guard let range = Range(lineRange, in: fullText) else { return nil }
            let opacity = if index < focusLineIndex {
                tuning.readOpacity
            } else if index == focusLineIndex {
                tuning.currentOpacity
            } else {
                tuning.unreadOpacity
            }
            return HUDTextRun(
                text: String(fullText[range]),
                opacity: opacity,
                isFocused: index == focusLineIndex
            )
        }
    }
}
