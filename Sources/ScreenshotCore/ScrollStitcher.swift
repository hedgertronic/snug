import CoreGraphics
import Foundation

/// Joins same-size frames of one screen area, captured while its content scrolls down, into one tall image.
///
/// Rows that stay identical at the top and bottom of the area when it first moves are fixed bands (a sticky header or
/// footer): the header appears once at the top and the latest footer once at the bottom. Each frame is matched against the
/// last frame that added rows: the vertical offset whose overlapping rows differ least wins, and only the rows the content
/// moved in are appended. A frame that did not move, moved up, or matches nowhere adds nothing.
public actor ScrollStitcher {
    /// The tallest stitched image, in pixels.
    public static let maximumHeight = 30_000

    public let width: Int
    private let frameHeight: Int
    private let bytesPerRow: Int
    /// Stitched rows above the footer, RGBA.
    private var body: [UInt8]
    private var footer: [UInt8] = []
    /// The last frame that added rows, and each of its rows' luminance samples.
    private var reference: [UInt8]
    private var referenceRows: [[Int16]]
    /// Fixed top and bottom bands, set when the area first moves.
    private var bands: (top: Int, bottom: Int)?

    public init(first: CGImage) {
        width = first.width
        frameHeight = first.height
        bytesPerRow = first.width * 4
        let bytes = Self.rgba(first)
        body = bytes
        reference = bytes
        referenceRows = Self.rows(bytes, width: first.width, height: first.height)
    }

    /// Stitched height in pixels.
    public var height: Int { body.count / bytesPerRow + footer.count / bytesPerRow }

    /// Whether the stitched image reached `maximumHeight`; later frames add nothing.
    public var isFull: Bool { height >= Self.maximumHeight }

    /// Adds a frame; returns whether it added rows.
    @discardableResult
    public func add(_ frame: CGImage) -> Bool {
        guard frame.width == width, frame.height == frameHeight, !isFull else { return false }
        let bytes = Self.rgba(frame)
        let rows = Self.rows(bytes, width: width, height: frameHeight)
        let same = zip(referenceRows, rows).map { $0 == $1 }
        guard same.contains(false) else { return false }
        let fixed = bands ?? (
            top: min(same.prefix { $0 }.count, frameHeight / 3),
            bottom: min(same.reversed().prefix { $0 }.count, frameHeight / 3)
        )
        let band = fixed.top..<(frameHeight - fixed.bottom)
        // The content moved down by `shift` when the new frame's row r shows what the reference's row r + shift showed.
        var best: (shift: Int, difference: Int)?
        for shift in 1..<max(1, band.count - 16) {
            let overlap = band.lowerBound..<(band.upperBound - shift)
            var difference = 0
            for row in overlap {
                for (a, b) in zip(referenceRows[row + shift], rows[row]) { difference += abs(Int(a) - Int(b)) }
                if let best, difference >= best.difference * overlap.count { break }
            }
            let mean = difference / overlap.count
            if mean < (best?.difference ?? Int.max) { best = (shift, mean) }
            if mean == 0 { break }
        }
        // Mean summed difference per row: 64 samples of luminance, about 2 levels each.
        guard let best, best.difference <= 128 else { return false }
        if bands == nil {
            bands = fixed
            body.removeLast(fixed.bottom * bytesPerRow)
        }
        let added = min(best.shift, Self.maximumHeight - height)
        body += bytes[((band.upperBound - best.shift) * bytesPerRow)..<((band.upperBound - best.shift + added) * bytesPerRow)]
        footer = Array(bytes[(band.upperBound * bytesPerRow)...])
        reference = bytes
        referenceRows = rows
        return true
    }

    /// The stitched image: the first frame's header, every added row, and the latest footer.
    public func image() -> CGImage {
        let data = Data(body + footer) as CFData
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
