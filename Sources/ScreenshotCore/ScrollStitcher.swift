import CoreGraphics
import Foundation

/// Joins same-size frames of one screen area, captured while its content scrolls, into one tall image that ends at the bottom
/// of the latest frame: scrolling back up trims the end, and scrolling down again adds it back.
///
/// Rows that stay identical at the top and bottom of the area when it first moves are fixed bands (a sticky header or
/// footer): the header appears once at the top and the latest footer once at the bottom. Each frame is matched against the
/// last matched frame on the samples that changed, so a fixed overlay over part of the width (a tooltip, a floating button)
/// does not steer the offset. Rows that scrolled above the bottom band join the stitched image; the latest frame supplies the
/// rest, from where they end down. A fixed overlay in the lower part of the area holds that point above it, so the overlay
/// appears once, where the latest frame shows it. A frame that did not move, moved up past the first frame, or matches
/// nowhere changes nothing.
public actor ScrollStitcher {
    /// The tallest stitched image, in pixels.
    public static let maximumHeight = 30_000

    public let width: Int
    private let frameHeight: Int
    private let bytesPerRow: Int
    /// Stitched rows, RGBA; the output continues with the latest frame from row `cursor` down.
    private var body: [UInt8]
    /// The last matched frame, each of its rows' luminance samples, and the row of it where `body` ends.
    private var latest: [UInt8]
    private var latestRows: [[Int16]]
    private var cursor: Int
    /// Fixed top and bottom bands, set when the area first moves.
    private var bands: (top: Int, bottom: Int)?
    /// The rows and sample columns of an overlay that stayed put in the lower part of the area while the content moved.
    private var overlay: (rows: Range<Int>, columns: ClosedRange<Int>)?

    public init(first: CGImage) {
        width = first.width
        frameHeight = first.height
        bytesPerRow = first.width * 4
        let bytes = Self.rgba(first)
        body = bytes
        latest = bytes
        latestRows = Self.rows(bytes, width: first.width, height: first.height)
        cursor = first.height
    }

    /// Stitched height in pixels, the height of `image()`.
    public var height: Int { min(body.count / bytesPerRow + frameHeight - cursor, Self.maximumHeight) }

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
        let changed = still.map { $0.count(where: { !$0 }) }
        // The content moved down by `shift` when the new frame's row r shows what the latest frame's row r + shift showed. Only
        // samples that changed in both rows count; one mismatches when it is more than 8 levels off. The fewest mismatches per
        // compared sample wins, counting one mismatch more so that a shift with few samples cannot win on a lucky zero; the
        // smaller distance wins a tie. A shift needs 64 compared samples, and at most 1 in 10 may mismatch (an overlay appearing, say).
        var best: (shift: Int, mismatches: Int, compared: Int)?
        for distance in 1..<max(1, band.count - 16) {
            for shift in [distance, -distance] {
                let overlap = max(band.lowerBound, band.lowerBound - shift)..<min(band.upperBound, band.upperBound - shift)
                // At most `bound` samples compare, so past this many mismatches the shift cannot win.
                let bound = changed[overlap].reduce(0, +)
                let ceiling = best.map { ($0.mismatches + 1) * bound / $0.compared } ?? bound / 10
                var mismatches = 0, compared = 0
                for row in overlap {
                    for column in 0..<64 where !still[row][column] && !still[row + shift][column] {
                        compared += 1
                        if abs(Int(latestRows[row + shift][column]) - Int(rows[row][column])) > 8 { mismatches += 1 }
                    }
                    if mismatches > ceiling { break }
                }
                if compared >= 64, mismatches * 10 <= compared, best.map({ (mismatches + 1) * $0.compared < ($0.mismatches + 1) * compared }) ?? true {
                    best = (shift, mismatches, compared)
                }
            }
            if best?.mismatches == 0 { break }
        }
        guard let best, height + best.shift >= frameHeight, best.shift < 0 || height < Self.maximumHeight else { return false }
        if bands == nil {
            bands = fixed
            body.removeLast(fixed.bottom * bytesPerRow)
            cursor = band.upperBound
        }
        // An overlay that stayed put while the content moved, or appeared: rows with samples unlike what the move brought there.
        // From the top of the highest such run in the lower part of the area, padded, the output takes only the latest frame.
        // A frame that brings no such rows keeps the last overlay while its samples stay still.
        let stray = band.map { row in band.contains(row + best.shift) ? (0..<64).filter { abs(Int(latestRows[row + best.shift][$0]) - Int(rows[row][$0])) > 16 } : [] }
        if let start = band.first(where: { $0 >= band.lowerBound + band.count / 2 && !stray[$0 - band.lowerBound].isEmpty }) {
            var top = start
            for row in (band.lowerBound..<start).reversed() where top - row <= 16 && !stray[row - band.lowerBound].isEmpty { top = row }
            var bottom = start
            for row in start..<band.upperBound where row - bottom <= 16 && !stray[row - band.lowerBound].isEmpty { bottom = row }
            let columns = stray[(top - band.lowerBound)...(bottom - band.lowerBound)].joined()
            overlay = (top..<(bottom + 1), columns.min()!...columns.max()!)
        } else if let overlay, !overlay.rows.allSatisfy({ row in overlay.columns.allSatisfy { still[row][$0] } }) {
            self.overlay = nil
        }
        let limit = overlay.map { $0.rows.lowerBound - 16 }.flatMap { $0 > band.lowerBound + band.count / 4 ? $0 : nil } ?? band.upperBound
        cursor = max(cursor - best.shift, band.lowerBound)
        if cursor > limit {
            body.removeLast((cursor - limit) * bytesPerRow)
        } else {
            body += bytes[(cursor * bytesPerRow)..<(limit * bytesPerRow)]
        }
        cursor = limit
        latest = bytes
        latestRows = rows
        return true
    }

    /// The stitched image: the first frame's header, the stitched rows, and the latest frame from where they end.
    public func image() -> CGImage {
        let data = Data((body + latest[(cursor * bytesPerRow)...]).prefix(height * bytesPerRow)) as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
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
