import CoreGraphics
import Testing
@testable import ScreenshotCore

struct SnapFitsTests {
    let drag = CGRect(x: 100, y: 100, width: 300, height: 200)

    @Test func accessibilityFitsComeFirstAndPixelDuplicatesDrop() {
        let ax = CGRect(x: 96, y: 104, width: 310, height: 190)
        let pixel = [CGRect(x: 97, y: 104, width: 309, height: 190), CGRect(x: 90, y: 92, width: 320, height: 215)]
        let merged = SnapFits.merge(frames: [ax], pixel: pixel, drag: drag, scale: 1)
        #expect(merged == [ax, pixel[1]])
    }

    @Test func aPixelFitNearerTheDragThanAFrameGoesFirst() {
        // The logo fixture shown in an image view: the view's frame is the image's bounds, 28 px outside the drag on every side; the
        // rounded square drawn in it is 12 px inside.
        let image = CGRect(x: 0, y: 0, width: 400, height: 400), square = CGRect(x: 40, y: 40, width: 320, height: 320)
        let drag = CGRect(x: 28, y: 28, width: 344, height: 344)
        #expect(SnapFits.merge(frames: [image], pixel: [square, image], drag: drag, scale: 1) == [square, image])
        // A drag nearer the image's bounds keeps the frame first.
        let hugging = CGRect(x: 10, y: 10, width: 380, height: 380)
        #expect(SnapFits.merge(frames: [image], pixel: [square], drag: hugging, scale: 1) == [image, square])
    }

    @Test func framesWithAnySideOutsideTheBandAreIgnored() {
        let nearOnThreeSides = CGRect(x: 100, y: 100, width: 300, height: 260)
        let tooSmall = CGRect(x: 100, y: 100, width: 40, height: 40)
        let pixel = [CGRect(x: 98, y: 98, width: 304, height: 204)]
        #expect(SnapFits.merge(frames: [nearOnThreeSides, tooSmall], pixel: pixel, drag: drag, scale: 1) == pixel)
    }

    @Test func closestFramesRankFirstAndRepeatsCollapse() {
        let exact = CGRect(x: 100, y: 100, width: 300, height: 200)
        let off = CGRect(x: 90, y: 90, width: 320, height: 220)
        let merged = SnapFits.merge(frames: [off, exact, exact], pixel: [], drag: drag, scale: 1)
        #expect(merged == [exact, off])
    }

    @Test func bandFloorIsEightPointsAtTheCaptureScale() {
        #expect(SmartSnap.band(side: 22, scale: 1) == 8)
        #expect(SmartSnap.band(side: 22, scale: 2) == 16)
        #expect(SmartSnap.band(side: 400, scale: 1) == 48)
        #expect(SmartSnap.band(side: 2000, scale: 1) == 56)
        let drag = CGRect(x: 0, y: 0, width: 200, height: 22)
        #expect(AreaSelection.preview(drag.insetBy(dx: -6, dy: -7), stillFits: drag, scale: 1))
        #expect(!AreaSelection.preview(drag.insetBy(dx: -6, dy: -7), stillFits: drag.offsetBy(dx: 0, dy: 9), scale: 1))
    }

    @Test func nearestEdgeWithinBandPrefersFramesOnATie() {
        let frames = [CGRect(x: 10, y: 0, width: 190, height: 50)]
        #expect(SnapFits.edge(near: 205, band: 12, frames: frames, pixel: [210, 230], vertical: true) == 200)
        #expect(SnapFits.edge(near: 205, band: 12, frames: frames, pixel: [207], vertical: true) == 207)
        #expect(SnapFits.edge(near: 205, band: 12, frames: [], pixel: [230], vertical: true) == nil)
        #expect(SnapFits.edge(near: 52, band: 12, frames: frames, pixel: [], vertical: false) == 50)
        #expect(SnapFits.edge(near: 200, band: 12, frames: frames, pixel: [198], vertical: true) == 200)
    }
}
