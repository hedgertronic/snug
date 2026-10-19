import AppKit
import Foundation
import ScreenshotCore

private struct SuiteManifest: Decodable {
    let version: Int
    let targets: [SuiteTarget]
}

private struct SuiteTarget: Decodable {
    let id: String
    let image: String
    let split: String
    let scale: Int
    let bounds: [Double]
    let requiredContent: [String]
    let excludedContent: [String]
    let labelQuality: String
    let roughDrags: [[Double]]
    let hoverAnchors: [[Double]]

    var target: CGRect { CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }
}

private struct SuiteSnapRun: Codable {
    let name: String
    let rough: CGRect
    let suggestions: [CGRect]
    let firstEdgeError: Double?
    let firstWithin8Points: Bool
    let fallsBackToExactDrag: Bool
}

private struct SuiteHoverResult: Codable {
    let detector: DetectorKind
    let reachableWithinTwoCorrections: Bool
    let firstChoiceAccepted: Bool
}

private struct SuiteTargetResult: Codable {
    let id: String
    let image: String
    let split: String
    let target: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let roughDrags: [CGRect]
    let hoverAnchors: [CGPoint]
    let requiredContent: [String]
    let excludedContent: [String]
    let labelQuality: String
    let maxEdgeError: Double?
    let firstSuggestionWithin8Points: Bool
    let exactDragFallbackCount: Int
    let hover: [SuiteHoverResult]
    let regressions: [String]

    var passed: Bool { regressions.isEmpty }
}

private struct SuiteReport: Codable {
    let version: Int
    let targets: [SuiteTargetResult]
}

