import Foundation
import CoreGraphics
import Testing
@testable import ScreenshotCore

struct WindowInteriorTests {
    /// An sRGB premultiplied RGBA image whose pixel at (x, y) (top-left origin) is `pixel(x, y)`.
    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]) = pixel(x, y)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return Array(data[(y * image.bytesPerRow + x * 4)..<(y * image.bytesPerRow + x * 4 + 4)])
    }

    /// ScreenCaptureKit's capture of a blurred terminal: a 100 x 80 window of flat material gray (105, 107, 109) at (10, 6) in a shadow
    /// (black, alpha 80) that reaches further below, its corner pixels cut to alpha 0 and the pixel next to the top-left corner antialiased
    /// (alpha 128).
    private var capture: CGImage {
        image(width: 120, height: 100) { x, y in
            let window = (10..<110).contains(x) && (6..<86).contains(y)
            if [(10, 6), (109, 6), (10, 85), (109, 85)].contains(where: { $0 == (x, y) }) { return (0, 0, 0, 0) }
            if (x, y) == (11, 6) { return (53, 54, 55, 128) }
            return window ? (105, 107, 109, 255) : (0, 0, 0, 80)
        }
    }

    /// The same window on the frozen display: a dark terminal (20, 20, 20) with a red marker in its top-left quadrant.
    private func frozen(width: Int = 100, height: Int = 80) -> CGImage {
        image(width: width, height: height) { x, y in (5..<15).contains(x) && (5..<15).contains(y) ? (255, 0, 0, 255) : (20, 20, 20, 255) }
    }

    @Test func theWindowTakesTheFrozenPixelsAndKeepsItsShapeAndShadow() throws {
        let filled = try #require(fillingWindowInterior(capture, from: frozen()))
        #expect(rgba(filled, 20, 16) == [255, 0, 0, 255])
        #expect(rgba(filled, 20, 76) == [20, 20, 20, 255] && rgba(filled, 100, 80) == [20, 20, 20, 255] && rgba(filled, 60, 50) == [20, 20, 20, 255])
        #expect(rgba(filled, 5, 5) == [0, 0, 0, 80] && rgba(filled, 115, 95) == [0, 0, 0, 80])
        #expect(rgba(filled, 10, 6) == [0, 0, 0, 0] && rgba(filled, 109, 85) == [0, 0, 0, 0])
        #expect(rgba(filled, 11, 6) == [53, 54, 55, 128])
    }

    @Test func aWindowWhoseSizeDiffersFromTheFrozenOneKeepsItsCapture() {
        #expect(fillingWindowInterior(capture, from: frozen(width: 90)) == nil)
        #expect(fillingWindowInterior(capture, from: frozen(height: 76)) == nil)
        #expect(fillingWindowInterior(capture, from: frozen(width: 98, height: 82)) != nil)
    }
}
