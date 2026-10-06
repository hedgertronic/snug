import CoreGraphics
import Foundation
import Vision

/// Proposes screenshot regions using Vision's document recognition and OCR.
public struct VisionDetector {
    /// Creates a Vision-backed detector.
    public init() {}

    /// Detects document containers and, when needed, groups OCR lines into text blocks.
    public func detect(in image: CGImage) async throws -> [Candidate] {
        try Task.checkCancellation()

        let handler = ImageRequestHandler(image)
        let observations = try await handler.perform(RecognizeDocumentsRequest())
        try Task.checkCancellation()

        let imageSize = CGSize(width: image.width, height: image.height)
        var candidates: [Candidate] = []

        for observation in observations {
            try Task.checkCancellation()
            let document = observation.document

            for table in document.tables {
                try Task.checkCancellation()
                let tableBounds = pixelBounds(for: table.boundingRegion.boundingBox, imageSize: imageSize)
                candidates.append(CandidateProposal(kind: .table, label: "Table", bounds: tableBounds, score: 0.99).candidate)

                for row in table.rows {
                    for cell in row {
                        try Task.checkCancellation()
                        let cellBounds = pixelBounds(for: cell.content.boundingRegion.boundingBox, imageSize: imageSize)
                        candidates.append(CandidateProposal(kind: .cell, label: "Table Cell", bounds: cellBounds, score: 0.74).candidate)
                    }
                }
            }

            if let title = document.title {
                candidates.append(CandidateProposal(
                    kind: .text,
                    label: "Title",
                    bounds: pixelBounds(for: title.boundingRegion.boundingBox, imageSize: imageSize),
                    score: 0.87
                ).candidate)
            }

            for paragraph in document.paragraphs {
                candidates.append(CandidateProposal(
                    kind: .text,
                    label: "Paragraph",
                    bounds: pixelBounds(for: paragraph.boundingRegion.boundingBox, imageSize: imageSize),
                    score: 0.82
                ).candidate)
            }
        }

        candidates = candidates.filter(isUsable)
        let text = try await detectText(in: image)
        let lines = text.filter { $0.label == "Text line" }.map(\.bounds)
        candidates = candidates.map { candidate in
            guard candidate.kind == .text else { return candidate }
            return Candidate(id: candidate.id, label: candidate.label, bounds: candidate.bounds,
                score: candidate.score, kind: candidate.kind, hitRegions: lines.filter {
                    candidate.bounds.contains(CGPoint(x: $0.midX, y: $0.midY))
                })
        }
        candidates += text

        return stableRanked(candidates, limit: 600)
    }

    /// Returns individual OCR lines and larger text blocks without logging recognized text.
    public func detectText(in image: CGImage) async throws -> [Candidate] {
        try Task.checkCancellation()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeightFraction = 0.004
        request.automaticallyDetectsLanguage = true
        let observations = try await ImageRequestHandler(image).perform(request)
        try Task.checkCancellation()
        let size = CGSize(width: image.width, height: image.height)
        let lines = observations.map {
            Candidate(id: "", label: "Text line", bounds: pixelBounds(for: $0.boundingBox, imageSize: size),
                      score: 0.80, kind: .text, hitRegions: [pixelBounds(for: $0.boundingBox, imageSize: size)])
        }
        return stableRanked(lines + groupedTextCandidates(from: lines.map(\.bounds)), limit: 400)
    }

}

private struct CandidateProposal {
    let kind: CandidateKind
    let label: String
    let bounds: CGRect
    let score: Double

    var candidate: Candidate {
        Candidate(id: "", label: label, bounds: bounds, score: score, kind: kind)
    }
}

private func pixelBounds(for rect: NormalizedRect, imageSize: CGSize) -> CGRect {
    rect.toImageCoordinates(imageSize, origin: .upperLeft)
}

private func isUsable(_ candidate: Candidate) -> Bool {
    let bounds = candidate.bounds.standardized
    return bounds.minX.isFinite && bounds.minY.isFinite && bounds.maxX.isFinite && bounds.maxY.isFinite
        && bounds.width >= 8 && bounds.height >= 8
}

// Group by neighboring line geometry, never by the growing union's height.
func groupedTextCandidates(from rectangles: [CGRect]) -> [Candidate] {
    let lines = rectangles.filter {
        $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite
            && $0.width >= 4 && $0.height >= 4
    }.sorted {
        if $0.minY != $1.minY { return $0.minY < $1.minY }
        return $0.minX < $1.minX
    }
    var blocks: [[CGRect]] = []
    for line in lines {
        let match = blocks.indices.filter { index in
            guard let last = blocks[index].last, let first = blocks[index].first else { return false }
            let height = min(first.height, line.height)
            let gap = line.minY - last.maxY
            return gap >= -height * 0.15 && gap <= height * 0.9
                && max(first.height, line.height) <= height * 1.5
                && abs(line.minX - first.minX) <= height * 0.75
        }.min { line.minY - blocks[$0].last!.maxY < line.minY - blocks[$1].last!.maxY }
        if let match { blocks[match].append(line) } else { blocks.append([line]) }
    }
    return blocks.filter { $0.count > 1 }.map { lines in
        let bounds = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        return Candidate(id: "", label: "Text block", bounds: bounds, score: 0.70,
                         kind: .text, hitRegions: lines)
    }
}

private func stableRanked(_ candidates: [Candidate], limit: Int) -> [Candidate] {
    let sorted = candidates.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
        if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
        if $0.bounds.height != $1.bounds.height { return $0.bounds.height > $1.bounds.height }
        return $0.bounds.width > $1.bounds.width
    }

    return sorted.prefix(limit).enumerated().map { index, candidate in
        let rect = candidate.bounds.integral
        let identifier = String(
            format: "vision-%@-%03d-%d-%d-%d-%d",
            candidate.kind.rawValue,
            index,
            Int(rect.minX),
            Int(rect.minY),
            Int(rect.width),
            Int(rect.height)
        )
        return Candidate(id: identifier, label: candidate.label, bounds: candidate.bounds, score: candidate.score, kind: candidate.kind, hitRegions: candidate.hitRegions)
    }
}