public enum ScreenshotBenchSuite {
    @MainActor
    public static func run(manifestURL: URL, baselineURL: URL?, outputURL: URL) async throws {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(SuiteManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, !manifest.targets.isEmpty,
              Set(manifest.targets.map(\.id)).count == manifest.targets.count else {
            throw BenchError.message("Manifest must be version 1 with nonempty, unique target IDs")
        }
        let manifestPath = manifestURL.standardizedFileURL.path
        if let privatePath = manifestPath.range(of: "/evaluation/private/") {
            let privateRoot = String(manifestPath[..<privatePath.upperBound].dropLast())
            let outputPath = outputURL.standardizedFileURL.path
            guard outputPath == privateRoot || outputPath.hasPrefix(privateRoot + "/") else {
                throw BenchError.message("Private evaluation outputs must stay under \(privateRoot)")
            }
        }
        let base = manifestURL.deletingLastPathComponent()
        var imageByPath: [String: CGImage] = [:]
        var hoverByImage: [String: [DetectorKind: [Candidate]]] = [:]
        var resultRows: [SuiteTargetResult] = []
        var reviewRuns: [String: [SuiteSnapRun]] = [:]

        for target in manifest.targets {
            guard target.bounds.count == 4, target.bounds.allSatisfy(\.isFinite),
                  !target.roughDrags.isEmpty, target.roughDrags.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }),
                  !target.hoverAnchors.isEmpty, target.hoverAnchors.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
                  ["development", "holdout"].contains(target.split), target.scale > 0, !target.labelQuality.isEmpty else {
                throw BenchError.message("Invalid target geometry, split, label quality, or missing inputs: \(target.id)")
            }
            let imageURL = URL(fileURLWithPath: target.image, relativeTo: base).standardizedFileURL
            let imageKey = imageURL.path
            let image = try imageByPath[imageKey] ?? PNG.read(imageURL)
            imageByPath[imageKey] = image
            let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let targetBounds = target.target
            guard targetBounds.width > 0, targetBounds.height > 0, extent.contains(targetBounds) else {
                throw BenchError.message("Target is outside its image: \(target.id)")
            }
            let roughs = target.roughDrags.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            let anchors = target.hoverAnchors.map { CGPoint(x: $0[0], y: $0[1]) }
            guard roughs.allSatisfy({ $0.width > 0 && $0.height > 0 && extent.contains($0) }),
                  anchors.allSatisfy({ extent.contains($0) }) else {
                throw BenchError.message("Rough drag or hover anchor is outside its image: \(target.id)")
            }

            var generated: [(String, CGRect)] = []
            for (index, rough) in roughs.enumerated() {
                generated.append(("rough-\(index + 1)", rough))
                generated.append(("inset-\(index + 1)", rough.insetBy(dx: max(2, rough.width * 0.04), dy: max(2, rough.height * 0.04))))
                generated.append(("outset-\(index + 1)", rough.insetBy(dx: -max(2, rough.width * 0.04), dy: -max(2, rough.height * 0.04))))
                generated.append(("asymmetric-\(index + 1)", CGRect(x: rough.minX + max(2, rough.width * 0.025),
                    y: rough.minY - max(2, rough.height * 0.03), width: rough.width - max(2, rough.width * 0.01),
                    height: rough.height + max(2, rough.height * 0.025))))
                for jitter in [4.0, 8.0, 16.0] {
                    generated.append(("jitter-plus-\(Int(jitter))-\(index + 1)", rough.offsetBy(dx: jitter, dy: jitter)))
                    generated.append(("jitter-minus-\(Int(jitter))-\(index + 1)", rough.offsetBy(dx: -jitter, dy: -jitter)))
                }
            }
            let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            for (name, scale) in [("small", 0.55), ("large", 1.45)] {
                let rect = CGRect(x: center.x - targetBounds.width * scale / 2,
                                  y: center.y - targetBounds.height * scale / 2,
                                  width: targetBounds.width * scale, height: targetBounds.height * scale)
                generated.append(("small-to-large-\(name)", rect))
            }

            var snapRuns: [SuiteSnapRun] = []
            for (name, rough) in generated {
                let suggestions = try await Task.detached {
                    try await SmartSnap().suggest(in: image, roughBounds: rough)
                }.value
                let bounds = suggestions.map(\.bounds)
                let error = bounds.first.map { edgeError($0, targetBounds) }
                snapRuns.append(SuiteSnapRun(name: name, rough: rough, suggestions: bounds,
                    firstEdgeError: error, firstWithin8Points: suggestions.first.map { Acceptance.accepts($0.bounds, targetBounds, scale: target.scale) } ?? false,
                    fallsBackToExactDrag: suggestions.isEmpty))
            }
            reviewRuns[target.id] = snapRuns

            if hoverByImage[imageKey] == nil {
                var reports: [DetectorKind: [Candidate]] = [:]
                for detector in DetectorKind.allCases {
                    let report = try await Task.detached { try await Detection.run(detector, image: image) }.value
                    reports[detector] = report.candidates
                }
                hoverByImage[imageKey] = reports
            }
            let hoverResults = DetectorKind.allCases.map { detector -> SuiteHoverResult in
                let candidates = hoverByImage[imageKey]?[detector] ?? []
                let accepts = { (rect: CGRect) in Acceptance.accepts(rect, targetBounds, scale: target.scale) }
                let sessions = anchors.map { SelectionSession(candidates: candidates, extent: extent, anchor: $0) }
                return SuiteHoverResult(detector: detector,
                    reachableWithinTwoCorrections: sessions.contains { Acceptance.corrections(from: $0, candidateList: false, accepts: accepts) != nil },
                    firstChoiceAccepted: sessions.contains { $0.selected.map { accepts($0.bounds) } ?? false })
            }
            resultRows.append(SuiteTargetResult(id: target.id, image: target.image, split: target.split,
                target: targetBounds, pixelWidth: image.width, pixelHeight: image.height,
                roughDrags: roughs, hoverAnchors: anchors,
                requiredContent: target.requiredContent, excludedContent: target.excludedContent,
                labelQuality: target.labelQuality,
                maxEdgeError: snapRuns.compactMap(\.firstEdgeError).max(),
                firstSuggestionWithin8Points: snapRuns.contains(where: \.firstWithin8Points),
                exactDragFallbackCount: snapRuns.count(where: \.fallsBackToExactDrag),
                hover: hoverResults, regressions: []))
        }

