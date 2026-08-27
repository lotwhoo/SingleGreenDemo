import Foundation

enum PresentationMode: String, Equatable, Sendable {
    case compact
    case focused
    case alert
    case result
}

enum HUDTextStyle: Equatable, Sendable {
    case title
    case value
    case detail
}

enum HUDElementContent: Equatable, Sendable {
    case text(String, HUDTextStyle)
    case symbol(String)
    case progress(Double)
}

struct HUDElement: Identifiable, Equatable, Sendable {
    let id: String
    let frame: NormalizedRect
    let content: HUDElementContent
}

struct HUDScene: Equatable, Sendable {
    let sceneID: String
    let revision: Int
    let presentation: PresentationMode
    let elements: [HUDElement]
}
