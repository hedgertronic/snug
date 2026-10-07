import CoreGraphics

/// Estimates the corner radius of a shape in image pixels, using top-left image coordinates.
public func cornerRadius(in image: CGImage, rect: CGRect) -> CGFloat {
    let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width >= 3, height >= 3 else { return 0 }

    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let cropped = image.cropping(to: bounds)!
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let index = y * bytesPerRow + x * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    func sideColor(_ points: [(Int, Int)], inward: (Int, Int)) -> (Int, Int, Int) {
        var counts: [Int: Int] = [:]
        let depth = min(width, height) / 2
        for (x, y) in points {
            for step in 0...depth {
                let sample = color(x + step * inward.0, y + step * inward.1)
                let key = sample.0 << 16 | sample.1 << 8 | sample.2
                counts[key, default: 0] += 1
            }
        }
        let key = counts.max { $0.value < $1.value }!.key
        return ((key >> 16) & 0xff, (key >> 8) & 0xff, key & 0xff)
    }

    let third = max(1, width / 3), verticalThird = max(1, height / 3)
    let horizontalPositions = [max(0, width / 2 - third / 2), width / 2, min(width - 1, width / 2 + third / 2)]
    let verticalPositions = [max(0, height / 2 - verticalThird / 2), height / 2, min(height - 1, height / 2 + verticalThird / 2)]
    let top = sideColor(horizontalPositions.map { ($0, 0) }, inward: (0, 1))
    let bottom = sideColor(horizontalPositions.map { ($0, height - 1) }, inward: (0, -1))
    let left = sideColor(verticalPositions.map { (0, $0) }, inward: (1, 0))
    let right = sideColor(verticalPositions.map { (width - 1, $0) }, inward: (-1, 0))

    func matches(_ x: Int, _ y: Int, _ first: (Int, Int, Int), _ second: (Int, Int, Int)) -> Bool {
        let sample = color(x, y)
        func distance(_ edge: (Int, Int, Int)) -> Double {
            let red = Double(sample.0 - edge.0), green = Double(sample.1 - edge.1), blue = Double(sample.2 - edge.2)
            return (red * red + green * green + blue * blue).squareRoot()
        }
        return distance(first) <= 24 || distance(second) <= 24
    }

    func cornerGap(startX: Int, startY: Int, stepX: Int, stepY: Int,
                   first: (Int, Int, Int), second: (Int, Int, Int)) -> CGFloat? {
        let limit = min(width, height) / 2
        for step in 0...limit {
            if matches(startX + step * stepX, startY + step * stepY, first, second) {
                // Outside the arc the background changes smoothly (flat, gradient, blur); busy content is not a corner. The last 3 steps are the anti-aliased edge.
                for outsideStep in 1..<max(1, step - 3) {
                    let previous = color(startX + (outsideStep - 1) * stepX, startY + (outsideStep - 1) * stepY)
                    let sample = color(startX + outsideStep * stepX, startY + outsideStep * stepY)
                    let red = Double(sample.0 - previous.0), green = Double(sample.1 - previous.1), blue = Double(sample.2 - previous.2)
                    if (red * red + green * green + blue * blue).squareRoot() > 24 { return nil }
                }
                return CGFloat(step)
            }
        }
        return nil
    }

    let gaps = [
        cornerGap(startX: 0, startY: 0, stepX: 1, stepY: 1, first: top, second: left),
        cornerGap(startX: width - 1, startY: 0, stepX: -1, stepY: 1, first: top, second: right),
        cornerGap(startX: 0, startY: height - 1, stepX: 1, stepY: -1, first: bottom, second: left),
        cornerGap(startX: width - 1, startY: height - 1, stepX: -1, stepY: -1, first: bottom, second: right)
    ].compactMap { $0 }.map { $0 / (1 - 1 / CGFloat(2).squareRoot()) }
    guard gaps.count >= 3 else { return 0 }
    let sorted = gaps.sorted()
    let middle = sorted.count / 2
    let estimate = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    let agreeing = gaps.filter { abs($0 - estimate) <= estimate * 0.25 }
    guard agreeing.count >= 3 else { return 0 }
    return min(estimate.rounded(), CGFloat(min(width, height)) / 2)
}
