import CoreGraphics
import Foundation
import ImageIO
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

    /// Finder's column view: its AXBrowser spans the window a few points past it on each side, so it would be a second target ("Browser")
    /// beside the window ("Recents", the window title). The window target stays; an element inset well inside it still counts.
    @Test func hoverLevelSkipsElementsThatAreTheWindowsOwnFrame() {
        let window = AXFrame(roleDescription: "standard window", rect: CGRect(x: 55, y: 37, width: 890, height: 422), role: "AXWindow", title: "Recents")
        let frames = [
            AXFrame(roleDescription: "row", rect: CGRect(x: 220, y: 95, width: 225, height: 21), role: "AXRow"),
            AXFrame(roleDescription: "browser", rect: CGRect(x: 52, y: 34, width: 896, height: 428), role: "AXBrowser"),
            window
        ]
        #expect(AccessibilityBounds.hoverLevel(frames).map(\.roleDescription) == ["row"])
        let content = AXFrame(roleDescription: "browser", rect: CGRect(x: 208, y: 37, width: 737, height: 422), role: "AXBrowser")
        #expect(AccessibilityBounds.hoverLevel([content, window]).map(\.roleDescription) == ["browser"])
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

    /// A 2x Dock panel (rounded, 2 px light rim, icon tiles along its length) on a dark gradient, with a lighter window (`windowGray`) beside it.
    private func rimmedDock(size: CGSize, panel: CGRect, window: CGRect, windowGray: CGFloat = 0.3) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.1, green: 0.08, blue: 0.2, alpha: 1),
                                   CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1)] as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: windowGray, alpha: 1))
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

    @Test func aBrightWindowJustPastTheDockDoesNotTakeItsSide() throws {
        // A white window 11 pt right of the panel: its edge is inside the side search and far stronger than the rim.
        let panel = CGRect(x: 10, y: 140, width: 136, height: 1751)
        let image = rimmedDock(size: CGSize(width: 400, height: 1964), panel: panel, window: CGRect(x: 168, y: 88, width: 232, height: 1852), windowGray: 1)
        let found = try #require(DockTiles.panel(in: image, near: CGRect(x: 20, y: 140, width: 134, height: 1750), scale: 2))
        for (a, b) in [(found.minX, panel.minX), (found.maxX, panel.maxX), (found.minY, panel.minY), (found.maxY, panel.maxY)] {
            #expect(abs(a - b) <= 3, "found \(found), panel \(panel)")
        }
    }

    @Test func theUsersLeftDockBesideSafariComesFromItsRim() throws {
        // The user's left Dock with Safari 12 pt to its right: their 2000 px wide screenshot resampled to the display's 3024 px (2x) and cut
        // to its left 400 px. The panel's rims in those pixels run x 9 to 145 and y 139 to 1891. The union is this Dock's live one (hover.log).
        let url = try #require(Bundle.module.url(forResource: "DockBesideSafari", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let found = try #require(DockTiles.panel(in: image, near: CGRect(x: 20, y: 140, width: 134, height: 1750), scale: 2))
        for (a, b) in [(found.minX, 9), (found.maxX, 145), (found.minY, 139), (found.maxY, 1891)] as [(CGFloat, CGFloat)] {
            #expect(abs(a - b) <= 4, "found \(found)")
        }
        #expect(DockTiles.tiles(in: image, panel: found, scale: 2).count == 16)
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

/// Hover over system surfaces, with frames and rectangles from the user's hover.log (a 2x display, 1512 x 982 pt).
struct SystemSurfaceHoverTests {
    let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)

    /// What hover merges for one lookup in the window under the pointer, as `requestAccessibility` does.
    private func lookup(_ frames: [AXFrame], inWindowNamed name: String, frozen: Bool) async throws -> [Candidate] {
        guard AccessibilityBounds.looksUp(inWindowNamed: name, frozen: frozen) else { return [] }
        return try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(frames), displayOrigin: .zero, scale: 2, extent: extent)
    }

    /// A Dock lookup's chain (item, its magnified list, the Dock application) over the frozen Dock `panel` with one icon `tile`:
    /// a gap in the panel hovers the panel, the icon hovers its tile, and no Accessibility frame of the Dock joins.
    private func expectPanelHover(item: CGRect, list: CGRect, panel: CGRect, tile: CGRect, gap: CGPoint) async throws {
        let frames = [AXFrame(roleDescription: "application dock item", rect: item, role: "AXDockItem", title: "Safari"),
                      AXFrame(roleDescription: "list", rect: list, role: "AXList"),
                      AXFrame(roleDescription: "application", rect: .zero, role: "AXApplication", title: "Dock")]
        let found = try await lookup(frames, inWindowNamed: "Dock", frozen: true)
        #expect(found.isEmpty)
        let dock = Candidate(id: "window-0", label: "Window", bounds: panel, score: 0, kind: .window)
        let icon = Candidate(id: "dock-2", label: "Safari", bounds: tile, score: AccessibilityBounds.baseScore, kind: .element)
        var session = SelectionSession(candidates: [dock, icon] + found, extent: extent, anchor: gap)
        #expect(session.selected?.id == dock.id, "a gap in the Dock hovers the panel, not \(String(describing: session.selected))")
        #expect(!session.parents.contains { $0.kind == .element })
        session.hover(at: CGPoint(x: tile.midX, y: tile.midY))
        #expect(session.selected?.id == icon.id)
        #expect(session.parents.first?.id == dock.id)
    }

    @Test func theLeftVerticalMagnifiedDockHoversItsPanelNeverItsList() async throws {
        // hover.log: a lookup over Safari with magnification on, and the panel read from the frozen image's rim.
        try await expectPanelHover(item: CGRect(x: 5, y: 155.9, width: 115, height: 99), list: CGRect(x: 10, y: -20, width: 67, height: 1058),
                                   panel: CGRect(x: 8, y: 140, width: 138, height: 1750), tile: CGRect(x: 29, y: 316, width: 96, height: 96), gap: CGPoint(x: 77, y: 430))
    }

    @Test func theBottomMagnifiedDockHoversItsPanelNeverItsList() async throws {
        try await expectPanelHover(item: CGRect(x: 700, y: 880, width: 100, height: 84), list: CGRect(x: 440, y: 880, width: 640, height: 102),
                                   panel: CGRect(x: 1000, y: 1820, width: 1024, height: 136), tile: CGRect(x: 1100, y: 1840, width: 96, height: 96), gap: CGPoint(x: 1250, y: 1888))
    }

    @Test func otherFrozenTargetsAndWindowsStillLookUp() {
        #expect(AccessibilityBounds.looksUp(inWindowNamed: "Control Center", frozen: true))
        #expect(AccessibilityBounds.looksUp(inWindowNamed: "Dock", frozen: false))
    }

    @Test func stageManagerHoversTheThumbnailAndNeverItsFullScreenGroup() async throws {
        // hover.log: a lookup over the "-zsh" thumbnail in the Stage Manager strip on the right.
        let frames = [AXFrame(roleDescription: "button", rect: CGRect(x: 1294.71, y: 342.27, width: 201.29, height: 150.23), role: "AXButton", title: "-zsh"),
                      AXFrame(roleDescription: "list", rect: CGRect(x: 1294.71, y: 162.03, width: 201.29, height: 690.94), role: "AXList"),
                      AXFrame(roleDescription: "group", rect: CGRect(x: 0, y: 0, width: 1512, height: 982), role: "AXGroup"),
                      AXFrame(roleDescription: "application", rect: .zero, role: "AXApplication", title: "WindowManager")]
        let found = try await lookup(frames, inWindowNamed: "WindowManager", frozen: false)
        #expect(found.map(\.label) == ["Button"], "the strip's list is never a candidate")
        let window = Candidate(id: "window-1", label: "Window", bounds: CGRect(x: 200, y: 100, width: 2000, height: 1500), score: -1, kind: .window)
        var session = SelectionSession(candidates: [window] + found, extent: extent, anchor: CGPoint(x: 2838, y: 847))
        #expect(session.selected?.bounds == CGRect(x: 2589, y: 684, width: 403, height: 301))
        session.hover(at: CGPoint(x: 1000, y: 800))
        #expect(session.selected?.id == window.id, "the window behind is hovered, not \(String(describing: session.selected))")
        session.hover(at: CGPoint(x: 2838, y: 1100))
        #expect(session.selected?.kind == .display, "the gap below the thumbnail hovers what is behind the strip, not \(String(describing: session.selected))")
    }

    @Test func stageManagerThumbnailsAreTheirVisiblePicturesNotTheirPaddedButtons() async throws {
        // The user's capture of the strip's list (2586, 378, 406, 1274 px; hover.log), put back where it was on a 2x display, and the
        // lookups' button frames. Each tilted picture's left edge is at x 146 in the capture; the frames start at x 3.
        let url = try #require(Bundle.module.url(forResource: "StageManagerStrip", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let strip = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: 3024, height: 1964, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(strip, in: CGRect(x: 2586, y: 1964 - 378 - 1274, width: 406, height: 1274))
        let image = try #require(context.makeImage())
        let window = Candidate(id: "window-1", label: "Window", bounds: CGRect(x: 168, y: 88, width: 2484, height: 1854), score: -1, kind: .window)
        for index in 0..<3 {
            let frames = [AXFrame(roleDescription: "button", rect: CGRect(x: 1294.71, y: 189.15 + 180.23 * Double(index), width: 201.29, height: 150.23), role: "AXButton"),
                          AXFrame(roleDescription: "list", rect: CGRect(x: 1293.43, y: 189.15, width: 202.57, height: 636.7), role: "AXList"),
                          AXFrame(roleDescription: "group", rect: CGRect(x: 0, y: 0, width: 1512, height: 982), role: "AXGroup"),
                          AXFrame(roleDescription: "application", rect: .zero, role: "AXApplication", title: "WindowManager")]
            let button = try #require(try await lookup(frames, inWindowNamed: "WindowManager", frozen: false).first)
            let found = StageManager.visibleThumbnails([button], frames: frames, in: image, scale: 2)
            let thumbnail = try #require(found.first).bounds
            #expect(abs(thumbnail.minX - (2586 + 146)) <= 2 && thumbnail.maxX == button.bounds.maxX
                    && thumbnail.minY == button.bounds.minY && thumbnail.maxY == button.bounds.maxY, "button \(button.bounds), found \(thumbnail)")
            var session = SelectionSession(candidates: [window] + found, extent: extent, anchor: CGPoint(x: 2800, y: button.bounds.midY))
            #expect(session.selected?.bounds == thumbnail)
            session.hover(at: CGPoint(x: 2620, y: button.bounds.midY))
            #expect(session.selected?.id == window.id, "the padding left of the picture hovers the window behind, not \(String(describing: session.selected))")
        }
        // The strip on the left (the default with the Dock at the bottom): the same capture mirrored at the screen's left edge, whose
        // pictures' right edges sit at x 3024 - 2732 = 292.
        context.clear(CGRect(x: 0, y: 0, width: 3024, height: 1964))
        context.translateBy(x: 3024, y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(strip, in: CGRect(x: 2586, y: 1964 - 378 - 1274, width: 406, height: 1274))
        let mirrored = try #require(context.makeImage())
        for index in 0..<3 {
            let button = CGRect(x: 32, y: (378 + 360.46 * Double(index)).rounded(), width: 403, height: 301)
            let thumbnail = StageManager.thumbnail(in: mirrored, button: button, scale: 2)
            #expect(abs(thumbnail.maxX - 292) <= 2 && thumbnail.minX == button.minX && thumbnail.minY == button.minY && thumbnail.maxY == button.maxY,
                    "mirrored button \(button), found \(thumbnail)")
        }
        // Frames from any other app stay as they are.
        let other = Candidate(id: "ax", label: "Button", bounds: CGRect(x: 2589, y: 378, width: 403, height: 301), score: 2, kind: .element)
        #expect(StageManager.visibleThumbnails([other], frames: [AXFrame(roleDescription: "application", rect: .zero, role: "AXApplication", title: "Finder")], in: image, scale: 2) == [other])
    }
}
