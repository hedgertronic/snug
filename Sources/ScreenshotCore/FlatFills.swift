import CoreGraphics

/// Small uniform fills (pills, chips, buttons) that `GeometryDetector` skips for their size, found by flood fill from one point.
public struct FlatFills: Sendable {
    /// The side range a fill may have, in image pixels (points, on a 1x image).
    public static let sides = 12...400

    private let bytes: [UInt8]
    private let width, height: Int

    /// Reads `image`'s pixels; pass the 1x downsample so the sides are in points.
    public init(_ image: CGImage) {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        (self.bytes, self.width, self.height) = (bytes, width, height)
    }

    /// The closed uniform fill around `point` (top-left origin), or nil. The fill's color is the commonest one within 6 px of the point,
    /// so a point on a label in a pill still finds the pill. The fill takes the colors within 24 (summed over RGB) of that one; it counts
    /// when it never reaches `sides.upperBound` px from the point or the image edge, spans `sides` on both axes, covers at least half
    /// its box (a thin border ring or a line does not), and has a uniform surround (not just a part of a larger picture).
    public func region(at point: CGPoint) -> Candidate? {
        let (px, py) = (Int(point.x), Int(point.y))
        guard (0..<width).contains(px), (0..<height).contains(py) else { return nil }
        func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
        func gap(_ a: Int, _ b: Int) -> Int { abs(Int(bytes[a]) - Int(bytes[b])) + abs(Int(bytes[a + 1]) - Int(bytes[b + 1])) + abs(Int(bytes[a + 2]) - Int(bytes[b + 2])) }

        var votes: [Int: (count: Int, x: Int, y: Int)] = [:]
        for y in max(0, py - 6)...min(height - 1, py + 6) {
            for x in max(0, px - 6)...min(width - 1, px + 6) {
                let at = offset(x, y)
                let key = Int(bytes[at] >> 3) << 10 | Int(bytes[at + 1] >> 3) << 5 | Int(bytes[at + 2] >> 3)
                let old = votes[key] ?? (0, x, y)
                let nearer = hypot(Double(x - px), Double(y - py)) < hypot(Double(old.x - px), Double(old.y - py))
                votes[key] = (old.count + 1, nearer ? x : old.x, nearer ? y : old.y)
            }
        }
        let seed = votes.values.max { $0.count < $1.count }!
        let color = offset(seed.x, seed.y)

        // Scanline fill inside a box of `sides.upperBound` around the point; reaching the box (or the image edge) ends the search.
        let box = (minX: max(0, px - Self.sides.upperBound), maxX: min(width - 1, px + Self.sides.upperBound),
                   minY: max(0, py - Self.sides.upperBound), maxY: min(height - 1, py + Self.sides.upperBound))
        let boxWidth = box.maxX - box.minX + 1
        var seen = [Bool](repeating: false, count: boxWidth * (box.maxY - box.minY + 1))
        func isFill(_ x: Int, _ y: Int) -> Bool { !seen[(y - box.minY) * boxWidth + x - box.minX] && gap(offset(x, y), color) <= 24 }
        var stack = [(x: seed.x, y: seed.y)]
        var (minX, maxX, minY, maxY, area) = (seed.x, seed.x, seed.y, seed.y, 0)
        while let (x, y) = stack.popLast() {
            guard isFill(x, y) else { continue }
            var (left, right) = (x, x)
            while left > box.minX, isFill(left - 1, y) { left -= 1 }
            while right < box.maxX, isFill(right + 1, y) { right += 1 }
            if left == box.minX || right == box.maxX || y == box.minY || y == box.maxY { return nil }
            for column in left...right { seen[(y - box.minY) * boxWidth + column - box.minX] = true }
            area += right - left + 1
            (minX, maxX, minY, maxY) = (min(minX, left), max(maxX, right), min(minY, y), max(maxY, y))
            for next in [y - 1, y + 1] {
                var inRun = false
                for column in left...right {
                    let fill = isFill(column, next)
                    if fill && !inRun { stack.append((column, next)) }
                    inRun = fill
                }
            }
        }
        let (fillWidth, fillHeight) = (maxX - minX + 1, maxY - minY + 1)
        guard Self.sides.contains(fillWidth), Self.sides.contains(fillHeight), area * 2 >= fillWidth * fillHeight,
              minX >= 3, minY >= 3, maxX + 3 < width, maxY + 3 < height else { return nil }
        // A shape of its own is set off by one surround: 70% of the pixels 3 px outside its box share the color at the middle of its top.
        let surround = (minX - 3...maxX + 3).flatMap { [offset($0, minY - 3), offset($0, maxY + 3)] }
            + (minY - 3...maxY + 3).flatMap { [offset(minX - 3, $0), offset(maxX + 3, $0)] }
        let around = offset((minX + maxX) / 2, minY - 3)
        guard surround.count(where: { gap($0, around) <= 24 }) * 10 >= surround.count * 7 else { return nil }
        return Candidate(id: "fill-\(minX)-\(minY)", label: "Fill", bounds: CGRect(x: minX, y: minY, width: fillWidth, height: fillHeight),
                         score: 1, kind: .region)
    }
}
