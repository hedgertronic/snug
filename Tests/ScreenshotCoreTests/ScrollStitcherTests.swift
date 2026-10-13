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

    /// A text page: runs of white rows between rows of dark marks on white, every marked row different.
    func page(_ row: Int) -> [UInt8] {
        (0..<width).flatMap { column -> [UInt8] in
            var hash = UInt32(truncatingIfNeeded: row &* 73_856_093 ^ column &* 19_349_663)
            hash ^= hash >> 13
            hash = hash &* 0x5BD1_E995
            hash ^= hash >> 15
            let mark = row % 17 < 11 && hash % 5 == 0
            let value: UInt8 = mark ? UInt8(20 + (row + column) % 60) : 255
            return [value, value, value, 255]
        }
    }

    /// The text page scrolled to `offset` under the header and above the footer, with a dark tooltip (a third of the width,
    /// uniform padding around light marks) whose top sits at screen row `tooltip`.
    func textFrame(_ offset: Int, tooltip: Int?) -> [UInt8] {
        let tip = 15, left = 6, right = 6 + width / 3
        var bytes = [UInt8](repeating: 200, count: header * width * 4) + (offset..<(offset + view)).flatMap(page)
            + [UInt8](repeating: 60, count: footer * width * 4)
        guard let tooltip else { return bytes }
        for row in tooltip..<(tooltip + tip) {
            for column in left..<right {
                let mark = (4..<11).contains(row - tooltip) && (row * 3 + column * 7) % 4 == 0
                let value: UInt8 = mark ? 235 : 32
                bytes.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [value, value, value])
            }
        }
        return bytes
    }

    @Test func stitchesScrolledFramesWithStickyBandsOnce() async {
        let stitcher = ScrollStitcher(first: frame(0))
        // Still, down, down, a small scroll back up, then further down.
        for (offset, adds) in [(0, false), (50, true), (170, true), (150, true), (320, true), (530, true)] {
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

    /// Scrolling back up trims the end to the bottom of the view and scrolling down adds it back; the height counts the image
    /// throughout. Above the first frame nothing changes.
    @Test func scrollingUpTrimsAndScrollingDownAddsBack() async {
        let stitcher = ScrollStitcher(first: frame(0))
        for (offset, moves) in [(60, true), (180, true), (150, true), (40, true), (0, true), (-20, false), (90, true), (250, true), (210, true)] {
            #expect(await stitcher.add(frame(offset)) == moves, "offset \(offset)")
            let (height, image) = (await stitcher.height, await stitcher.image())
            #expect(height == header + max(offset, 0) + view + footer && image.height == height, "offset \(offset): \(height) \(image.height)")
        }
        let expected = [UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000, count: 210 + view)
            + [UInt8](repeating: 60, count: footer * width * 4)
        #expect(bytes(await stitcher.image()) == expected)
    }

    /// A tooltip that appears mid-scroll just above the bottom of the area, as on the round 10 fixture, with shifts smaller than it
    /// and a slowing tail of 1 to 6 px: the output is the page with the tooltip once, where the latest frame shows it.
    @Test func aPartialWidthOverlayAtTheBottomIsNeverRepeated() async {
        let tooltip = header + view - 18
        let steps = [(0, false), (10, false), (21, true), (32, true), (42, true), (53, true), (61, true), (100, true), (110, true),
                     (116, true), (121, true), (124, true), (126, true), (127, true)]
        let stitcher = ScrollStitcher(first: image(textFrame(0, tooltip: nil)))
        for (offset, shown) in steps.dropFirst() {
            #expect(await stitcher.add(image(textFrame(offset, tooltip: shown ? tooltip : nil))), "offset \(offset)")
            let (height, image) = (await stitcher.height, await stitcher.image())
            #expect(height == header + offset + view + footer && image.height == height, "offset \(offset): \(height) \(image.height)")
        }
        let latest = textFrame(127, tooltip: tooltip)
        let expected = [UInt8](repeating: 200, count: header * width * 4) + (0..<127).flatMap(page) + latest[(header * width * 4)...]
        #expect(bytes(await stitcher.image()) == expected)
    }

    /// A tooltip fixed in the upper part of the area: offsets come from the content that moves, and the tooltip stays once where
    /// the first frame showed it.
    @Test func offsetsComeFromTheContentUnderAPartialWidthOverlay() async {
        let tooltip = header + 50
        let stitcher = ScrollStitcher(first: image(textFrame(0, tooltip: tooltip)))
        for offset in [7, 19, 30, 44, 52, 66, 90, 95, 97] {
            #expect(await stitcher.add(image(textFrame(offset, tooltip: tooltip))), "offset \(offset)")
        }
        let first = textFrame(0, tooltip: tooltip)
        let expected = first[..<((header + view) * width * 4)] + (view..<(97 + view)).flatMap(page)
            + [UInt8](repeating: 60, count: footer * width * 4)
        #expect(bytes(await stitcher.image()) == Array(expected))
    }
}
