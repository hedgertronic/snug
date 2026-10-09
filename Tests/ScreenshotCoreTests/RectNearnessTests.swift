import CoreGraphics
import Testing
@testable import ScreenshotCore

struct RectNearnessTests {
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func identicalAndSlightlyOffRectanglesAreNear() {
        #expect(rect.isNear(rect, within: 4))
        #expect(rect.isNear(rect.insetBy(dx: 4, dy: 4), within: 4))
        #expect(rect.isNear(rect.offsetBy(dx: 3, dy: -4), within: 4))
    }

    @Test func oneSideBeyondTheToleranceIsNotNear() {
        #expect(!rect.isNear(CGRect(x: 100, y: 100, width: 405, height: 300), within: 4))
        #expect(!rect.isNear(CGRect(x: 100, y: 95, width: 400, height: 305), within: 4))
        #expect(!rect.isNear(rect.insetBy(dx: 12, dy: 12), within: 4))
    }
}
