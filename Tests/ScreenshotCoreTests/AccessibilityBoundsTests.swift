import CoreGraphics
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
        #expect(result.allSatisfy { $0.kind == .element && $0.score > 1 })
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

    @Test func hoverLevelSkipsWindowsStaticTextAndTinyFrames() {
        let frames = [
            AXFrame(roleDescription: "text", rect: CGRect(x: 150, y: -850, width: 80, height: 20), role: "AXStaticText"),
            AXFrame(roleDescription: "icon", rect: CGRect(x: 150, y: -850, width: 15, height: 40), role: "AXImage"),
            AXFrame(roleDescription: "button", rect: CGRect(x: 140, y: -860, width: 100, height: 40), role: "AXButton"),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600), role: "AXWindow")
        ]
        #expect(AccessibilityBounds.hoverLevel(frames).map(\.roleDescription) == ["button"])
        #expect(AccessibilityBounds.hoverLevel([AXFrame(roleDescription: "edge", rect: CGRect(x: 0, y: 0, width: 16, height: 16), role: "AXButton")]).count == 1)
    }
}

struct DockRectTests {
    let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)

    @Test func dockIsTheUnionOfItsListsInImagePixels() {
        let lists = [CGRect(x: 600, y: 900, width: 300, height: 70), CGRect(x: 920, y: 905, width: 60, height: 70)]
        let rect = AccessibilityBounds.dockRect(lists: lists, displayOrigin: .zero, scale: 2, extent: extent)
        #expect(rect == CGRect(x: 1200, y: 1800, width: 760, height: 150))
        let shifted = AccessibilityBounds.dockRect(lists: lists, displayOrigin: CGPoint(x: 100, y: 50), scale: 2, extent: extent)
        #expect(shifted == CGRect(x: 1000, y: 1700, width: 760, height: 150))
    }

    @Test func dockPanelMovesEachSideToTheRimFromInsideOrOutside() {
        // A vertical Dock: a dark panel with a large corner radius and a 2 px light rim, on a dark gradient, with light icons inside.
        let panel = CGRect(x: 10, y: 140, width: 134, height: 1750)
        let context = CGContext(data: nil, width: 400, height: 1964, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.08, blue: 0.2, alpha: 1),
                                   CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: 400, y: 1964), options: [])
        // CGContext is bottom-up: flip so rects are top-left like image pixels.
        context.translateBy(x: 0, y: 1964)
        context.scaleBy(x: 1, y: -1)
        context.addPath(CGPath(roundedRect: panel.insetBy(dx: 1, dy: 1), cornerWidth: 50, cornerHeight: 50, transform: nil))
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineWidth(2)
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.drawPath(using: .fillStroke)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        for y in stride(from: 170, to: 1800, by: 102) { context.fill(CGRect(x: 39, y: y, width: 76, height: 76)) }
        let union = CGRect(x: 20, y: 140, width: 134, height: 1824)
        let found = AccessibilityBounds.dockPanel(in: context.makeImage()!, around: union, scale: 2)
        for (a, b) in [(found.minX, panel.minX), (found.maxX, panel.maxX), (found.minY, panel.minY), (found.maxY, panel.maxY)] {
            #expect(abs(a - b) <= 2, "found \(found), panel \(panel)")
        }
    }

    @Test func trimmingADockSlotKeepsTheIconAndIgnoresTheRunningDot() {
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 60, y: 50, width: 76, height: 76))
        context.fillEllipse(in: CGRect(x: 44, y: 86, width: 4, height: 4))
        // Bottom-up drawing: the icon is at y 200 - 126 = 74 in top-left image pixels.
        let slot = CGRect(x: 40, y: 60, width: 116, height: 102)
        #expect(AccessibilityBounds.trimmedToContent(in: context.makeImage()!, rect: slot) == CGRect(x: 60, y: 74, width: 76, height: 76))
    }

    @Test func unusableListsGiveNoDock() {
        #expect(AccessibilityBounds.dockRect(lists: [], displayOrigin: .zero, scale: 2, extent: extent) == nil)
        let bad = [CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), CGRect(x: 5, y: 5, width: 0, height: 50),
                   CGRect(x: 9000, y: 9000, width: 100, height: 100), CGRect(x: 0, y: 0, width: 2, height: 2)]
        #expect(AccessibilityBounds.dockRect(lists: bad, displayOrigin: .zero, scale: 2, extent: extent) == nil)
    }
}
