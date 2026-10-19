import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

/// Hover over a Safari page's content area (the web view under the tab bar), round 14: on a light page the user saw no hint for it.
struct SafariWebAreaHoverTests {
    /// A Safari window on ko-fi.com, 2x, cropped to the window, with the other tabs' titles blanked: a dark toolbar and tab bar over
    /// 146 px, then the light page. Pixel geometry, as hover runs it (half size, then scaled back), finds the page as its own
    /// panel, and a hover anywhere on the page selects it with the window as its parent.
    @Test func geometryFindsTheLightPageUnderTheTabBar() async throws {
        let url = try #require(Bundle.module.url(forResource: "SafariLightPage", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let found = try await GeometryDetector().detect(in: Detection.downsampled(image, by: 2)).map { $0.scaled(by: 2) }
        let content = CGRect(x: 0, y: 146, width: 2000, height: 1346)
        #expect(found.contains { $0.bounds.isNear(content, within: 4) }, "\(found.map(\.bounds))")
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let window = Candidate(id: "window-0", label: "Window", bounds: extent, score: 0, kind: .window)
        for point in [CGPoint(x: 1000, y: 800), CGPoint(x: 600, y: 520), CGPoint(x: 1000, y: 280)] {
            let session = SelectionSession(candidates: found + [window], extent: extent, anchor: point)
            #expect(session.selected.map { $0.bounds.isNear(content, within: 4) } == true, "at \(point): \(String(describing: session.selected))")
            #expect(session.parents.first?.kind == .window, "at \(point)")
        }
    }

