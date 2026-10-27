import CoreGraphics
import Foundation

/// Joins same-size frames of one screen area, captured while its content scrolls, into one tall image that ends with the latest
/// frame: scrolling back up trims the end, and scrolling down again adds it back.
///
/// Rows that stay identical at the top and bottom of the area when it first moves are fixed bands (a sticky header or footer):
/// the header appears once at the top. Each frame is matched against the last matched frame on 64 luminance samples a row, those
/// that changed, so a fixed overlay does not steer the offset.
///
/// When the area first moves, the first frame joins the stitched image down to its lowest row that matches the new frame one move
/// away, so a footer, the window's rounded corners or an overlay at the bottom stay out, and pinned content above stays where the
/// first frame showed it. After that, a row joins once two matched frames agree on it one move apart, every pixel of it, in order
/// from where the stitched rows end; the latest frame supplies the rest. Content that stays put or changes in place stops the
/// joining there and appears once, where the latest frame shows it: an overlay scroller moving down the last columns, a tooltip, an
/// animation. Between two frames the seam goes on the joined row that changed least. A row that scrolls out above the bands before
/// two frames agreed on it joins as the latest frame showed it; `unmatchedRows` counts those whose comparison had failed, where the
/// result can repeat or mix content. A frame that did not move, moved up past the first frame, or matches nowhere changes nothing.
///
/// Known limits: two frames agree on the inside of a plain overlay that moves slower than the content (a scroller longer than two
/// moves), so it can join; and a move that starts the new frame's rows inside pinned content shows it a second time. Neither counts
/// in `unmatchedRows`.
public actor ScrollStitcher {
    /// The tallest stitched image, in pixels.
    public static let maximumHeight = 30_000
    /// The most pixels in a stitched image: 60 megapixels, 229 MiB of RGBA, so a wide area stops sooner than `maximumHeight` (at
    /// 6,000 px wide, at 10,000 px tall).
    public static let maximumPixels = 60_000_000

    public let width: Int
    /// This capture's tallest image: `maximumHeight`, or fewer rows when `maximumPixels` runs out first, never under one frame.
    public nonisolated let heightLimit: Int
    private let frameHeight: Int
    private let bytesPerRow: Int
    /// Stitched rows, RGBA; the output continues with the latest frame from row `cursor` down.
    private var body: [UInt8]
    /// The last matched frame, each of its rows' luminance samples, and the row of it where `body` ends.
    private var latest: [UInt8]
    private var latestRows: [[Int16]]
    private var cursor: Int
    /// Whether the latest frame's row at `cursor` failed the comparison with the frame before it.
    private var mismatched = false
    /// Fixed top and bottom bands, set when the area first moves.
    private var bands: (top: Int, bottom: Int)?
    /// Rows that joined the stitched image as one frame showed them after failing the comparison between two frames.
    public private(set) var unmatchedRows = 0

    public init(first: CGImage, maximumPixels: Int = ScrollStitcher.maximumPixels) {
        width = first.width
        frameHeight = first.height
        heightLimit = min(Self.maximumHeight, max(first.height, maximumPixels / max(1, first.width)))
        bytesPerRow = first.width * 4
        let bytes = Self.rgba(first)
        body = bytes
        latest = bytes
        latestRows = Self.rows(bytes, width: first.width, height: first.height)
        cursor = first.height
    }

    /// Stitched height in pixels, the height of `image()`.
    public var height: Int { min(body.count / bytesPerRow + frameHeight - cursor, heightLimit) }

    /// Whether the image has reached `heightLimit`: scrolling further down adds nothing; scrolling back up still trims it.
    public var isFull: Bool { height >= heightLimit }

    /// Adds a frame; returns whether it matched a move.
    @discardableResult
    public func add(_ frame: CGImage) -> Bool {
        guard frame.width == width, frame.height == frameHeight else { return false }
        let bytes = Self.rgba(frame)
        let rows = Self.rows(bytes, width: width, height: frameHeight)
        // Samples that kept their value at the same screen position: a fixed overlay or a plain background, which say nothing
        // about the move.
        let still = zip(latestRows, rows).map { zip($0, $1).map { $0 == $1 } }
        let same = still.map { !$0.contains(false) }
        guard same.contains(false) else { return false }
        let fixed = bands ?? (
            top: min(same.prefix { $0 }.count, frameHeight / 3),
            bottom: min(same.reversed().prefix { $0 }.count, frameHeight / 3)
        )
        let band = fixed.top..<(frameHeight - fixed.bottom)
        // The content moved down by `shift` when the new frame's row r shows what the latest frame's row r + shift showed. A row votes
        // when at least 4 of its samples changed in both rows, and agrees when at most 1 in 8 of those are more than 8 levels off, so a
        // frosted header or an animation costs only its own rows. The most agreeing rows win, the nearer shift a tie; a shift needs 16
        // agreeing rows and must keep the image at least a frame tall and under the limit. Shifts walk outward, and stop
        // once the overlap holds fewer rows than the best count, so a tiny overlap of plain background cannot win.
        var best: (shift: Int, rows: Int)?
        for distance in 1..<max(1, band.count - 16) {
            if let best, band.count - distance <= best.rows { break }
            // A capture that ended mid-search adds nothing.
            if Task.isCancelled { return false }
            for shift in [distance, -distance] {
                guard height + shift >= frameHeight, shift < 0 || height < heightLimit else { continue }
                var (agreeing, voting) = (0, 0)
                for row in max(band.lowerBound, band.lowerBound - shift)..<min(band.upperBound, band.upperBound - shift) {
                    var mismatches = 0, compared = 0
                    for column in 0..<64 where !still[row][column] && !still[row + shift][column] {
                        compared += 1
                        if abs(Int(latestRows[row + shift][column]) - Int(rows[row][column])) > 8 { mismatches += 1 }
                    }
                    guard compared >= 4 else { continue }
                    voting += 1
                    if mismatches * 8 <= compared { agreeing += 1 }
                }
                if agreeing >= 16, agreeing > best?.rows ?? 0 { best = (shift, agreeing) }
            }
        }
        guard let best else { return false }
        let shift = best.shift
        // How the new frame's row differs from the latest frame's row, over every channel of every pixel: the largest and the total
        // difference. Rows match when no channel is more than 16 levels off.
        func change(_ row: Int, _ latestRow: Int) -> (largest: Int, total: Int) {
            var (largest, total) = (0, 0)
            for index in 0..<bytesPerRow {
                let difference = abs(Int(bytes[row * bytesPerRow + index]) - Int(latest[latestRow * bytesPerRow + index]))
                (largest, total) = (max(largest, difference), total + difference)
            }
            return (largest, total)
        }
        if bands == nil {
            // The first frame joins down to its lowest row that matches the new frame one move away; the rows below it (a footer, the
            // window's rounded corners, an overlay at the bottom) are left to the latest frame.
            bands = fixed
            cursor = ((band.lowerBound + shift)..<band.upperBound).last { change($0 - shift, $0).largest <= 16 }.map { $0 + 1 } ?? band.lowerBound
            mismatched = cursor < band.upperBound
            body.removeLast((frameHeight - cursor) * bytesPerRow)
        }
        // Where the stitched rows end, in the new frame. Rows that scrolled out above the band before they joined join as the latest
        // frame showed them; scrolling up past the band's bottom trims the stitched rows to it.
        var start = cursor - shift
        if start < band.lowerBound {
            if mismatched { unmatchedRows += band.lowerBound - start }
            body += latest[(cursor * bytesPerRow)..<((band.lowerBound + shift) * bytesPerRow)]
            start = band.lowerBound
        } else if start > band.upperBound {
            body.removeLast((start - band.upperBound) * bytesPerRow)
            start = band.upperBound
        }
        // Rows from `start` down join while they match what the latest frame showed one move away. The latest frame supplies the joined
        // rows above the seam, the new frame the rest.
        var (end, seam, least) = (start, start, Int.max)
        while end < band.upperBound, band.contains(end + shift) {
            let change = change(end, end + shift)
            guard change.largest <= 16 else { break }
            if change.total < least { (seam, least) = (end, change.total) }
            end += 1
        }
        body += latest[((start + shift) * bytesPerRow)..<((seam + shift) * bytesPerRow)] + bytes[(seam * bytesPerRow)..<(end * bytesPerRow)]
        mismatched = end < band.upperBound && band.contains(end + shift)
        cursor = end
        latest = bytes
        latestRows = rows
        return true
    }

    /// The stitched image: the first frame's header, the stitched rows, and the latest frame from where they end. The rows are copied
    /// once, straight into the image's data.
    public func image() -> CGImage {
        let total = height * bytesPerRow
        var data = Data(capacity: total)
        data.append(contentsOf: body.prefix(total))
        data.append(contentsOf: latest[(cursor * bytesPerRow)...].prefix(total - data.count))
        return Self.cgImage(data, width: width, height: height)
    }

    /// The stitched image scaled down (never up) to fit `size` in pixels, each pixel the average of 2 x 2 samples read in place, so a
    /// frame costs a thumbnail's pixels, not the stitched image's.
    public func thumbnail(fitting size: CGSize) -> CGImage {
        let scale = min(size.width / CGFloat(width), size.height / CGFloat(height), 1)
        let (thumbWidth, thumbHeight) = (max(1, Int(CGFloat(width) * scale)), max(1, Int(CGFloat(height) * scale)))
        let bodyRows = body.count / bytesPerRow
        var bytes = [UInt8](repeating: 0, count: thumbWidth * thumbHeight * 4)
        for y in 0..<thumbHeight {
            let sourceRows = (0..<2).map { (y * 2 + $0) * height / (thumbHeight * 2) }
            for x in 0..<thumbWidth {
                let columns = (0..<2).map { (x * 2 + $0) * width / (thumbWidth * 2) * 4 }
                for channel in 0..<4 {
                    let sum = sourceRows.reduce(0) { sum, row in
                        let (source, start) = row < bodyRows ? (body, row * bytesPerRow) : (latest, (cursor + row - bodyRows) * bytesPerRow)
                        return columns.reduce(sum) { $0 + Int(source[start + $1 + channel]) }
                    }
                    bytes[(y * thumbWidth + x) * 4 + channel] = UInt8(sum / 4)
                }
            }
        }
        return Self.cgImage(Data(bytes), width: thumbWidth, height: thumbHeight)
    }

    private static func cgImage(_ data: Data, width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// 64 luminance samples across each row, top row first.
    private static func rows(_ bytes: [UInt8], width: Int, height: Int) -> [[Int16]] {
        let columns = (0..<64).map { $0 * width / 64 }
        return (0..<height).map { row in
            columns.map { column in
                let index = (row * width + column) * 4
                return Int16((Int(bytes[index]) * 3 + Int(bytes[index + 1]) * 6 + Int(bytes[index + 2])) / 10)
            }
        }
    }
}
