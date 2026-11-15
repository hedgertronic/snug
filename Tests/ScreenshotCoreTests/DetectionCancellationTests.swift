import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

/// Checks cancellation of image detection.
struct DetectionCancellationTests {
    /// An immediately cancelled detection task throws a cancellation error instead of returning a report.
    @Test func runThrowsWhenCancelledImmediately() async throws {
        let url = fixtureURL("Sidebar.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let task = Task { try await Detection.run(.geometry, image: image) }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled detection run returned a report.")
        } catch is CancellationError {
        }
    }
}