        if let baselineURL {
            let baseline = try decoder.decode(SuiteReport.self, from: Data(contentsOf: baselineURL))
            let previous = Dictionary(uniqueKeysWithValues: baseline.targets.map { ($0.id, $0) })
            guard Set(previous.keys) == Set(resultRows.map(\.id)) else {
                throw BenchError.message("Baseline target IDs do not match the manifest")
            }
            for index in resultRows.indices {
                guard let old = previous[resultRows[index].id] else {
                    resultRows[index] = replacing(resultRows[index], regressions: ["missing baseline target"])
                    continue
                }
                var regressions: [String] = []
                if let oldError = old.maxEdgeError, let newError = resultRows[index].maxEdgeError,
                   newError > oldError + 0.001 { regressions.append("max edge error") }
                if old.firstSuggestionWithin8Points && !resultRows[index].firstSuggestionWithin8Points {
                    regressions.append("first suggestion within 8 pt")
                }
                if resultRows[index].exactDragFallbackCount > old.exactDragFallbackCount {
                    regressions.append("exact-drag fallback count")
                }
                for detector in DetectorKind.allCases {
                    let wasReachable = old.hover.first(where: { $0.detector == detector })?.reachableWithinTwoCorrections ?? false
                    let isReachable = resultRows[index].hover.first(where: { $0.detector == detector })?.reachableWithinTwoCorrections ?? false
                    if wasReachable && !isReachable { regressions.append("\(detector.rawValue) hover within 2 corrections") }
                }
                resultRows[index] = replacing(resultRows[index], regressions: regressions)
            }
        }

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = SuiteReport(version: 1, targets: resultRows)
        try encoder.encode(report).write(to: outputURL.appendingPathComponent("results.json"))
        let assets = outputURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for (path, image) in imageByPath {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            let destination = assets.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: destination.path) { try PNG.write(image, to: destination) }
        }
        try writeSuiteHTML(report, runs: reviewRuns, to: outputURL.appendingPathComponent("review.html"))
        print("TARGET\tMAX EDGE PX\tFIRST <=8PT\tGEOMETRY 2-CORR\tVISION 2-CORR\tEXACT FALLBACKS\tRESULT")
        for row in resultRows {
            let geometry = row.hover.first(where: { $0.detector == .geometry })?.reachableWithinTwoCorrections == true ? "yes" : "no"
            let vision = row.hover.first(where: { $0.detector == .vision })?.reachableWithinTwoCorrections == true ? "yes" : "no"
            print("\(row.id)\t\(row.maxEdgeError.map { String(format: "%.1f", $0) } ?? "n/a")\t\(row.firstSuggestionWithin8Points ? "yes" : "no")\t\(geometry)\t\(vision)\t\(row.exactDragFallbackCount)\t\(row.passed ? "PASS" : "FAIL: \(row.regressions.joined(separator: ", "))")")
        }
        if resultRows.contains(where: { !$0.passed }) { throw BenchError.message("Suite metrics regressed against baseline") }
    }

    private static func edgeError(_ a: CGRect, _ b: CGRect) -> Double {
        Double(max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)))
    }

    private static func replacing(_ row: SuiteTargetResult, regressions: [String]) -> SuiteTargetResult {
        SuiteTargetResult(id: row.id, image: row.image, split: row.split, target: row.target,
            pixelWidth: row.pixelWidth, pixelHeight: row.pixelHeight,
            roughDrags: row.roughDrags, hoverAnchors: row.hoverAnchors,
            requiredContent: row.requiredContent, excludedContent: row.excludedContent,
            labelQuality: row.labelQuality, maxEdgeError: row.maxEdgeError,
            firstSuggestionWithin8Points: row.firstSuggestionWithin8Points,
            exactDragFallbackCount: row.exactDragFallbackCount, hover: row.hover, regressions: regressions)
    }

    @MainActor
    private static func writeSuiteHTML(_ report: SuiteReport, runs: [String: [SuiteSnapRun]], to url: URL) throws {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func rectangle(_ rect: CGRect, color: String, width: Int, dash: Bool = false) -> String {
            "<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(width)\" \(dash ? "stroke-dasharray=\"12 8\"" : "")/>"
        }
        var html = "<!doctype html><meta charset=\"utf-8\"><title>ScreenshotBench suite</title><style>body{font:14px system-ui;margin:24px;background:#f5f4f6;color:#211d26}section{background:white;padding:18px;margin:18px 0;border-radius:12px}figure{margin:12px 0;position:relative}img,svg{width:100%;height:auto}svg{position:absolute;inset:0}.legend{display:flex;gap:18px}.rough{color:#e87522}.suggested{color:#2176d2}.target{color:#18855b}</style><h1>ScreenshotBench suite</h1><p>Orange: rough drags · blue: suggestions · green: labeled target</p>"
        for row in report.targets {
            let filename = URL(fileURLWithPath: row.image).lastPathComponent
            var overlays = rectangle(row.target, color: "#18855b", width: 6)
            for run in runs[row.id] ?? [] {
                overlays += rectangle(run.rough, color: "#e87522", width: 3, dash: true)
                if let suggestion = run.suggestions.first { overlays += rectangle(suggestion, color: "#2176d2", width: 3) }
            }
            html += "<section><h2>\(escaped(row.id)) <small>(\(escaped(row.split)), \(escaped(row.labelQuality)))</small></h2><figure><img src=\"assets/\(escaped(filename))\" width=\"\(row.pixelWidth)\" height=\"\(row.pixelHeight)\"><svg viewBox=\"0 0 \(row.pixelWidth) \(row.pixelHeight)\" preserveAspectRatio=\"none\">\(overlays)</svg></figure><p>Max edge error: \(row.maxEdgeError.map { String(format: "%.1f px", $0) } ?? "n/a"); first suggestion within 8 pt: \(row.firstSuggestionWithin8Points); exact fallback: \(row.exactDragFallbackCount) drags</p><p>Required: \(escaped(row.requiredContent.joined(separator: "; ")))<br>Excluded: \(escaped(row.excludedContent.joined(separator: "; ")))</p></section>"
        }
        try html.write(to: url, atomically: true, encoding: .utf8)
    }
}
