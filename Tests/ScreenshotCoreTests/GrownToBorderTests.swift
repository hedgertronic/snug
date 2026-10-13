import CoreGraphics
import Testing
@testable import ScreenshotCore

struct GrownToBorderTests {
    private let border = CGRect(x: 60, y: 50, width: 240, height: 100)

    /// A dark (26,29,33) canvas, with a 1 px (46,46,48) border of radius 16 around `border` when `ring` is set.
    private func canvas(ring: Bool) -> CGImage {
        let context = CGContext(data: nil, width: 360, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 26 / 255, green: 29 / 255, blue: 33 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 360, height: 200))
        if ring {
            context.setStrokeColor(CGColor(red: 46 / 255, green: 46 / 255, blue: 48 / 255, alpha: 1))
            context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: border.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 15.5, cornerHeight: 15.5, transform: nil))
            context.strokePath()
        }
        return context.makeImage()!
    }

    @Test func aRectOneOrTwoPxInsideABorderGrowsToItsOuterEdge() {
        let image = canvas(ring: true)
        for inset in [1.0, 2.0] {
            let inner = Candidate(id: "box", label: "Box", bounds: border.insetBy(dx: inset, dy: inset), score: 1, kind: .element)
            let grown = inner.grownToBorder(in: image)
            #expect(grown.bounds == border, "inset \(inset): \(grown.bounds)")
            #expect(abs(cornerRadius(in: image, rect: grown.bounds) - 16) <= 2, "inset \(inset): radius \(cornerRadius(in: image, rect: grown.bounds))")
        }
    }

    @Test func aRectWithoutABorderOrAlreadyOnItStaysAsItIs() {
        let plain = Candidate(id: "box", label: "Box", bounds: border.insetBy(dx: 2, dy: 2), score: 1, kind: .element)
        #expect(plain.grownToBorder(in: canvas(ring: false)) == plain)
        let onBorder = Candidate(id: "box", label: "Box", bounds: border, score: 1, kind: .element)
        #expect(onBorder.grownToBorder(in: canvas(ring: true)) == onBorder)
    }
}
