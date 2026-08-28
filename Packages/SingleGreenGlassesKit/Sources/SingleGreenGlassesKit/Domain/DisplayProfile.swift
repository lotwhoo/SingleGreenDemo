public enum DisplayAlignment: String, CaseIterable, Equatable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

public struct NormalizedEdgeInsets: Equatable, Sendable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public struct DisplayColorComponents: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum DisplayProfileField: String, Equatable, Sendable {
    case visibleAspectRatio
    case surfaceWidthFraction
    case verticalOffsetFraction
    case viewportX
    case viewportY
    case viewportWidth
    case viewportHeight
    case safeAreaTop
    case safeAreaLeading
    case safeAreaBottom
    case safeAreaTrailing
    case textScale
    case lineScale
    case red
    case green
    case blue
}

public enum DisplayProfileValidationError: Error, Equatable, Sendable {
    case blankIdentifier
    case blankDisplayName
    case nonFiniteValue(DisplayProfileField)
    case nonPositiveValue(DisplayProfileField)
    case surfaceWidthFractionOutOfRange
    case verticalOffsetFractionOutOfRange
    case invalidViewport
    case negativeSafeAreaEdge(DisplayProfileField)
    case invalidSafeAreaHorizontalSum
    case invalidSafeAreaVerticalSum
    case invalidPresentationContainerAspectRatio
    case colorComponentOutOfRange(DisplayProfileField)
}

public struct DisplayProfile: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let visibleAspectRatio: Double
    public let surfaceWidthFraction: Double
    public let alignment: DisplayAlignment
    public let verticalOffsetFraction: Double
    public let viewport: NormalizedRect
    public let safeArea: NormalizedEdgeInsets
    public let textScale: Double
    public let lineScale: Double
    public let color: DisplayColorComponents

    public var visibleWidthFraction: Double {
        Self.visibleWidthFraction(viewport: viewport, safeArea: safeArea)
    }

    public var visibleHeightFraction: Double {
        Self.visibleHeightFraction(viewport: viewport, safeArea: safeArea)
    }

    public var presentationContainerAspectRatio: Double {
        Self.presentationContainerAspectRatio(
            visibleAspectRatio: visibleAspectRatio,
            viewport: viewport,
            safeArea: safeArea
        )
    }

    public init(
        id: String,
        displayName: String,
        visibleAspectRatio: Double,
        surfaceWidthFraction: Double,
        alignment: DisplayAlignment,
        verticalOffsetFraction: Double,
        viewport: NormalizedRect,
        safeArea: NormalizedEdgeInsets,
        textScale: Double,
        lineScale: Double,
        color: DisplayColorComponents
    ) throws {
        guard !id.trimmed.isEmpty else {
            throw DisplayProfileValidationError.blankIdentifier
        }
        guard !displayName.trimmed.isEmpty else {
            throw DisplayProfileValidationError.blankDisplayName
        }

        let finiteValues: [(DisplayProfileField, Double)] = [
            (.visibleAspectRatio, visibleAspectRatio),
            (.surfaceWidthFraction, surfaceWidthFraction),
            (.verticalOffsetFraction, verticalOffsetFraction),
            (.viewportX, viewport.x),
            (.viewportY, viewport.y),
            (.viewportWidth, viewport.width),
            (.viewportHeight, viewport.height),
            (.safeAreaTop, safeArea.top),
            (.safeAreaLeading, safeArea.leading),
            (.safeAreaBottom, safeArea.bottom),
            (.safeAreaTrailing, safeArea.trailing),
            (.textScale, textScale),
            (.lineScale, lineScale),
            (.red, color.red),
            (.green, color.green),
            (.blue, color.blue)
        ]
        if let invalid = finiteValues.first(where: { !$0.1.isFinite }) {
            throw DisplayProfileValidationError.nonFiniteValue(invalid.0)
        }

        guard visibleAspectRatio > 0 else {
            throw DisplayProfileValidationError.nonPositiveValue(.visibleAspectRatio)
        }
        guard surfaceWidthFraction > 0, surfaceWidthFraction <= 1 else {
            throw DisplayProfileValidationError.surfaceWidthFractionOutOfRange
        }
        guard (-1 ... 1).contains(verticalOffsetFraction) else {
            throw DisplayProfileValidationError.verticalOffsetFractionOutOfRange
        }
        guard viewport.x >= 0,
              viewport.y >= 0,
              viewport.width > 0,
              viewport.height > 0,
              viewport.x + viewport.width <= 1,
              viewport.y + viewport.height <= 1 else {
            throw DisplayProfileValidationError.invalidViewport
        }

        let safeAreaEdges: [(DisplayProfileField, Double)] = [
            (.safeAreaTop, safeArea.top),
            (.safeAreaLeading, safeArea.leading),
            (.safeAreaBottom, safeArea.bottom),
            (.safeAreaTrailing, safeArea.trailing)
        ]
        if let invalid = safeAreaEdges.first(where: { $0.1 < 0 }) {
            throw DisplayProfileValidationError.negativeSafeAreaEdge(invalid.0)
        }
        guard safeArea.leading + safeArea.trailing < 1 else {
            throw DisplayProfileValidationError.invalidSafeAreaHorizontalSum
        }
        guard safeArea.top + safeArea.bottom < 1 else {
            throw DisplayProfileValidationError.invalidSafeAreaVerticalSum
        }
        let presentationContainerAspectRatio = Self.presentationContainerAspectRatio(
            visibleAspectRatio: visibleAspectRatio,
            viewport: viewport,
            safeArea: safeArea
        )
        guard presentationContainerAspectRatio.isFinite,
              presentationContainerAspectRatio > 0 else {
            throw DisplayProfileValidationError.invalidPresentationContainerAspectRatio
        }
        guard textScale > 0 else {
            throw DisplayProfileValidationError.nonPositiveValue(.textScale)
        }
        guard lineScale > 0 else {
            throw DisplayProfileValidationError.nonPositiveValue(.lineScale)
        }

        let colorComponents: [(DisplayProfileField, Double)] = [
            (.red, color.red), (.green, color.green), (.blue, color.blue)
        ]
        if let invalid = colorComponents.first(where: { !(0 ... 1).contains($0.1) }) {
            throw DisplayProfileValidationError.colorComponentOutOfRange(invalid.0)
        }

        self.id = id
        self.displayName = displayName
        self.visibleAspectRatio = visibleAspectRatio
        self.surfaceWidthFraction = surfaceWidthFraction
        self.alignment = alignment
        self.verticalOffsetFraction = verticalOffsetFraction
        self.viewport = viewport
        self.safeArea = safeArea
        self.textScale = textScale
        self.lineScale = lineScale
        self.color = color
    }

    private static func visibleWidthFraction(
        viewport: NormalizedRect,
        safeArea: NormalizedEdgeInsets
    ) -> Double {
        viewport.width * (1 - safeArea.leading - safeArea.trailing)
    }

    private static func visibleHeightFraction(
        viewport: NormalizedRect,
        safeArea: NormalizedEdgeInsets
    ) -> Double {
        viewport.height * (1 - safeArea.top - safeArea.bottom)
    }

    private static func presentationContainerAspectRatio(
        visibleAspectRatio: Double,
        viewport: NormalizedRect,
        safeArea: NormalizedEdgeInsets
    ) -> Double {
        visibleAspectRatio
            * visibleHeightFraction(viewport: viewport, safeArea: safeArea)
            / visibleWidthFraction(viewport: viewport, safeArea: safeArea)
    }
}
