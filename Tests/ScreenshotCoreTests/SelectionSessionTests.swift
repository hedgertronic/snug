import Foundation
import Testing
@testable import ScreenshotCore

struct SelectionSessionTests {
    let extent = CGRect(x: 0, y: 0, width: 1000, height: 800)
    var regions: [Candidate] { [
        Candidate(id: "table", label: "Table", bounds: CGRect(x: 100, y: 100, width: 600, height: 400), score: 90, kind: .table),
        Candidate(id: "cell", label: "Cell", bounds: CGRect(x: 100, y: 100, width: 200, height: 100), score: 30, kind: .cell),
        Candidate(id: "window", label: "Window", bounds: CGRect(x: 50, y: 50, width: 800, height: 600), score: -50, kind: .window)
    ] }

    @Test func keyboardChoiceSurvivesPointerMotion() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        #expect(session.selected?.id == "cell")
        session.cycle()
        #expect(session.selected?.id == "table")
        session.hover(at: CGPoint(x: 900, y: 750))
        #expect(session.selected?.id == "table")
        session.toggleLock()
        session.hover(at: CGPoint(x: 900, y: 750))
        #expect(session.selected?.kind == .display)
    }

    @Test func thePointerAtTheScreenEdgePicksTheDisplay() {
        let atEdge = Candidate(id: "edge", label: "Sidebar", bounds: CGRect(x: 0, y: 0, width: 200, height: 800), score: 2, kind: .element)
        var session = SelectionSession(candidates: regions + [atEdge], extent: extent, anchor: CGPoint(x: 0, y: 400))
        #expect(session.selected?.kind == .display && session.anchorAtEdge)
        session.hover(at: CGPoint(x: 3, y: 400))
        #expect(session.selected?.id == "edge" && !session.anchorAtEdge)
        session.hover(at: CGPoint(x: 999, y: 799))
        #expect(session.selected?.kind == .display)
    }

    @Test func childIsWhatDownWouldSelect() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        #expect(session.selected?.id == "cell" && session.child == nil && session.parents.first?.id == "table")
        session.expand()
        #expect(session.selected?.id == "table" && session.child?.id == "cell")
        session.expand()
        let child = session.child
        session.shrink()
        #expect(child?.id == "table" && session.selected?.id == "table" && session.child?.id == "cell")
    }

    @Test func aKeyAtTheScreenEdgeReleasesOnceThePointerMovesAway() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 0, y: 400))
        session.expand()
        #expect(session.selected?.kind == .display && session.isLocked)
        #expect(session.holds(at: CGPoint(x: 6, y: 404)))
        #expect(!session.holds(at: CGPoint(x: 150, y: 150)))
        session.toggleLock()
        session.hover(at: CGPoint(x: 150, y: 150))
        #expect(session.selected?.id == "cell")
    }

    @Test func upReachesAWindowBarelyLargerThanItsContentArea() {
        // iTerm2: the terminal area below a 36 pt tab bar overlaps its window by more than 96%.
        let window = Candidate(id: "window-0", label: "Window", bounds: CGRect(x: 0, y: 0, width: 1242, height: 927), score: 0, kind: .window)
        let content = Candidate(id: "content", label: "Group", bounds: CGRect(x: 0, y: 36, width: 1242, height: 891), score: 2, kind: .element)
        var session = SelectionSession(candidates: [window, content], extent: CGRect(x: 0, y: 0, width: 1512, height: 982), anchor: CGPoint(x: 600, y: 500))
        session.merge([])
        #expect(session.selected?.id == "content")
        session.expand()
        #expect(session.selected?.id == "window-0")
        session.expand()
        #expect(session.selected?.kind == .display)
    }

    @Test func accessibilityElementsBeatGeometryCellsAndLeadTheShortlist() {
        let element = Candidate(id: "ax", label: "button", bounds: CGRect(x: 120, y: 110, width: 100, height: 50), score: 2, kind: .element)
        let session = SelectionSession(candidates: regions + [element], extent: extent, anchor: CGPoint(x: 150, y: 130))
        #expect(session.selected?.id == "ax")
        #expect(session.shortlist.first?.id == "ax" && session.shortlist.contains { $0.id == "cell" })
    }

    @Test func pickSelectsTheShortlistEntryAndLocks() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        session.pick(1)
        #expect(session.selected?.id == session.shortlist[1].id && session.isLocked)
        session.pick(99)
        #expect(session.selected?.id == session.shortlist[1].id)
    }

    @Test func parentsListTheExpansionPathNearestFirst() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        #expect(session.parents.map(\.id) == ["table", "window", "display"])
        session.expand()
        #expect(session.parents.map(\.id) == ["window", "display"])
    }

    @Test func lateResultsJoinThePoolWithoutChangingAPick() {
        let late = Candidate(id: "late", label: "Late", bounds: CGRect(x: 120, y: 120, width: 60, height: 40), score: 99, kind: .text)
        var hovering = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        hovering.merge([late])
        #expect(hovering.selected?.id == "late")
        var picked = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        picked.pick(1)
        let (selected, shortlist) = (picked.selected, picked.shortlist)
        picked.merge([late])
        #expect(picked.selected == selected && picked.shortlist == shortlist)
        #expect(picked.candidates.contains { $0.id == "late" })
        picked.hover(at: CGPoint(x: 150, y: 150))
        #expect(picked.selected == selected)
        picked.toggleLock()
        picked.hover(at: CGPoint(x: 150, y: 150))
        #expect(picked.selected?.id == "late")
    }

    @Test func cyclingStepsThroughCandidatesAtThePointBothWays() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        let first = session.selected?.id
        session.cycle()
        #expect(session.selected?.id != first)
        session.cycle(backward: true)
        #expect(session.selected?.id == first)
    }

    @Test func expandingAndShrinkingRestoresExactRegion() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        session.expand(); #expect(session.selected?.id == "table")
        session.expand(); #expect(session.selected?.id == "window")
        session.expand(); #expect(session.selected?.kind == .display)
        session.shrink(); #expect(session.selected?.id == "window")
        session.shrink(); #expect(session.selected?.id == "table")
        session.shrink(); #expect(session.selected?.id == "cell")
    }

    @Test func pointerDistinguishesTextCellAndTableBorder() {
        let text = Candidate(id: "text", label: "Text", bounds: CGRect(x: 120, y: 120, width: 80, height: 20),
                             score: 0.8, kind: .text)
        let broadText = Candidate(id: "block", label: "Text block", bounds: regions[0].bounds.insetBy(dx: 1, dy: 1),
                                  score: 0.7, kind: .text)
        var session = SelectionSession(candidates: regions + [text, broadText], extent: extent, anchor: CGPoint(x: 150, y: 130))
        #expect(session.selected?.id == "text")
        session.expand(); #expect(session.selected?.id == "cell")
        session.expand(); #expect(session.selected?.id == "table")
        session.toggleLock()
        session.hover(at: CGPoint(x: 250, y: 175))
        #expect(session.selected?.id == "cell")
        session.hover(at: CGPoint(x: 101, y: 150))
        #expect(session.selected?.id == "table")
        session.hover(at: CGPoint(x: 500, y: 350))
        #expect(session.selected?.id == "table")
    }

    @Test func manualCropClipsAndNudgesWithoutResizing() {
        var session = SelectionSession(candidates: [], extent: extent, anchor: .zero)
        session.setManual(CGRect(x: -20, y: -10, width: 200, height: 100))
        #expect(session.selected?.bounds == CGRect(x: 0, y: 0, width: 180, height: 90))
        session.moveManual(dx: 1000, dy: 1000)
        #expect(session.selected?.bounds == CGRect(x: 820, y: 710, width: 180, height: 90))
    }

    @Test func duplicateAndOutsideRegionsAreRemoved() {
        let duplicate = Candidate(id: "duplicate", label: "Duplicate", bounds: regions[0].bounds, score: 0)
        let outside = Candidate(id: "outside", label: "Outside", bounds: CGRect(x: -50, y: -50, width: 10, height: 10), score: 100)
        let result = Detection.normalized(regions + [duplicate, outside], within: extent)
        #expect(result.count == regions.count)
    }

    @Test func mergesCellBoundaryEstimatesButPreservesNeighborsAndText() {
        let geometry = Candidate(id: "geometry-cell", label: "Cell", bounds: CGRect(x: 281, y: 198, width: 219, height: 54), score: 0.95, kind: .cell)
        let vision = Candidate(id: "vision-cell", label: "Cell", bounds: CGRect(x: 282, y: 202, width: 220, height: 49), score: 0.74, kind: .cell)
        let neighbor = Candidate(id: "neighbor", label: "Cell", bounds: CGRect(x: 500, y: 198, width: 220, height: 54), score: 0.95, kind: .cell)
        let text = Candidate(id: "text", label: "Text", bounds: CGRect(x: 295, y: 215, width: 50, height: 20), score: 0.8, kind: .text)
        let result = Detection.normalized([vision, neighbor, text, geometry], within: extent)
        #expect(Set(result.map(\.id)) == Set(["geometry-cell", "neighbor", "text"]))
        var session = SelectionSession(candidates: result, extent: extent, anchor: CGPoint(x: 400, y: 225))
        #expect(session.selected?.id == "geometry-cell")
        session.cycle()
        #expect(session.selected?.kind == .display)
    }

    @Test func fullImageShortcutRestoresPreviousSelection() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        session.select(kind: .display); #expect(session.selected?.kind == .display)
        session.select(kind: .display); #expect(session.selected?.id == "cell")
    }

    @Test func upReachesAnElementWhosePixelEdgesOverhangItsFrameSlightly() {
        // A board found in pixels overhangs the accessibility frame of the card around it by 2 px on the right and bottom.
        let card = Candidate(id: "card", label: "Group", bounds: CGRect(x: 200, y: 450, width: 1590, height: 750), score: 2, kind: .element)
        let board = Candidate(id: "board", label: "Table", bounds: CGRect(x: 1042, y: 454, width: 750, height: 748), score: 0.92, kind: .table)
        let page = Candidate(id: "page", label: "Web Area", bounds: CGRect(x: 0, y: 100, width: 2000, height: 1250), score: 1.99, kind: .element)
        var session = SelectionSession(candidates: [card, board, page], extent: CGRect(x: 0, y: 0, width: 2000, height: 1353), anchor: CGPoint(x: 1400, y: 800))
        session.pick(session.shortlist.firstIndex { $0.id == "board" }!)
        session.expand()
        #expect(session.selected?.id == "card")
        session.shrink()
        session.shrink()
        #expect(session.selected?.id == "board")
    }

    @Test func theSmallestAccessibilityFrameAtThePointerIsHoverableEvenWhenAnotherLookupScoredALargerOneHigher() {
        // From the design canvas: a row group found as the innermost frame of one lookup (2.0) and the link inside it found one level up
        // from another lookup (1.99). Up from the link reaches the row, and the pointer over the link must pick the link directly.
        let row = Candidate(id: "row", label: "Group", bounds: CGRect(x: 372, y: 656, width: 2280, height: 84), score: 2.0, kind: .element)
        let link = Candidate(id: "link", label: "Link", bounds: CGRect(x: 420, y: 672, width: 122, height: 52), score: 1.99, kind: .element)
        let page = Candidate(id: "page", label: "Group", bounds: CGRect(x: 168, y: 248, width: 2484, height: 1694), score: 1.99, kind: .element)
        var session = SelectionSession(candidates: [row, link, page], extent: CGRect(x: 0, y: 0, width: 3024, height: 1964), anchor: CGPoint(x: 480, y: 700))
        #expect(session.selected?.id == "link")
        #expect(session.parents.map(\.id).prefix(2) == ["row", "page"])
        session.hover(at: CGPoint(x: 1500, y: 700))
        #expect(session.selected?.id == "row")
        session.hover(at: CGPoint(x: 1500, y: 900))
        #expect(session.selected?.id == "page")
    }
}
