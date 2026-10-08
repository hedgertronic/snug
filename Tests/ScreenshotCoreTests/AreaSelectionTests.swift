import CoreGraphics
import Testing
@testable import ScreenshotCore

struct AreaSelectionTests {
    let extent = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let exact = CGRect(x: 100, y: 100, width: 200, height: 100)
    let snapped = CGRect(x: 96, y: 96, width: 210, height: 110)

    @Test func dragStandardizesAndClamps() {
        var drag = AreaDrag(extent: extent, origin: CGPoint(x: 300, y: 300))
        drag.update(to: CGPoint(x: 200, y: 1200), moving: false)
        #expect(drag.rect == CGRect(x: 200, y: 300, width: 100, height: 500))
    }

    @Test func spaceMovesTheDragWithoutResizing() {
        var drag = AreaDrag(extent: extent, origin: CGPoint(x: 100, y: 100))
        drag.update(to: CGPoint(x: 300, y: 200), moving: false)
        drag.update(to: CGPoint(x: 340, y: 230), moving: true)
        #expect(drag.rect == CGRect(x: 140, y: 130, width: 200, height: 100))
        drag.update(to: CGPoint(x: 5000, y: 230), moving: true)
        #expect(drag.rect == CGRect(x: 800, y: 130, width: 200, height: 100))
    }

    @Test func releaseTakesFirstSuggestionAndTabCyclesToExactAndBack() {
        var selection = AreaSelection(extent: extent, exact: exact, suggestions: [snapped], takingFirst: true)
        #expect(selection.rect == snapped)
        selection.cycle(); #expect(selection.rect == exact)
        selection.cycle(); #expect(selection.rect == snapped)
        selection.cycle(backward: true); #expect(selection.rect == exact)
    }

    @Test func noSuggestionsKeepsExactAndLateSuggestionsCycle() {
        var selection = AreaSelection(extent: extent, exact: exact)
        selection.cycle(); #expect(selection.rect == exact)
        selection.setSuggestions([snapped])
        #expect(selection.rect == exact)
        selection.cycle(); #expect(selection.rect == snapped)
    }

    @Test func editingDropsFitsAndMakesTheEditExact() {
        var selection = AreaSelection(extent: extent, exact: exact, suggestions: [snapped], takingFirst: true)
        selection.move(by: CGPoint(x: 2, y: 0))
        #expect(selection.fits == [snapped.offsetBy(dx: 2, dy: 0)])
        #expect(selection.exact == selection.rect)
    }

    @Test func moveClampsToExtent() {
        var selection = AreaSelection(extent: extent, exact: exact)
        selection.move(by: CGPoint(x: -500, y: 5000))
        #expect(selection.rect == CGRect(x: 0, y: 700, width: 200, height: 100))
    }

    @Test func handlesHitTestAndResize() {
        var selection = AreaSelection(extent: extent, exact: exact)
        #expect(selection.handle(at: CGPoint(x: 103, y: 98), tolerance: 8) == .topLeft)
        #expect(selection.handle(at: CGPoint(x: 200, y: 101), tolerance: 8) == .top)
        #expect(selection.handle(at: CGPoint(x: 200, y: 150), tolerance: 8) == nil)
        selection.resize(.bottomRight, to: CGPoint(x: 400, y: 260))
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 300, height: 160))
        selection.resize(.left, to: CGPoint(x: 395, y: 0))
        #expect(selection.rect.width == AreaSelection.minimumSize)
        selection.resize(.top, to: CGPoint(x: 0, y: -50))
        #expect(selection.rect.minY == 0)
    }

    @Test func sidesAreDraggableAlongTheirLength() {
        var selection = AreaSelection(extent: extent, exact: exact)
        #expect(selection.handle(at: CGPoint(x: 103, y: 125), tolerance: 8) == .left)
        #expect(selection.handle(at: CGPoint(x: 296, y: 170), tolerance: 8) == .right)
        #expect(selection.handle(at: CGPoint(x: 140, y: 106), tolerance: 8) == .top)
        #expect(selection.handle(at: CGPoint(x: 250, y: 194), tolerance: 8) == .bottom)
        #expect(selection.handle(at: CGPoint(x: 90, y: 250), tolerance: 8) == nil)
        #expect(selection.handle(at: CGPoint(x: 250, y: 150), tolerance: 8) == nil)
        selection.resize(.right, to: CGPoint(x: 340, y: 999))
        #expect(selection.rect == CGRect(x: 100, y: 100, width: 240, height: 100))
    }

    @Test func previewSurvivesJitterInsideTheSnapBand() {
        let drag = CGRect(x: 350, y: 458, width: 580, height: 64)
        let preview = CGRect(x: 346, y: 454, width: 590, height: 72)
        #expect(AreaSelection.preview(preview, stillFits: drag.offsetBy(dx: 2, dy: 1), scale: 1))
        #expect(!AreaSelection.preview(preview, stillFits: drag.offsetBy(dx: 80, dy: 0), scale: 1))
    }
}
