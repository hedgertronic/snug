import CoreGraphics
import Testing
@testable import ScreenshotCore

struct CornerRadiusTests {
    private let shapeRect = CGRect(x: 20, y: 20, width: 140, height: 120)
    private let dimensions = (180, 160)

    private func image(radius: CGFloat, background: Int) -> CGImage {
        let width = dimensions.0, height = dimensions.1, bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state: UInt32 = 0x12345678
        for pixel in 0..<(width * height) {
            let index = pixel * 4
            if background == 1 {
                state = state &* 1664525 &+ 1013904223
                bytes[index] = UInt8(40 + (state >> 24) % 176)
                state = state &* 1664525 &+ 1013904223
                bytes[index + 1] = UInt8(40 + (state >> 24) % 176)
                state = state &* 1664525 &+ 1013904223
                bytes[index + 2] = UInt8(40 + (state >> 24) % 176)
            } else if background == 2 {
                bytes[index] = 245
                bytes[index + 1] = 244
                bytes[index + 2] = 242
            } else {
                bytes[index] = 250
                bytes[index + 1] = 250
                bytes[index + 2] = 250
            }
            bytes[index + 3] = 255
        }
        let result = bytes.withUnsafeMutableBytes { storage -> CGImage? in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.setShouldAntialias(true)
            let path = radius == 0
                ? CGPath(rect: shapeRect, transform: nil)
                : CGPath(roundedRect: shapeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(CGColor(red: 220 / 255, green: 220 / 255, blue: 220 / 255, alpha: 1))
            context.fillPath()
            return context.makeImage()
        }
        return result!
    }

    @Test func estimatesSyntheticCornerRadiiAcrossBackgrounds() {
        let backgrounds = [("flat", 0), ("close", 2)]
        for (name, background) in backgrounds {
            for radius: CGFloat in [0, 8, 20, 40, 60] {
                let estimate = cornerRadius(in: image(radius: radius, background: background), rect: shapeRect)
                print("corner-radius case=\(name) true=\(Int(radius)) estimated=\(estimate)")
                if radius == 0 {
                    #expect(estimate == 0)
                } else {
                    #expect(abs(estimate - radius) <= max(2, radius * 0.05))
                }
            }
        }
    }

    @Test func rejectsRectangleOverNonuniformBackground() {
        #expect(cornerRadius(in: image(radius: 0, background: 1), rect: shapeRect) == 0)
    }
}
