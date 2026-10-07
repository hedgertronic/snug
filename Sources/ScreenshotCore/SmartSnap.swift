import CoreGraphics
import Foundation

/// A locally detected rectangle that refines a user's rough drag.
public struct SnapSuggestion: Sendable {
    /// The suggested crop in source-image pixels, with a top-left origin.
    public let bounds: CGRect
    /// Estimated support for the rectangle's four edges, from zero to one.
    public let confidence: Double
    /// A short description of the boundary evidence supporting the suggestion.
    public let reason: String

    /// Creates a suggestion with source-image bounds and its supporting evidence.
    public init(bounds: CGRect, confidence: Double, reason: String) {
        self.bounds = bounds
        self.confidence = confidence
        self.reason = reason
    }
}

/// Finds nearby rectangular boundaries directly in the screenshot pixels.
public struct SmartSnap {
    /// Creates a local rough-drag snapper.
    public init() {}

    /// How far a side may move to snap, in pixels: 12% of the side's length, at most 56, and never under 8 points.
    public static func band(side: CGFloat, scale: CGFloat) -> Int {
        max(Int((8 * scale).rounded()), min(56, Int((side * 0.12).rounded())))
    }

    /// Suggests nearby rectangles whose four sides have continuous pixel-edge support.
    ///
    /// The rough drag and returned bounds use source-image pixels with a top-left origin; `scale` is the capture's
    /// pixels per point, which sets the smallest search band. A side whose band reaches the image border snaps to it.
    /// Empty results mean the drag should be kept as drawn.
    public func suggest(in image: CGImage, roughBounds: CGRect, scale: CGFloat = 1) async throws -> [SnapSuggestion] {
        try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard roughBounds.minX.isFinite, roughBounds.minY.isFinite,
              roughBounds.width.isFinite, roughBounds.height.isFinite else { return [] }
        let rough = roughBounds.standardized.intersection(extent)
        guard !rough.isNull, rough.width >= 16, rough.height >= 16 else { return [] }

        let maxMoveX = Self.band(side: rough.width, scale: scale)
        let maxMoveY = Self.band(side: rough.height, scale: scale)
        let crop = CGRect(x: max(0, rough.minX - CGFloat(maxMoveX + 4)),
                          y: max(0, rough.minY - CGFloat(maxMoveY + 4)),
                          width: 0, height: 0)
        let cropRect = CGRect(x: crop.minX, y: crop.minY,
                              width: min(CGFloat(image.width) - crop.minX, rough.maxX + CGFloat(maxMoveX + 4) - crop.minX),
                              height: min(CGFloat(image.height) - crop.minY, rough.maxY + CGFloat(maxMoveY + 4) - crop.minY)).integral
        guard let raster = snapRasterize(image, crop: cropRect) else { return [] }
        try Task.checkCancellation()
        let left = Int((rough.minX - cropRect.minX).rounded()), right = Int((rough.maxX - cropRect.minX).rounded())
        let top = Int((rough.minY - cropRect.minY).rounded()), bottom = Int((rough.maxY - cropRect.minY).rounded())
        let horizontalInset = max(2, Int(rough.width * 0.16))
        let verticalInset = max(2, Int(rough.height * 0.16))

        let sideChoices: [[SideChoice]] = [
            try snapSideChoices(raster, vertical: true, fixedRange: (top + verticalInset, bottom - verticalInset),
                            around: left, radius: maxMoveX, positionLimit: raster.width, border: raster.borders.left ? 0 : nil),
            try snapSideChoices(raster, vertical: true, fixedRange: (top + verticalInset, bottom - verticalInset),
                            around: right, radius: maxMoveX, positionLimit: raster.width, border: raster.borders.right ? raster.width : nil),
            try snapSideChoices(raster, vertical: false, fixedRange: (left + horizontalInset, right - horizontalInset),
                            around: top, radius: maxMoveY, positionLimit: raster.height, border: raster.borders.top ? 0 : nil),
            try snapSideChoices(raster, vertical: false, fixedRange: (left + horizontalInset, right - horizontalInset),
                            around: bottom, radius: maxMoveY, positionLimit: raster.height, border: raster.borders.bottom ? raster.height : nil)
        ]
        guard sideChoices.allSatisfy({ !$0.isEmpty }) else { return [] }

        var scored: [(rect: CGRect, confidence: Double, displacement: Double)] = []
        for l in sideChoices[0].prefix(3) {
            for r in sideChoices[1].prefix(3) where r.position - l.position >= 16 {
                for t in sideChoices[2].prefix(3) {
                    for b in sideChoices[3].prefix(3) where b.position - t.position >= 16 {
                        try Task.checkCancellation()
                        let rect = CGRect(x: l.position, y: t.position,
                                          width: r.position - l.position, height: b.position - t.position)
                        guard rect.minX >= 0, rect.minY >= 0,
                              rect.maxX <= CGFloat(raster.width), rect.maxY <= CGFloat(raster.height) else { continue }
                        let supports = [l.support, r.support, t.support, b.support]
                        let mean = supports.reduce(0, +) / 4
                        let weakest = supports.min() ?? 0
                        guard weakest >= 0.31, mean >= 0.43 else { continue }
                        let corners = snapCornerSupport(raster, rect: rect)
                        guard corners >= 0.60 else { continue }
                        let edgeConfidence = mean * 0.78 + weakest * 0.22
                        let confidence = edgeConfidence * 0.62 + corners * 0.38
                        let displacement = (abs(Double(l.position - left)) / Double(maxMoveX)
                            + abs(Double(r.position - right)) / Double(maxMoveX)
                            + abs(Double(t.position - top)) / Double(maxMoveY)
                            + abs(Double(b.position - bottom)) / Double(maxMoveY)) / 4
                        scored.append((rect, confidence, displacement))
                    }
                }
            }
        }

        let ranked = scored.sorted {
            let a = $0.confidence - $0.displacement * 0.035
            let b = $1.confidence - $1.displacement * 0.035
            if a != b { return a > b }
            return abs($0.rect.width - rough.width) + abs($0.rect.height - rough.height)
                < abs($1.rect.width - rough.width) + abs($1.rect.height - rough.height)
        }
        var output: [SnapSuggestion] = []
        for item in ranked where item.confidence >= 0.48 {
            let bounds = item.rect.integral
            let sourceBounds = bounds.offsetBy(dx: cropRect.minX, dy: cropRect.minY)
            guard !output.contains(where: { snapOverlap($0.bounds, sourceBounds) > 0.94 }) else { continue }
            output.append(SnapSuggestion(bounds: sourceBounds, confidence: item.confidence,
                                         reason: "Four nearby sides show continuous pixel boundaries"))
            if output.count == 4 { break }
        }
        return output
    }

