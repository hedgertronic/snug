import Foundation
import CoreGraphics
import os

private let detectionSignposter = OSSignposter(subsystem: "local.smartscreenshot.lab", category: "pipeline")

/// The source or visual role of a proposed screenshot region.
public enum CandidateKind: String, Codable, Sendable {
    case region, table, cell, text, window, display, manual
}

/// A crop proposal in source-image pixels, with its origin at the top left.
public struct Candidate: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let bounds: CGRect
    public let score: Double
    public let kind: CandidateKind
    /// Actual text-line rectangles used for pointer hit testing, when available.
    public let hitRegions: [CGRect]?

    /// Creates a rectangle proposal. Higher scores make better default selections.
    public init(id: String, label: String, bounds: CGRect, score: Double, kind: CandidateKind = .region, hitRegions: [CGRect]? = nil) {
        self.id = id
        self.label = label
        self.bounds = bounds
        self.score = score
        self.kind = kind
        self.hitRegions = hitRegions
    }
}

/// Detector variants available for the same screenshot.
public enum DetectorKind: String, CaseIterable, Codable, Sendable {
    case geometry, vision
}

/// A timed detection result; elapsed time includes all detector processing.
public struct DetectionReport: Codable, Sendable {
    public let detector: DetectorKind
    public let elapsedMilliseconds: Double
    public let candidates: [Candidate]
}

/// Runs a detector without UI state and normalizes its output.
public enum Detection {
    /// Analyze a source image. Call from a background task to avoid blocking UI work.
    public static func run(_ detector: DetectorKind, image: CGImage) async throws -> DetectionReport {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let raw: [Candidate]
        switch detector {
        case .geometry:
            let geometryInterval = detectionSignposter.beginInterval("Geometry")
            let regions = try await GeometryDetector().detect(in: image)
            detectionSignposter.endInterval("Geometry", geometryInterval)
            try Task.checkCancellation()
            let ocrInterval = detectionSignposter.beginInterval("OCR")
            let text = try await VisionDetector().detectText(in: image)
            detectionSignposter.endInterval("OCR", ocrInterval)
            raw = regions + text
        case .vision:
            let ocrInterval = detectionSignposter.beginInterval("OCR")
            let documents = try await VisionDetector().detect(in: image)
            detectionSignposter.endInterval("OCR", ocrInterval)
            try Task.checkCancellation()
            let geometryInterval = detectionSignposter.beginInterval("Geometry")
            let panels = try await GeometryDetector().detect(in: image).filter { candidate in
                let rect = candidate.bounds
                let touchedEdges = [rect.minX <= 1, rect.minY <= 1,
                                    rect.maxX >= CGFloat(image.width) - 1,
                                    rect.maxY >= CGFloat(image.height) - 1].count { $0 }
                return candidate.kind == .cell || (candidate.kind == .region && touchedEdges >= 2)
            }
            detectionSignposter.endInterval("Geometry", geometryInterval)
            raw = documents + panels
        }
        try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let candidates = normalized(raw, within: extent)
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        return DetectionReport(detector: detector, elapsedMilliseconds: milliseconds, candidates: candidates)
    }

    /// Clips, filters, and deduplicates regions without changing their coordinate convention.
    public static func normalized(_ candidates: [Candidate], within extent: CGRect) -> [Candidate] {
        var output: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let rect = candidate.bounds.standardized.intersection(extent).integral
            guard !rect.isNull, rect.width >= 8, rect.height >= 8,
                  rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { continue }
            guard !output.contains(where: { existing in
                if overlap(existing.bounds, rect) > 0.96 { return true }
                guard existing.kind == .cell, candidate.kind == .cell else { return false }
                let a = existing.bounds
                let tolerance = min(6, min(a.width, a.height, rect.width, rect.height) * 0.15)
                return overlap(a, rect) >= 0.80
                    && abs(a.minX - rect.minX) <= tolerance && abs(a.maxX - rect.maxX) <= tolerance
                    && abs(a.minY - rect.minY) <= tolerance && abs(a.maxY - rect.maxY) <= tolerance
            }) else { continue }
            output.append(Candidate(id: candidate.id, label: candidate.label, bounds: rect, score: candidate.score, kind: candidate.kind, hitRegions: candidate.hitRegions))
        }
        return output
    }

    /// Intersection over union used by deduplication and evaluation.
    public static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        return union > 0 ? area / union : 0
    }
}
