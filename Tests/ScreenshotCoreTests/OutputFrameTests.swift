import CoreGraphics
import Testing
@testable import ScreenshotCore

struct OutputFrameTests {
    let crop = CGRect(x: 100, y: 100, width: 200, height: 100)

    func image() -> CGImage {
        let context = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        return context.makeImage()!
    }

    @Test func aFrameAddsItsPaddingPerSide() {
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: nil) == crop)
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: 24) == CGRect(x: 52, y: 52, width: 296, height: 196))
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: 16) == CGRect(x: 68, y: 68, width: 264, height: 164))
        #expect(OutputFrame.rect(around: crop, scale: 1, padding: 40) == CGRect(x: 60, y: 60, width: 280, height: 180))
    }

    @Test func renderedSizesMatchTheFrame() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, padding: nil)
        #expect((tight.width, tight.height) == (200, 100))
        for padding in [16.0, 24, 40] {
            let backdrop = try OutputFrame.render(source, crop: crop, scale: 2, padding: padding)
            #expect((backdrop.width, backdrop.height) == (200 + Int(4 * padding), 100 + Int(4 * padding)))
        }
    }

    @Test func unframedRadiusMasksCorners() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, padding: nil, cornerRadii: CornerRadii(24))
        var tightBytes = [UInt8](repeating: 0, count: tight.width * tight.height * 4)
        tightBytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: tight.width, height: tight.height,
                                    bitsPerComponent: 8, bytesPerRow: tight.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(tight, in: CGRect(x: 0, y: 0, width: tight.width, height: tight.height))
        }
        #expect(tightBytes[3] == 0)
        #expect(tightBytes[((tight.height / 2) * tight.width + tight.width / 2) * 4 + 3] == 255)
    }

    /// At each padding and scale the shadow falls just under the image, not above it, and fades out inside the canvas.
    @Test(arguments: [16.0, 24, 40], [1.0, 2])
    func aFrameIsTransparentPaddingWithASoftShadowBelow(padding: CGFloat, scale: CGFloat) throws {
        let backdrop = try OutputFrame.render(image(), crop: crop, scale: scale, padding: padding)
        var bytes = [UInt8](repeating: 0, count: backdrop.width * backdrop.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: backdrop.width, height: backdrop.height,
                                    bitsPerComponent: 8, bytesPerRow: backdrop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(backdrop, in: CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * backdrop.width + x) * 4 + 3] }
        let pad = Int(padding * scale)
        #expect(alpha(0, 0) == 0)
        #expect(alpha(backdrop.width - 1, 0) == 0)
        #expect(alpha(backdrop.width / 2, backdrop.height / 2) == 255)
        // Rows run top-left down: `pad` rows of padding below the image, with the shadow just under it and not above it.
        let below = alpha(backdrop.width / 2, backdrop.height - pad + pad / 8)
        #expect(below > 0 && below < 255)
        #expect(alpha(backdrop.width / 2, 0) == 0)
        // The shadow has faded out at the bottom row and the side columns, so the canvas does not clip it.
        #expect((0..<backdrop.width).allSatisfy { alpha($0, backdrop.height - 1) <= 2 })
        #expect((0..<backdrop.height).allSatisfy { alpha(0, $0) <= 2 && alpha(backdrop.width - 1, $0) <= 2 })
    }
}
