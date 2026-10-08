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

    /// The Dock's visible panel in `image`: each side of the AXList union moves to the panel's rim, within 48 pt either way.
    /// The union is off by several points (measured on a vertical Dock: 5 pt inside on the left, 37 pt past the bottom), and the
    /// rim is a bright 1-2 px line. Along 9 lines across the middle of a side, the side's hit is the boundary between neighbors
    /// differing by at least 30 (summed RGB) nearest the union's side, moved out over the rim's other boundary when that is
    /// within 3 px. The side takes the hit nearest the union that 3 lines share within 2 px, so a rounded end counts from its
    /// middle. A side with no such hit stays where it is.
    public static func dockPanel(in image: CGImage, around union: CGRect, scale: CGFloat) -> CGRect {
        let union = union.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let width = image.width, height = image.height, bytesPerRow = width * 4
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        func sum(_ x: Int, _ y: Int) -> Int { (0..<3).reduce(0) { $0 + Int(bytes[y * bytesPerRow + x * 4 + $1]) } }
        let reach = Int(48 * scale)

        // Boundaries are pixel edges: boundary b lies between pixels b - 1 and b. `outward` is -1 for left and top, +1 for right and bottom.
        func side(_ start: Int, outward: Int, vertical: Bool, lines: [Int]) -> Int {
            let limit = vertical ? width : height
            func jump(_ b: Int, _ line: Int) -> Bool {
                guard b >= 1, b < limit else { return false }
                return vertical ? abs(sum(b - 1, line) - sum(b, line)) >= 30 : abs(sum(line, b - 1) - sum(line, b)) >= 30
            }
            let hits = lines.compactMap { line -> Int? in
                guard let near = (0...reach).flatMap({ [start - $0, start + $0] }).first(where: { jump($0, line) }) else { return nil }
                return (1...3).map { near + outward * $0 }.last { jump($0, line) } ?? near
            }.sorted { abs($0 - start) < abs($1 - start) }
            return hits.first { hit in hits.filter { abs($0 - hit) <= 2 }.count >= 3 } ?? start
        }
        let rows = (0..<9).map { Int(union.minY) + Int(union.height) * (3 + $0) / 15 }
        let columns = (0..<9).map { Int(union.minX) + Int(union.width) * (3 + $0) / 15 }
        let left = side(Int(union.minX), outward: -1, vertical: true, lines: rows)
        let right = side(Int(union.maxX), outward: 1, vertical: true, lines: rows)
        let top = side(Int(union.minY), outward: -1, vertical: false, lines: columns)
        let bottom = side(Int(union.maxY), outward: 1, vertical: false, lines: columns)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `rect` with its plain margins removed: each side moves in while at least 95% of its line is within 40 (summed RGB) of the
    /// color at the rect's top-left corner, so a small mark in the margin (a Dock running dot) does not stop it.
    public static func trimmedToContent(in image: CGImage, rect: CGRect) -> CGRect {
        let crop = image.cropping(to: rect.integral)!
        let width = crop.width, height = crop.height, bytesPerRow = width * 4
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        func plain(_ x: Int, _ y: Int) -> Bool { (0..<3).reduce(0) { $0 + abs(Int(bytes[y * bytesPerRow + x * 4 + $1]) - Int(bytes[$1])) } <= 40 }
        func plainLine(_ points: [(Int, Int)]) -> Bool { points.filter { plain($0.0, $0.1) }.count * 100 >= points.count * 95 }
        var (left, top, right, bottom) = (0, 0, width - 1, height - 1)
        while left < right, plainLine((top...bottom).map { (left, $0) }) { left += 1 }
        while right > left, plainLine((top...bottom).map { (right, $0) }) { right -= 1 }
        while top < bottom, plainLine((left...right).map { ($0, top) }) { top += 1 }
        while bottom > top, plainLine((left...right).map { ($0, bottom) }) { bottom -= 1 }
        return CGRect(x: rect.integral.minX + CGFloat(left), y: rect.integral.minY + CGFloat(top), width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
    }

    /// A parent whose every side is within this many points of the kept inner frame is only padding, not a step.
    public static let paddingTolerance: CGFloat = 12

    /// The smallest side, in points, of an element a hover lands on.
    public static let minimumHoverSide: CGFloat = 16

    /// The frames a hover can land on: not the window (its rectangle comes from the window list, where a click captures it as a window),
    /// not static text, and nothing under 16 pt on a side. Roles, not role descriptions: those are localized.
    public static func hoverLevel(_ frames: [AXFrame]) -> [AXFrame] {
        frames.filter { $0.role != "AXWindow" && $0.role != "AXStaticText" && $0.rect.width >= minimumHoverSide && $0.rect.height >= minimumHoverSide }
    }

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
    public static func candidates(frames: [AXFrame], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect, image: CGImage? = nil) -> [Candidate] {
        var output: [Candidate] = []
        var inner: CGRect?
        for (index, frame) in clippedToViewports(frames.filter { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].allSatisfy(\.isFinite) }).enumerated() {
            let r = frame.rect
            var pixels = CGRect(x: (r.minX - displayOrigin.x) * scale, y: (r.minY - displayOrigin.y) * scale,
                                width: r.width * scale, height: r.height * scale).intersection(extent).integral
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8 else { continue }
            // A Dock item's frame is its whole slot; the icon sits inside it.
            if frame.role == "AXDockItem", let image { pixels = trimmedToContent(in: image, rect: pixels) }
            let tolerance = paddingTolerance * scale
            if let inner, abs(pixels.minX - inner.minX) <= tolerance, abs(pixels.minY - inner.minY) <= tolerance,
               abs(pixels.maxX - inner.maxX) <= tolerance, abs(pixels.maxY - inner.maxY) <= tolerance { continue }
            inner = pixels
            let label = frame.roleDescription.isEmpty ? "Element" : frame.roleDescription
            output.append(Candidate(id: "ax-\(Int(pixels.minX))-\(Int(pixels.minY))-\(Int(pixels.width))-\(Int(pixels.height))", label: label,
                                    bounds: pixels, score: baseScore - Double(index) * 0.01, kind: .element))
        }
        return output
    }
}
