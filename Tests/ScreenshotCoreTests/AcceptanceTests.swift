import ScreenshotBench
import ScreenshotCore
import XCTest

final class AcceptanceTests: XCTestCase {
    private let target = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testEdgeDistanceIsInLogicalPoints() {
        let off = { (pixels: CGFloat) in CGRect(x: 100 + pixels, y: 100, width: 400 - pixels, height: 300) }
        XCTAssertTrue(Acceptance.accepts(off(8), target, scale: 1))
        XCTAssertFalse(Acceptance.accepts(off(9), target, scale: 1))
        XCTAssertTrue(Acceptance.accepts(off(16), target, scale: 2))
        XCTAssertFalse(Acceptance.accepts(off(17), target, scale: 2))
        XCTAssertTrue(Acceptance.accepts(off(24), target, scale: 3))
    }

    func testCorrectionsUseTheHoverKeys() {
        let inner = Candidate(id: "inner", label: "inner", bounds: CGRect(x: 120, y: 120, width: 100, height: 60), score: 1, kind: .element)
        let outer = Candidate(id: "outer", label: "outer", bounds: target, score: 1, kind: .element)
        let side = Candidate(id: "side", label: "side", bounds: CGRect(x: 300, y: 120, width: 100, height: 60), score: 1, kind: .element)
        let session = SelectionSession(candidates: [inner, outer, side], extent: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       anchor: CGPoint(x: 150, y: 140))
        XCTAssertEqual(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, inner.bounds, scale: 1) }, 0)
        XCTAssertEqual(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, outer.bounds, scale: 1) }, 1)
        XCTAssertEqual(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, side.bounds, scale: 1) }, 1)
        XCTAssertNil(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, CGRect(x: 10, y: 10, width: 30, height: 30), scale: 1) })
    }
}