    /// Pixel edges for one side of `rect`: the positions within `band` of `position` where the pixels along that
    /// side's span change strongly, plus the image border when the band reaches it. The caller picks among them.
    /// `vertical` scans for a vertical edge (an x position); positions are source-image pixels.
    public func edges(in image: CGImage, of rect: CGRect, vertical: Bool, near position: CGFloat, band: Int) throws -> [CGFloat] {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let span = rect.intersection(extent)
        guard !span.isNull else { return [] }
        let reach = CGFloat(band + 4)
        let strip = vertical ? CGRect(x: position - reach, y: span.minY, width: 2 * reach, height: span.height)
                             : CGRect(x: span.minX, y: position - reach, width: span.width, height: 2 * reach)
        let cropRect = strip.intersection(extent).integral
        guard !cropRect.isNull, let raster = snapRasterize(image, crop: cropRect) else { return [] }
        let origin = vertical ? cropRect.minX : cropRect.minY
        let length = vertical ? raster.height : raster.width
        let inset = max(2, Int(CGFloat(length) * 0.16))
        let low = vertical ? raster.borders.left : raster.borders.top
        let high = vertical ? raster.borders.right : raster.borders.bottom
        let limit = vertical ? raster.width : raster.height
        let choices = try snapSideChoices(raster, vertical: vertical, fixedRange: (inset, length - inset),
                                          around: Int((position - origin).rounded()), radius: band, positionLimit: limit,
                                          border: low ? 0 : high ? limit : nil)
        return choices.filter { $0.support >= 0.43 }.map { origin + CGFloat($0.position) }
    }
}

private struct SnapRaster {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    /// Which sides of the raster are the image's own border.
    let borders: (left: Bool, top: Bool, right: Bool, bottom: Bool)

    func channel(_ x: Int, _ y: Int, _ component: Int) -> Int {
        Int(bytes[(y * width + x) * 4 + component])
    }
}

private struct SideChoice {
    let position: Int
    let support: Double
}

private func snapRasterize(_ image: CGImage, crop: CGRect) -> SnapRaster? {
    guard let croppedImage = image.cropping(to: crop) else { return nil }
    let width = max(1, Int(crop.width.rounded(.up))), height = max(1, Int(crop.height.rounded(.up)))
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
        guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        // CGImage cropping and bitmap storage both preserve source row order.
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    let borders = (left: crop.minX == 0, top: crop.minY == 0, right: crop.maxX == CGFloat(image.width), bottom: crop.maxY == CGFloat(image.height))
    return rendered ? SnapRaster(bytes: bytes, width: width, height: height, borders: borders) : nil
}

