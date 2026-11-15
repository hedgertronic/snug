import CoreGraphics
import ScreenshotBench
import ScreenshotCore
import Testing

/// Checks edge tolerances and keyboard corrections for benchmark acceptance.
struct AcceptanceTests {
    /// The accepted rectangle in source-image pixels.
    private let target = CGRect(x: 100, y: 100, width: 400, height: 300)

    /// Edge tolerance scales from logical points to source-image pixels.
    @Test func edgeDistanceIsInLogicalPoints() {
        let off = { (pixels: CGFloat) in CGRect(x: 100 + pixels, y: 100, width: 400 - pixels, height: 300) }
        #expect(Acceptance.accepts(off(8), target, scale: 1))
        #expect(!Acceptance.accepts(off(9), target, scale: 1))
        #expect(Acceptance.accepts(off(16), target, scale: 2))
        #expect(!Acceptance.accepts(off(17), target, scale: 2))
        #expect(Acceptance.accepts(off(24), target, scale: 3))
    }

    /// Hover keys reach the selected rectangle, its parent, and its peer within the correction limit.
    @Test func correctionsUseTheHoverKeys() {
        let inner = Candidate(id: "inner", label: "inner", bounds: CGRect(x: 120, y: 120, width: 100, height: 60), score: 1, kind: .element)
        let outer = Candidate(id: "outer", label: "outer", bounds: target, score: 1, kind: .element)
        let side = Candidate(id: "side", label: "side", bounds: CGRect(x: 300, y: 120, width: 100, height: 60), score: 1, kind: .element)
        let session = SelectionSession(candidates: [inner, outer, side], extent: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       anchor: CGPoint(x: 150, y: 140))
        #expect(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, inner.bounds, scale: 1) } == 0)
        #expect(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, outer.bounds, scale: 1) } == 1)
        #expect(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, side.bounds, scale: 1) } == 1)
        #expect(Acceptance.corrections(from: session, candidateList: false) { Acceptance.accepts($0, CGRect(x: 10, y: 10, width: 30, height: 30), scale: 1) } == nil)
    }
}
