import Foundation
import ScreenshotBench
import XCTest

/// Runs the public bench suite against its frozen baseline. The suite measures `Detection.run` (geometry or Vision detection on the
/// full-size image), not the app's hover pipeline, which runs `GeometryDetector` on a downsampled capture alongside Accessibility
/// (`OverlayController+Extras.swift`), so a pass here does not cover hover in the app.
final class ScreenshotBenchSuiteTests: XCTestCase {
    @MainActor
    func testPublicSuiteAgainstFrozenBaseline() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("results.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("review.html").path))
    }
}
