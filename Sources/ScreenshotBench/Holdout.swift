import Foundation
import ScreenshotCore

private struct HoldoutTask: Decodable {
    let id: String
    let image: String
    let split: String
    let family: String?
    let scale: Int
    let bounds: [Double]
    let alternates: [[Double]]?
    let hoverAnchors: [[Double]]

    /// Every rectangle that counts as the right crop.
    var accepted: [CGRect] { ([bounds] + (alternates ?? [])).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
}

private struct HoldoutManifest: Decodable {
    let targets: [HoldoutTask]
}

extension ScreenshotBenchSuite {
    /// Prints the selection report for the manifest's tasks in `split` ("all" for every task), counting every task: first-choice
    /// accepts, tasks reachable within two corrections, and failures split into missing proposals and poor ranking. Detection runs the
    /// same `Detection.run` the suite uses, on saved images, so it never has Accessibility. `live.tsv` beside the manifest
    /// (id, on|off, 0|1|2|miss per line) adds the live Accessibility on and off rows.
    @MainActor
    public static func holdout(manifestURL: URL, split: String, candidateList: Bool) async throws {
        let manifest = try JSONDecoder().decode(HoldoutManifest.self, from: Data(contentsOf: manifestURL))
        let ids = Set(manifest.targets.map(\.id))
        precondition(ids.count == manifest.targets.count, "Task IDs must be unique")
        var splitOfFamily: [String: String] = [:]
        for task in manifest.targets {
            precondition(["development", "holdout"].contains(task.split) && task.scale > 0 && task.bounds.count == 4
                && (task.alternates ?? []).allSatisfy { $0.count == 4 } && !task.hoverAnchors.isEmpty
                && task.hoverAnchors.allSatisfy { $0.count == 2 }, "Invalid task: \(task.id)")
            let family = task.family ?? task.image
            precondition(splitOfFamily.updateValue(task.split, forKey: family) ?? task.split == task.split,
                         "Related screens must share a split: \(family)")
        }
        let tasks = manifest.targets.filter { split == "all" || $0.split == split }
        precondition(!tasks.isEmpty, "No tasks in split \(split)")

        let base = manifestURL.deletingLastPathComponent()
        var detected: [String: (extent: CGRect, byDetector: [DetectorKind: [Candidate]])] = [:]
        // One row per task and detector: the fewest corrections needed (nil when more than two) and whether any proposal is acceptable.
        var rows: [DetectorKind: [(id: String, corrections: Int?, proposed: Bool)]] = [:]
        for task in tasks {
            let imageURL = URL(fileURLWithPath: task.image, relativeTo: base).standardizedFileURL
            if detected[imageURL.path] == nil {
                let image = try PNG.read(imageURL)
                var byDetector: [DetectorKind: [Candidate]] = [:]
                for detector in DetectorKind.allCases {
                    byDetector[detector] = try await Task.detached { try await Detection.run(detector, image: image) }.value.candidates
                }
                detected[imageURL.path] = (CGRect(x: 0, y: 0, width: image.width, height: image.height), byDetector)
            }
            let (extent, byDetector) = detected[imageURL.path]!
            let accepted = task.accepted
            let anchors = task.hoverAnchors.map { CGPoint(x: $0[0], y: $0[1]) }
            precondition(accepted.allSatisfy { extent.contains($0) } && anchors.allSatisfy { extent.contains($0) },
                         "Label is outside its image: \(task.id)")
            let accepts = { (rect: CGRect) in accepted.contains { Acceptance.accepts(rect, $0, scale: task.scale) } }
            for detector in DetectorKind.allCases {
                let candidates = byDetector[detector]!
                let fewest = anchors.compactMap {
                    Acceptance.corrections(from: SelectionSession(candidates: candidates, extent: extent, anchor: $0),
                                           candidateList: candidateList, accepts: accepts)
                }.min()
                rows[detector, default: []].append((task.id, fewest, candidates.contains { accepts($0.bounds) }))
            }
        }

        func percent(_ count: Int, _ total: Int) -> String { String(format: "%d/%d (%.0f%%)", count, total, Double(count) * 100 / Double(total)) }
        print("Split \(split): \(tasks.count) tasks, \(Set(tasks.map { $0.family ?? $0.image }).count) families; failed tasks count in every denominator.")
        if tasks.count < 30 { print("Only \(tasks.count) tasks: below the 30 the holdout needs.") }
        for detector in DetectorKind.allCases {
            let results = rows[detector]!
            print("\n\(detector.rawValue)\(candidateList ? " (digits 1-5 counted)" : "")")
            print("  first choice accepted:          \(percent(results.filter { $0.corrections == 0 }.count, results.count))  target >= 80%")
            print("  reachable within 2 corrections: \(percent(results.filter { $0.corrections != nil }.count, results.count))  target >= 95%")
            for (name, failed) in [("not first choice", results.filter { $0.corrections != 0 }), ("not reachable in 2", results.filter { $0.corrections == nil })] {
                let missing = failed.filter { !$0.proposed }.count
                print("  \(name): \(failed.count) = \(missing) missing proposal + \(failed.count - missing) poor ranking")
            }
            print("  not reachable in 2: " + results.filter { $0.corrections == nil }.map { $0.id + ($0.proposed ? " [ranking]" : " [missing]") }.joined(separator: ", "))
        }

        let liveURL = base.appendingPathComponent("live.tsv")
        if FileManager.default.fileExists(atPath: liveURL.path) {
            var live: [String: [String: String]] = [:]
            for line in try String(contentsOf: liveURL, encoding: .utf8).split(separator: "\n") {
                let fields = line.split(separator: "\t").map(String.init)
                precondition(fields.count == 3 && ids.contains(fields[0]) && ["on", "off"].contains(fields[1])
                    && ["0", "1", "2", "miss"].contains(fields[2]), "Bad live.tsv line: \(line)")
                live[fields[1], default: [:]][fields[0]] = fields[2]
            }
            print("\nLive Snug (live.tsv; tasks in this split that have a line)")
            for ax in ["on", "off"] {
                let recorded = tasks.compactMap { live[ax]?[$0.id] }
                guard !recorded.isEmpty else { print("  Accessibility \(ax): no lines"); continue }
                print("  Accessibility \(ax): \(recorded.count) of \(tasks.count) recorded; first choice \(percent(recorded.filter { $0 == "0" }.count, recorded.count)); within 2 \(percent(recorded.filter { $0 != "miss" }.count, recorded.count))")
            }
        }
    }
}
