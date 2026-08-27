import Foundation

enum DemoEvent: Equatable, Sendable {
    case tap
    case swipeUp
    case swipeDown
    case triggerAlert
    case tick(Date)
    case reset

    var debugName: String {
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

enum ExperienceKind: String, CaseIterable, Identifiable, Sendable {
    case conversation
    case systemStatus
    case navigation
    case notification
    case caption

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conversation: "AI 对话"
        case .systemStatus: "状态"
        case .navigation: "导航"
        case .notification: "通知"
        case .caption: "字幕 / 提词"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "waveform.circle"
        case .systemStatus: "gauge.with.dots.needle.33percent"
        case .navigation: "location.north.line"
        case .notification: "bell"
        case .caption: "captions.bubble"
        }
    }
}
