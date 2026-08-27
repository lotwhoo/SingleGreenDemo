import CoreGraphics

/// 仅当内容形成新视觉高度且溢出视口时跟随尾部。
public enum StreamingTextAutoFollowPolicy {
    public static func shouldFollow(
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat,
        viewportHeight: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        newContentHeight > viewportHeight + tolerance
            && newContentHeight > previousContentHeight + tolerance
    }
}
