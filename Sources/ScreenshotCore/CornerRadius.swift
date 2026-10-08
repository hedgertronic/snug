import CoreGraphics
import Foundation

/// Estimates the corner radius of a shape in image pixels, using top-left image coordinates.
/// From each corner it casts rays at several angles and takes the first edge along each. A rounded corner puts those edges on a circle
/// of one radius tangent to both sides; anything else (square corners, busy content) leaves no consistent radius. At least 3 corners must agree.
public func cornerRadius(in image: CGImage, rect: CGRect) -> CGFloat {
    let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = Int(bounds.width), height = Int(bounds.height)
    guard min(width, height) >= 16 else { return 0 } // the smallest radius tried is 8, half the short side

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
        return best.1 <= max(1.25, Double(best.0) * 0.1) ? best.0 : nil
    }

    let radii = [fit(corner: (0, 0), step: (1, 1)), fit(corner: (width - 1, 0), step: (-1, 1)),
                 fit(corner: (0, height - 1), step: (1, -1)), fit(corner: (width - 1, height - 1), step: (-1, -1))].compactMap { $0 }
    guard radii.count >= 3 else { return 0 }
    let estimate = radii.sorted()[radii.count / 2]
    guard radii.filter({ abs($0 - estimate) <= max(2, estimate / 5) }).count >= 3 else { return 0 }
    return CGFloat(min(estimate, min(width, height) / 2))
}
