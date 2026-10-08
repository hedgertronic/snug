import CoreGraphics
import Testing
@testable import ScreenshotCore

struct CornerRadiusTests {
    private let shapeRect = CGRect(x: 20, y: 20, width: 140, height: 120)
    private let dimensions = (180, 160)

    private func image(radius: CGFloat, background: Int, rim: CGFloat = 0) -> CGImage {
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
            } else if background == 3 {
                bytes[index] = UInt8(60 + (pixel % width) * 120 / width)
                bytes[index + 1] = UInt8(90 + (pixel / width) * 100 / height)
                bytes[index + 2] = 140
            } else if background == 4 {
                state = state &* 1664525 &+ 1013904223
                let level = UInt8(48 + (state >> 24) % 5)
                bytes[index] = level
                bytes[index + 1] = level
                bytes[index + 2] = level + 12
            } else if background == 5 {
                let block = UInt32(pixel % width / 7 * 31 + pixel / width / 7 * 17)
                let level = UInt8(truncatingIfNeeded: (block &* 2654435761) >> 24)
                bytes[index] = level
                bytes[index + 1] = level &+ 90
                bytes[index + 2] = level &* 3
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
            if rim > 0 { context.setFillColor(CGColor(red: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1)) }
            context.fillPath()
            if rim > 0 {
                context.addPath(radius == 0
                    ? CGPath(rect: shapeRect.insetBy(dx: rim / 2, dy: rim / 2), transform: nil)
                    : CGPath(roundedRect: shapeRect.insetBy(dx: rim / 2, dy: rim / 2), cornerWidth: radius - rim / 2, cornerHeight: radius - rim / 2, transform: nil))
                context.setStrokeColor(CGColor(red: 200 / 255, green: 200 / 255, blue: 205 / 255, alpha: 1))
                context.setLineWidth(rim)
                context.strokePath()
            }
            return context.makeImage()
        }
        return result!
    }

    @Test func estimatesSyntheticCornerRadiiAcrossBackgrounds() {
        let backgrounds = [("flat", 0), ("close", 2), ("gradient", 3)]
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

    @Test func estimatesRimmedShapeOverDarkAndGradientBackgrounds() {
        for (name, background) in [("dark noise", 4), ("gradient", 3)] {
            for radius: CGFloat in [12, 24, 50] {
                let estimate = cornerRadius(in: image(radius: radius, background: background, rim: 1), rect: shapeRect)
                print("corner-radius case=rim \(name) true=\(Int(radius)) estimated=\(estimate)")
                #expect(abs(estimate - radius) <= max(2, radius * 0.1))
            }
        }
    }

    @Test func rejectsRectangleOverBusyBackground() {
        #expect(cornerRadius(in: image(radius: 0, background: 5), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 5, rim: 1), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 4, rim: 1), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 4, rim: 2), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 0, rim: 2), rect: shapeRect) == 0)
    }
    @Test func estimatesRadiusOfShapeWithSoftShadow() {
        let shapeRect = CGRect(x: 40, y: 40, width: 200, height: 160)
        for radius: CGFloat in [12, 20, 30] {
            let context = CGContext(data: nil, width: 280, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.26, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 280, height: 240))
            context.setShadow(offset: .zero, blur: 16, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
            context.addPath(CGPath(roundedRect: shapeRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillPath()
            let estimate = cornerRadius(in: context.makeImage()!, rect: shapeRect)
            #expect(abs(estimate - radius) <= max(2, radius * 0.1), "radius \(radius) estimated \(estimate)")
        }
    }
}
