import SwiftUI

struct DisplayProfile: Equatable, Sendable {
    let id: String
    let displayName: String
    let viewport: NormalizedRect
    let safeArea: NormalizedInsets
    let red: Double
    let green: Double
    let blue: Double
    let textScale: Double
    let lineScale: Double

    var tintColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    static let simulatorDefault = DisplayProfile(
        id: "simulator.default.v1",
        displayName: "默认单绿",
        viewport: NormalizedRect(x: 0.08, y: 0.12, width: 0.84, height: 0.60),
        safeArea: NormalizedInsets(horizontal: 0.08, vertical: 0.10),
        red: 109.0 / 255.0,
        green: 1.0,
        blue: 135.0 / 255.0,
        textScale: 1.0,
        lineScale: 1.0
    )
}

@MainActor
final class DisplayProfileStore: ObservableObject {
    @Published var activeProfile: DisplayProfile = .simulatorDefault
    @Published var intensity = 0.85
    @Published var hudEnabled = true
}
