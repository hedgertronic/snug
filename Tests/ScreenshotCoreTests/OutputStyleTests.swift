import CoreGraphics
import Testing
@testable import ScreenshotCore

struct OutputStyleTests {
    let extent = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let crop = CGRect(x: 100, y: 100, width: 200, height: 100)

    func image() -> CGImage {
        let context = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        return context.makeImage()!
    }

    @Test func cyclesThroughAllStyles() {
        #expect(OutputStyle.tight.next == .margin)
        #expect(OutputStyle.margin.next == .backdrop)
        #expect(OutputStyle.backdrop.next == .tight)
    }

    @Test func marginAddsSixteenPointsPerSideAndClampsToTheImage() {
        #expect(OutputStyle.margin.frame(around: crop, in: extent, scale: 2) == CGRect(x: 68, y: 68, width: 264, height: 164))
        let corner = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(OutputStyle.margin.frame(around: corner, in: extent, scale: 2) == CGRect(x: 0, y: 0, width: 132, height: 132))
    }

    @Test func renderedSizesMatchTheFrame() throws {
        let source = image()
        let tight = try OutputStyle.tight.render(source, crop: crop, scale: 2)
        let margin = try OutputStyle.margin.render(source, crop: crop, scale: 2)
        let backdrop = try OutputStyle.backdrop.render(source, crop: crop, scale: 2)
        #expect((tight.width, tight.height) == (200, 100))
        #expect((margin.width, margin.height) == (264, 164))
        #expect((backdrop.width, backdrop.height) == (296, 196))
    }

    @Test func tightRadiusMasksCornersAndMarginIgnoresRadius() throws {
        let source = image()
        let tight = try OutputStyle.tight.render(source, crop: crop, scale: 2, cornerRadius: 24)
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

        let margin = try OutputStyle.margin.render(source, crop: crop, scale: 2)
        let marginWithRadius = try OutputStyle.margin.render(source, crop: crop, scale: 2, cornerRadius: 24)
        #expect(margin.width == marginWithRadius.width)
        #expect(margin.height == marginWithRadius.height)
        #expect(ColorFormat.average(of: margin, in: CGRect(x: 0, y: 0, width: margin.width, height: margin.height)) ==
                ColorFormat.average(of: marginWithRadius, in: CGRect(x: 0, y: 0, width: marginWithRadius.width, height: marginWithRadius.height)))
    }
}
