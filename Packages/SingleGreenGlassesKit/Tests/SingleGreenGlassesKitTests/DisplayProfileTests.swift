import XCTest
@testable import SingleGreenGlassesKit

final class DisplayProfileTests: XCTestCase {
    func testAsymmetricSafeAreaDerivesVisibleFractionsAndPresentationAspect() throws {
        let profile = try makeProfile(
            visibleAspectRatio: 2.0,
            viewport: NormalizedRect(x: 0.10, y: 0.20, width: 0.80, height: 0.60),
            safeArea: NormalizedEdgeInsets(top: 0.10, leading: 0.20, bottom: 0.15, trailing: 0.05)
        )

        XCTAssertEqual(profile.visibleWidthFraction, 0.60, accuracy: 0.000_001)
        XCTAssertEqual(profile.visibleHeightFraction, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(profile.presentationContainerAspectRatio, 1.50, accuracy: 0.000_001)
    }

    func testAllNineAlignmentsAreRepresentable() {
        XCTAssertEqual(
            DisplayAlignment.allCases,
            [
                .topLeading, .top, .topTrailing,
                .leading, .center, .trailing,
                .bottomLeading, .bottom, .bottomTrailing
            ]
        )
    }

    func testRejectsBlankIdentityFields() {
        XCTAssertThrowsError(try makeProfile(id: " \n")) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .blankIdentifier)
        }
        XCTAssertThrowsError(try makeProfile(displayName: "\t")) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .blankDisplayName)
        }
    }

    func testRejectsEveryNonFiniteField() {
        let expectations: [(DisplayProfileField, () throws -> DisplayProfile)] = [
            (.visibleAspectRatio, { try self.makeProfile(visibleAspectRatio: .infinity) }),
            (.surfaceWidthFraction, { try self.makeProfile(surfaceWidthFraction: .nan) }),
            (.verticalOffsetFraction, { try self.makeProfile(verticalOffsetFraction: -.infinity) }),
            (.viewportX, { try self.makeProfile(viewport: .init(x: .nan, y: 0, width: 1, height: 1)) }),
            (.viewportY, { try self.makeProfile(viewport: .init(x: 0, y: .infinity, width: 1, height: 1)) }),
            (.viewportWidth, { try self.makeProfile(viewport: .init(x: 0, y: 0, width: .nan, height: 1)) }),
            (.viewportHeight, { try self.makeProfile(viewport: .init(x: 0, y: 0, width: 1, height: .infinity)) }),
            (.safeAreaTop, { try self.makeProfile(safeArea: .init(top: .nan, leading: 0, bottom: 0, trailing: 0)) }),
            (.safeAreaLeading, { try self.makeProfile(safeArea: .init(top: 0, leading: .infinity, bottom: 0, trailing: 0)) }),
            (.safeAreaBottom, { try self.makeProfile(safeArea: .init(top: 0, leading: 0, bottom: .nan, trailing: 0)) }),
            (.safeAreaTrailing, { try self.makeProfile(safeArea: .init(top: 0, leading: 0, bottom: 0, trailing: .infinity)) }),
            (.textScale, { try self.makeProfile(textScale: .nan) }),
            (.lineScale, { try self.makeProfile(lineScale: .infinity) }),
            (.red, { try self.makeProfile(color: .init(red: .nan, green: 1, blue: 1)) }),
            (.green, { try self.makeProfile(color: .init(red: 1, green: .infinity, blue: 1)) }),
            (.blue, { try self.makeProfile(color: .init(red: 1, green: 1, blue: -.infinity)) })
        ]

        for (field, operation) in expectations {
            XCTAssertThrowsError(try operation(), "Expected rejection for \(field)") {
                XCTAssertEqual($0 as? DisplayProfileValidationError, .nonFiniteValue(field))
            }
        }
    }

    func testRejectsInvalidAspectSurfaceOffsetAndScales() {
        XCTAssertThrowsError(try makeProfile(visibleAspectRatio: 0)) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .nonPositiveValue(.visibleAspectRatio))
        }
        for value in [0.0, -0.1, 1.01] {
            XCTAssertThrowsError(try makeProfile(surfaceWidthFraction: value)) {
                XCTAssertEqual($0 as? DisplayProfileValidationError, .surfaceWidthFractionOutOfRange)
            }
        }
        for value in [-1.01, 1.01] {
            XCTAssertThrowsError(try makeProfile(verticalOffsetFraction: value)) {
                XCTAssertEqual($0 as? DisplayProfileValidationError, .verticalOffsetFractionOutOfRange)
            }
        }
        XCTAssertThrowsError(try makeProfile(textScale: 0)) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .nonPositiveValue(.textScale))
        }
        XCTAssertThrowsError(try makeProfile(lineScale: -0.1)) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .nonPositiveValue(.lineScale))
        }
    }

    func testRejectsInvalidViewportGeometry() {
        let invalidViewports = [
            NormalizedRect(x: -0.01, y: 0, width: 1, height: 1),
            NormalizedRect(x: 0, y: -0.01, width: 1, height: 1),
            NormalizedRect(x: 0, y: 0, width: 0, height: 1),
            NormalizedRect(x: 0, y: 0, width: 1, height: 0),
            NormalizedRect(x: 0.5, y: 0, width: 0.51, height: 1),
            NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.51)
        ]

        for viewport in invalidViewports {
            XCTAssertThrowsError(try makeProfile(viewport: viewport)) {
                XCTAssertEqual($0 as? DisplayProfileValidationError, .invalidViewport)
            }
        }
    }

    func testRejectsNegativeOrCollapsedSafeArea() {
        XCTAssertThrowsError(
            try makeProfile(safeArea: .init(top: -0.01, leading: 0, bottom: 0, trailing: 0))
        ) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .negativeSafeAreaEdge(.safeAreaTop))
        }
        XCTAssertThrowsError(
            try makeProfile(safeArea: .init(top: 0, leading: 0.6, bottom: 0, trailing: 0.4))
        ) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .invalidSafeAreaHorizontalSum)
        }
        XCTAssertThrowsError(
            try makeProfile(safeArea: .init(top: 0.5, leading: 0, bottom: 0.5, trailing: 0))
        ) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .invalidSafeAreaVerticalSum)
        }
    }

    func testRejectsColorComponentsOutsideUnitRange() {
        XCTAssertThrowsError(try makeProfile(color: .init(red: -0.01, green: 1, blue: 1))) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .colorComponentOutOfRange(.red))
        }
        XCTAssertThrowsError(try makeProfile(color: .init(red: 1, green: 1.01, blue: 1))) {
            XCTAssertEqual($0 as? DisplayProfileValidationError, .colorComponentOutOfRange(.green))
        }
    }

    func testRejectsFiniteInputsThatOverflowPresentationContainerAspectRatio() {
        XCTAssertThrowsError(
            try makeProfile(
                visibleAspectRatio: .greatestFiniteMagnitude,
                viewport: NormalizedRect(
                    x: 0,
                    y: 0,
                    width: .leastNonzeroMagnitude,
                    height: 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? DisplayProfileValidationError,
                .invalidPresentationContainerAspectRatio
            )
        }
    }

    func testRejectsFiniteInputsThatUnderflowPresentationContainerAspectRatio() {
        XCTAssertThrowsError(
            try makeProfile(
                visibleAspectRatio: .leastNonzeroMagnitude,
                viewport: NormalizedRect(
                    x: 0,
                    y: 0,
                    width: 1,
                    height: .leastNonzeroMagnitude
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? DisplayProfileValidationError,
                .invalidPresentationContainerAspectRatio
            )
        }
    }

    private func makeProfile(
        id: String = "tests.profile",
        displayName: String = "Tests",
        visibleAspectRatio: Double = 8.0 / 3.0,
        surfaceWidthFraction: Double = 0.9,
        alignment: DisplayAlignment = .center,
        verticalOffsetFraction: Double = 0,
        viewport: NormalizedRect = .init(x: 0, y: 0, width: 1, height: 1),
        safeArea: NormalizedEdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0),
        textScale: Double = 1,
        lineScale: Double = 1,
        color: DisplayColorComponents = .init(red: 0, green: 1, blue: 0)
    ) throws -> DisplayProfile {
        try DisplayProfile(
            id: id,
            displayName: displayName,
            visibleAspectRatio: visibleAspectRatio,
            surfaceWidthFraction: surfaceWidthFraction,
            alignment: alignment,
            verticalOffsetFraction: verticalOffsetFraction,
            viewport: viewport,
            safeArea: safeArea,
            textScale: textScale,
            lineScale: lineScale,
            color: color
        )
    }
}
