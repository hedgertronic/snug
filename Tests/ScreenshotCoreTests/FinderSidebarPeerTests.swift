import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

/// Left and Right in a Finder sidebar. The frames are the live AX tree of a Finder column-view window titled "build" (read from the
/// shell on a 2x, 1512 x 982 pt display): window (341, 162, 920 x 436), a scroll area
/// (341, 214, 159 x 384) over an outline (340, 213, 161 x 748) of 23 rows, each a 159 pt `AXRow` around a 139 pt `AXCell`; rows are 32 pt
/// tall, section headers 19 pt. The hovered element is the cell: its row is only padding, and the rows are the row's siblings.
struct FinderSidebarPeerTests {
    let extent = CGRect(x: 0, y: 0, width: 3024, height: 1964)
    let rowYs: [(y: CGFloat, height: CGFloat)] = [(214, 32), (246, 32), (291, 19), (310, 32), (342, 32), (374, 32), (406, 32), (438, 32), (483, 19), (502, 32), (534, 32), (566, 32), (598, 32), (630, 32)]
    let ancestors = [AXFrame(roleDescription: "outline", rect: CGRect(x: 340, y: 213, width: 161, height: 748), role: "AXOutline"),
                     AXFrame(roleDescription: "scroll area", rect: CGRect(x: 341, y: 214, width: 159, height: 384), role: "AXScrollArea"),
                     AXFrame(roleDescription: "split group", rect: CGRect(x: 341, y: 162, width: 920, height: 436), role: "AXSplitGroup"),
                     AXFrame(roleDescription: "standard window", rect: CGRect(x: 341, y: 162, width: 920, height: 436), role: "AXWindow"),
                     AXFrame(roleDescription: "application", rect: .zero, role: "AXApplication", title: "Finder")]

    private func row(_ index: Int) -> AXFrame {
        AXFrame(roleDescription: "row", rect: CGRect(x: 341, y: rowYs[index].y, width: 159, height: rowYs[index].height), role: "AXRow", subrole: "AXOutlineRow")
    }
    private func cell(_ index: Int) -> AXFrame { AXFrame(roleDescription: "cell", rect: CGRect(x: 351, y: rowYs[index].y, width: 139, height: rowYs[index].height), role: "AXCell") }
    private func text(_ index: Int) -> AXFrame {
        AXFrame(roleDescription: "text", rect: CGRect(x: 375, y: rowYs[index].y + 8, width: 70, height: 16), role: "AXStaticText", title: "Row \(index)")
    }
    private func pixels(_ frame: AXFrame) -> CGRect { AccessibilityBounds.pixels(of: frame.rect, displayOrigin: .zero, scale: 2, extent: extent) }

    /// The hover lookup over row 6's text.
    private var hovered: [AXFrame] { [text(6), cell(6), row(6)] + ancestors }
    /// The other rows' chains as `Accessibility.peers(of:)` builds them: each row collapsed to its single child, then the ancestors. A 19 pt
    /// section header collapses on to its text, which fills its cell.
    private var siblings: [[AXFrame]] {
        rowYs.indices.filter { $0 != 6 }.map { index in
            let header = AXFrame(roleDescription: "text", rect: CGRect(x: 356, y: rowYs[index].y - 1, width: 141, height: 21), role: "AXStaticText")
            return (rowYs[index].height == 19 ? [header, cell(index), row(index)] : [cell(index), row(index)]) + ancestors
        }
    }

    @Test func peersHangOffTheRowAroundTheHoveredCell() {
        #expect(AccessibilityBounds.hoverLevel(hovered).first == cell(6), "the text is not hoverable and the row is padding, so the cell hovers")
        #expect(AccessibilityBounds.peerLevel(hovered) == 2, "the row (index 2 after the text and the cell) is the element with siblings")
        #expect(AccessibilityBounds.peerLevel([cell(6), row(6)] + ancestors) == 1)
        #expect(AccessibilityBounds.peerLevel([AXFrame(roleDescription: "text", rect: CGRect(x: 0, y: 0, width: 5, height: 5), role: "AXStaticText")]) == nil)
        let full = AXFrame(roleDescription: "group", rect: ancestors[3].rect, role: "AXGroup")
        #expect(AccessibilityBounds.peerLevel([cell(6), full] + ancestors.suffix(2)) == 0, "the run never climbs into the window")
    }

    @Test func peersArriveAtTheCellDepthAndOffScreenRowsDrop() async throws {
        let peers = try await AccessibilityBounds.peerCandidates(siblings, displayOrigin: .zero, scale: 2, extent: extent)
        let visible = rowYs.indices.filter { $0 != 6 && rowYs[$0].y < 598 }
        #expect(visible.filter { rowYs[$0].height == 32 }.map { pixels(cell($0)) }.allSatisfy { cellRect in peers.contains { $0.bounds == cellRect } },
                "each visible item row arrives as its cell: \(peers.map(\.bounds))")
        #expect(!visible.filter { rowYs[$0].height == 19 }.map { pixels(cell($0)) }.contains { cellRect in peers.contains { $0.bounds == cellRect } }, "no header is a peer")
        #expect(!peers.contains { $0.bounds == pixels(row(0)) }, "no peer is a padded row")
        #expect(!peers.contains { $0.bounds.minY >= 598 * 2 && $0.bounds.height < 100 }, "rows below the scroll area's edge are not candidates")
    }

    @Test func rightAndLeftStepThroughTheSidebarFromTheHoveredRowAndUpStillReachesTheOutline() async throws {
        let hover = try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(hovered), displayOrigin: .zero, scale: 2, extent: extent)
        let peers = try await AccessibilityBounds.peerCandidates(siblings, displayOrigin: .zero, scale: 2, extent: extent)
        let window = Candidate(id: "window-0", label: "Window", bounds: pixels(ancestors[3]), score: 0, kind: .window)
        var session = SelectionSession(candidates: [window] + hover, extent: extent, anchor: CGPoint(x: pixels(cell(6)).midX, y: pixels(cell(6)).midY))
        #expect(session.selected?.bounds == pixels(cell(6)))
        #expect(!session.step(right: false) && session.selected?.bounds == pixels(cell(6)), "with only the hovered row, there is no peer: a beep")
        session.merge(peers)
        #expect(session.selected?.bounds == pixels(cell(6)), "the hover is unchanged by the peers")
        #expect(session.parents.first?.label == "Outline", "Up from the cell goes to the outline, not to a padded row: \(session.parents.map(\.label))")
        #expect(session.step(right: true) && session.selected?.bounds == pixels(cell(7)))
        #expect(session.step(right: false) && session.step(right: false) && session.selected?.bounds == pixels(cell(5)))
        for _ in 0..<4 { _ = session.step(right: false) }
        #expect(session.selected?.bounds == pixels(cell(0)), "four more steps up from the cell at index 5 reach the top row, skipping the 19 pt header at index 2")
        #expect(session.step(right: false) && session.selected?.bounds == pixels(cell(11)), "Left from the top wraps to the last visible row")
    }
}
