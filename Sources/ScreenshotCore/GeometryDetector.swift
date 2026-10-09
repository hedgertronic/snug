import CoreGraphics
import Foundation

/// Finds likely panels and tables from aligned color transitions in a screenshot.
public struct GeometryDetector {
    /// Creates a local, pixel-based screenshot detector.
    public init() {}

    /// Returns nested panel and table proposals in source-image pixels, with a top-left origin.
    public func detect(in image: CGImage) async throws -> [Candidate] {
        try Task.checkCancellation()
        let scale = min(1.0, 1024.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let pixels = rasterize(image, width: width, height: height) else { return [] }

        let edges = EdgeProfiles(raster: pixels)
        let xLines = [0] + linePositions(in: edges.vertical, minimumSupport: 0.055) + [width]
        let yLines = [0] + linePositions(in: edges.horizontal, minimumSupport: 0.055) + [height]
        guard xLines.count >= 2, yLines.count >= 2 else { return [] }

        var proposals: [ScoredRectangle] = []
        for leftIndex in 0..<(xLines.count - 1) {
            try Task.checkCancellation()
            for rightIndex in (leftIndex + 1)..<xLines.count {
                let left = xLines[leftIndex]
                let right = xLines[rightIndex]
                guard right - left >= max(28, width / 22) else { continue }

                for topIndex in 0..<(yLines.count - 1) {
                    let top = yLines[topIndex]
                    guard top < height else { continue }
                    for bottomIndex in (topIndex + 1)..<yLines.count {
                        let bottom = yLines[bottomIndex]
                        guard bottom - top >= max(24, height / 24) else { continue }
                        let areaFraction = Double((right - left) * (bottom - top)) / Double(width * height)
                        guard areaFraction >= 0.018, areaFraction <= 0.94 else { continue }

                        let topSupport = edges.support(at: top, start: left, end: right, vertical: false)
                        let bottomSupport = edges.support(at: bottom, start: left, end: right, vertical: false)
                        let leftSupport = edges.support(at: left, start: top, end: bottom, vertical: true)
                        let rightSupport = edges.support(at: right, start: top, end: bottom, vertical: true)
                        let supports = [topSupport, bottomSupport, leftSupport, rightSupport]
                        let onImageEdge = [top == 0, bottom == height, left == 0, right == width]
                        let measuredSides = zip(supports, onImageEdge).filter { !$0.1 }.map { $0.0 }
                        if onImageEdge.contains(true) {
                            guard !measuredSides.isEmpty, measuredSides.allSatisfy({ $0 >= 0.98 }) else { continue }
                        }
                        let meanSupport = supports.reduce(0, +) / 4
                        // Each side must support the same rectangle; unrelated edges cannot close it.
                        guard supports.allSatisfy({ $0 >= 0.80 }),
                              edges.connects(at: top, start: left, end: right, vertical: false),
                              edges.connects(at: bottom, start: left, end: right, vertical: false),
                              edges.connects(at: left, start: top, end: bottom, vertical: true),
                              edges.connects(at: right, start: top, end: bottom, vertical: true) else { continue }

                        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                        let dividerSupport = internalDividerSupport(edges, rect: rect, xLines: xLines, yLines: yLines)
                        let isTable = dividerSupport.vertical >= 2 && dividerSupport.horizontal >= 2
                        let sizeScore = min(1, areaFraction / 0.42)
                        let gridScore = min(1, Double(dividerSupport.vertical + dividerSupport.horizontal) / 10)
                        let boundaryPenalty = isTable
                            ? tableBoundaryPenalty(edges, rect: rect, xLines: xLines, yLines: yLines)
                            : 0
                        let score = 0.40 + meanSupport * 0.42 + sizeScore * 0.12
                            + (isTable ? 0.04 + gridScore * 0.18 : 0) - boundaryPenalty

                        proposals.append(ScoredRectangle(rect: rect, score: score, kind: isTable ? .table : .region))
                    }
                }
            }
        }

        let xScale = Double(image.width) / Double(width)
        let yScale = Double(image.height) / Double(height)
        let sorted = proposals.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
            return $0.rect.minX < $1.rect.minX
        }

        // Keep complete edge panels reachable even when a grid generates many subrectangles.
        let edgePanels = Array(sorted.filter {
            $0.kind == .region && ($0.rect.minX == 0 || $0.rect.maxX == CGFloat(width))
                && ($0.rect.minY == 0 || $0.rect.maxY == CGFloat(height))
        }.prefix(16))
        var tables: [ScoredRectangle] = []
        for table in sorted where table.kind == .table {
            if !tables.contains(where: { Detection.overlap($0.rect, table.rect) > 0.1 }) {
                tables.append(table)
            }
        }
        var cells: [ScoredRectangle] = []
        for table in tables.prefix(8) {
            let rect = table.rect
            let columns = [Int(rect.minX)] + xLines.filter {
                $0 > Int(rect.minX) + 3 && $0 < Int(rect.maxX) - 3 &&
                edges.support(at: $0, start: Int(rect.minY), end: Int(rect.maxY), vertical: true) >= 0.82
            } + [Int(rect.maxX)]
            let rows = [Int(rect.minY)] + yLines.filter {
                $0 > Int(rect.minY) + 3 && $0 < Int(rect.maxY) - 3 &&
                edges.support(at: $0, start: Int(rect.minX), end: Int(rect.maxX), vertical: false) >= 0.82
            } + [Int(rect.maxY)]
            for (left, right) in zip(columns, columns.dropFirst()) {
                for (top, bottom) in zip(rows, rows.dropFirst()) where right - left >= 8 && bottom - top >= 8 {
                    cells.append(ScoredRectangle(rect: CGRect(x: left, y: top, width: right - left,
                        height: bottom - top), score: 0.95, kind: .cell))
                }
            }
        }
        // One-row strips (board ranks, segmented controls): their column edges are too short to register in the
        // whole-image profile, so look for dividers inside each short band between two horizontal lines.
        var strips: [ScoredRectangle] = []
        for (topIndex, top) in yLines.enumerated() {
            for bottom in yLines[(topIndex + 1)...] where bottom - top >= 12 && bottom - top <= height / 8 {
                var dividers: [Int] = []
                for x in 1..<width where edges.support(at: x, start: top, end: bottom, vertical: true) >= 0.82 {
                    if let last = dividers.last, x - last <= 3 { continue }
                    dividers.append(x)
                }
                var run: [CGRect] = []
                func flush() {
                    let strip = run.reduce(CGRect.null) { $0.union($1) }
                    if run.count >= 3, !tables.prefix(8).contains(where: { $0.rect.intersects(strip) }) {
                        strips.append(ScoredRectangle(rect: strip, score: 0.9, kind: .table))
                        cells += run.map { ScoredRectangle(rect: $0, score: 0.95, kind: .cell) }
                    }
                    run = []
                }
                for (left, right) in zip(dividers, dividers.dropFirst()) {
                    if right - left >= 12,
                       edges.support(at: top, start: left, end: right, vertical: false) >= 0.8,
                       edges.support(at: bottom, start: left, end: right, vertical: false) >= 0.8 {
                        run.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
                    } else {
                        flush()
                    }
                }
                flush()
            }
        }
        // Regular grids (boards, calendars, galleries): 9+ touching cells, at least two thirds within 10% of the median cell size. Any
        // other panel or table holding some but not all of a regular grid's cells, or lying inside it, cuts through it (a
        // chessboard yields hundreds of such subrectangles) and is dropped. Each regular grid joins whole, with each band of 3+
        // median-height cells as a row across it. Irregular grids (page layouts) keep their subrectangles.
        cells = Array(cells.prefix(300))
        var group = Array(cells.indices)
        func root(_ index: Int) -> Int { group[index] == index ? index : root(group[index]) }
        for a in cells.indices {
            for b in cells.indices where b > a && cells[a].rect.insetBy(dx: -2, dy: -2).intersects(cells[b].rect) {
                group[root(b)] = root(a)
            }
        }
        let grids = Dictionary(grouping: cells.indices, by: root).values.map { $0.map { cells[$0].rect } }.compactMap { grid -> (cells: [CGRect], whole: CGRect, rowHeight: CGFloat)? in
            guard grid.count >= 9 else { return nil }
            let width = grid.map(\.width).sorted()[grid.count / 2], height = grid.map(\.height).sorted()[grid.count / 2]
            let typical = grid.filter { abs($0.width - width) <= width * 0.1 && abs($0.height - height) <= height * 0.1 }
            guard typical.count * 3 >= grid.count * 2 else { return nil }
            return (grid, grid.reduce(CGRect.null) { $0.union($1) }, height)
        }
        func cutsThrough(_ rect: CGRect) -> Bool {
            grids.contains { grid in
                let held = grid.cells.filter { rect.insetBy(dx: -2, dy: -2).contains($0) }.count
                return held > 0 && held < grid.cells.count
                    || grid.whole.insetBy(dx: -2, dy: -2).contains(rect) && !rect.insetBy(dx: -4, dy: -4).contains(grid.whole)
            }
        }
        var gridLevels: [ScoredRectangle] = []
        for grid in grids {
            gridLevels.append(ScoredRectangle(rect: grid.whole, score: 0.92, kind: .table))
            let rows = grid.cells.filter { abs($0.height - grid.rowHeight) <= grid.rowHeight * 0.1 }
            for band in Dictionary(grouping: rows, by: { "\(Int($0.minY))-\(Int($0.maxY))" }).values where band.count >= 3 {
                gridLevels.append(ScoredRectangle(rect: CGRect(x: grid.whole.minX, y: band[0].minY, width: grid.whole.width, height: band[0].height), score: 0.9, kind: .table))
            }
        }
        let ordered = cells + gridLevels + (strips + edgePanels + sorted).filter { !cutsThrough($0.rect) }
        var output: [Candidate] = []
        for proposal in ordered {
            let bounds = CGRect(
                x: proposal.rect.minX * CGFloat(xScale),
                y: (CGFloat(height) - proposal.rect.maxY) * CGFloat(yScale),
                width: proposal.rect.width * CGFloat(xScale),
                height: proposal.rect.height * CGFloat(yScale)
            ).integral
            guard !output.contains(where: { Detection.overlap($0.bounds, bounds) > 0.985 }) else { continue }
            let x = Int(bounds.minX.rounded()), y = Int(bounds.minY.rounded())
            let w = Int(bounds.width.rounded()), h = Int(bounds.height.rounded())
            let kindName = proposal.kind.rawValue
            output.append(Candidate(
                id: "geometry-\(kindName)-\(x)-\(y)-\(w)-\(h)",
                label: proposal.kind == .cell ? "Table Cell" : (proposal.kind == .table ? "Table" : "Panel"),
                bounds: bounds,
                score: proposal.score,
                kind: proposal.kind
            ))
            if output.count == 150 + min(cells.count, 300) { break }
        }
        return output
    }
}

