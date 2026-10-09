import CoreGraphics

/// The radius of each corner of a rectangle, in image pixels.
public struct CornerRadii: Equatable, Sendable {
    public var topLeft, topRight, bottomLeft, bottomRight: CGFloat

    public static let zero = CornerRadii(0)

    public init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        (self.topLeft, self.topRight, self.bottomLeft, self.bottomRight) = (topLeft, topRight, bottomLeft, bottomRight)
    }

    /// All four corners at `radius`.
    public init(_ radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    public var isSquare: Bool { self == .zero }

    private func map(_ transform: (CGFloat) -> CGFloat) -> CornerRadii {
        CornerRadii(topLeft: transform(topLeft), topRight: transform(topRight), bottomLeft: transform(bottomLeft), bottomRight: transform(bottomRight))
    }

    public func scaled(by factor: CGFloat) -> CornerRadii { map { $0 * factor } }

    /// Every corner changed by `delta`, kept within 0 and half the short side of a rectangle of `size`.
    public func offset(by delta: CGFloat, in size: CGSize) -> CornerRadii {
        map { min(max($0 + delta, 0), min(size.width, size.height) / 2) }
    }

    /// The corners of `crop` within 2 px of the same corner of `window` take `radius`; the others keep their value.
    /// Both rectangles are in the same image's pixels, top-left origin.
    public func replacingCorners(sharedWith window: CGRect, in crop: CGRect, with radius: CGFloat) -> CornerRadii {
        let left = abs(crop.minX - window.minX) <= 2, right = abs(crop.maxX - window.maxX) <= 2
        let top = abs(crop.minY - window.minY) <= 2, bottom = abs(crop.maxY - window.maxY) <= 2
        var result = self
        if left && top { result.topLeft = radius }
        if right && top { result.topRight = radius }
        if left && bottom { result.bottomLeft = radius }
        if right && bottom { result.bottomRight = radius }
        return result
    }

    /// The rounded outline of `rect` in a bottom-up coordinate space (a CGContext or an AppKit view): the top corners are at `maxY`.
    /// Each radius is capped at half the short side.
    public func path(in rect: CGRect) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: min(topRight, limit))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: min(bottomRight, limit))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: min(bottomLeft, limit))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: min(topLeft, limit))
        path.closeSubpath()
        return path
    }
}
