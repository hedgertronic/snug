import Foundation
import Testing
@testable import ScreenshotCore

struct AccessibilityBoundsTests {
    let extent = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    /// A 2x display whose top-left sits at (100, -900) in global points (a display above the primary).
    let origin = CGPoint(x: 100, y: -900)

    @Test func framesConvertToImagePixelsAndRankInnermostFirst() {
        let frames = [
            AXFrame(roleDescription: "button", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "group", rect: CGRect(x: 120, y: -880, width: 400, height: 300)),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600))
        ]
        let result = AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["button", "group", "standard window"])
        #expect(result[0].bounds == CGRect(x: 100, y: 100, width: 120, height: 40))
        #expect(result[2].bounds == CGRect(x: 0, y: 0, width: 1800, height: 1200))
        #expect(result.map(\.score) == result.map(\.score).sorted(by: >))
        #expect(result.allSatisfy { $0.kind == .region && $0.score > 1 })
    }

    @Test func degenerateOffscreenAndRepeatedFramesAreDropped() {
        let frames = [
            AXFrame(roleDescription: "", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "same", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "tiny", rect: CGRect(x: 150, y: -850, width: 2, height: 2)),
            AXFrame(roleDescription: "off", rect: CGRect(x: 5000, y: 5000, width: 100, height: 100)),
            AXFrame(roleDescription: "nan", rect: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100))
        ]
        let result = AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["Element"])
        #expect(AccessibilityBounds.candidates(frames: [], displayOrigin: origin, scale: 2, extent: extent).isEmpty)
    }

    @Test func framesClipToTheNearestScrollViewport() {
        let frames = [
            AXFrame(roleDescription: "link", rect: CGRect(x: 150, y: -850, width: 100, height: 40), role: "AXLink"),
            AXFrame(roleDescription: "link", rect: CGRect(x: 150, y: -1000, width: 100, height: 300), role: "AXLink"),
            AXFrame(roleDescription: "HTML content", rect: CGRect(x: 100, y: -1000, width: 800, height: 5000), role: "AXWebArea"),
            AXFrame(roleDescription: "scroll area", rect: CGRect(x: 100, y: -880, width: 800, height: 500), role: "AXScrollArea"),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600), role: "AXWindow")
        ]
        let clipped = AccessibilityBounds.clippedToViewports(frames)
        #expect(clipped[0].rect == frames[0].rect)
        #expect(clipped[1].rect == CGRect(x: 150, y: -880, width: 100, height: 180))
        #expect(clipped[2].rect == CGRect(x: 100, y: -880, width: 800, height: 500))
        #expect(clipped[3].rect == frames[3].rect)
        #expect(clipped[4].rect == frames[4].rect)

        let above = AXFrame(roleDescription: "heading", rect: CGRect(x: 150, y: -2000, width: 100, height: 40), role: "AXHeading")
        #expect(AccessibilityBounds.clippedToViewports([above] + frames[2...]).map(\.roleDescription) == ["HTML content", "scroll area", "standard window"])
    }

    @Test func paddingOnlyParentsCollapseIntoTheirChild() {
        // Notion-like chain: cell, group 6 pt larger per side, table, group 10 pt larger, then a window.
        let frames = [
            AXFrame(roleDescription: "cell", rect: CGRect(x: 200, y: -800, width: 100, height: 40)),
            AXFrame(roleDescription: "padded group", rect: CGRect(x: 194, y: -806, width: 112, height: 52)),
            AXFrame(roleDescription: "table", rect: CGRect(x: 150, y: -850, width: 400, height: 200)),
            AXFrame(roleDescription: "padded group", rect: CGRect(x: 140, y: -860, width: 420, height: 220)),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600))
        ]
        let result = AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["cell", "table", "standard window"])
        let wide = AXFrame(roleDescription: "wide", rect: CGRect(x: 180, y: -820, width: 140, height: 80))
        #expect(AccessibilityBounds.candidates(frames: [frames[0], wide], displayOrigin: origin, scale: 2, extent: extent).count == 2)
    }

    @Test func pixelsMapToGlobalPoints() {
        #expect(AccessibilityBounds.point(forPixel: CGPoint(x: 200, y: 100), displayOrigin: origin, scale: 2) == CGPoint(x: 200, y: -850))
    }

    @Test func accessibilityCandidatesOutrankGeometryInASession() {
        let geometry = Candidate(id: "g", label: "Region", bounds: CGRect(x: 100, y: 100, width: 300, height: 200), score: 0.8, kind: .region)
        let ax = AccessibilityBounds.candidates(frames: [AXFrame(roleDescription: "button", rect: CGRect(x: 110, y: -880, width: 60, height: 40))],
                                                displayOrigin: origin, scale: 2, extent: extent)
        let session = SelectionSession(candidates: [geometry] + ax, extent: extent, anchor: CGPoint(x: 40, y: 80))
        #expect(session.selected?.label == "button")
    }
}
