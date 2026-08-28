import Foundation

public enum DemoEvent: Equatable, Sendable {
    case tap
    case swipeUp
    case swipeDown
    case triggerAlert
    case tick(Date)
    case reset

    public var debugName: String {
        switch self {
        case .tap: "tap"
        case .swipeUp: "swipe_up"
        case .swipeDown: "swipe_down"
        case .triggerAlert: "trigger_alert"
        case .tick: "tick"
        case .reset: "reset"
        }
    }
}

/// Stable catalog identifiers use the case-sensitive ASCII grammar
/// `[A-Za-z0-9][A-Za-z0-9._-]*`. Values are never trimmed or normalized.
enum StableCatalogIdentifierGrammar {
    static func isCanonical(_ value: String) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first, isASCIILetterOrDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIILetterOrDigit($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}

public struct ExperienceKind: RawRepresentable, Hashable, Identifiable, CaseIterable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard StableCatalogIdentifierGrammar.isCanonical(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        precondition(
            StableCatalogIdentifierGrammar.isCanonical(rawValue),
            "ExperienceKind must use the stable ASCII identifier grammar"
        )
        self.rawValue = rawValue
    }

    private init(canonicalRawValue: String) {
        self.rawValue = canonicalRawValue
    }

    public var id: String { rawValue }

    public static let conversation = Self(canonicalRawValue: "conversation")
    public static let systemStatus = Self(canonicalRawValue: "systemStatus")
    public static let navigation = Self(canonicalRawValue: "navigation")
    public static let notification = Self(canonicalRawValue: "notification")
    public static let caption = Self(canonicalRawValue: "caption")

    /// Stable built-in order used by the catalog before extension registrations.
    public static let builtInCases: [Self] = [
        .conversation,
        .systemStatus,
        .navigation,
        .notification,
        .caption
    ]

    /// Compatibility alias for callers that previously enumerated the closed built-in enum.
    public static let allCases = builtInCases

    private static let builtInDisplayNames: [Self: String] = [
        .conversation: "AI 对话",
        .systemStatus: "状态",
        .navigation: "导航",
        .notification: "通知",
        .caption: "字幕 / 提词"
    ]

    private static let builtInSystemImages: [Self: String] = [
        .conversation: "waveform.circle",
        .systemStatus: "gauge.with.dots.needle.33percent",
        .navigation: "location.north.line",
        .notification: "bell",
        .caption: "captions.bubble"
    ]

    public var displayName: String {
        Self.builtInDisplayNames[self] ?? rawValue
    }

    public var systemImage: String {
        Self.builtInSystemImages[self] ?? "square.grid.2x2"
    }
}
