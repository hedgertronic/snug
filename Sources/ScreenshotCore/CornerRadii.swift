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

    public static let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    /// The radius of a corner handle (`.topLeft`, `.topRight`, `.bottomLeft`, `.bottomRight`).
    public subscript(corner: Handle) -> CGFloat {
        get {
            switch corner {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomLeft: bottomLeft
            case .bottomRight: bottomRight
            default: preconditionFailure("\(corner) is not a corner")
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomLeft: bottomLeft = newValue
            case .bottomRight: bottomRight = newValue
            default: preconditionFailure("\(corner) is not a corner")
            }
        }
    }

    /// The corner dot's position on `rect` (top-left origin): on the corner's arc at its 45-degree point, and never closer to the corner
    /// than `minimumInset` along the diagonal, so a square corner's dot sits clear of its resize handle.
    public func dot(of corner: Handle, in rect: CGRect, minimumInset: CGFloat) -> CGPoint {
        let radius = min(self[corner], min(rect.width, rect.height) / 2)
        let along = max(radius * (2.0.squareRoot() - 1), minimumInset) / 2.0.squareRoot()
        let origin = corner.position(on: rect)
        return CGPoint(x: origin.x + (corner.movesLeft ? along : -along), y: origin.y + (corner.movesTop ? along : -along))
    }

    /// The corner whose dot is within `tolerance` of `point`, nearest first.
    public func corner(at point: CGPoint, in rect: CGRect, tolerance: CGFloat, minimumInset: CGFloat) -> Handle? {
        Self.corners
            .map { (corner: $0, dot: dot(of: $0, in: rect, minimumInset: minimumInset)) }
            .map { (corner: $0.corner, distance: hypot($0.dot.x - point.x, $0.dot.y - point.y)) }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }?.corner
    }

    /// How far `delta` goes along the diagonal from `corner` toward the rectangle's center.
    public static func inwardDistance(of delta: CGPoint, from corner: Handle) -> CGFloat {
        ((corner.movesLeft ? delta.x : -delta.x) + (corner.movesTop ? delta.y : -delta.y)) / 2.0.squareRoot()
    }

    /// Every corner changed by `delta`, or only `corner` when `alone`; kept within 0 and half the short side of a rectangle of `size`.
    public func moving(_ corner: Handle, by delta: CGFloat, alone: Bool, in size: CGSize) -> CornerRadii {
        guard alone else { return offset(by: delta, in: size) }
        var result = self
        result[corner] = min(max(self[corner] + delta, 0), min(size.width, size.height) / 2)
        return result
    }

    /// The corners of `crop` that lie outside the rounded corner of `window` (its `radius`), where a square corner would show what lies
    /// outside the window: those within 2 px of the window's corner take `radius`, and those further inside take `radius` less their
    /// inset beyond 2 px (the larger of the two sides), which keeps the corner inside the window's arc (concentric when the insets match).
    /// The others keep their value. Both rectangles are in the same image's pixels, top-left origin.
    public func replacingCorners(sharedWith window: CGRect, in crop: CGRect, with radius: CGFloat) -> CornerRadii {
        let left = crop.minX - window.minX, right = window.maxX - crop.maxX, top = crop.minY - window.minY, bottom = window.maxY - crop.maxY
        var result = self
        for (corner, x, y) in [(Handle.topLeft, left, top), (.topRight, right, top), (.bottomLeft, left, bottom), (.bottomRight, right, bottom)]
        where abs(x) <= 2 && abs(y) <= 2 || x >= -2 && y >= -2 && x < radius && y < radius && hypot(radius - x, radius - y) > radius {
            result[corner] = radius - max(0, max(x, y) - 2)
        }
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
