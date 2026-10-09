import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

struct ScrollStitcherTests {
    let width = 160
    let header = 40, footer = 30, view = 230

    /// RGBA rows: a sticky header, `count` rows of content starting at content row `start`, and a sticky footer.
    func rows(start: Int, count: Int) -> [UInt8] {
        func row(_ seed: Int, shade: UInt8? = nil) -> [UInt8] {
            (0..<width).flatMap { column -> [UInt8] in
                if let shade { return [shade, shade, shade, 255] }
                let value = UInt8((seed * 7919 + column * 104_729 + (seed * column) % 251) % 256)
                return [value, UInt8((Int(value) + seed) % 256), UInt8((Int(value) * 3) % 256), 255]
            }
        }
        return (0..<count).flatMap { row(start + $0) }
    }

    func image(_ bytes: [UInt8]) -> CGImage {
        CGImage(width: width, height: bytes.count / (width * 4), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The screen area with the page scrolled to content row `offset`.
    func frame(_ offset: Int) -> CGImage {
        image([UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000 + offset, count: view)
              + [UInt8](repeating: 60, count: footer * width * 4))
    }

    func bytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test func stitchesScrolledFramesWithStickyBandsOnce() async {
        let stitcher = ScrollStitcher(first: frame(0))
        // Still, down, down, a small scroll back up, then further down.
        for (offset, adds) in [(0, false), (50, true), (170, true), (150, false), (320, true), (530, true)] {
            #expect(await stitcher.add(frame(offset)) == adds, "offset \(offset)")
        }
        let expected = [UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000, count: 530 + view)
            + [UInt8](repeating: 60, count: footer * width * 4)
        let stitched = bytes(await stitcher.image())
        #expect(stitched.count == expected.count)
        #expect(stitched == expected)
    }

    @Test func aFrameThatMatchesNowhereAddsNothing() async {
        let stitcher = ScrollStitcher(first: frame(0))
        #expect(await !stitcher.add(frame(5_000)))
        #expect(await stitcher.height == header + view + footer)
    }
}
