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
}
