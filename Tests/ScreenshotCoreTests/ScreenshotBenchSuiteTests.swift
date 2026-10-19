import Foundation
import ScreenshotBench
import XCTest

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
