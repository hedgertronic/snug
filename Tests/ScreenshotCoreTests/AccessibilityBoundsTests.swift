import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

struct AccessibilityBoundsTests {
    let extent = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    /// A 2x display whose top-left sits at (100, -900) in global points (a display above the primary).
    let origin = CGPoint(x: 100, y: -900)

    @Test func framesConvertToImagePixelsAndRankInnermostFirst() async throws {
        let frames = [
            AXFrame(roleDescription: "button", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "group", rect: CGRect(x: 120, y: -880, width: 400, height: 300)),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600))
        ]
        let result = try await AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["Button", "Group", "Standard Window"])
        #expect(result[0].bounds == CGRect(x: 100, y: 100, width: 120, height: 40))
        #expect(result[2].bounds == CGRect(x: 0, y: 0, width: 1800, height: 1200))
        #expect(result.map(\.score) == result.map(\.score).sorted(by: >))
        #expect(result.allSatisfy { $0.kind == .element && $0.score > 1 })
    }

    @Test func degenerateOffscreenAndRepeatedFramesAreDropped() async throws {
        let frames = [
            AXFrame(roleDescription: "", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "same", rect: CGRect(x: 150, y: -850, width: 60, height: 20)),
            AXFrame(roleDescription: "tiny", rect: CGRect(x: 150, y: -850, width: 2, height: 2)),
            AXFrame(roleDescription: "off", rect: CGRect(x: 5000, y: 5000, width: 100, height: 100)),
            AXFrame(roleDescription: "nan", rect: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100))
        ]
        let result = try await AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["Element"])
        #expect(try await AccessibilityBounds.candidates(frames: [], displayOrigin: origin, scale: 2, extent: extent).isEmpty)
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

    @Test func paddingOnlyParentsCollapseIntoTheirChild() async throws {
        // Notion-like chain: cell, group 6 pt larger per side, table, group 10 pt larger, then a window.
        let frames = [
            AXFrame(roleDescription: "cell", rect: CGRect(x: 200, y: -800, width: 100, height: 40)),
            AXFrame(roleDescription: "padded group", rect: CGRect(x: 194, y: -806, width: 112, height: 52)),
            AXFrame(roleDescription: "table", rect: CGRect(x: 150, y: -850, width: 400, height: 200)),
            AXFrame(roleDescription: "padded group", rect: CGRect(x: 140, y: -860, width: 420, height: 220)),
            AXFrame(roleDescription: "standard window", rect: CGRect(x: 100, y: -900, width: 900, height: 600))
        ]
        let result = try await AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: 2, extent: extent)
        #expect(result.map(\.label) == ["Cell", "Table", "Standard Window"])
        let wide = AXFrame(roleDescription: "wide", rect: CGRect(x: 180, y: -820, width: 140, height: 80))
        #expect(try await AccessibilityBounds.candidates(frames: [frames[0], wide], displayOrigin: origin, scale: 2, extent: extent).count == 2)
    }

    @Test func pixelsMapToGlobalPoints() {
        #expect(AccessibilityBounds.point(forPixel: CGPoint(x: 200, y: 100), displayOrigin: origin, scale: 2) == CGPoint(x: 200, y: -850))
    }

    @Test func accessibilityCandidatesOutrankGeometryInASession() async throws {
        let geometry = Candidate(id: "g", label: "Region", bounds: CGRect(x: 100, y: 100, width: 300, height: 200), score: 0.8, kind: .region)
        let ax = try await AccessibilityBounds.candidates(frames: [AXFrame(roleDescription: "button", rect: CGRect(x: 110, y: -880, width: 60, height: 40))],
                                                displayOrigin: origin, scale: 2, extent: extent)
        let session = SelectionSession(candidates: [geometry] + ax, extent: extent, anchor: CGPoint(x: 40, y: 80))
        #expect(session.selected?.label == "Button")
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

    /// A vertical Dock at 2x: a dark panel with rounded corners and a 2 px light rim, on a dark gradient, with light icons inside.
    private func dockImage(panel: CGRect) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 1964, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.08, blue: 0.2, alpha: 1),
                                   CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: 400, y: 1964), options: [])
        // CGContext is bottom-up: flip so rects are top-left like image pixels.
        context.translateBy(x: 0, y: 1964)
        context.scaleBy(x: 1, y: -1)
        context.addPath(CGPath(roundedRect: panel.insetBy(dx: 1, dy: 1), cornerWidth: 30, cornerHeight: 30, transform: nil))
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineWidth(2)
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.drawPath(using: .fillStroke)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        for y in stride(from: 200, to: 1800, by: 102) { context.fill(CGRect(x: 39, y: y, width: 76, height: 76)) }
        return context.makeImage()!
    }

    @Test func theDockUnionSnapsToThePanelEvenWhenItRunsFarPastTheBottom() async throws {
        let panel = CGRect(x: 10, y: 140, width: 134, height: 1750)
        // The union as measured on a real vertical Dock: 5 pt (10 px) inside on the left, 37 pt (74 px) past the bottom.
        let union = CGRect(x: 20, y: 140, width: 134, height: 1824)
        let image = dockImage(panel: panel)
        #expect(try await SmartSnap().suggest(in: image, roughBounds: union, scale: 2).isEmpty)
        let found = try #require(try await SmartSnap().suggest(in: image, roughBounds: union, scale: 2, cap: 96).first).bounds
        for (a, b) in [(found.minX, panel.minX), (found.maxX, panel.maxX), (found.minY, panel.minY), (found.maxY, panel.maxY)] {
            #expect(abs(a - b) <= 4, "found \(found), panel \(panel)")
        }
    }

    @Test func aVerticalDockGivesOneTightTilePerIcon() {
        let tiles = DockTiles.tiles(in: dockImage(panel: CGRect(x: 10, y: 140, width: 134, height: 1750)), panel: CGRect(x: 10, y: 140, width: 134, height: 1750), scale: 2)
        let icons = stride(from: 200, to: 1800, by: 102).map { CGRect(x: 39, y: $0, width: 76, height: 76) }
        #expect(tiles.count == icons.count)
        for (found, icon) in zip(tiles, icons) {
            for (a, b) in [(found.minX, icon.minX), (found.maxX, icon.maxX), (found.minY, icon.minY), (found.maxY, icon.maxY)] {
                #expect(abs(a - b) <= 3, "found \(found), icon \(icon)")
            }
        }
    }

    @Test func aHorizontalDockSkipsDotsAndSeparators() {
        let panel = CGRect(x: 100, y: 1800, width: 900, height: 134)
        let context = CGContext(data: nil, width: 1200, height: 1964, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 1964)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.fill(panel)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        let icons = [CGRect(x: 130, y: 1829, width: 76, height: 76), CGRect(x: 232, y: 1829, width: 76, height: 76), CGRect(x: 520, y: 1829, width: 76, height: 76)]
        for icon in icons { context.fill(icon) }
        context.fill(CGRect(x: 266, y: 1915, width: 8, height: 8))
        context.fill(CGRect(x: 410, y: 1815, width: 3, height: 104))
        let tiles = DockTiles.tiles(in: context.makeImage()!, panel: panel, scale: 2)
        #expect(tiles.count == icons.count)
        for (found, icon) in zip(tiles, icons) {
            for (a, b) in [(found.minX, icon.minX), (found.maxX, icon.maxX), (found.minY, icon.minY), (found.maxY, icon.maxY)] {
                #expect(abs(a - b) <= 3, "found \(found), icon \(icon)")
            }
        }
    }

    /// A 2x Dock panel (rounded, 2 px light rim, icon tiles along its length) on a dark gradient, with a lighter window whose edge sits 25 px past the panel.
    private func rimmedDock(size: CGSize, panel: CGRect, window: CGRect) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.08, blue: 0.2, alpha: 1),
                                   CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(window)
        context.addPath(CGPath(roundedRect: panel.insetBy(dx: 1, dy: 1), cornerWidth: 30, cornerHeight: 30, transform: nil))
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineWidth(2)
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.drawPath(using: .fillStroke)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        let vertical = panel.height > panel.width
        for offset in stride(from: 60, to: Int(vertical ? panel.height : panel.width) - 100, by: 102) {
            context.fill(vertical ? CGRect(x: panel.minX + 29, y: panel.minY + CGFloat(offset), width: 76, height: 76)
                         : CGRect(x: panel.minX + CGFloat(offset), y: panel.minY + 29, width: 76, height: 76))
        }
        return context.makeImage()!
    }

    @Test func theDockPanelComesFromItsRimWhenTheUnionIsMagnified() throws {
        // As measured on a real vertical Dock: the union 10 px inside on the left, 8 past on the right, 86 above and 74 below the panel.
        let panel = CGRect(x: 10, y: 140, width: 136, height: 1751)
        let image = rimmedDock(size: CGSize(width: 400, height: 1964), panel: panel, window: CGRect(x: 171, y: 100, width: 229, height: 1500))
        let union = CGRect(x: 20, y: 54, width: 134, height: 1910)
        let found = try #require(DockTiles.panel(in: image, near: union, scale: 2))
        for (a, b) in [(found.minX, panel.minX), (found.maxX, panel.maxX), (found.minY, panel.minY), (found.maxY, panel.maxY)] {
            #expect(abs(a - b) <= 3, "found \(found), panel \(panel)")
        }
        // A union that stops short of the panel's ends finds the same panel.
        #expect(DockTiles.panel(in: image, near: CGRect(x: 4, y: 200, width: 150, height: 1700), scale: 2) == found)
    }

    @Test func aHorizontalDockPanelComesFromItsRim() throws {
        let panel = CGRect(x: 300, y: 1780, width: 1200, height: 136)
        let image = rimmedDock(size: CGSize(width: 1800, height: 1964), panel: panel, window: CGRect(x: 0, y: 0, width: 1800, height: 1755))
        let union = CGRect(x: 230, y: 1770, width: 1340, height: 150)
        let found = try #require(DockTiles.panel(in: image, near: union, scale: 2))
        for (a, b) in [(found.minX, panel.minX), (found.maxX, panel.maxX), (found.minY, panel.minY), (found.maxY, panel.maxY)] {
            #expect(abs(a - b) <= 3, "found \(found), panel \(panel)")
        }
    }

    @Test func noRimNearTheUnionGivesNoPanel() {
        let image = rimmedDock(size: CGSize(width: 400, height: 1964), panel: CGRect(x: 10, y: 140, width: 136, height: 1751), window: .zero)
        #expect(DockTiles.panel(in: image, near: CGRect(x: 250, y: 300, width: 130, height: 1500), scale: 2) == nil)
    }

    @Test func unusableListsGiveNoDock() {
        #expect(AccessibilityBounds.dockRect(lists: [], displayOrigin: .zero, scale: 2, extent: extent) == nil)
        let bad = [CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), CGRect(x: 5, y: 5, width: 0, height: 50),
                   CGRect(x: 9000, y: 9000, width: 100, height: 100), CGRect(x: 0, y: 0, width: 2, height: 2)]
        #expect(AccessibilityBounds.dockRect(lists: bad, displayOrigin: .zero, scale: 2, extent: extent) == nil)
    }
}
