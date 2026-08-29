import CoreGraphics
import SingleGreenGlassesKit
import SwiftUI

enum DisplayProfileCatalogError: Error, Equatable {
    case emptyCatalog
    case duplicateIdentifier(String)
    case missingDefaultProfile(String)
    case unknownProfile(String)
}

struct DisplayProfileCatalog {
    let profiles: [DisplayProfile]
    let defaultProfileID: String

    var defaultProfile: DisplayProfile {
        guard let profile = profiles.first(where: { $0.id == defaultProfileID }) else {
            preconditionFailure("A validated display profile catalog must contain its default profile")
        }
        return profile
    }

    init(profiles: [DisplayProfile], defaultProfileID: String) throws {
        guard !profiles.isEmpty else {
            throw DisplayProfileCatalogError.emptyCatalog
        }

        var identifiers = Set<String>()
        for profile in profiles where !identifiers.insert(profile.id).inserted {
            throw DisplayProfileCatalogError.duplicateIdentifier(profile.id)
        }

        guard profiles.contains(where: { $0.id == defaultProfileID }) else {
            throw DisplayProfileCatalogError.missingDefaultProfile(defaultProfileID)
        }

        self.profiles = profiles
        self.defaultProfileID = defaultProfileID
    }

    func profile(id: String) throws -> DisplayProfile {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw DisplayProfileCatalogError.unknownProfile(id)
        }
        return profile
    }

    static let builtIn: DisplayProfileCatalog = {
        do {
            let simulatorDefault = try DisplayProfile(
                id: "simulator.default.v2",
                displayName: "默认单绿",
                visibleAspectRatio: 8.0 / 3.0,
                surfaceWidthFraction: 0.90,
                alignment: .center,
                verticalOffsetFraction: -0.20,
                viewport: NormalizedRect(x: 0.08, y: 0.12, width: 0.84, height: 0.60),
                safeArea: NormalizedEdgeInsets(
                    top: 0.10,
                    leading: 0.08,
                    bottom: 0.10,
                    trailing: 0.08
                ),
                textScale: 1.0,
                lineScale: 1.0,
                color: DisplayColorComponents(
                    red: 109.0 / 255.0,
                    green: 1.0,
                    blue: 135.0 / 255.0
                )
            )
            let calibrationFixture = try DisplayProfile(
                id: "calibration.fixture.non-production.v1",
                displayName: "标定测试（非生产）",
                visibleAspectRatio: 2.0,
                surfaceWidthFraction: 0.72,
                alignment: .topLeading,
                verticalOffsetFraction: 0.08,
                viewport: NormalizedRect(x: 0.10, y: 0.08, width: 0.76, height: 0.70),
                safeArea: NormalizedEdgeInsets(
                    top: 0.05,
                    leading: 0.12,
                    bottom: 0.17,
                    trailing: 0.06
                ),
                textScale: 0.90,
                lineScale: 1.40,
                color: DisplayColorComponents(red: 0.20, green: 0.80, blue: 0.40)
            )
            return try DisplayProfileCatalog(
                profiles: [simulatorDefault, calibrationFixture],
                defaultProfileID: simulatorDefault.id
            )
        } catch {
            preconditionFailure("Built-in display profile catalog is invalid: \(error)")
        }
    }()
}

@MainActor
final class DisplayProfileStore: ObservableObject {
    let catalog: DisplayProfileCatalog
    @Published private(set) var activeProfile: DisplayProfile
    @Published var intensity: Double
    @Published var hudEnabled: Bool

    var activeProfileID: String { activeProfile.id }

    init() {
        let catalog = DisplayProfileCatalog.builtIn
        self.catalog = catalog
        activeProfile = catalog.defaultProfile
        intensity = 0.85
        hudEnabled = true
    }

    init(
        catalog: DisplayProfileCatalog,
        activeProfileID: String,
        intensity: Double = 0.85,
        hudEnabled: Bool = true
    ) throws {
        self.catalog = catalog
        activeProfile = try catalog.profile(id: activeProfileID)
        self.intensity = intensity
        self.hudEnabled = hudEnabled
    }

    func selectProfile(id: String) throws {
        activeProfile = try catalog.profile(id: id)
    }
}

struct HUDPreviewProjection {
    let surfaceWidthFraction: Double
    let containerAspectRatio: Double
    let alignment: Alignment
    let verticalOffsetFraction: Double

    init(profile: DisplayProfile) {
        surfaceWidthFraction = profile.surfaceWidthFraction
        containerAspectRatio = profile.presentationContainerAspectRatio
        alignment = profile.alignment.swiftUIAlignment
        verticalOffsetFraction = profile.verticalOffsetFraction
    }

    func surfaceSize(in containerSize: CGSize) -> CGSize {
        let width = containerSize.width * surfaceWidthFraction
        return CGSize(width: width, height: width / containerAspectRatio)
    }

    func verticalOffset(in containerSize: CGSize) -> CGFloat {
        containerSize.height * verticalOffsetFraction
    }
}

extension DisplayAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }
}

extension DisplayProfile {
    var tintColor: Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}

extension NormalizedRect {
    func rect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + bounds.width * x,
            y: bounds.minY + bounds.height * y,
            width: bounds.width * width,
            height: bounds.height * height
        )
    }
}

extension NormalizedEdgeInsets {
    func inset(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * leading,
            y: rect.minY + rect.height * top,
            width: rect.width * (1 - leading - trailing),
            height: rect.height * (1 - top - bottom)
        )
    }
}
