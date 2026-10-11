import CoreGraphics
import Foundation

/// Estimates the corner radius of a shape in image pixels, using top-left image coordinates: the radius its corners' arcs agree on.
public func cornerRadius(in image: CGImage, rect: CGRect) -> CGFloat {
    cornerArcs(in: image, rect: rect).agreed
}

/// The radius of the arc each corner of `rect` follows, in image pixels with top-left image coordinates; 0 where a corner follows none.
/// From each corner it casts rays at several angles and takes the first edge along each. A rounded corner puts those edges on a circle
/// of one radius tangent to both sides; anything else (square corners, busy content) leaves no consistent radius.
public func cornerArcs(in image: CGImage, rect: CGRect) -> CornerRadii {
    let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = Int(bounds.width), height = Int(bounds.height)
    guard min(width, height) >= 16 else { return .zero } // the smallest radius tried is 8, half the short side

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

    let limit = Double(min(width, height) / 2)
    let angles = [15.0, 30, 45, 60, 75].map { $0 * .pi / 180 }

    func gap(_ a: Int, _ b: Int) -> Int { (0..<3).reduce(0) { $0 + abs(Int(bytes[a + $1]) - Int(bytes[b + $1])) } }

    // Distance from the corner to the first edge along the ray: the colors 2 px apart differ by at least 14 (summed over RGB),
    // and the far one is closer to the shape's side color (0 and 2 px in from either side, half the short side from the corner),
    // so a background ramp outside the corner, such as a soft shadow, does not count as the edge.
    func edge(corner: (x: Int, y: Int), step: (x: Int, y: Int), angle: Double) -> Double? {
        let sides: [Int] = [0, 2].flatMap { depth -> [Int] in
            [(corner.y + step.y * depth) * bytesPerRow + (corner.x + step.x * Int(limit)) * 4,
             (corner.y + step.y * Int(limit)) * bytesPerRow + (corner.x + step.x * depth) * 4]
        }
        func offset(_ distance: Double) -> Int {
            (corner.y + step.y * Int(distance * sin(angle))) * bytesPerRow + (corner.x + step.x * Int(distance * cos(angle))) * 4
        }
        for distance in stride(from: 0.0, to: limit, by: 0.5) {
            let near = offset(distance), far = offset(distance + 2)
            if gap(near, far) >= 14, sides.contains(where: { gap(far, $0) < gap(near, $0) }) { return distance + 2 }
        }
        return nil
    }

    func fit(corner: (x: Int, y: Int), step: (x: Int, y: Int)) -> Int? {
        let distances = angles.map { edge(corner: corner, step: step, angle: $0) }
        guard !distances.contains(where: { $0 == nil }) else { return nil }
        // A circle of radius r tangent to both sides is first reached at r * (k - sqrt(k^2 - 1)) along the ray at an angle with k = cos + sin.
        let best = (8...Int(limit)).map { radius in
            (radius, zip(angles, distances).map { angle, distance in
                let k = cos(angle) + sin(angle)
                return abs(distance! - Double(radius) * (k - (k * k - 1).squareRoot()))
            }.max()!)
        }.min { $0.1 < $1.1 }!
        // Within a tenth of the radius, at most 3 px: edges of a grid around the corner can fit a large circle to a tenth of it.
        return best.1 <= max(1.25, min(3, Double(best.0) * 0.1)) ? best.0 : nil
    }

    return CornerRadii(topLeft: CGFloat(fit(corner: (0, 0), step: (1, 1)) ?? 0), topRight: CGFloat(fit(corner: (width - 1, 0), step: (-1, 1)) ?? 0),
                       bottomLeft: CGFloat(fit(corner: (0, height - 1), step: (1, -1)) ?? 0),
                       bottomRight: CGFloat(fit(corner: (width - 1, height - 1), step: (-1, -1)) ?? 0))
}

/// The corner radius of a window whose frame is `rect` (image pixels, top-left origin): at each corner, the circle tangent to both
/// sides that best follows where the window's own color begins on each line, inside a rim of up to 2 px along the sides. Edge pixels
/// blended with what lies outside the window sit outside that circle, so clipping to it leaves none of the outside showing. The window's color is read 2 px in from each side,
/// `reach` from the corner; a corner whose two samples differ, or whose lines do not follow a circle, is skipped (content or another
/// window covering it). The median of the corners that fit; 0 when none does.
public func windowCornerRadius(in image: CGImage, rect: CGRect) -> CGFloat {
    let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = Int(bounds.width), height = Int(bounds.height)
    let reach = min(80, min(width, height) / 2)
    guard reach >= 12 else { return 0 }
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image.cropping(to: bounds)!, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func fit(corner: (x: Int, y: Int), step: (x: Int, y: Int)) -> Double? {
        // `along` runs along the corner's horizontal side, `down` along its vertical side, both from the corner.
        func offset(_ along: Int, _ down: Int) -> Int { (corner.y + step.y * down) * bytesPerRow + (corner.x + step.x * along) * 4 }
        func gap(_ a: Int, _ b: Int) -> Int { (0..<3).reduce(0) { $0 + abs(Int(bytes[a + $1]) - Int(bytes[b + $1])) } }
        let color = offset(reach, 2)
        guard gap(color, offset(2, reach)) <= 12 else { return nil }
        // The first 2 lines run along the side, where nearly every pixel is a blend; they carry no shape.
        let starts = (2..<reach).map { down in
            (down, (0..<(reach - 2)).first { along in (0..<3).allSatisfy { gap(offset(along + $0, down), color) <= 12 } })
        }
        guard !starts.contains(where: { $0.1 == nil }) else { return nil }
        // A rim `inset` px wide runs along the sides; inside it, the window's color starts on a circle of `radius`.
        func errors(_ radius: Double, _ inset: Double) -> [Double] {
            starts.map { down, start in
                let y = Double(down) + 0.5 - inset
                let predicted: Double = inset + (y < radius ? radius - (radius * radius - (radius - y) * (radius - y)).squareRoot() : 0)
                return abs(Double(start!) - predicted)
            }
        }
        let shapes: [(radius: Double, inset: Double)] = [0.0, 1, 2].flatMap { inset in stride(from: 8.0, through: Double(reach), by: 0.5).map { (radius: $0, inset: inset) } }
        let best = shapes.min { errors($0.radius, $0.inset).reduce(0, +) < errors($1.radius, $1.inset).reduce(0, +) }!
        let misses = errors(best.radius, best.inset)
        // The circle tangent to the frame's sides around the rim and the window's color at the corner.
        return misses.max()! <= 3 && misses.reduce(0, +) / Double(misses.count) <= 0.75 ? best.radius + best.inset : nil
    }

    let fits = [fit(corner: (0, 0), step: (1, 1)), fit(corner: (width - 1, 0), step: (-1, 1)),
                fit(corner: (0, height - 1), step: (1, -1)), fit(corner: (width - 1, height - 1), step: (-1, -1))].compactMap { $0 }.sorted()
    return fits.isEmpty ? 0 : CGFloat(fits[fits.count / 2])
}