    /// Safari's AX tree read from the shell (macOS 26): a 1242 x 927 pt window holds four
    /// wrappers of its own size (split group, tab group, the BrowserView group, a group), then a 1242 x 837 pt scroll area and a web area
    /// of the document's height (4928 pt). The window was in Stage Manager's strip, so its web frames' positions were not usable; here the
    /// scroll area sits 90 pt down, under the 52 pt toolbar and the 38 pt tab bar. Hover gets the content area from the web area,
    /// clipped to its scroll area.
    @Test func theWebAreaChainHoversTheContentArea() async throws {
        let window = CGRect(x: 84, y: 44, width: 1242, height: 927)
        let scrollArea = CGRect(x: 84, y: 134, width: 1242, height: 837)
        let frames = [AXFrame(roleDescription: "HTML content", rect: CGRect(x: 84, y: 134, width: 1242, height: 4928), role: "AXWebArea"),
                      AXFrame(roleDescription: "scroll area", rect: scrollArea, role: "AXScrollArea")]
            + ["AXGroup", "AXGroup", "AXTabGroup", "AXSplitGroup"].map { AXFrame(roleDescription: "group", rect: window, role: $0) }
            + [AXFrame(roleDescription: "standard window", rect: window, role: "AXWindow", subrole: "AXStandardWindow")]
        let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let found = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(frames), displayOrigin: .zero, scale: 2, extent: extent)
        #expect(found.map(\.bounds) == [AccessibilityBounds.pixels(of: scrollArea, displayOrigin: .zero, scale: 2, extent: extent)], "\(found.map(\.bounds))")
    }

    private static let window = CGRect(x: 84, y: 44, width: 1242, height: 927)

    /// A chain of the user's ko-fi log (hover.log, 10-18) above the page: `inner` frames, then the web area and the scroll area as logged,
    /// then the wrappers and window at `window` ((84, 44, 1242, 927) unless the window was moved).
    private static func kofiChain(inner: [AXFrame], webArea: CGRect, window: CGRect = window) -> [AXFrame] {
        inner + [AXFrame(roleDescription: "HTML content", rect: webArea, role: "AXWebArea"),
                 AXFrame(roleDescription: "scroll area", rect: CGRect(x: 0, y: 1072, width: 1242, height: 837), role: "AXScrollArea")]
            + ["AXGroup", "AXGroup", "AXTabGroup", "AXSplitGroup"].map { AXFrame(roleDescription: "group", rect: window, role: $0) }
            + [AXFrame(roleDescription: "standard window", rect: window, role: "AXWindow", subrole: "AXStandardWindow")]
    }

    /// The same window moved to (111, 251) (hover.log lines 106-204). The scroll area is still logged at (0, 1072, 1242, 837), which now
    /// overlaps the window (y 251-1178), but its parent does not contain it: moved to meet its parent's bottom and right it is
    /// (111, 341, 1242, 837), under the tab bar at y 303 + 38.
    private static let movedWindow = CGRect(x: 111, y: 251, width: 1242, height: 927)
    private static let movedOffset = CGSize(width: 111, height: -731)
    private static let navigation = AXFrame(roleDescription: "navigation", rect: CGRect(x: 0, y: 1072, width: 1242, height: 60), role: "AXGroup")
    private static let kofiPage = CGRect(x: 0, y: 1072, width: 1242, height: 4928)

    /// Line 106: the hit is the web area itself; moved, it contains the pointer, and hover gets the content area.
    @Test func aMovedWindowsDisplacedWebAreaGivesTheContentArea() async throws {
        let frames = Self.kofiChain(inner: [], webArea: Self.kofiPage, window: Self.movedWindow)
        let point = CGPoint(x: 961.92578125, y: 746.50390625)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: point))
        #expect(displaced.through == 1)
        #expect(displaced.offset == Self.movedOffset)
        let moved = frames.enumerated().map { $0.offset <= displaced.through ? $0.element.translated(by: displaced.offset!) : $0.element }
        let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let found = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(moved), displayOrigin: .zero, scale: 2, extent: extent)
        let content = CGRect(x: 111, y: 341, width: 1242, height: 837)
        #expect(found.map(\.bounds) == [AccessibilityBounds.pixels(of: content, displayOrigin: .zero, scale: 2, extent: extent)], "\(found.map(\.bounds))")
    }

    /// Line 118: "How it works" (796, 1091, 98, 22) moves to (907, 360, 98, 22), around the pointer at (990, 379).
    @Test func aMovedWindowsDisplacedLinkIsMovedBack() throws {
        let inner = [AXFrame(roleDescription: "text", rect: CGRect(x: 796, y: 1091, width: 98, height: 22), role: "AXStaticText"),
                     AXFrame(roleDescription: "link", rect: CGRect(x: 796, y: 1091, width: 99, height: 22), role: "AXLink", title: "How it works"),
                     AXFrame(roleDescription: "group", rect: CGRect(x: 796, y: 1090, width: 99, height: 24), role: "AXGroup"),
                     AXFrame(roleDescription: "content list", rect: CGRect(x: 796, y: 1090, width: 240, height: 24), role: "AXList"), Self.navigation]
        let frames = Self.kofiChain(inner: inner, webArea: Self.kofiPage, window: Self.movedWindow)
        let point = CGPoint(x: 989.97265625, y: 378.67578125)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: point))
        #expect(displaced.through == 6)
        #expect(displaced.offset == Self.movedOffset)
        let moved = frames[0].translated(by: displaced.offset!).rect
        #expect(moved == CGRect(x: 907, y: 360, width: 98, height: 22) && moved.contains(point))
    }

    /// Line 109: the page's navigation bar (0, 1072, 1242, 60) moves to the top of the content area, around the pointer at (921, 357).
    @Test func aMovedWindowsDisplacedNavigationBarIsMovedBack() throws {
        let frames = Self.kofiChain(inner: [Self.navigation], webArea: Self.kofiPage, window: Self.movedWindow)
        let point = CGPoint(x: 920.890625, y: 356.5859375)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: point))
        #expect(displaced.through == 2)
        #expect(displaced.offset == Self.movedOffset)
        #expect(frames[0].translated(by: displaced.offset!).rect == CGRect(x: 111, y: 341, width: 1242, height: 60))
    }

    /// The gate holds in the moved window: a pointer the moved hit does not contain drops the displaced frames.
    @Test func aMovedWindowsDisplacedPageIsDroppedWhenTheMoveMissesThePointer() throws {
        let frames = Self.kofiChain(inner: [Self.navigation], webArea: Self.kofiPage, window: Self.movedWindow)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: CGPoint(x: 700, y: 900)))
        #expect(displaced.through == 2)
        #expect(displaced.offset == nil)
    }

    /// Log line 61: every frame from the scroll area down is displaced by (-84, +938) and the hit, "How it works", is 98 x 22 at (796, 1091).
    /// Moved by (+84, -938) it is x 880-978, y 153-175 around the pointer at (974, 162).
    @Test func aDisplacedPageIsMovedBackWhenTheHitThenContainsThePointer() async throws {
        let frames = Self.kofiChain(inner: [AXFrame(roleDescription: "text", rect: CGRect(x: 796, y: 1091, width: 98, height: 22), role: "AXStaticText"),
                                            AXFrame(roleDescription: "link", rect: CGRect(x: 796, y: 1091, width: 99, height: 22), role: "AXLink", title: "How it works")],
                                    webArea: CGRect(x: 0, y: 1072, width: 1242, height: 4928))
        let point = CGPoint(x: 974.01953125, y: 161.73828125)
        #expect(frames[0].rect.contains(point) == false)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: point))
        #expect(displaced.through == 3)
        #expect(displaced.offset == CGSize(width: 84, height: -938))
        let moved = frames.enumerated().map { $0.offset <= displaced.through ? $0.element.translated(by: displaced.offset!) : $0.element }
        #expect(moved[0].rect == CGRect(x: 880, y: 153, width: 98, height: 22) && moved[0].rect.contains(point))
        let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let found = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(moved), displayOrigin: .zero, scale: 2, extent: extent)
        #expect(found.first?.bounds == AccessibilityBounds.pixels(of: moved[1].rect, displayOrigin: .zero, scale: 2, extent: extent), "\(found.map(\.bounds))")
    }

    /// Log line 83, after a scroll: the web area is at y 623 (scrolled), and the hit group at (180, 1275, 426, 56) moves to (264, 337, 426, 56),
    /// around the pointer at (521, 385).
    @Test func aScrolledDisplacedPageIsMovedBack() throws {
        let frames = Self.kofiChain(inner: [AXFrame(roleDescription: "group", rect: CGRect(x: 180, y: 1275, width: 426, height: 56), role: "AXGroup")],
                                    webArea: CGRect(x: 0, y: 623, width: 1242, height: 4928))
        let point = CGPoint(x: 521.26171875, y: 385.01171875)
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: point))
        #expect(displaced.through == 2)
        #expect(displaced.offset == CGSize(width: 84, height: -938))
        #expect(frames[0].translated(by: displaced.offset!).rect == CGRect(x: 264, y: 337, width: 426, height: 56))
    }

    /// Log line 4: the web area alone is displaced, its scroll area is right; it moves to meet the scroll area's bottom and right.
    @Test func aDisplacedWebAreaAloneIsMovedToItsScrollArea() throws {
        let frames = [AXFrame(roleDescription: "HTML content", rect: CGRect(x: 0, y: 1072, width: 1242, height: 837), role: "AXWebArea"),
                      AXFrame(roleDescription: "scroll area", rect: CGRect(x: 84, y: 134, width: 1242, height: 837), role: "AXScrollArea"),
                      AXFrame(roleDescription: "group", rect: Self.window, role: "AXGroup"),
                      AXFrame(roleDescription: "standard window", rect: Self.window, role: "AXWindow")]
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: CGPoint(x: 1070, y: 346)))
        #expect(displaced.through == 0)
        #expect(displaced.offset == CGSize(width: 84, height: -938))
    }

    /// The gate: when the moved hit does not contain the pointer either, the displaced frames are dropped, not moved.
    @Test func aDisplacedPageIsDroppedWhenTheMoveDoesNotPutTheHitUnderThePointer() throws {
        let frames = Self.kofiChain(inner: [AXFrame(roleDescription: "link", rect: CGRect(x: 796, y: 1091, width: 99, height: 22), role: "AXLink")],
                                    webArea: CGRect(x: 0, y: 1072, width: 1242, height: 4928))
        let displaced = try #require(AccessibilityBounds.displacement(frames, at: CGPoint(x: 300, y: 600)))
        #expect(displaced.through == 2)
        #expect(displaced.offset == nil)
    }

    /// A chain whose hit already contains the pointer is left alone, as is one that never leaves its window.
    @Test func anUndisplacedChainIsLeftAlone() {
        let window = Self.window
        let frames = [AXFrame(roleDescription: "link", rect: CGRect(x: 200, y: 300, width: 100, height: 20), role: "AXLink"),
                      AXFrame(roleDescription: "scroll area", rect: CGRect(x: 84, y: 134, width: 1242, height: 837), role: "AXScrollArea"),
                      AXFrame(roleDescription: "standard window", rect: window, role: "AXWindow")]
        #expect(AccessibilityBounds.displacement(frames, at: CGPoint(x: 250, y: 310)) == nil)
        #expect(AccessibilityBounds.displacement(frames, at: CGPoint(x: 900, y: 800)) == nil)
    }
}
