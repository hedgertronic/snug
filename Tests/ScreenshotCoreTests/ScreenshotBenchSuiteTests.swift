import Foundation
import ScreenshotBench
import Testing

/// Runs the public bench suite against its frozen baseline. The suite measures `Detection.run` (geometry or Vision detection on the
/// full-size image), not the app's hover pipeline, which runs `GeometryDetector` on a downsampled capture alongside Accessibility
/// (`OverlayController+Extras.swift`), so a pass here does not cover hover in the app.
struct ScreenshotBenchSuiteTests {
    /// The public fixture suite meets its frozen baseline and writes both result files.
    @MainActor
    @Test func publicSuiteAgainstFrozenBaseline() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("snug-public-suite-\(UUID().uuidString)", isDirectory: true)
        try await ScreenshotBenchSuite.run(
            manifestURL: root.appendingPathComponent("Tests/Fixtures/evaluation/public-suite.json"),
            baselineURL: root.appendingPathComponent("Tests/Fixtures/evaluation/baselines/public-suite.json"),
            outputURL: output
        )
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("results.json").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("review.html").path))
    }
}
