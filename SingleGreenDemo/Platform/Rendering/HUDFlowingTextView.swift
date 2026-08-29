import StreamingTextKit
import SwiftUI

/// AI 回答专用视口：保持固定可读字号，内容溢出后自动跟随尾部。
struct HUDFlowingTextView: View {
    let text: String
    let isStreaming: Bool
    let footer: String?
    let font: Font
    let cursorColor: Color
    let visibleLineCount: Int?
    let lineHeight: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var cursorStartedAt = Date()
    private let tailID = "hud_flowing_text_tail"

    var body: some View {
        GeometryReader { container in
            let viewportHeight = HUDFlowingTextViewportPolicy.viewportHeight(
                availableHeight: container.size.height,
                visibleLineCount: visibleLineCount,
                lineHeight: lineHeight
            )

            Group {
                if visibleLineCount != nil, footer == nil {
                    fixedLineViewport(
                        width: container.size.width,
                        height: viewportHeight
                    )
                } else {
                    scrollableViewport(
                        width: container.size.width,
                        height: viewportHeight
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHidden(isStreaming)
    }

    private var accessibilityText: String {
        [text, footer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "。")
    }

    private func flowingText(cursorOpacity: Double) -> Text {
        let cursor = isStreaming
            ? Text(" ▌").foregroundColor(cursorColor.opacity(cursorOpacity))
            : Text("")
        return Text("\(Text(text))\(cursor)")
    }

    private var flowingContent: some View {
        VStack(alignment: .leading, spacing: footer == nil ? 0 : 8) {
            TimelineView(.animation(
                minimumInterval: 1.0 / 30.0,
                paused: !isStreaming || reduceMotion
            )) { timeline in
                let elapsed = max(
                    0,
                    timeline.date.timeIntervalSince(cursorStartedAt)
                )
                flowingText(cursorOpacity: HUDMotionPolicy.cursorOpacity(
                    elapsed: elapsed,
                    reduceMotion: reduceMotion
                ))
                .font(font)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .opacity(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { content in
                Color.clear.preference(
                    key: HUDFlowingTextContentHeightKey.self,
                    value: content.size.height
                )
            }
        }
    }

    private func fixedLineViewport(width: CGFloat, height: CGFloat) -> some View {
        flowingContent
            .frame(width: width, alignment: .topLeading)
            .frame(width: width, height: height, alignment: .bottomLeading)
            .clipped()
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: HUDFlowingTextViewportPolicy.answerOverflowAnimationDuration),
                value: text
            )
    }

    private func scrollableViewport(width: CGFloat, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                flowingContent
                    .overlay(alignment: .bottom) {
                        Color.clear
                            .frame(height: 1)
                            .id(tailID)
                    }
            }
            .scrollIndicators(.hidden)
            .onPreferenceChange(HUDFlowingTextContentHeightKey.self) { newHeight in
                let shouldFollow = StreamingTextAutoFollowPolicy.shouldFollow(
                    previousContentHeight: contentHeight,
                    newContentHeight: newHeight,
                    viewportHeight: height
                )
                contentHeight = newHeight
                if shouldFollow { followTail(proxy) }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    private func followTail(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(tailID, anchor: .bottom)
        } else {
            withAnimation(.linear(duration: 0.08)) {
                proxy.scrollTo(tailID, anchor: .bottom)
            }
        }
    }
}

enum HUDFlowingTextViewportPolicy {
    static let answerVisibleLineCount = 2
    static let answerOverflowAnimationDuration: TimeInterval = 0.30

    static func viewportHeight(
        availableHeight: CGFloat,
        visibleLineCount: Int?,
        lineHeight: CGFloat?
    ) -> CGFloat {
        guard let visibleLineCount,
              visibleLineCount > 0,
              let lineHeight,
              lineHeight > 0 else {
            return max(availableHeight, 0)
        }
        return min(
            max(availableHeight, 0),
            CGFloat(visibleLineCount) * lineHeight
        )
    }
}

private struct HUDFlowingTextContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
