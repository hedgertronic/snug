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

    @Test func pickSelectsTheShortlistEntryAndLocks() {
        var session = SelectionSession(candidates: regions, extent: extent, anchor: CGPoint(x: 150, y: 150))
        session.pick(1)
        #expect(session.selected?.id == session.shortlist[1].id && session.isLocked)
        session.pick(99)
        #expect(session.selected?.id == session.shortlist[1].id)
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
}
