import Foundation
import CoreGraphics

/// One accessibility element's frame in global screen points with a top-left origin, and its role description.
public struct AXFrame: Sendable, Equatable {
    public let roleDescription: String
    public let rect: CGRect

    public init(roleDescription: String, rect: CGRect) {
        self.roleDescription = roleDescription
        self.rect = rect
    }
}

/// Pure conversion and ranking for accessibility-derived candidates.
public enum AccessibilityBounds {
    /// Score of the innermost element; every accessibility candidate outranks pixel geometry (at most 0.99).
    public static let baseScore = 2.0

    /// An image pixel as a global accessibility point. `displayOrigin` is the display's top-left in the same space.
    public static func point(forPixel pixel: CGPoint, displayOrigin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: displayOrigin.x + pixel.x / scale, y: displayOrigin.y + pixel.y / scale)
    }

    /// Candidates from `frames` (innermost element first, window last), in image pixels clipped to `extent`.
    /// The innermost element scores highest; repeated rectangles keep only the innermost.
    public static func candidates(frames: [AXFrame], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) -> [Candidate] {
        var seen = Set<CGRect>()
        var output: [Candidate] = []
        for (index, frame) in frames.enumerated() {
            let r = frame.rect
            guard [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) else { continue }
            let pixels = CGRect(x: (r.minX - displayOrigin.x) * scale, y: (r.minY - displayOrigin.y) * scale,
                                width: r.width * scale, height: r.height * scale).intersection(extent).integral
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8, seen.insert(pixels).inserted else { continue }
            let label = frame.roleDescription.isEmpty ? "Element" : frame.roleDescription
            output.append(Candidate(id: "ax-\(Int(pixels.minX))-\(Int(pixels.minY))-\(Int(pixels.width))-\(Int(pixels.height))", label: label,
                                    bounds: pixels, score: baseScore - Double(index) * 0.01, kind: .region))
        }
        return output
    }
}
