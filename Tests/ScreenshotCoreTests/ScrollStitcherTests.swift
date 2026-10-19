import CoreGraphics
import Foundation
import ImageIO
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

    func image(_ bytes: [UInt8], width: Int = 160) -> CGImage {
        CGImage(width: width, height: bytes.count / (width * 4), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The screen area with the page scrolled to content row `offset`.
    func frame(_ offset: Int) -> CGImage { image(area(offset)) }

    func area(_ offset: Int) -> [UInt8] {
        [UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000 + offset, count: view) + [UInt8](repeating: 60, count: footer * width * 4)
    }

    /// Records an issue when a run of 8 rows, none of them one shade, appears twice.
    func expectNoRepeatedRows(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        let rows = stride(from: 0, to: bytes.count, by: width * 4).map { Array(bytes[$0..<($0 + width * 4)]) }
        let plain = rows.map { row in stride(from: 0, to: row.count, by: 4).allSatisfy { row[$0..<($0 + 3)] == row[0..<3] } }
        var seen: [[[UInt8]]: Int] = [:]
        for start in 0...(rows.count - 8) where !plain[start..<(start + 8)].contains(true) {
            let run = Array(rows[start..<(start + 8)])
            if let first = seen[run] {
                Issue.record("rows \(first) and \(start) repeat", sourceLocation: sourceLocation)
                return
            }
            seen[run] = start
        }
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

    /// The thumbnail reads the stitched rows and the latest frame's rows in place: at full size it is the image, and scaled it keeps
    /// the aspect ratio and the bands' shades.
    @Test func thumbnailSamplesTheStitchedImageInPlace() async {
        let stitcher = ScrollStitcher(first: frame(0))
        for offset in [50, 170, 150, 320] { await stitcher.add(frame(offset)) }
        let height = await stitcher.height
        let full = await stitcher.thumbnail(fitting: CGSize(width: 1000, height: 5000))
        #expect(full.width == width && full.height == height)
        #expect(bytes(full) == bytes(await stitcher.image()))
        let small = await stitcher.thumbnail(fitting: CGSize(width: 40, height: 5000))
        let pixels = bytes(small)
        #expect(small.width == 40 && small.height == height / 4)
        #expect(pixels[0] == 200 && pixels[(small.height - 1) * small.width * 4] == 60)
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
        #expect(await stitcher.unmatchedRows == 0)
    }

    /// A fixed column a third wide over the whole area, as a sticky sidebar: offsets still come from the content beside it. No two
    /// frames agree on a row, so rows join as they scroll out at the top and the output repeats the sidebar's top rows, a known limit
    /// that `unmatchedRows` counts; only the moving columns are compared.
    @Test func offsetsComeFromTheContentBesideAStickySidebar() async {
        func withSidebar(_ bytes: [UInt8]) -> [UInt8] {
            var bytes = bytes
            for row in header..<(header + view) {
                for column in 0..<(width / 3) {
                    let value = UInt8((row * 5 + column * 11) % 200)
                    bytes.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [value, value, value])
                }
            }
            return bytes
        }
        let stitcher = ScrollStitcher(first: image(withSidebar(textFrame(0, tooltip: nil))))
        for offset in [9, 20, 33, 41, 80, 86, 88] {
            #expect(await stitcher.add(image(withSidebar(textFrame(offset, tooltip: nil)))), "offset \(offset)")
        }
        let stitched = bytes(await stitcher.image())
        let expected = textFrame(0, tooltip: nil)[..<((header + view) * width * 4)] + (view..<(88 + view)).flatMap(page)
            + [UInt8](repeating: 60, count: footer * width * 4)
        let moving = { (bytes: [UInt8]) in stride(from: 0, to: bytes.count, by: self.width * 4).flatMap { bytes[($0 + self.width / 3 * 4)..<($0 + self.width * 4)] } }
        #expect(stitched.count == expected.count && moving(stitched) == moving(Array(expected)))
        #expect(await stitcher.unmatchedRows > 0)
    }

    /// Only the expected shifts are tried: a range without the true move adds nothing, and one around it finds the move.
    @Test func anExpectedRangeLimitsTheShiftsTried() async {
        let stitcher = ScrollStitcher(first: frame(0))
        #expect(await !stitcher.add(frame(50), expected: 60...100))
        #expect(await stitcher.add(frame(50), expected: 30...70))
        #expect(await stitcher.height == header + 50 + view + footer)
    }

    /// Scroll deltas in points, at times in seconds: each frame shows the running sum somewhere in the lag before its capture, so the
    /// range is the difference of the two, a quarter and 24 pt wider, in pixels; line deltas give only the direction.
    @Test func expectedShiftsFollowTheScrollDeltas() {
        func shifts(_ deltas: [(TimeInterval, CGFloat, Bool)]) -> ClosedRange<Int>? {
            ScrollStitcher.expectedShifts(deltas.map { ($0.0, $0.1, $0.2) }, matched: 1, now: 2, lag: 0.25, scale: 2)
        }
        // After the matched frame: the new frame shows the first 10 pt and perhaps the next 30.
        #expect(shifts([(1.5, -10, true), (1.9, -30, true)]) == -23...148)
        // Within the lag before the matched frame, which may already show its 40 pt; the new frame shows all 60.
        #expect(shifts([(0.9, -40, true), (1.5, -20, true)]) == 2...198)
        // Before the lag, so both frames show it; then 30 pt the other way.
        #expect(shifts([(0.5, -100, true), (1.5, 30, true)]) == -123...(-27))
        #expect(shifts([]) == -48...48)
        #expect(shifts([(1.5, -1, false), (1.6, -2, false)]) == 1...ScrollStitcher.maximumHeight)
        #expect(shifts([(1.5, -1, false), (1.6, 1, false)]) == nil)
    }

    /// A frosted header: its rows change with every move and never match, as a blur of the content passing under it. Offsets come
    /// from the content below it, and the stitched image ends with the page whole below the header.
    @Test func aFrostedHeaderThatNeverMatchesKeepsTheOffsets() async {
        func frosted(_ offset: Int) -> [UInt8] {
            var bytes = area(offset)
            for index in stride(from: 0, to: header * width * 4, by: 4) {
                let value = UInt8((index / 4 * 31 + offset * 97) % 251)
                bytes.replaceSubrange(index..<(index + 3), with: [value, value, value])
            }
            return bytes
        }
        let stitcher = ScrollStitcher(first: image(frosted(0)))
        for offset in [20, 45, 80, 120, 150, 190] {
            #expect(await stitcher.add(image(frosted(offset))), "offset \(offset)")
            #expect(await stitcher.height == header + offset + view + footer, "offset \(offset)")
        }
        let stitched = bytes(await stitcher.image())
        let below = header * width * 4
        #expect(Array(stitched[below...]) == rows(start: 10_000, count: 190 + view) + [UInt8](repeating: 60, count: footer * width * 4))
    }

    /// Real pixels: crops of a web page scrolled under the round 10 fixture's tooltip, pasted 15 px above the area's bottom from the
    /// third frame on, with a fast jump and a slowing tail. The output is the clean page with the tooltip once, in the latest frame.
    @Test func aRealTooltipOverARealPageAppearsOnce() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func load(_ path: String) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let page = try load("Tests/Fixtures/real-web/form-test.png")
        let (left, top, areaWidth, areaHeight) = (400, 200, 1000, 600)
        let (tipWidth, tipHeight) = (324, 16)
        let tip = bytes(try load("Tests/Fixtures/scroll-savant-tooltip-repeats.png").cropping(to: CGRect(x: 6, y: 641, width: tipWidth, height: tipHeight))!)
        let tipTop = areaHeight - 15 - tipHeight
        func frame(_ offset: Int, tooltip: Bool) -> [UInt8] {
            var frame = bytes(page.cropping(to: CGRect(x: left, y: top + offset, width: areaWidth, height: areaHeight))!)
            for row in 0..<tipHeight where tooltip {
                let start = ((tipTop + row) * areaWidth + 20) * 4
                frame.replaceSubrange(start..<(start + tipWidth * 4), with: tip[(row * tipWidth * 4)..<((row + 1) * tipWidth * 4)])
            }
            return frame
        }
        let stitcher = ScrollStitcher(first: image(frame(0, tooltip: false), width: areaWidth))
        var slowest = Duration.zero
        for (index, offset) in [40, 80, 120, 160, 310, 330, 340, 346, 350, 352, 353].enumerated() {
            let next = image(frame(offset, tooltip: index >= 1), width: areaWidth)
            let start = ContinuousClock.now
            #expect(await stitcher.add(next), "offset \(offset)")
            slowest = max(slowest, ContinuousClock.now - start)
            let (height, image) = (await stitcher.height, await stitcher.image())
            #expect(height == offset + areaHeight && image.height == height, "offset \(offset): \(height) \(image.height)")
        }
        print("slowest add at \(areaWidth) x \(areaHeight): \(slowest)")
        let expected = bytes(page.cropping(to: CGRect(x: left, y: top, width: areaWidth, height: 353))!) + frame(353, tooltip: true)
        #expect(bytes(await stitcher.image()) == expected)
    }

    /// `area` with a block pinned mid-band: content rows 90 to 140, all but 16 px at each side.
    func pinned(_ area: [UInt8]) -> [UInt8] {
        let block = rows(start: 50_000, count: 50)
        var bytes = area
        for row in 0..<50 {
            let (start, source) = (((header + 90 + row) * width + 16) * 4, (row * width + 16) * 4)
            bytes.replaceSubrange(start..<(start + (width - 32) * 4), with: block[source..<(source + (width - 32) * 4)])
        }
        return bytes
    }

    /// A block pinned mid-band while the content around it scrolls, as a sticky card: the block appears once, where the first frame
    /// showed it, the page whole below it, and no rows twice.
    @Test func aBlockPinnedMidBandAppearsOnce() async {
        func pinned(_ offset: Int) -> [UInt8] { self.pinned(area(offset)) }
        let stitcher = ScrollStitcher(first: image(pinned(0)))
        for offset in [30, 70, 100, 140, 175, 210, 260, 300] {
            #expect(await stitcher.add(image(pinned(offset))), "offset \(offset)")
            #expect(await stitcher.height == header + offset + view + footer, "offset \(offset)")
        }
        let stitched = bytes(await stitcher.image())
        let below = (header + 140) * width * 4
        let expected = Array(pinned(0)[..<below]) + rows(start: 10_140, count: 300) + pinned(300)[below...]
        #expect(stitched == expected)
        expectNoRepeatedRows(stitched)
        #expect(await stitcher.unmatchedRows == 0)
    }

    /// Stitches the page with an overlay scroller: a dark strip 80 rows tall in the last 2 columns (under 1/64 of the width) that shows
    /// once the content moves, starting `first` rows below the header and moving down a sixth as fast as the content moves up. Returns
    /// the stitched image, its rows that are neither the clean page nor the latest frame's strip, and the unmatched row count.
    func stitchUnderAScroller(first: Int, offsets: [Int]) async -> (stitched: [UInt8], wrong: [Int], unmatched: Int) {
        func top(_ offset: Int) -> Int { header + first + offset / 6 }
        func scrolled(_ offset: Int) -> [UInt8] {
            var bytes = area(offset)
            for row in top(offset)..<(top(offset) + 80) where offset > 0 {
                for column in (width - 2)..<width { bytes.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [24, 24, 24]) }
            }
            return bytes
        }
        let stitcher = ScrollStitcher(first: image(scrolled(0)))
        for offset in offsets {
            #expect(await stitcher.add(image(scrolled(offset))), "offset \(offset)")
            #expect(await stitcher.height == header + offset + view + footer, "offset \(offset)")
        }
        let (stitched, last) = (bytes(await stitcher.image()), offsets.last!)
        let (clean, latest, strip) = ([UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000, count: last) + area(last)[(header * width * 4)...],
                                      scrolled(last), (last + top(last))..<(last + top(last) + 80))
        func line(_ bytes: [UInt8], _ y: Int) -> ArraySlice<UInt8> { bytes[(y * width * 4)..<((y + 1) * width * 4)] }
        #expect(stitched.count == clean.count)
        return (stitched, (0..<(clean.count / (width * 4))).filter { y in
            line(stitched, y) != line(clean, y) && !(strip.contains(y) && line(stitched, y) == line(latest, y - last))
        }, await stitcher.unmatchedRows)
    }

    /// The overlay scroller on a long page scrolled from its top (2) and from mid-page (100), 30 to 45 px a frame: the stitched image is
    /// the clean page, with the strip at most where the latest frame shows it.
    @Test(arguments: [2, 100]) func aScrollerStripInTheLastColumnsStaysOutOfTheStitchedRows(first: Int) async {
        let (stitched, wrong, unmatched) = await stitchUnderAScroller(first: first, offsets: [40, 80, 120, 165, 200, 240, 270, 300])
        #expect(wrong.isEmpty, "rows neither the clean page nor the latest strip: \(wrong)")
        expectNoRepeatedRows(stitched)
        #expect(unmatched == 0)
    }

    /// The overlay scroller from mid-page, 15 px a frame: the strip is longer than two moves.
    @Test func aSlowScrollUnderALongScrollerStripKeepsItOut() async {
        let (_, wrong, unmatched) = await stitchUnderAScroller(first: 100, offsets: Array(stride(from: 15, through: 300, by: 15)))
        withKnownIssue("Two frames agree on the inside of a plain strip that moves slower than the content, so strip rows join, uncounted") {
            #expect(wrong.isEmpty, "rows neither the clean page nor the latest strip: \(wrong)")
        }
        #expect(unmatched == 0)
    }

    /// `pinned` content running to the area's bottom, where the window's rounded corners past a 12 px radius show the dark desktop.
    func cornered(_ offset: Int) -> [UInt8] {
        let (radius, height) = (12, header + view + footer)
        var bytes = pinned([UInt8](repeating: 200, count: header * width * 4) + rows(start: 10_000 + offset, count: view + footer))
        for row in (height - radius)..<height {
            for column in 0..<width {
                let dx = Double(min(column, width - 1 - column)) + 0.5 - Double(radius), dy = Double(row - (height - radius)) + 0.5
                if dx < 0, dx * dx + dy * dy > Double(radius * radius) {
                    bytes.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [30, 30, 30])
                }
            }
        }
        return bytes
    }

    /// Stitches `cornered` frames; returns the stitched image and what it should be: the first frame down to the pinned block's bottom,
    /// the page, and the latest frame from the block's bottom down, its corners the only ones.
    func stitchCornered(_ offsets: [Int]) async -> (stitched: [UInt8], expected: [UInt8], unmatched: Int) {
        let stitcher = ScrollStitcher(first: image(cornered(0)))
        for offset in offsets {
            #expect(await stitcher.add(image(cornered(offset))), "offset \(offset)")
            #expect(await stitcher.height == header + offset + view + footer, "offset \(offset)")
        }
        let below = (header + 140) * width * 4
        return (bytes(await stitcher.image()), Array(cornered(0)[..<below]) + rows(start: 10_140, count: offsets.last!) + cornered(offsets.last!)[below...],
                await stitcher.unmatchedRows)
    }

    /// A window's rounded bottom corners inside the area, with the pinned block above, 20 to 50 px a frame: the corners appear once, at
    /// the bottom of the stitched image.
    @Test func roundedBottomCornersAppearOnlyAtTheBottom() async {
        let (stitched, expected, unmatched) = await stitchCornered([40, 90, 130, 180, 230, 280, 300])
        #expect(stitched == expected)
        expectNoRepeatedRows(stitched)
        #expect(unmatched == 0)
    }

    /// The same area with a 70 px move after a 50 px one, so the new frame's rows past where the stitched rows end start inside the
    /// pinned block.
    @Test func aFastScrollPastAPinnedBlockKeepsItOnce() async {
        let (stitched, expected, unmatched) = await stitchCornered([40, 90, 130, 180, 250, 300])
        withKnownIssue("The joining stops inside the pinned block, so the latest frame shows it again below the first frame's, uncounted") {
            #expect(stitched == expected)
        }
        #expect(unmatched == 0)
    }
}

