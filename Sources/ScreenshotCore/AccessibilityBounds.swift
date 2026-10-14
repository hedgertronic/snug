import Foundation
import CoreGraphics

/// One accessibility element's frame in global screen points with a top-left origin, its role description, its AX role, and its title;
/// and its subrole, identifier and description ("" where the element has none).
public struct AXFrame: Sendable, Equatable {
    public let roleDescription: String
    public let rect: CGRect
    public let role: String
    public let title: String
    public let subrole: String
    public let identifier: String
    /// The element's `AXDescription`.
    public let elementDescription: String

    public init(roleDescription: String, rect: CGRect, role: String = "", title: String = "", subrole: String = "", identifier: String = "",
                elementDescription: String = "") {
        self.roleDescription = roleDescription
        self.rect = rect
        self.role = role
        self.title = title
        self.subrole = subrole
        self.identifier = identifier
        self.elementDescription = elementDescription
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

    /// The smallest side, in points, of an element a hover lands on.
    public static let minimumHoverSide: CGFloat = 16

    /// The frames a hover can land on: not the window (its rectangle comes from the window list, where a click captures it as a window),
    /// nor an element within `paddingTolerance` of the window's frame on every side (Finder's column view AXBrowser is
    /// 1 pt larger than its window on every side, measured on macOS 26), not static text, not Stage Manager's strip list (it would win in the gaps between thumbnails and around their
    /// tilted pictures), and nothing under 16 pt on a side. Roles, not role descriptions: those are localized.
    public static func hoverLevel(_ frames: [AXFrame]) -> [AXFrame] {
        let stageManager = StageManager.owns(frames)
        let window = frames.first { $0.role == "AXWindow" }?.rect
        return frames.filter { frame in
            frame.role != "AXWindow" && frame.role != "AXStaticText" && !(stageManager && frame.role == "AXList")
                && frame.rect.width >= minimumHoverSide && frame.rect.height >= minimumHoverSide
                && !(window.map { frame.rect.isNear($0, within: paddingTolerance) } ?? false)
        }
    }

    /// Whether hover looks up accessibility frames in a window: not in the frozen Dock (named "Dock" by the window listing), whose live
    /// frames are the magnified Dock. Its panel (the window's rectangle) and its icon tiles come from the frozen image instead.
    public static func looksUp(inWindowNamed name: String, frozen: Bool) -> Bool { !(frozen && name == "Dock") }

    /// Each frame clipped to the visible area of its nearest `AXScrollArea` or `AXWebArea` ancestor (itself clipped the same way);
    /// frames that end up empty are dropped. Order is kept.
    public static func clippedToViewports(_ frames: [AXFrame]) -> [AXFrame] {
        var clipped = frames
        for index in frames.indices.reversed() {
            if let viewport = frames[(index + 1)...].indices.first(where: { ["AXScrollArea", "AXWebArea"].contains(frames[$0].role) }) {
                clipped[index] = AXFrame(roleDescription: frames[index].roleDescription, rect: frames[index].rect.intersection(clipped[viewport].rect), role: frames[index].role, title: frames[index].title)
            }
        }
        return clipped.filter { !$0.rect.isNull && !$0.rect.isEmpty }
    }

    /// Candidates from `frames` (innermost element first, window last), in image pixels clipped to `extent` and to scroll viewports.
    /// The innermost element scores highest; repeated rectangles and padding-only parents keep only the innermost. A frame covering all of
    /// `extent` (Stage Manager's full-screen group) is the display, not an element.
    public static func candidates(frames: [AXFrame], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) async throws -> [Candidate] {
        var output: [Candidate] = []
        var inner: CGRect?
        for (index, frame) in clippedToViewports(frames.filter { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].allSatisfy(\.isFinite) }).enumerated() {
            let r = frame.rect
            let pixels = CGRect(x: (r.minX - displayOrigin.x) * scale, y: (r.minY - displayOrigin.y) * scale,
                                width: r.width * scale, height: r.height * scale).intersection(extent).integral
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8, pixels != extent else { continue }
            let tolerance = paddingTolerance * scale
            if let inner, abs(pixels.minX - inner.minX) <= tolerance, abs(pixels.minY - inner.minY) <= tolerance,
               abs(pixels.maxX - inner.maxX) <= tolerance, abs(pixels.maxY - inner.maxY) <= tolerance { continue }
            inner = pixels
            // Named by its role description ("Text Field").
            let label = frame.roleDescription.isEmpty ? "Element" : frame.roleDescription.capitalized
            output.append(Candidate(id: "ax-\(Int(pixels.minX))-\(Int(pixels.minY))-\(Int(pixels.width))-\(Int(pixels.height))", label: label,
                                    bounds: pixels, score: baseScore - Double(index) * 0.01, kind: .element))
        }
        return output
    }
}
