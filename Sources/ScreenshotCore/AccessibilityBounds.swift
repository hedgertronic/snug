import Foundation
import CoreGraphics

/// One accessibility element's frame in global screen points with a top-left origin, its role description, and its AX role.
public struct AXFrame: Sendable, Equatable {
    public let roleDescription: String
    public let rect: CGRect
    public let role: String

    public init(roleDescription: String, rect: CGRect, role: String = "") {
        self.roleDescription = roleDescription
        self.rect = rect
        self.role = role
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

    /// The whole dock in image pixels: the union of the Dock's `AXList` frames (global points), each clipped to `extent`.
    /// Nil when no list has a finite frame at least 8 pixels square on the display.
    public static func dockRect(lists: [CGRect], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) -> CGRect? {
        let union = lists.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }.map {
            CGRect(x: ($0.minX - displayOrigin.x) * scale, y: ($0.minY - displayOrigin.y) * scale, width: $0.width * scale, height: $0.height * scale)
                .intersection(extent)
        }.filter { !$0.isNull && $0.width >= 8 && $0.height >= 8 }.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? nil : union.integral
    }

    /// A parent whose every side is within this many points of the kept inner frame is only padding, not a step.
    public static let paddingTolerance: CGFloat = 12

    /// Each frame clipped to the visible area of its nearest `AXScrollArea` or `AXWebArea` ancestor (itself clipped the same way);
    /// frames that end up empty are dropped. Order is kept.
    public static func clippedToViewports(_ frames: [AXFrame]) -> [AXFrame] {
        var clipped = frames
        for index in frames.indices.reversed() {
            if let viewport = frames[(index + 1)...].indices.first(where: { ["AXScrollArea", "AXWebArea"].contains(frames[$0].role) }) {
                clipped[index] = AXFrame(roleDescription: frames[index].roleDescription, rect: frames[index].rect.intersection(clipped[viewport].rect), role: frames[index].role)
            }
        }
        return clipped.filter { !$0.rect.isNull && !$0.rect.isEmpty }
    }

    /// Candidates from `frames` (innermost element first, window last), in image pixels clipped to `extent` and to scroll viewports.
    /// The innermost element scores highest; repeated rectangles and padding-only parents keep only the innermost.
    public static func candidates(frames: [AXFrame], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) -> [Candidate] {
        var output: [Candidate] = []
        var inner: CGRect?
        for (index, frame) in clippedToViewports(frames.filter { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].allSatisfy(\.isFinite) }).enumerated() {
            let r = frame.rect
            let pixels = CGRect(x: (r.minX - displayOrigin.x) * scale, y: (r.minY - displayOrigin.y) * scale,
                                width: r.width * scale, height: r.height * scale).intersection(extent).integral
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8 else { continue }
            let tolerance = paddingTolerance * scale
            if let inner, abs(pixels.minX - inner.minX) <= tolerance, abs(pixels.minY - inner.minY) <= tolerance,
               abs(pixels.maxX - inner.maxX) <= tolerance, abs(pixels.maxY - inner.maxY) <= tolerance { continue }
            inner = pixels
            let label = frame.roleDescription.isEmpty ? "Element" : frame.roleDescription
            output.append(Candidate(id: "ax-\(Int(pixels.minX))-\(Int(pixels.minY))-\(Int(pixels.width))-\(Int(pixels.height))", label: label,
                                    bounds: pixels, score: baseScore - Double(index) * 0.01, kind: .region))
        }
        return output
    }
}
