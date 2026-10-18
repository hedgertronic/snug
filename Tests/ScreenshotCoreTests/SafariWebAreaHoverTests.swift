import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

/// Hover over a Safari page's content area (the web view under the tab bar), round 14: on a light page the user saw no hint for it.
struct SafariWebAreaHoverTests {
    /// The user's Safari window on ko-fi.com (notes/fixtures/round14/safari-light-kofi.png), 2x, cropped to the window: a dark toolbar and
    /// tab bar over 146 px, then the light page. Pixel geometry, as hover runs it (half size, then scaled back), finds the page as its own
    /// panel, and a hover anywhere on the page selects it with the window as its parent.
    @Test func geometryFindsTheLightPageUnderTheTabBar() async throws {
        let url = try #require(Bundle.module.url(forResource: "SafariLightKofi", withExtension: "png", subdirectory: "Fixtures"))
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

    /// Safari's AX tree read from the shell (macOS 26, notes/sidebar-debug/safari-ax-probe.swift): a 1242 x 927 pt window holds four
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
}