private struct Raster {
    let bytes: [UInt8]
    let width: Int
    let height: Int

    func channel(_ x: Int, _ y: Int, _ component: Int) -> Int {
        Int(bytes[(y * width + x) * 4 + component])
    }
}

private struct ScoredRectangle {
    let rect: CGRect
    let score: Double
    let kind: CandidateKind
}

private struct EdgeProfiles {
    let raster: Raster
    let vertical: [Double]
    let horizontal: [Double]
    private let verticalPrefix: [UInt16]
    private let horizontalPrefix: [UInt16]

    init(raster: Raster) {
        self.raster = raster
        let width = raster.width
        let height = raster.height
        let verticalStride = height + 1
        let horizontalStride = width + 1
        var verticalPrefix = [UInt16](repeating: 0, count: width * verticalStride)
        var horizontalPrefix = [UInt16](repeating: 0, count: height * horizontalStride)
        var vertical = [Double](repeating: 0, count: width)
        var horizontal = [Double](repeating: 0, count: height)

        if width > 1 {
            for x in 1..<width {
                let base = x * verticalStride
                var hits = 0
                for y in 0..<height {
                    if colorDistance(raster, x - 1, y, x, y) >= 34 { hits += 1 }
                    verticalPrefix[base + y + 1] = UInt16(hits)
                }
                vertical[x] = Double(hits) / Double(max(1, height))
            }
        }
        if height > 1 {
            for y in 1..<height {
                let base = y * horizontalStride
                var hits = 0
                for x in 0..<width {
                    if colorDistance(raster, x, y - 1, x, y) >= 34 { hits += 1 }
                    horizontalPrefix[base + x + 1] = UInt16(hits)
                }
                horizontal[y] = Double(hits) / Double(max(1, width))
            }
        }
        self.verticalPrefix = verticalPrefix
        self.horizontalPrefix = horizontalPrefix
        self.vertical = vertical
        self.horizontal = horizontal
    }

