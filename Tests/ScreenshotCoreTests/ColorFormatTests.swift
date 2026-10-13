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

    /// A `width` x `height` sRGB image of vertical stripes: each color with its width in pixels, left to right.
    func stripes(_ bands: [(color: (Double, Double, Double), width: Int)], height: Int) -> CGImage {
        let context = CGContext(data: nil, width: bands.map(\.width).reduce(0, +), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x = 0
        for band in bands {
            context.setFillColor(CGColor(srgbRed: band.color.0, green: band.color.1, blue: band.color.2, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: band.width, height: height))
            x += band.width
        }
        return context.makeImage()!
    }

    @Test func paletteOfAFlatRegionIsOneColor() {
        let palette = ColorFormat.palette(of: stripes([((0.2, 0.4, 0.6), 8)], height: 8), in: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(palette.map(ColorFormat.hex.string) == ["#336699"])
    }

    @Test func paletteListsTheCommonestColorFirst() {
        let image = stripes([((1, 0, 0), 10), ((0, 0, 1), 30)], height: 10)
        let palette = ColorFormat.palette(of: image, in: CGRect(x: 0, y: 0, width: 40, height: 10))
        #expect(palette.map(ColorFormat.hex.string) == ["#0000FF", "#FF0000"])
    }

    @Test func paletteFindsFiveColorsMostCommonFirst() {
        let bands: [(color: (Double, Double, Double), width: Int)] = [((0, 0, 0), 10), ((1, 1, 0), 20), ((0, 0, 1), 30), ((0, 1, 0), 40), ((1, 0, 0), 50)]
        let palette = ColorFormat.palette(of: stripes(bands, height: 20), in: CGRect(x: 0, y: 0, width: 150, height: 20))
        #expect(palette.map(ColorFormat.hex.string) == ["#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#000000"])
    }

    @Test func paletteStopsAtFiveColors() {
        let bands: [(color: (Double, Double, Double), width: Int)] = [((1, 0, 0), 50), ((0, 1, 0), 40), ((0, 0, 1), 30), ((1, 1, 0), 20), ((0, 0, 0), 10), ((1, 1, 1), 5)]
        #expect(ColorFormat.palette(of: stripes(bands, height: 20), in: CGRect(x: 0, y: 0, width: 155, height: 20)).count == 5)
    }

    @Test func paletteSamplesALargeRegionDown() {
        let image = stripes([((1, 0, 0), 1500), ((0, 0, 1), 1500)], height: 1000)
        let palette = ColorFormat.palette(of: image, in: CGRect(x: 0, y: 0, width: 3000, height: 1000))
        #expect(Set(palette.map(ColorFormat.hex.string)) == ["#FF0000", "#0000FF"])
    }

    @Test func paletteReadsOnlyTheRect() {
        let image = stripes([((1, 0, 0), 10), ((0, 0, 1), 10)], height: 10)
        #expect(ColorFormat.palette(of: image, in: CGRect(x: 10, y: 0, width: 10, height: 10)).map(ColorFormat.hex.string) == ["#0000FF"])
    }
}
