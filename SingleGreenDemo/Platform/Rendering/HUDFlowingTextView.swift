import StreamingTextKit
import SingleGreenGlassesKit
import SwiftUI
import UIKit

/// AI 回答专用视口：保持固定可读字号，内容溢出后自动跟随尾部。
struct HUDFlowingTextView: View {
    let text: String
    let textRuns: [HUDTextRun]?
    let isStreaming: Bool
    let footer: String?
    let font: Font
    let cursorColor: Color
    let visibleLineCount: Int?
    let lineHeight: CGFloat?
    let platformFont: UIFont?
    let usesCompleteLineTail: Bool
    let alignsCompleteLinesToTop: Bool
    let completeLineFocusUTF16Offset: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var cursorStartedAt = Date()
    private let tailID = "hud_flowing_text_tail"

    var body: some View {
        GeometryReader { container in
            let viewportHeight = usesCompleteLineTail
                ? HUDFlowingTextViewportPolicy.completeLineViewportHeight(
                    availableHeight: container.size.height,
                    lineHeight: lineHeight ?? 0,
                    maximumLineCount: visibleLineCount
                )
                : HUDFlowingTextViewportPolicy.viewportHeight(
                    availableHeight: container.size.height,
                    visibleLineCount: visibleLineCount,
                    lineHeight: lineHeight
                )
            let completeLineCount = lineHeight.map {
                Int(floor(viewportHeight / max($0, 1)))
            } ?? 0
            let selection = if usesCompleteLineTail,
                               completeLineCount > 0,
                               let platformFont {
                HUDCompleteLineTextPolicy.visibleSelection(
                    text,
                    width: container.size.width,
                    font: platformFont,
                    maximumLineCount: completeLineCount,
                    maximumHeight: viewportHeight,
                    alignsToTop: alignsCompleteLinesToTop,
                    focusUTF16Offset: completeLineFocusUTF16Offset
                )
            } else {
                HUDCompleteLineTextSelection(
                    text: text,
                    utf16Range: NSRange(location: 0, length: (text as NSString).length)
                )
            }
            let selectedRuns: [HUDTextRun]? = if usesCompleteLineTail,
                                                   let completeLineFocusUTF16Offset,
                                                   selection.lineUTF16Ranges.count == 3 {
                HUDTeleprompterLineRunPolicy.visibleRuns(
                    fullText: text,
                    selectedLineUTF16Ranges: selection.lineUTF16Ranges,
                    focusUTF16Offset: completeLineFocusUTF16Offset
                )
            } else {
                textRuns.map {
                    HUDTextRunSelectionPolicy.visibleRuns(
                        $0,
                        fullText: text,
                        selectedUTF16Range: selection.utf16Range
                    )
                }
            }

            Group {
                if (visibleLineCount != nil || usesCompleteLineTail), footer == nil {
                    fixedLineViewport(
                        text: selection.text,
                        runs: selectedRuns,
                        width: container.size.width,
                        height: viewportHeight,
                        alignsToTop: alignsCompleteLinesToTop,
                        transitionID: selection.utf16Range.location
                    )
                } else {
                    scrollableViewport(
                        text: selection.text,
                        runs: selectedRuns,
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

    private func flowingText(
        _ value: String,
        runs: [HUDTextRun]?,
        cursorOpacity: Double,
        showsCursor: Bool
    ) -> Text {
        let cursor = isStreaming && showsCursor
            ? Text(" ▌").foregroundColor(cursorColor.opacity(cursorOpacity))
            : Text("")
        let content = runs?.reduce(Text("")) { result, run in
            let fragment = Text(run.text)
                .foregroundColor(cursorColor.opacity(run.opacity))
            return Text("\(result)\(fragment)")
        } ?? Text(value)
        return Text("\(content)\(cursor)")
    }

    private func flowingContent(
        _ value: String,
        runs: [HUDTextRun]?,
        showsCursor: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: footer == nil ? 0 : 8) {
            TimelineView(.animation(
                minimumInterval: 1.0 / 30.0,
                paused: !isStreaming || reduceMotion
            )) { timeline in
                let elapsed = max(
                    0,
                    timeline.date.timeIntervalSince(cursorStartedAt)
                )
                flowingText(
                    value,
                    runs: runs,
                    cursorOpacity: HUDMotionPolicy.cursorOpacity(
                        elapsed: elapsed,
                        reduceMotion: reduceMotion
                    ),
                    showsCursor: showsCursor
                )
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

    private func fixedLineViewport(
        text: String,
        runs: [HUDTextRun]?,
        width: CGFloat,
        height: CGFloat,
        alignsToTop: Bool,
        transitionID: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            flowingContent(text, runs: runs, showsCursor: false)
                .frame(width: width, alignment: .topLeading)
                .id(transitionID)
                .transition(
                    reduceMotion
                        ? .identity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                )
        }
        .frame(
            width: width,
            height: height,
            alignment: alignsToTop ? .topLeading : .bottomLeading
        )
        .clipped()
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: HUDFlowingTextViewportPolicy.teleprompterFollowAnimationDuration),
            value: transitionID
        )
    }

    private func scrollableViewport(
        text: String,
        runs: [HUDTextRun]?,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                flowingContent(text, runs: runs, showsCursor: true)
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
    static let teleprompterVisibleLineCount = 3
    static let answerOverflowAnimationDuration: TimeInterval = 0.30
    static let teleprompterFollowAnimationDuration: TimeInterval = 0.18

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

    static func completeLineViewportHeight(
        availableHeight: CGFloat,
        lineHeight: CGFloat,
        maximumLineCount: Int? = nil
    ) -> CGFloat {
        guard availableHeight > 0, lineHeight > 0 else { return 0 }
        let measuredHeight = floor(availableHeight / lineHeight) * lineHeight
        guard let maximumLineCount, maximumLineCount > 0 else { return measuredHeight }
        return min(measuredHeight, CGFloat(maximumLineCount) * lineHeight)
    }

    static func usesCompleteLineTail(sceneID: String, elementID: String) -> Bool {
        (sceneID == "text_adventure.green_signal" && elementID == "game_body")
            || (sceneID == "teleprompter.asr" && elementID == "teleprompter_body")
    }

    static func alignsCompleteLinesToTop(sceneID: String, elementID: String) -> Bool {
        sceneID == "teleprompter.asr" && elementID == "teleprompter_body"
    }

    static func completeLineFocusUTF16Offset(
        text: String,
        sceneID: String,
        elementID: String
    ) -> Int? {
        guard sceneID == "teleprompter.asr",
              elementID == "teleprompter_body" else { return nil }
        let firstParagraphBreak = (text as NSString).range(of: "\n")
        guard firstParagraphBreak.location != NSNotFound else { return 0 }
        return NSMaxRange(firstParagraphBreak)
    }

    static func completeLineFocusUTF16Offset(
        runs: [HUDTextRun],
        sceneID: String,
        elementID: String
    ) -> Int? {
        guard sceneID == "teleprompter.asr",
              elementID == "teleprompter_body" else { return nil }
        var offset = 0
        for run in runs {
            if run.isFocused { return offset }
            offset += (run.text as NSString).length
        }
        return nil
    }
}

/// Uses the same UIKit font metrics as the HUD renderer to select only whole
/// TextKit line fragments before SwiftUI draws them. Ranges are converted back
/// through `String.Index`, preserving composed grapheme boundaries.
struct HUDCompleteLineTextSelection: Equatable {
    let text: String
    let utf16Range: NSRange
    let lineUTF16Ranges: [NSRange]

    init(
        text: String,
        utf16Range: NSRange,
        lineUTF16Ranges: [NSRange] = []
    ) {
        self.text = text
        self.utf16Range = utf16Range
        self.lineUTF16Ranges = lineUTF16Ranges
    }
}

enum HUDCompleteLineTextPolicy {
    static func visibleText(
        _ text: String,
        width: CGFloat,
        font: UIFont,
        maximumLineCount: Int,
        maximumHeight: CGFloat? = nil,
        alignsToTop: Bool,
        focusUTF16Offset: Int? = nil
    ) -> String {
        visibleSelection(
            text,
            width: width,
            font: font,
            maximumLineCount: maximumLineCount,
            maximumHeight: maximumHeight,
            alignsToTop: alignsToTop,
            focusUTF16Offset: focusUTF16Offset
        ).text
    }

    static func visibleSelection(
        _ text: String,
        width: CGFloat,
        font: UIFont,
        maximumLineCount: Int,
        maximumHeight: CGFloat? = nil,
        alignsToTop: Bool,
        focusUTF16Offset: Int? = nil
    ) -> HUDCompleteLineTextSelection {
        let empty = HUDCompleteLineTextSelection(
            text: "",
            utf16Range: NSRange(location: 0, length: 0)
        )
        guard !text.isEmpty, width > 0, maximumLineCount > 0 else { return empty }

        let storage = NSTextStorage(
            attributedString: NSAttributedString(string: text, attributes: [.font: font])
        )
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var lineFragments: [LineFragment] = []
        let glyphRange = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, lineGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            if characterRange.length > 0 {
                lineFragments.append(LineFragment(range: characterRange, usedRect: usedRect))
            }
        }
        guard !lineFragments.isEmpty else {
            let range = NSRange(location: 0, length: (text as NSString).length)
            return HUDCompleteLineTextSelection(
                text: text,
                utf16Range: range,
                lineUTF16Ranges: [range]
            )
        }

        let count = min(maximumLineCount, lineFragments.count)
        var selectedRange: Range<Int>
        if let focusUTF16Offset,
           let focusLine = focusLineIndex(
               utf16Offset: focusUTF16Offset,
               lineFragments: lineFragments
           ) {
            var start = max(0, focusLine - count / 2)
            var end = min(lineFragments.count, start + count)
            start = max(0, end - count)
            end = min(lineFragments.count, start + count)
            selectedRange = start..<end
        } else if alignsToTop {
            selectedRange = 0..<count
        } else {
            selectedRange = (lineFragments.count - count)..<lineFragments.count
        }

        if let maximumHeight, maximumHeight > 0 {
            selectedRange = rangeFittingHeight(
                selectedRange,
                focusLine: focusUTF16Offset.flatMap {
                    focusLineIndex(
                        utf16Offset: $0,
                        lineFragments: lineFragments
                    )
                },
                lineFragments: lineFragments,
                maximumHeight: maximumHeight
            )
        }

        guard let firstIndex = selectedRange.first,
              let lastIndex = selectedRange.last else { return empty }
        let first = lineFragments[firstIndex].range
        let last = lineFragments[lastIndex].range
        let aggregate = NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )
        guard let range = Range(aggregate, in: text) else { return empty }
        return HUDCompleteLineTextSelection(
            text: String(text[range]),
            utf16Range: aggregate,
            lineUTF16Ranges: selectedRange.map { lineFragments[$0].range }
        )
    }

    private static func focusLineIndex(
        utf16Offset: Int,
        lineFragments: [LineFragment]
    ) -> Int? {
        return lineFragments.firstIndex {
            utf16Offset >= $0.range.location && utf16Offset < NSMaxRange($0.range)
        }
    }

    private static func rangeFittingHeight(
        _ proposed: Range<Int>,
        focusLine: Int?,
        lineFragments: [LineFragment],
        maximumHeight: CGFloat
    ) -> Range<Int> {
        var start = proposed.lowerBound
        var end = proposed.upperBound
        while start < end,
              measuredHeight(
                  of: start..<end,
                  lineFragments: lineFragments
              ) > maximumHeight {
            guard end - start > 1 else { return start..<start }
            if let focusLine {
                let leadingDistance = focusLine - start
                let trailingDistance = (end - 1) - focusLine
                if trailingDistance >= leadingDistance {
                    end -= 1
                } else {
                    start += 1
                }
            } else {
                start += 1
            }
        }
        return start..<end
    }

    private static func measuredHeight(
        of range: Range<Int>,
        lineFragments: [LineFragment]
    ) -> CGFloat {
        guard let first = range.first, let last = range.last else { return 0 }
        return lineFragments[last].usedRect.maxY - lineFragments[first].usedRect.minY
    }

    private struct LineFragment {
        let range: NSRange
        let usedRect: CGRect
    }
}

/// The teleprompter is a semantic three-line window: the complete line before
/// the ASR focus is read, the focus line is current, and the following line is
/// unread. Coloring measured TextKit line fragments here prevents a long
/// sentence from consuming two bright "current" rows.
enum HUDTeleprompterLineRunPolicy {
    static func visibleRuns(
        fullText: String,
        selectedLineUTF16Ranges: [NSRange],
        focusUTF16Offset: Int
    ) -> [HUDTextRun] {
        guard selectedLineUTF16Ranges.count == 3 else { return [] }
        let focusLineIndex = selectedLineUTF16Ranges.firstIndex {
            focusUTF16Offset >= $0.location
                && focusUTF16Offset < NSMaxRange($0)
        } ?? 1

        return selectedLineUTF16Ranges.enumerated().compactMap { index, lineRange in
            guard let range = Range(lineRange, in: fullText) else { return nil }
            let opacity = if index < focusLineIndex {
                0.32
            } else if index == focusLineIndex {
                1.0
            } else {
                0.68
            }
            return HUDTextRun(
                text: String(fullText[range]),
                opacity: opacity,
                isFocused: index == focusLineIndex
            )
        }
    }
}

/// Slices semantic text runs by the same UTF-16 range selected by TextKit so
/// complete-line clipping keeps the intended read/current/unread contrast.
enum HUDTextRunSelectionPolicy {
    static func visibleRuns(
        _ runs: [HUDTextRun],
        fullText: String,
        selectedUTF16Range: NSRange
    ) -> [HUDTextRun] {
        guard selectedUTF16Range.location != NSNotFound,
              selectedUTF16Range.length > 0,
              let selectedRange = Range(selectedUTF16Range, in: fullText) else { return [] }
        let fallback = [HUDTextRun(text: String(fullText[selectedRange]))]
        guard runs.map(\.text).joined() == fullText else { return fallback }

        let selectedEnd = NSMaxRange(selectedUTF16Range)
        var offset = 0
        let selectedRuns: [HUDTextRun] = runs.compactMap { run -> HUDTextRun? in
            let runLength = (run.text as NSString).length
            defer { offset += runLength }
            let start = max(offset, selectedUTF16Range.location)
            let end = min(offset + runLength, selectedEnd)
            guard start < end else { return nil }
            let intersection = NSRange(location: start, length: end - start)
            guard let range = Range(intersection, in: fullText) else { return nil }
            return HUDTextRun(
                text: String(fullText[range]),
                opacity: run.opacity,
                isFocused: run.isFocused
            )
        }
        return selectedRuns.map { $0.text }.joined() == fallback[0].text
            ? selectedRuns
            : fallback
    }
}

private struct HUDFlowingTextContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
