import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

struct FlatFillsTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func load(_ path: String) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The Notion pill pasted at (1000, 800) on a display-sized canvas of its background color, as the 1x downsample hover reads.
    private func pillScreen() throws -> CGImage {
        let pill = try load("notes/fixtures/round11/notion-pill.png")
        let context = CGContext(data: nil, width: 3024, height: 1964, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3024, height: 1964))
        context.draw(pill, in: CGRect(x: 1000, y: 1964 - 800 - pill.height, width: pill.width, height: pill.height))
        return Detection.downsampled(context.makeImage()!, by: 2)
    }

    @Test func aPillOnItsBackgroundIsFoundFromTheFillOrTheLabel() throws {
        let fills = FlatFills(try pillScreen())
        // The pill spans about x 15...178, y 17...55 of the fixture: on the 1x screen (500, 400) plus half of that.
        let expected = CGRect(x: 507, y: 408, width: 82, height: 19)
        for point in [CGPoint(x: 512, y: 417), CGPoint(x: 545, y: 417), CGPoint(x: 580, y: 412)] {
            let found = try #require(fills.region(at: point), "no fill at \(point)")
            #expect(found.bounds.isNear(expected, within: 4), "\(found.bounds) at \(point)")
        }
    }

    @Test func theBackgroundAroundThePillIsNotAFill() throws {
        let fills = FlatFills(try pillScreen())
        #expect(fills.region(at: CGPoint(x: 300, y: 300)) == nil)
        #expect(fills.region(at: CGPoint(x: 540, y: 440)) == nil)
    }

    @Test func aFillOutsideTheSizeRangeIsNotFound() throws {
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 300, width: 8, height: 8))       // too small
        context.fill(CGRect(x: 50, y: 100, width: 450, height: 200))   // too wide
        let fills = FlatFills(context.makeImage()!)
        #expect(fills.region(at: CGPoint(x: 24, y: 96)) == nil)
        #expect(fills.region(at: CGPoint(x: 250, y: 200)) == nil)
    }

    @Test func formTestAddsFewFills() async throws {
        let screen = Detection.downsampled(try load("notes/real-web/form-test.png"), by: 2)
        let fills = FlatFills(screen)
        var found: [Candidate] = []
        for y in stride(from: 0, to: screen.height, by: 24) {
            for x in stride(from: 0, to: screen.width, by: 24) {
                if let fill = fills.region(at: CGPoint(x: x, y: y)) { found.append(fill) }
            }
        }
        let extent = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        let geometry = try await GeometryDetector().detect(in: screen)
        let before = Detection.normalized(geometry, within: extent).count, after = Detection.normalized(geometry + found, within: extent).count
        print("flat-fills form-test geometry candidates before=\(before) after=\(after)")
        #expect(after - before <= 20, "added \(after - before): the inputs, cart rows, badge and buttons")
    }
}
