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
}