    func connects(at position: Int, start: Int, end: Int, vertical: Bool) -> Bool {
        let length = min(12, max(4, (end - start) / 4))
        return support(at: position, start: start, end: min(end, start + length), vertical: vertical) >= 0.5
            && support(at: position, start: max(start, end - length), end: end, vertical: vertical) >= 0.5
    }

    func support(at position: Int, start: Int, end: Int, vertical isVertical: Bool) -> Double {
        let spanLimit = isVertical ? raster.height : raster.width
        let positionLimit = isVertical ? raster.width : raster.height
        guard end > start else { return 0 }
        // The image boundary closes a clipped panel without a visible color transition.
        if position == 0 || position == positionLimit { return 1 }
        guard position > 0, position < positionLimit else { return 0 }
        let inset = (start == 0 || end == spanLimit) ? 0 : max(1, (end - start) / 12)
        let lower = max(0, start + inset)
        let upper = min(spanLimit, end - inset)
        guard upper > lower else { return 0 }
        let stride = spanLimit + 1
        let base = position * stride
        let prefix = isVertical ? verticalPrefix : horizontalPrefix
        let count = Int(prefix[base + upper]) - Int(prefix[base + lower])
        return Double(count) / Double(upper - lower)
    }
}

private func rasterize(_ image: CGImage, width: Int, height: Int) -> Raster? {
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / CGFloat(image.width), y: -CGFloat(height) / CGFloat(image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return rendered ? Raster(bytes: bytes, width: width, height: height) : nil
}

private func colorDistance(_ raster: Raster, _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
    let red = abs(raster.channel(ax, ay, 0) - raster.channel(bx, by, 0))
    let green = abs(raster.channel(ax, ay, 1) - raster.channel(bx, by, 1))
    let blue = abs(raster.channel(ax, ay, 2) - raster.channel(bx, by, 2))
    return red + green + blue
}

private func linePositions(in profile: [Double], minimumSupport: Double) -> [Int] {
    guard profile.count > 2 else { return [] }
    var peaks: [Int] = []
    for index in 1..<(profile.count - 1) where profile[index] >= minimumSupport {
        if profile[index] >= profile[index - 1] && profile[index] >= profile[index + 1] {
            peaks.append(index)
        }
    }
    peaks.sort { profile[$0] > profile[$1] }
    var selected: [Int] = []
    for peak in peaks where !selected.contains(where: { abs($0 - peak) <= 3 }) {
        selected.append(peak)
        if selected.count == 24 { break }
    }
    return selected.sorted()
}

private func internalDividerSupport(
    _ edges: EdgeProfiles,
    rect: CGRect,
    xLines: [Int],
    yLines: [Int]
) -> (vertical: Int, horizontal: Int) {
    let left = Int(rect.minX), right = Int(rect.maxX), top = Int(rect.minY), bottom = Int(rect.maxY)
    let vertical = xLines.filter { $0 >= left + 3 && $0 < right - 3 }
        .count { edges.support(at: $0, start: top + 2, end: bottom - 2, vertical: true) >= 0.82 }
    let horizontal = yLines.filter { $0 >= top + 3 && $0 < bottom - 3 }
        .count { edges.support(at: $0, start: left + 2, end: right - 2, vertical: false) >= 0.82 }
    return (vertical, horizontal)
}

private func tableBoundaryPenalty(
    _ edges: EdgeProfiles,
    rect: CGRect,
    xLines: [Int],
    yLines: [Int]
) -> Double {
    let left = Int(rect.minX), right = Int(rect.maxX), top = Int(rect.minY), bottom = Int(rect.maxY)
    let verticalMargin = Int(Double(right - left) * 0.16)
    let horizontalMargin = Int(Double(bottom - top) * 0.16)
    let hasNearVerticalDivider = xLines.contains { line in
        line >= left + 3 && line < right - 3 &&
            min(line - left, right - line) <= verticalMargin &&
            edges.support(at: line, start: top + 2, end: bottom - 2, vertical: true) >= 0.82
    }
    let hasNearHorizontalDivider = yLines.contains { line in
        line >= top + 3 && line < bottom - 3 &&
            min(line - top, bottom - line) <= horizontalMargin &&
            edges.support(at: line, start: left + 2, end: right - 2, vertical: false) >= 0.82
    }
    return (hasNearVerticalDivider ? 0.06 : 0) + (hasNearHorizontalDivider ? 0.06 : 0)
}
