import StreamingTextKit
import SwiftUI

/// AI 回答专用视口：保持固定可读字号，内容溢出后自动跟随尾部。
struct HUDFlowingTextView: View {
    let text: String
    let isStreaming: Bool
    let footer: String?
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    private let tailID = "hud_flowing_text_tail"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(text)\(isStreaming ? " ▌" : "")")
                            .font(font)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let footer, !footer.isEmpty {
                            Text(footer)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .opacity(0.85)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(tailID)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: HUDFlowingTextContentHeightKey.self,
                                value: content.size.height
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onPreferenceChange(HUDFlowingTextContentHeightKey.self) { newHeight in
                    let shouldFollow = StreamingTextAutoFollowPolicy.shouldFollow(
                        previousContentHeight: contentHeight,
                        newContentHeight: newHeight,
                        viewportHeight: viewport.size.height
                    )
                    contentHeight = newHeight
                    if shouldFollow { followTail(proxy) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHidden(isStreaming)
    }

    private var accessibilityText: String {
        [text, footer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "。")
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

private struct HUDFlowingTextContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
