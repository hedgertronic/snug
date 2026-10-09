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

    @Test func aFrameAddsTwentyFourPointsPerSide() {
        #expect(OutputFrame.rect(around: crop, scale: 2, framed: false) == crop)
        #expect(OutputFrame.rect(around: crop, scale: 2, framed: true) == CGRect(x: 52, y: 52, width: 296, height: 196))
    }

    @Test func renderedSizesMatchTheFrame() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, framed: false)
        let backdrop = try OutputFrame.render(source, crop: crop, scale: 2, framed: true)
        #expect((tight.width, tight.height) == (200, 100))
        #expect((backdrop.width, backdrop.height) == (296, 196))
    }

    @Test func unframedRadiusMasksCorners() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, framed: false, cornerRadii: CornerRadii(24))
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

    @Test func aFrameIsTransparentPaddingWithASoftShadowBelow() throws {
        let backdrop = try OutputFrame.render(image(), crop: crop, scale: 2, framed: true)
        var bytes = [UInt8](repeating: 0, count: backdrop.width * backdrop.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: backdrop.width, height: backdrop.height,
                                    bitsPerComponent: 8, bytesPerRow: backdrop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(backdrop, in: CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * backdrop.width + x) * 4 + 3] }
        #expect(alpha(0, 0) == 0)
        #expect(alpha(backdrop.width - 1, 0) == 0)
        #expect(alpha(backdrop.width / 2, backdrop.height / 2) == 255)
        // 48 px of padding below the image (top-left rows): the shadow falls just under it, and not above it.
        let below = alpha(backdrop.width / 2, backdrop.height - 48 + 6)
        #expect(below > 0 && below < 255)
        #expect(alpha(backdrop.width / 2, 0) == 0)
    }
}
