import Foundation

public enum PresentationMode: String, Equatable, Sendable {
    case compact
    case focused
    case alert
    case result
}

public enum HUDTextStyle: Equatable, Sendable {
    case title
    case value
    case detail
}

public enum HUDElementContent: Equatable, Sendable {
    case text(String, HUDTextStyle)
    case flowingText(String, isStreaming: Bool, footer: String?)
    case symbol(String)
    case progress(Double)
}

public struct HUDElement: Identifiable, Equatable, Sendable {
    public let id: String
    public let frame: NormalizedRect
    public let content: HUDElementContent

    public init(id: String, frame: NormalizedRect, content: HUDElementContent) {
        self.id = id
        self.frame = frame
        self.content = content
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
