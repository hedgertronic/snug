import Foundation
import CoreGraphics

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

    /// The main colors of `rect` (image pixels, top-left origin), most common first: median cut over a copy of the crop sampled down
    /// to about 64k pixels. A box is split on its widest channel at that channel's mean, the one with the most pixels times that range first;
    /// fewer than `count` come back when the region has fewer distinct colors.
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
        var boxes = [pixels.indices]
        while boxes.count < count, let split = boxes.indices.filter({ boxes[$0].count > 1 && widest(boxes[$0]).range > 0 }).max(by: { boxes[$0].count * widest(boxes[$0]).range < boxes[$1].count * widest(boxes[$1]).range }) {
            let box = boxes.remove(at: split), channel = widest(box).channel
            let sum = pixels[box].reduce(SIMD3<Int>.zero, &+)
            let middle = pixels[box].partition { $0[channel] * box.count > sum[channel] }
            boxes += [box.lowerBound..<middle, middle..<box.upperBound]
        }
        return boxes.sorted { $0.count > $1.count }.map { box in
            let sum = pixels[box].reduce(SIMD3<Int>.zero, &+)
            let scale = Double(box.count) * 255
            return SRGBColor(red: Double(sum.x) / scale, green: Double(sum.y) / scale, blue: Double(sum.z) / scale)
        }
    }
}
