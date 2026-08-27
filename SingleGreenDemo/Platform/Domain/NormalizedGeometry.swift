import CoreGraphics

struct NormalizedRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func rect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + bounds.width * x,
            y: bounds.minY + bounds.height * y,
            width: bounds.width * width,
            height: bounds.height * height
        )
    }
}

struct NormalizedInsets: Equatable, Sendable {
    let horizontal: Double
    let vertical: Double

    func inset(_ rect: CGRect) -> CGRect {
        rect.insetBy(
            dx: rect.width * horizontal,
            dy: rect.height * vertical
        )
    }
}
