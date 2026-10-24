import CoreGraphics
import Testing
@testable import ScreenshotCore

struct CutoutOutputTests {
    /// A 200 x 200 transparent image with `shape` filled opaque red (top-left origin).
    func subject(_ shape: CGRect, oval: Bool) -> CGImage {
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let flipped = CGRect(x: shape.minX, y: 200 - shape.maxY, width: shape.width, height: shape.height)
        if oval { context.fillEllipse(in: flipped) } else { context.fill(flipped) }
        return context.makeImage()!
    }

    /// The image's alpha at a pixel, top-left origin.
    func alpha(_ image: CGImage) -> (Int, Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return { x, y in bytes[(y * image.width + x) * 4 + 3] }
    }

    @Test func uncroppedOutputMasksTheCanvasCornersWithTheRadii() throws {
        let full = subject(CGRect(x: 0, y: 0, width: 200, height: 200), oval: false)
        let output = try OutputFrame.renderCutout(full, bounds: nil, cornerRadii: CornerRadii(24), framed: false, scale: 2)
        let a = alpha(output)
        #expect((output.width, output.height) == (200, 200))
        #expect(a(0, 0) == 0 && a(199, 199) == 0)
        #expect(a(100, 0) == 255 && a(100, 100) == 255)
    }

    @Test func croppedOutputIsTheBoundsWithNoPaddingAndNoRadius() throws {
        let bounds = CGRect(x: 30, y: 50, width: 120, height: 80)
        let output = try OutputFrame.renderCutout(subject(bounds, oval: false), bounds: bounds, cornerRadii: CornerRadii(24), framed: false, scale: 2)
        let a = alpha(output)
        #expect((output.width, output.height) == (120, 80))
        #expect(a(0, 0) == 255 && a(119, 79) == 255)
    }

    @Test func theShadowFollowsTheSubjectsAlphaAndFallsBelowIt() throws {
        let disc = CGRect(x: 60, y: 60, width: 80, height: 80)
        let output = try OutputFrame.renderCutout(subject(disc, oval: true), bounds: disc, cornerRadii: .zero, framed: true, scale: 2)
        let a = alpha(output)
        // 104 px of padding to the sides, 70 above and 140 below the 80 px disc.
        #expect((output.width, output.height) == (80 + 208, 80 + 70 + 140))
        let (centerX, top, bottom) = (104 + 40, 70, 70 + 80)
        #expect(a(centerX, top + 40) == 255)
        // Just outside the disc the shadow shows, more below than above; the disc's own bounding-box corner stays clearer than its bottom edge.
        let below = a(centerX, bottom + 10), above = a(centerX, top - 10)
        #expect(below > 60 && above < below)
        #expect(a(104, bottom - 1) < below)
        // It has faded out at the canvas edges.
        #expect(a(0, 0) <= 2 && a(output.width - 1, output.height - 1) <= 2 && a(centerX, output.height - 1) <= 2)
    }

    /// Frame off adds nothing; on, a subject gets the window shadow's canvas and an area or element the card's padding (24 pt here).
    @Test func outputSizesByTargetAndFrame() throws {
        let full = subject(CGRect(x: 0, y: 0, width: 200, height: 200), oval: false)
        let crop = CGRect(x: 0, y: 0, width: 200, height: 200)
        for scale in [1.0, 2.0] {
            let padding = OutputFrame.shadowPadding(scale: scale)
            let off = try OutputFrame.renderCutout(full, bounds: nil, cornerRadii: .zero, framed: false, scale: scale)
            let on = try OutputFrame.renderCutout(full, bounds: nil, cornerRadii: .zero, framed: true, scale: scale)
            #expect((off.width, off.height) == (200, 200))
            #expect((on.width, on.height) == (200 + 2 * padding.sides, 200 + padding.top + padding.bottom))
            let pad = Int(24 * scale)
            #expect(try OutputFrame.render(full, crop: crop, scale: scale, padding: nil).width == 200)
            let area = try OutputFrame.render(full, crop: crop, scale: scale, padding: 24)
            #expect((area.width, area.height) == (200 + 2 * pad, 200 + 2 * pad))
        }
        #expect(OutputFrame.shadowPadding(scale: 2) == (104, 70, 140))
    }
}
