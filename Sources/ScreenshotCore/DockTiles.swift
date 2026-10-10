import Foundation
import CoreGraphics

/// Dock icon tiles read from the frozen image. Live Dock item frames are the magnified geometry, so they never match the capture.
public enum DockTiles {
    /// A pixel is an edge when its neighbors on either side differ by more than this on some channel (0...255).
    /// The Dock's blurred wallpaper changes by a few levels per pixel; icon outlines change by 13 or more.
    public static let edgeThreshold = 13

    /// An icon is at least this many points long on each axis; separators and running-indicator dots are shorter.
    public static let minimumSide: CGFloat = 24

    /// The Dock panel's rectangle (image pixels) from its rim in the frozen image, near `rough` (the Accessibility union of the Dock's lists).
    /// The union is the magnified Dock, so it runs tens of points past the panel along the Dock's long axis and a few points off across it.
    /// Across: the rim is the innermost column near each side of `rough` whose edge persists on 80% of the rows in the middle of `rough` (icon
    /// edges and the blurred wallpaper do not); within a rim's width of it, the outermost column at half the peak is the panel's side. Along: the rims run straight until the
    /// corner arcs start; the panel's end is the outermost row between the side rims, near where they stop, that carries a rim across.
    /// Nil when no rim is found near a side.
    public static func panel(in image: CGImage, near rough: CGRect, scale: CGFloat) -> CGRect? {
        let bounds = rough.insetBy(dx: -64 * scale, dy: -64 * scale).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = image.cropping(to: bounds)!
        let (width, height) = (crop.width, crop.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let vertical = rough.height > rough.width
        let (length, depth) = vertical ? (height, width) : (width, height)
        let local = rough.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let (roughAlong, roughAcross) = vertical ? (Int(local.minY)..<Int(local.maxY), Int(local.minX)..<Int(local.maxX)) : (Int(local.minX)..<Int(local.maxX), Int(local.minY)..<Int(local.maxY))

        func difference(_ a: Int, _ c: Int, _ a2: Int, _ c2: Int) -> Int {
            let (first, second) = (vertical ? (a * width + c) * 4 : (c * width + a) * 4, vertical ? (a2 * width + c2) * 4 : (c2 * width + a2) * 4)
            return max(abs(Int(pixels[first]) - Int(pixels[second])), abs(Int(pixels[first + 1]) - Int(pixels[second + 1])), abs(Int(pixels[first + 2]) - Int(pixels[second + 2])))
        }
        /// The 20th percentile of the edge across (or along) the Dock at each of `lines`: what is there on 80% of them.
        func persistent(_ lines: [Int], _ edge: (Int) -> Int) -> Int { lines.map(edge).sorted()[lines.count / 5] }
        /// The strongest position in `window` (ordered outermost first), moved outward to the outermost one within a rim's width (2 pt)
        /// of it that is at least half as strong. Nil when the peak is not an edge.
        func outermost(in window: [Int], strength: (Int) -> Int) -> Int? {
            let strengths = window.map(strength)
            guard let peak = strengths.indices.max(by: { strengths[$0] < strengths[$1] }), strengths[peak] > edgeThreshold else { return nil }
            return window.indices.first { abs(window[$0] - window[peak]) <= Int(2 * scale) && strengths[$0] * 2 >= strengths[peak] }.map { window[$0] }
        }

        let center = roughAlong.lowerBound + roughAlong.count / 2
        let middle = Array(roughAlong.lowerBound + roughAlong.count / 5..<roughAlong.upperBound - roughAlong.count / 5).filter { (1..<length - 1).contains($0) }
        let reach = Int(12 * scale)
        func sideStrength(_ column: Int) -> Int { persistent(middle) { difference($0, column - 1, $0, column + 1) } }
        // A window's edge can sit within reach outside the panel and outshine the rim, so the side is the innermost persistent edge
        // (icon edges do not persist) and what lies within a rim's width of it.
        func side(near column: Int, outward: Int) -> Int? {
            let window = (column - reach...column + reach).filter { (1..<depth - 1).contains($0) }
            guard let inner = (outward < 0 ? window.reversed() : window).first(where: { sideStrength($0) > edgeThreshold }) else { return nil }
            return outermost(in: (outward < 0 ? window : window.reversed()).filter { abs($0 - inner) <= Int(2 * scale) }, strength: sideStrength)
        }
        guard let low = side(near: roughAcross.lowerBound, outward: -1), let high = side(near: roughAcross.upperBound, outward: 1), high - low > 8 else { return nil }

        // The side rims stop where the corner arcs start.
        let strip = Array((low + (high - low) * 3 / 10)..<(high - (high - low) * 3 / 10))
        func rim(_ a: Int) -> Int { (Array(low...low + 4) + Array(high - 4...high)).map { difference(a, $0 - 1, a, $0 + 1) }.max()! }
        func straightEnd(step: Int) -> Int {
            var (last, a) = (center, center)
            while abs(a - last) <= 6, (1..<length - 1).contains(a + step) {
                a += step
                if rim(a) > edgeThreshold { last = a }
            }
            return last
        }
        func end(step: Int) -> Int? {
            let straight = straightEnd(step: step)
            let window = (min(straight, straight + step * Int(32 * scale))...max(straight, straight + step * Int(32 * scale))).filter { (1..<length - 1).contains($0) }
            return outermost(in: step < 0 ? window : window.reversed(), strength: { a in persistent(strip) { difference(a - 1, $0, a + 1, $0) } })
        }
        guard let start = end(step: -1), let finish = end(step: 1) else { return nil }
        let (along, across) = (start..<finish + 1, low..<high + 1)
        return vertical ? CGRect(x: bounds.minX + CGFloat(across.lowerBound), y: bounds.minY + CGFloat(along.lowerBound), width: CGFloat(across.count), height: CGFloat(along.count))
            : CGRect(x: bounds.minX + CGFloat(along.lowerBound), y: bounds.minY + CGFloat(across.lowerBound), width: CGFloat(along.count), height: CGFloat(across.count))
    }

    /// The tight rectangle (image pixels) of each icon in the Dock `panel` (image pixels), in order along the Dock's long axis.
    /// Along that axis, an icon is a run of lines with edges in the middle 70% of the panel's width; across it, the run of
    /// columns with edges inside the icon's lines. The outer 15% on each side holds the panel's rim and the running dots.
    public static func tiles(in image: CGImage, panel: CGRect, scale: CGFloat) -> [CGRect] {
        let bounds = panel.integral
        let crop = image.cropping(to: bounds)!
        let (width, height) = (crop.width, crop.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let vertical = height > width
        let (length, depth) = vertical ? (height, width) : (width, height)
        let minimum = Int(minimumSide * scale)
        let band = Int(Double(depth) * 0.15)..<(depth - Int(Double(depth) * 0.15))

        func channelDifference(_ a: Int, _ c: Int, _ a2: Int, _ c2: Int) -> Int {
            let (first, second) = (vertical ? (a * width + c) * 4 : (c * width + a) * 4, vertical ? (a2 * width + c2) * 4 : (c2 * width + a2) * 4)
            return max(abs(Int(pixels[first]) - Int(pixels[second])), abs(Int(pixels[first + 1]) - Int(pixels[second + 1])), abs(Int(pixels[first + 2]) - Int(pixels[second + 2])))
        }
        func isEdge(_ a: Int, _ c: Int) -> Bool {
            channelDifference(a, c - 1, a, c + 1) > edgeThreshold || channelDifference(a - 1, c, a + 1, c) > edgeThreshold
        }
        /// The runs of `range` at least `minimum` long where `on` holds.
        func runs(in range: Range<Int>, where on: (Int) -> Bool) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var start: Int?
            for index in range.lowerBound...range.upperBound {
                if index < range.upperBound, on(index) { start = start ?? index } else if let begin = start {
                    if index - begin >= minimum { result.append(begin..<index) }
                    start = nil
                }
            }
            return result
        }

        return runs(in: 1..<(length - 1), where: { a in band.filter { isEdge(a, $0) }.count >= 2 }).compactMap { rows in
            let columns = runs(in: band, where: { c in rows.contains { isEdge($0, c) } })
            guard let first = columns.first, let last = columns.last else { return nil }
            let (along, across) = (rows, first.lowerBound..<last.upperBound)
            return vertical ? CGRect(x: bounds.minX + CGFloat(across.lowerBound), y: bounds.minY + CGFloat(along.lowerBound), width: CGFloat(across.count), height: CGFloat(along.count))
                : CGRect(x: bounds.minX + CGFloat(along.lowerBound), y: bounds.minY + CGFloat(across.lowerBound), width: CGFloat(along.count), height: CGFloat(across.count))
        }
    }
}
