import CoreGraphics
import ImageIO
import XCTest
@testable import ScreenshotCore

final class DetectionCancellationTests: XCTestCase {
    func testRunThrowsWhenCancelledImmediately() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Sidebar", withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let task = Task { try await Detection.run(.geometry, image: image) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled detection run returned a report.")
        } catch is CancellationError {
        }
    }
}
