import Foundation

public enum PresentationMode: String, Equatable, Sendable {
    case compact
    case focused
    case alert
    case result
}

public enum HUDTextStyle: Equatable, Sendable {
    case title
    case answer
    case value
    case detail
    case caption
    case question
}

public enum HUDContentAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

public enum HUDRuleOrientation: Equatable, Sendable {
    case horizontal
    case vertical
}

public enum HUDSemanticRole: Equatable, Sendable {
    case content
    case status
    case decorative
}

/// A provider-neutral text fragment whose opacity can express reading state
/// without coupling the HUD scene model to SwiftUI attributed strings.
public struct HUDTextRun: Equatable, Sendable {
    public let text: String
    public let opacity: Double
    public let isFocused: Bool

    public init(text: String, opacity: Double = 1, isFocused: Bool = false) {
        self.text = text
        self.opacity = min(max(opacity, 0), 1)
        self.isFocused = isFocused
    }
}

public enum HUDElementContent: Equatable, Sendable {
    case text(String, HUDTextStyle)
    case flowingText(String, isStreaming: Bool, footer: String?)
    case styledFlowingText(String, isStreaming: Bool, footer: String?, style: HUDTextStyle)
    case styledFlowingTextRuns([HUDTextRun], isStreaming: Bool, footer: String?, style: HUDTextStyle)
    case symbol(String)
    case voiceWaveform(level: Double, isActive: Bool)
    case progress(Double)
    case rule(HUDRuleOrientation, progress: Double)
    case activityIndicator
}

public struct HUDElement: Identifiable, Equatable, Sendable {
    public let id: String
    public let frame: NormalizedRect
    public let content: HUDElementContent
    public let opacity: Double
    public let scale: Double
    public let alignment: HUDContentAlignment
    public let semanticRole: HUDSemanticRole

    public init(
        id: String,
        frame: NormalizedRect,
        content: HUDElementContent
    ) {
        self.init(
            id: id,
            frame: frame,
            content: content,
            opacity: 1,
            semanticRole: .content
        )
    }

    public init(
        id: String,
        frame: NormalizedRect,
        content: HUDElementContent,
        opacity: Double,
        scale: Double = 1,
        alignment: HUDContentAlignment = .center,
        semanticRole: HUDSemanticRole = .content
    ) {
        self.id = id
        self.frame = frame
        self.content = content
        self.opacity = min(max(opacity, 0), 1)
        self.scale = max(scale, 0)
        self.alignment = alignment
        self.semanticRole = semanticRole
    }
}

public struct HUDScene: Equatable, Sendable {
    public let sceneID: String
    public let revision: Int
    public let presentation: PresentationMode
    public let elements: [HUDElement]

    public init(
        sceneID: String,
        revision: Int,
        presentation: PresentationMode,
        elements: [HUDElement]
    ) {
        self.sceneID = sceneID
        self.revision = revision
        self.presentation = presentation
        self.elements = elements
    }
}
