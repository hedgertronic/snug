import Foundation
import CoreGraphics
import simd

/// An sRGB color with components in 0...1.
public struct SRGBColor: Sendable, Equatable {
    public var red, green, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// How a picked color is written to the pasteboard.
public enum ColorFormat: String, CaseIterable, Sendable {
    case hex, rgb, hsl, swift

    public var label: String { self == .swift ? "Swift" : rawValue.uppercased() }

    /// The next format, wrapping around.
    public var next: ColorFormat {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public func string(for color: SRGBColor) -> String {
        let r = Int((color.red * 255).rounded()), g = Int((color.green * 255).rounded()), b = Int((color.blue * 255).rounded())
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let high = max(color.red, color.green, color.blue), low = min(color.red, color.green, color.blue)
            let lightness = (high + low) / 2
            let spread = high - low
            var hue = 0.0
            var saturation = 0.0
            if spread > 0 {
                saturation = spread / (1 - abs(2 * lightness - 1))
                switch high {
                case color.red: hue = (color.green - color.blue) / spread
                case color.green: hue = (color.blue - color.red) / spread + 2
                default: hue = (color.red - color.green) / spread + 4
                }
                hue = (hue * 60).truncatingRemainder(dividingBy: 360)
                if hue < 0 { hue += 360 }
            }
            return "hsl(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
        case .swift:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", color.red, color.green, color.blue)
        }
    }

    /// The mean sRGB color of `rect` (image pixels, top-left origin). The image may use any color space.
    public static func average(of image: CGImage, in rect: CGRect) -> SRGBColor {
        let crop = image.cropping(to: rect)!
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                    bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var sums = [0, 0, 0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Int(pixels[index + channel]) }
        }
        let scale = Double(crop.width * crop.height) * 255
        return SRGBColor(red: Double(sums[0]) / scale, green: Double(sums[1]) / scale, blue: Double(sums[2]) / scale)
    }

    /// The main colors of `rect` (image pixels, top-left origin), most common first. Median cut over a copy of the crop sampled down to
    /// about 64k pixels makes 24 buckets (a box is split on its widest channel at that channel's mean, the one with the most pixels times
    /// that range first). Buckets under 0.1% of the pixels are noise and drop out. Up to `count` bucket means are then chosen in OKLab by
    /// farthest-point selection: the commonest first, then repeatedly the one whose distance to the chosen ones times the square root of
    /// its share is largest, stopping when every remaining bucket is within 0.05 of a chosen color. Small accents like a blue row
    /// survive next to large gray areas; fewer than `count` come back when the region has fewer distinct colors.
    public static func palette(of image: CGImage, in rect: CGRect, count: Int = 5) -> [SRGBColor] {
        let crop = image.cropping(to: rect)!
        let shrink = min(1, (65_536 / Double(crop.width * crop.height)).squareRoot())
        let width = max(1, Int(Double(crop.width) * shrink)), height = max(1, Int(Double(crop.height) * shrink))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var pixels = (0..<width * height).map { SIMD3<Int>(Int(bytes[$0 * 4]), Int(bytes[$0 * 4 + 1]), Int(bytes[$0 * 4 + 2])) }
        func widest(_ box: Range<Int>) -> (channel: Int, range: Int) {
            let low = pixels[box].reduce(SIMD3<Int>(repeating: 255)) { $0.replacing(with: $1, where: $1 .< $0) }
            let high = pixels[box].reduce(SIMD3<Int>(repeating: 0)) { $0.replacing(with: $1, where: $1 .> $0) }
            let spread = high &- low
            let channel = spread.x >= max(spread.y, spread.z) ? 0 : spread.y >= spread.z ? 1 : 2
            return (channel, spread[channel])
        }
        var boxes = [(pixels: pixels.indices, widest: widest(pixels.indices))]
        while boxes.count < 24, let split = boxes.indices.filter({ boxes[$0].pixels.count > 1 && boxes[$0].widest.range > 0 }).max(by: { boxes[$0].pixels.count * boxes[$0].widest.range < boxes[$1].pixels.count * boxes[$1].widest.range }) {
            let (box, (channel, _)) = boxes.remove(at: split)
            let sum = pixels[box].reduce(SIMD3<Int>.zero, &+)
            let middle = pixels[box].partition { $0[channel] * box.count > sum[channel] }
            boxes += [box.lowerBound..<middle, middle..<box.upperBound].map { ($0, widest($0)) }
        }
        let buckets = boxes.map(\.pixels).filter { $0.count * 1000 >= pixels.count }.sorted { $0.count > $1.count }.map { box -> (color: SRGBColor, lab: SIMD3<Double>, share: Double) in
            let sum = pixels[box].reduce(SIMD3<Int>.zero, &+)
            let scale = Double(box.count) * 255
            let color = SRGBColor(red: Double(sum.x) / scale, green: Double(sum.y) / scale, blue: Double(sum.z) / scale)
            return (color, color.oklab, Double(box.count) / Double(pixels.count))
        }
        var chosen = [0]
        var gap = buckets.map { simd_distance($0.lab, buckets[0].lab) }
        while chosen.count < count, let next = buckets.indices.filter({ gap[$0] >= 0.05 }).max(by: { gap[$0] * buckets[$0].share.squareRoot() < gap[$1] * buckets[$1].share.squareRoot() }) {
            chosen.append(next)
            gap = zip(gap, buckets).map { min($0, simd_distance($1.lab, buckets[next].lab)) }
        }
        return chosen.sorted().map { buckets[$0].color }
    }
}

extension SRGBColor {
    /// The color in OKLab (L, a, b), the space where Euclidean distance tracks perceived difference.
    var oklab: SIMD3<Double> {
        let linear = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear[0], linear[1], linear[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
