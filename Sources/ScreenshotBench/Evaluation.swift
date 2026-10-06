import Foundation
import ScreenshotCore

struct EvaluationLabel: Decodable {
    let id: String
    let image: String
    let target: CGRect
    let anchor: CGPoint
}

struct EvaluationOutcome: Encodable {
    let id: String
    let image: String
    let detector: DetectorKind
    let target: CGRect
    let anchor: CGPoint
    let selected: Candidate?
    let bestCandidate: Candidate?
    let defaultIoU: Double
    let bestIoU: Double
    let proposalMatchesEdges: Bool
    let correctionsWithinTwo: Int?
}

extension ScreenshotBench {
    // Replays the production selection state against frozen proposals without rerunning OCR.
    @MainActor
    static func evaluate(labelsURL: URL, resultsURL: URL, outputURL: URL) throws {
        let decoder = JSONDecoder()
        let labels = try decoder.decode([EvaluationLabel].self, from: Data(contentsOf: labelsURL))
        guard !labels.isEmpty, Set(labels.map(\.id)).count == labels.count else {
            throw BenchError.message("Labels must be nonempty with unique IDs")
        }
        var outcomes: [EvaluationOutcome] = []
        for label in labels {
            let sourceURL = URL(fileURLWithPath: label.image)
            let source = try PNG.read(sourceURL)
            let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            guard extent.contains(label.target), extent.contains(label.anchor),
                  label.target.width > 0, label.target.height > 0 else {
                throw BenchError.message("Out-of-bounds label: \(label.id)")
            }
            for detector in DetectorKind.allCases {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let reportURL = resultsURL.appendingPathComponent("\(stem)-\(detector.rawValue).json")
                let report = try decoder.decode(BenchmarkResult.self, from: Data(contentsOf: reportURL))
                guard report.error == nil, report.pixelWidth == source.width,
                      report.pixelHeight == source.height, report.detector == detector else {
                    throw BenchError.message("Invalid frozen result: \(reportURL.path)")
                }
                let session = SelectionSession(candidates: report.candidates, extent: extent, anchor: label.anchor)
                func matches(_ rect: CGRect) -> Bool {
                    max(abs(rect.minX - label.target.minX), abs(rect.minY - label.target.minY),
                        abs(rect.maxX - label.target.maxX), abs(rect.maxY - label.target.maxY)) <= 8
                }
                var corrections: Int?
                var frontier = [session]
                for depth in 0...2 {
                    if frontier.contains(where: { $0.selected.map { matches($0.bounds) } ?? false }) {
                        corrections = depth
                        break
                    }
                    frontier = frontier.flatMap { state in
                        (0..<4).map { action in
                            var next = state
                            switch action {
                            case 0: next.cycle()
                            case 1: next.cycle(backward: true)
                            case 2: next.expand()
                            default: next.shrink()
                            }
                            return next
                        }
                    }
                }
                let best = report.candidates.max {
                    Detection.overlap($0.bounds, label.target) < Detection.overlap($1.bounds, label.target)
                }
                outcomes.append(EvaluationOutcome(id: label.id, image: label.image, detector: detector,
                    target: label.target, anchor: label.anchor, selected: session.selected, bestCandidate: best,
                    defaultIoU: session.selected.map { Detection.overlap($0.bounds, label.target) } ?? 0,
                    bestIoU: best.map { Detection.overlap($0.bounds, label.target) } ?? 0,
                    proposalMatchesEdges: report.candidates.contains { matches($0.bounds) },
                    correctionsWithinTwo: corrections))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outcomes).write(to: outputURL)
        print("Evaluated \(labels.count) targets × \(DetectorKind.allCases.count) modes from frozen proposals")
        for detector in DetectorKind.allCases {
            let rows = outcomes.filter { $0.detector == detector }
            print("\(detector.rawValue): proposals \(rows.filter(\.proposalMatchesEdges).count)/\(rows.count); default \(rows.filter { $0.correctionsWithinTwo == 0 }.count); within two corrections \(rows.filter { $0.correctionsWithinTwo != nil }.count)")
        }
    }
}