private func snapSideChoices(_ raster: SnapRaster, vertical: Bool, fixedRange: (Int, Int),
                             around: Int, radius: Int, positionLimit: Int, border: Int?) throws -> [SideChoice] {
    let spanLimit = vertical ? raster.height : raster.width
    let lower = max(1, fixedRange.0), upper = min(spanLimit - 1, fixedRange.1)
    guard upper - lower >= 8 else { return [] }
    let inset = max(1, (upper - lower) / 10)
    let sampleStart = lower + inset, sampleEnd = upper - inset
    let searchStart = max(2, around - radius), searchEnd = min(positionLimit - 2, around + radius)
    guard searchEnd >= searchStart else { return [] }

    var choices: [SideChoice] = []
    for position in searchStart...searchEnd {
        try Task.checkCancellation()
        var hits = 0, magnitude = 0.0, coherent = 0
        let sampleCount = sampleEnd - sampleStart
        guard sampleCount > 0 else { return [] }
        for along in sampleStart..<sampleEnd {
            let before = vertical ? snapColorDistance(raster, position - 2, along, position - 1, along)
                                  : snapColorDistance(raster, along, position - 2, along, position - 1)
            let after = vertical ? snapColorDistance(raster, position, along, position + 1, along)
                                 : snapColorDistance(raster, along, position, along, position + 1)
            let across = vertical ? snapColorDistance(raster, position - 1, along, position, along)
                                  : snapColorDistance(raster, along, position - 1, along, position)
            let strength = max(Double(across), Double(max(before, after)) * 0.72)
            if strength >= 9 { hits += 1 }
            magnitude += min(1, Double(strength) / 64)
            if strength >= 18 { coherent += 1 }
        }
        let hitFraction = Double(hits) / Double(sampleCount)
        let average = magnitude / Double(sampleCount)
        let strongFraction = Double(coherent) / Double(sampleCount)
        let support = min(1, hitFraction * 0.60 + average * 0.26 + strongFraction * 0.14)
        if support >= 0.20 { choices.append(SideChoice(position: position, support: support)) }
    }
    let strongest = Array(choices.sorted {
        if $0.support != $1.support { return $0.support > $1.support }
        return abs($0.position - around) < abs($1.position - around)
    }.prefix(6))
    guard let border, abs(border - around) <= radius else { return strongest }
    return [SideChoice(position: border, support: 1)] + strongest
}

private func snapColorDistance(_ raster: SnapRaster, _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
    let red = abs(raster.channel(ax, ay, 0) - raster.channel(bx, by, 0))
    let green = abs(raster.channel(ax, ay, 1) - raster.channel(bx, by, 1))
    let blue = abs(raster.channel(ax, ay, 2) - raster.channel(bx, by, 2))
    return red + green + blue
}

private func snapCornerSupport(_ raster: SnapRaster, rect: CGRect) -> Double {
    let x0 = Int(rect.minX), x1 = Int(rect.maxX) - 1
    let y0 = Int(rect.minY), y1 = Int(rect.maxY) - 1
    let window = min(40, max(10, Int(min(rect.width, rect.height) * 0.08)))
    let matchingTolerance = max(5, window / 3)
    let corners = [
        (horizontal: (position: y0, start: x0, direction: 1), vertical: (position: x0, start: y0, direction: 1)),
        (horizontal: (position: y0, start: x1, direction: -1), vertical: (position: x1, start: y0, direction: 1)),
        (horizontal: (position: y1, start: x0, direction: 1), vertical: (position: x0, start: y1, direction: -1)),
        (horizontal: (position: y1, start: x1, direction: -1), vertical: (position: x1, start: y1, direction: -1))
    ]
    var support = 0.0
    for corner in corners {
        let horizontal = snapCornerEdgeOffset(raster, vertical: false, position: corner.horizontal.position,
                                              start: corner.horizontal.start, direction: corner.horizontal.direction,
                                              limit: window)
        let vertical = snapCornerEdgeOffset(raster, vertical: true, position: corner.vertical.position,
                                            start: corner.vertical.start, direction: corner.vertical.direction,
                                            limit: window)
        guard let horizontal, let vertical else { continue }
        support += max(0, 1 - Double(abs(horizontal - vertical)) / Double(matchingTolerance))
    }
    return support / 4
}

private func snapCornerEdgeOffset(_ raster: SnapRaster, vertical: Bool, position: Int,
                                  start: Int, direction: Int, limit: Int) -> Int? {
    for offset in 0..<limit {
        let along = start + offset * direction
        guard along >= 0, along < (vertical ? raster.height : raster.width) else { return nil }
        if snapEdgeStrength(raster, vertical: vertical, position: position, along: along) >= 9 {
            return offset
        }
    }
    return nil
}

private func snapEdgeStrength(_ raster: SnapRaster, vertical: Bool, position: Int, along: Int) -> Double {
    let limit = vertical ? raster.width : raster.height
    let (low, high) = vertical ? (raster.borders.left, raster.borders.right) : (raster.borders.top, raster.borders.bottom)
    if (position < 2 && low) || (position >= limit - 2 && high) { return 64 }
    guard position >= 2, position < limit - 2 else { return 0 }
    let before = vertical ? snapColorDistance(raster, position - 2, along, position - 1, along)
                          : snapColorDistance(raster, along, position - 2, along, position - 1)
    let after = vertical ? snapColorDistance(raster, position, along, position + 1, along)
                         : snapColorDistance(raster, along, position, along, position + 1)
    let across = vertical ? snapColorDistance(raster, position - 1, along, position, along)
                          : snapColorDistance(raster, along, position - 1, along, position)
    return max(Double(across), Double(max(before, after)) * 0.72)
}

func snapOverlap(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    guard !intersection.isNull else { return 0 }
    let union = a.width * a.height + b.width * b.height - intersection.width * intersection.height
    return union > 0 ? intersection.width * intersection.height / union : 0
}
