import CoreGraphics
import Testing
@testable import ScreenshotCore

struct ColorFormatTests {
    let slate = SRGBColor(red: 0.2, green: 0.4, blue: 0.6)

    func solid(_ color: CGColor, space: CGColorSpace) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    @Test func formatsEachStyle() {
        #expect(ColorFormat.hex.string(for: slate) == "#336699")
        #expect(ColorFormat.rgb.string(for: slate) == "rgb(51, 102, 153)")
        #expect(ColorFormat.hsl.string(for: slate) == "hsl(210, 50%, 40%)")
        #expect(ColorFormat.swift.string(for: slate) == "Color(red: 0.200, green: 0.400, blue: 0.600)")
    }

    @Test func hslCoversPrimariesAndGray() {
        #expect(ColorFormat.hsl.string(for: SRGBColor(red: 1, green: 0, blue: 0)) == "hsl(0, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: SRGBColor(red: 0, green: 1, blue: 0)) == "hsl(120, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: SRGBColor(red: 1, green: 0, blue: 1)) == "hsl(300, 100%, 50%)")
        #expect(ColorFormat.hsl.string(for: SRGBColor(red: 0.5, green: 0.5, blue: 0.5)) == "hsl(0, 0%, 50%)")
    }

    @Test func cyclesThroughAllFormats() {
        #expect(ColorFormat.hex.next == .rgb)
        #expect(ColorFormat.swift.next == .hex)
        #expect(ColorFormat.swift.label == "Swift")
        #expect(ColorFormat.hex.label == "HEX")
    }

    @Test func averagesSRGBPixels() {
        let image = solid(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let color = ColorFormat.average(of: image, in: CGRect(x: 1, y: 1, width: 1, height: 1))
        #expect(ColorFormat.hex.string(for: color) == "#336699")
    }

    @Test func convertsDisplayP3ToSRGB() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let source = CGColor(colorSpace: p3, components: [0.2, 0.6, 0.4, 1])!
        let image = solid(source, space: p3)
        let expected = source.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        let color = ColorFormat.average(of: image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(abs(color.red - expected[0]) < 0.01 && abs(color.green - expected[1]) < 0.01 && abs(color.blue - expected[2]) < 0.01)
        #expect(ColorFormat.hex.string(for: color) != "#339966")
    }

    @Test func averagesAMixedRegion() {
        let context = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let color = ColorFormat.average(of: context.makeImage()!, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(ColorFormat.rgb.string(for: color) == "rgb(128, 128, 128)")
    }
}
