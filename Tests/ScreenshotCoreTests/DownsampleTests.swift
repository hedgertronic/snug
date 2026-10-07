import CoreGraphics
import Testing
@testable import ScreenshotCore

struct DownsampleTests {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 60, width: 200, height: 100))
        return context.makeImage()!
    }

    @Test func shrinksByTheFactorAndLeavesFactorOneAlone() {
        let source = image(width: 400, height: 300)
        let half = Detection.downsampled(source, by: 2)
        #expect(half.width == 200 && half.height == 150)
        #expect(Detection.downsampled(source, by: 1) === source)
    }

    @Test func scalingACandidateMapsBoundsAndHitRegions() {
        let candidate = Candidate(id: "a", label: "Text block", bounds: CGRect(x: 10, y: 20, width: 30, height: 40), score: 0.7,
                                  kind: .text, hitRegions: [CGRect(x: 10, y: 20, width: 30, height: 10)])
        let scaled = candidate.scaled(by: 2)
        #expect(scaled.bounds == CGRect(x: 20, y: 40, width: 60, height: 80))
        #expect(scaled.hitRegions == [CGRect(x: 20, y: 40, width: 60, height: 20)])
        #expect(scaled.id == "a" && scaled.label == "Text block" && scaled.score == 0.7 && scaled.kind == .text)
    }

    @Test func geometryOnTheHalfSizeCopyMapsBackToFullResolution() async throws {
        let source = image(width: 1200, height: 800)
        let full = try await GeometryDetector().detect(in: source)
        let half = try await GeometryDetector().detect(in: Detection.downsampled(source, by: 2)).map { $0.scaled(by: 2) }
        let target = CGRect(x: 40, y: 800 - 160, width: 200, height: 100)
        #expect(half.contains { Detection.overlap($0.bounds, target) > 0.9 } == full.contains { Detection.overlap($0.bounds, target) > 0.9 })
    }
}
