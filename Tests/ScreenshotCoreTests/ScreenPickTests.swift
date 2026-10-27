import CoreGraphics
import Testing
@testable import ScreenshotCore

struct ScreenPickTests {
    /// A 3024 x 1964 pt built-in display and a smaller one to its right, top-aligned in AppKit's bottom-left space.
    let builtIn = CGRect(x: 0, y: 0, width: 3024, height: 1964)
    let external = CGRect(x: 3024, y: 964, width: 1920, height: 1000)

    @Test func thePointerOnTheTopOrRightEdgeOfTheOnlyDisplayIsOnIt() {
        // The pointer pushed into the top of the menu bar sits at y == maxY, against the right edge at x == maxX.
        for point in [CGPoint(x: 1512, y: 1964), CGPoint(x: 3024, y: 900), CGPoint(x: 3024, y: 1964), CGPoint(x: 0, y: 0)] {
            #expect(ScreenPick.index(of: point, in: [builtIn]) == 0, "\(point)")
        }
    }

    @Test func aPointBetweenDisplaysTakesTheNearestOne() {
        let frames = [builtIn, external]
        #expect(ScreenPick.index(of: CGPoint(x: 3500, y: 1964), in: frames) == 1, "the top edge of the external display")
        #expect(ScreenPick.index(of: CGPoint(x: 4944, y: 1200), in: frames) == 1, "the right edge of the external display")
        #expect(ScreenPick.index(of: CGPoint(x: 3100, y: 500), in: frames) == 0, "below the external display, nearer the built-in one's edge")
        #expect(ScreenPick.index(of: CGPoint(x: 4900, y: 300), in: frames) == 1, "below the external display's far side")
        #expect(ScreenPick.index(of: CGPoint(x: 10, y: 10), in: []) == nil)
    }
}
