import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

/// Hover and Left/Right over Finder's sidebar in column view. The frames are the live AX tree of the round 13 "Recents" window
/// (notes/fixtures/round13), read from the shell on a 2x, 1512 x 982 pt display (macOS 26): the window and two split groups are
/// (341, 162, 920 x 436); the sidebar is a scroll area (341, 214, 159 x 384) over an outline (340, 213, 161 x 748) of 159 pt `AXOutlineRow`s,
/// each around a 139 pt `AXCell`. Item rows are 32 pt with an icon and a text starting 35 pt into the cell; section headers ("Favorites",
/// "Locations") are 19 pt, and their cell holds only a text (356, y - 1, 141 x 21) that fills it. The content split group holds the column
/// view's `AXBrowser` (340, 161, 922 x 438), which spans the sidebar too.
struct FinderSidebarHoverTests {
    let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)
    /// Every sidebar row's top and height down to the scroll area's bottom (598) and one past it; the 19 pt rows are headers.
    let rowYs: [(y: CGFloat, height: CGFloat)] = [(214, 32), (246, 32), (291, 19), (310, 32), (342, 32), (374, 32), (406, 32), (438, 32), (483, 19), (502, 32), (534, 32), (566, 32), (598, 32)]
    let window = AXFrame(roleDescription: "standard window", rect: CGRect(x: 341, y: 162, width: 920, height: 436), role: "AXWindow", title: "Recents",
                         subrole: "AXStandardWindow", identifier: "FinderWindow")
    let split = AXFrame(roleDescription: "split group", rect: CGRect(x: 341, y: 162, width: 920, height: 436), role: "AXSplitGroup")
    var sidebar: [AXFrame] {
        [AXFrame(roleDescription: "outline", rect: CGRect(x: 340, y: 213, width: 161, height: 748), role: "AXOutline", identifier: "_NS:8", elementDescription: "sidebar"),
         AXFrame(roleDescription: "scroll area", rect: CGRect(x: 341, y: 214, width: 159, height: 384), role: "AXScrollArea", identifier: "_NS:61"), split, window]
    }

    private func row(_ index: Int) -> AXFrame {
        AXFrame(roleDescription: "outline row", rect: CGRect(x: 341, y: rowYs[index].y, width: 159, height: rowYs[index].height), role: "AXRow", subrole: "AXOutlineRow")
    }
    private func cell(_ index: Int) -> AXFrame { AXFrame(roleDescription: "cell", rect: CGRect(x: 351, y: rowYs[index].y, width: 139, height: rowYs[index].height), role: "AXCell") }
    private func isHeader(_ index: Int) -> Bool { rowYs[index].height == 19 }
    private func text(_ index: Int) -> AXFrame {
        isHeader(index) ? AXFrame(roleDescription: "text", rect: CGRect(x: 356, y: rowYs[index].y - 1, width: 141, height: 21), role: "AXStaticText", identifier: "xSidebarHeader")
            : AXFrame(roleDescription: "text", rect: CGRect(x: 386, y: rowYs[index].y + 7, width: 97, height: 18), role: "AXStaticText")
    }
    private func pixels(_ rect: CGRect) -> CGRect { AccessibilityBounds.pixels(of: rect, displayOrigin: .zero, scale: 2, extent: extent) }
    /// The chain a hover over a row's text reads: the text, its cell, its row, then the sidebar up to the window.
    private func hovered(_ index: Int) -> [AXFrame] { [text(index), cell(index), row(index)] + sidebar }
    /// The other rows' chains as `Accessibility.peers(of:)` builds them: an item row collapses to its cell (two children), a header
    /// on through its cell to its text (one child that fills it).
    private func siblings(of hoveredIndex: Int) -> [[AXFrame]] {
        rowYs.indices.filter { $0 != hoveredIndex }.map { (isHeader($0) ? [text($0), cell($0), row($0)] : [cell($0), row($0)]) + sidebar }
    }

    /// Hit tested at (801, 380), Finder answered with the browser and its parents. Every one of them is the window's own frame, so
    /// hover drops them all and finds nothing: the hover falls back to the window, as reported over the sidebar.
    @Test func theWindowSizedBrowserChainGivesHoverNothing() {
        let browser = AXFrame(roleDescription: "browser", rect: CGRect(x: 340, y: 161, width: 922, height: 438), role: "AXBrowser", identifier: "ColumnView",
                              elementDescription: "column view")
        #expect(AccessibilityBounds.hoverLevel([browser, split, split, window]).isEmpty)
    }

    /// The chain the walk down by frames gives at (420, 326), the Applications row: the cell hovers, and Up reaches the sidebar
    /// (the outline clipped to its scroll area).
    @Test func theWalkedDownChainHoversTheRowAndTheSidebar() async throws {
        let found = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(hovered(3)), displayOrigin: .zero, scale: 2, extent: extent)
        #expect(found.map(\.bounds) == [pixels(cell(3).rect), pixels(CGRect(x: 341, y: 214, width: 159, height: 384))], "\(found.map(\.bounds))")
    }

    @Test func aHeaderIsAStaticTextThatFillsItsOutlineRow() {
        #expect(AccessibilityBounds.sectionHeaderRow(hovered(2)) == 2, "Favorites")
        #expect(AccessibilityBounds.sectionHeaderRow(hovered(8)) == 2, "Locations")
        #expect(AccessibilityBounds.sectionHeaderRow(hovered(3)) == nil, "Applications: its text starts 35 pt into the cell")
        #expect(AccessibilityBounds.sectionHeaderRow([cell(2), row(2)] + sidebar) == nil, "no text, no header")
        let tableRow = AXFrame(roleDescription: "row", rect: row(2).rect, role: "AXRow", subrole: "AXTableRow")
        #expect(AccessibilityBounds.sectionHeaderRow([text(2), cell(2), tableRow] + sidebar) == nil, "a text-only table row is not a header")
        #expect(AccessibilityBounds.hoverLevel(hovered(2)).first == sidebar[0], "hovering a header picks the sidebar, as hovering a text does")
        #expect(AccessibilityBounds.peerLevel(hovered(2)) == 2, "its peers are still the outline's rows, not the scroll area's children (the scroll bar)")
    }

    @Test func leftAndRightSkipTheSectionHeaders() async throws {
        let hover = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(hovered(3)), displayOrigin: .zero, scale: 2, extent: extent)
        let peers = try await AccessibilityBounds.peerCandidates(siblings(of: 3), displayOrigin: .zero, scale: 2, extent: extent)
        #expect(!peers.contains { $0.bounds == pixels(cell(2).rect) || $0.bounds == pixels(cell(8).rect) }, "no header is a peer")
        let windowCandidate = Candidate(id: "window-0", label: "Window", bounds: pixels(window.rect), score: 0, kind: .window)
        var session = SelectionSession(candidates: [windowCandidate] + hover, extent: extent, anchor: CGPoint(x: pixels(cell(3).rect).midX, y: pixels(cell(3).rect).midY))
        session.merge(peers)
        #expect(session.selected?.bounds == pixels(cell(3).rect))
        #expect(session.step(right: false) && session.selected?.bounds == pixels(cell(1).rect), "Left from Applications goes to Shared, past Favorites")
        #expect(session.step(right: true) && session.selected?.bounds == pixels(cell(3).rect))
        for _ in 0..<5 { _ = session.step(right: true) }
        #expect(session.selected?.bounds == pixels(cell(9).rect), "Right from Downloads goes to iCloud Drive, past Locations")
    }
}
