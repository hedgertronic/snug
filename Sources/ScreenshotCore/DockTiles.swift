import Foundation
import CoreGraphics

/// Dock icon tiles read from the frozen image. Live Dock item frames are the magnified geometry, so they never match the capture.
public enum DockTiles {
    /// A pixel is an edge when its neighbors on either side differ by more than this on some channel (0...255).
    /// The Dock's blurred wallpaper changes by a few levels per pixel; icon outlines change by 13 or more.
    public static let edgeThreshold = 13

    /// An icon is at least this many points long on each axis; separators and running-indicator dots are shorter.
    public static let minimumSide: CGFloat = 24

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
            return (0..<3).map { abs(Int(pixels[first + $0]) - Int(pixels[second + $0])) }.max()!
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
