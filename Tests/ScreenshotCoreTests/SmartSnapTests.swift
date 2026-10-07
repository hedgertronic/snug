import CoreGraphics
import Foundation
import XCTest
@testable import ScreenshotCore

final class SmartSnapTests: XCTestCase {
    func testOffCenterDragPreservesVerticalBoundaryCoordinates() async throws {
        let target = CGRect(x: 80, y: 100, width: 240, height: 180)
        let image = makeCanvas(width: 420, height: 480) { canvas in
            canvas.border(target, color: 140, thickness: 2)
        }
        for verticalOffset in [-8.0, 8.0] {
            let rough = target.insetBy(dx: -8, dy: -12).offsetBy(dx: 0, dy: verticalOffset)
            let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)
            let actual = try XCTUnwrap(suggestions.first).bounds
            XCTAssertTrue(near(actual, target, tolerance: 4), "Off-center drag returned \(actual)")
        }
    }

    func testSnapsNearFaintEmptyInput() async throws {
        let target = CGRect(x: 80, y: 70, width: 160, height: 34)
        let image = makeCanvas(width: 320, height: 220) { canvas in
            canvas.border(target, color: 226, thickness: 1)
        }
        let rough = CGRect(x: 74, y: 66, width: 172, height: 42)

        let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)

        let suggestion = try XCTUnwrap(suggestions.first { near($0.bounds, target, tolerance: 5) })
        XCTAssertTrue(near(try XCTUnwrap(suggestions.first).bounds, target, tolerance: 5),
                      "The best-ranked suggestion should be the nearby input")
        XCTAssertGreaterThanOrEqual(suggestion.confidence, 0)
        XCTAssertLessThanOrEqual(suggestion.confidence, 1)
        XCTAssertFalse(suggestion.reason.isEmpty)
        XCTAssertNoNearDuplicates(suggestions)
    }

    func testSnapsWholeCardIncludingImageAndCaption() async throws {
        let target = CGRect(x: 70, y: 40, width: 180, height: 180)
        let image = makeCanvas(width: 320, height: 280) { canvas in
            canvas.fill(CGRect(x: 71, y: 41, width: 178, height: 178), color: 250)
            canvas.border(target, color: 222, thickness: 1)

            canvas.fill(CGRect(x: 82, y: 52, width: 156, height: 96), color: 170)
            for offset in stride(from: 0, to: 156, by: 13) {
                canvas.fill(CGRect(x: 82 + offset, y: 52, width: 2, height: 96), color: UInt8(145 + offset % 45))
            }
            canvas.fill(CGRect(x: 84, y: 160, width: 104, height: 7), color: 80)
            canvas.fill(CGRect(x: 84, y: 174, width: 142, height: 4), color: 150)
            canvas.border(CGRect(x: 84, y: 188, width: 50, height: 20), color: 95, thickness: 1)
            canvas.border(CGRect(x: 144, y: 188, width: 82, height: 20), color: 95, thickness: 1)
        }
        let rough = CGRect(x: 76, y: 46, width: 168, height: 168)

        let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)

        XCTAssertTrue(near(try XCTUnwrap(suggestions.first).bounds, target, tolerance: 8),
                      "The best-ranked suggestion should enclose the card's image, caption, and controls; got \(suggestions.map(\.bounds))")
        XCTAssertNoNearDuplicates(suggestions)
    }

    func testUniformImageProducesNoSnap() async throws {
        let image = makeCanvas(width: 200, height: 160) { _ in }
        let suggestions = try await SmartSnap().suggest(
            in: image,
            roughBounds: CGRect(x: 35, y: 30, width: 120, height: 90)
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testOffImageAndTinyBoundsDoNotProduceOutOfImageCrops() async throws {
        let target = CGRect(x: 2, y: 46, width: 92, height: 54)
        let image = makeCanvas(width: 180, height: 140) { canvas in
            canvas.fill(CGRect(x: 0, y: 0, width: 180, height: 140), color: 250)
            canvas.fill(target, color: 238)
            canvas.border(target, color: 150, thickness: 2)
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let offImageSuggestions = try await SmartSnap().suggest(
            in: image,
            roughBounds: CGRect(x: -12, y: 42, width: 110, height: 62)
        )
        let tinySuggestions = try await SmartSnap().suggest(
            in: image,
            roughBounds: CGRect(x: 20, y: 20, width: 10, height: 10)
        )

        XCTAssertTrue(offImageSuggestions.allSatisfy { extent.contains($0.bounds) })
        XCTAssertTrue(tinySuggestions.isEmpty)
    }

    func testInvalidBoundsAndCancelledRequestAreRejected() async throws {
        let image = makeCanvas(width: 180, height: 140) { _ in }
        let snapper = SmartSnap()
        let invalidSuggestions = try await snapper.suggest(
            in: image,
            roughBounds: CGRect(x: CGFloat.infinity, y: 20, width: 70, height: 50)
        )
        XCTAssertTrue(invalidSuggestions.isEmpty)

        let task = Task {
            try await snapper.suggest(in: image, roughBounds: CGRect(x: 30, y: 30, width: 100, height: 70))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
        }
    }

    func testNearbyEdgesCannotMoveBeyondLocalSearchRange() async throws {
        let target = CGRect(x: 112, y: 86, width: 160, height: 72)
        let image = makeCanvas(width: 360, height: 240) { canvas in
            canvas.fill(CGRect(x: 0, y: 0, width: 360, height: 240), color: 250)
            canvas.fill(target, color: 228)
            canvas.border(target, color: 82, thickness: 2)
        }
        let rough = CGRect(x: 96, y: 80, width: 160, height: 72)
        let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)
        let maxXDisplacement = max(5, rough.width * 0.12) + 1
        let maxYDisplacement = max(5, rough.height * 0.12) + 1

        XCTAssertTrue(suggestions.allSatisfy { suggestion in
            abs(suggestion.bounds.minX - rough.minX) <= maxXDisplacement &&
                abs(suggestion.bounds.maxX - rough.maxX) <= maxXDisplacement &&
                abs(suggestion.bounds.minY - rough.minY) <= maxYDisplacement &&
                abs(suggestion.bounds.maxY - rough.maxY) <= maxYDisplacement
        })
    }

    func testRepeatedRequestReturnsSameSuggestions() async throws {
        let target = CGRect(x: 80, y: 70, width: 160, height: 34)
        let image = makeCanvas(width: 320, height: 220) { canvas in
            canvas.border(target, color: 226, thickness: 1)
        }
        let rough = CGRect(x: 74, y: 66, width: 172, height: 42)
        let snapper = SmartSnap()

        let first = try await snapper.suggest(in: image, roughBounds: rough)
        let second = try await snapper.suggest(in: image, roughBounds: rough)

        XCTAssertEqual(first.map(\.bounds), second.map(\.bounds))
        XCTAssertEqual(first.map(\.confidence), second.map(\.confidence))
        XCTAssertEqual(first.map(\.reason), second.map(\.reason))
    }

    func testTopTargetKeepsSourceCoordinatesWhenImageHasLowerDecoy() async throws {
        let target = CGRect(x: 80, y: 80, width: 160, height: 34)
        let image = makeCanvas(width: 320, height: 600) { canvas in
            canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 600), color: 250)
            canvas.fill(target, color: 232)
            canvas.border(target, color: 78, thickness: 2)
            let lowerDecoy = CGRect(x: 160, y: 460, width: 100, height: 90)
            canvas.fill(lowerDecoy, color: 214)
            canvas.border(lowerDecoy, color: 78, thickness: 2)
        }
        let rough = CGRect(x: 74, y: 76, width: 172, height: 42)

        let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)

        XCTAssertTrue(near(try XCTUnwrap(suggestions.first).bounds, target, tolerance: 5),
                      "A nearby target near the top of a tall image should retain source coordinates; got \(suggestions.map(\.bounds))")
        XCTAssertNoNearDuplicates(suggestions)
    }

    func testBandFloorSnapsSloppyDragAroundSmallPill() async throws {
        let pill = CGRect(x: 80, y: 100, width: 160, height: 22)
        let image = makeCanvas(width: 360, height: 240) { canvas in
            canvas.fill(pill, color: 255)
            canvas.border(pill, color: 150, thickness: 1)
        }
        let sloppy = pill.insetBy(dx: -7, dy: -7)

        let suggestions = try await SmartSnap().suggest(in: image, roughBounds: sloppy)
        XCTAssertTrue(near(try XCTUnwrap(suggestions.first).bounds, pill, tolerance: 2), "got \(suggestions.map(\.bounds))")

        let retina = try await SmartSnap().suggest(in: image, roughBounds: pill.insetBy(dx: -14, dy: -14), scale: 2)
        XCTAssertTrue(near(try XCTUnwrap(retina.first).bounds, pill, tolerance: 2), "got \(retina.map(\.bounds))")
        let tooFar = try await SmartSnap().suggest(in: image, roughBounds: pill.insetBy(dx: -14, dy: -14))
        XCTAssertTrue(tooFar.isEmpty, "a 14 px miss is outside the 8 px band at scale 1")
    }

    func testImageBorderIsASnapTarget() async throws {
        let strip = CGRect(x: 0, y: 60, width: 400, height: 40)
        let image = makeCanvas(width: 400, height: 200) { canvas in canvas.fill(strip, color: 200) }

        let full = try await SmartSnap().suggest(in: image, roughBounds: CGRect(x: 4, y: 3, width: 392, height: 194))
        XCTAssertEqual(try XCTUnwrap(full.first).bounds, CGRect(x: 0, y: 0, width: 400, height: 200))

        let toolbar = try await SmartSnap().suggest(in: image, roughBounds: CGRect(x: 5, y: 54, width: 390, height: 52))
        XCTAssertTrue(near(try XCTUnwrap(toolbar.first).bounds, strip, tolerance: 2), "got \(toolbar.map(\.bounds))")
    }

    func testEdgesFindsOneSideNearThePointer() throws {
        let card = CGRect(x: 100, y: 40, width: 120, height: 100)
        let image = makeCanvas(width: 400, height: 200) { canvas in
            canvas.fill(card, color: 255)
            canvas.border(card, color: 150, thickness: 2)
        }
        let selection = CGRect(x: 60, y: 30, width: 200, height: 120)

        let right = try SmartSnap().edges(in: image, of: selection, vertical: true, near: 226, band: 20)
        XCTAssertTrue(right.contains { abs($0 - card.maxX) <= 2 }, "got \(right)")
        let bottom = try SmartSnap().edges(in: image, of: selection, vertical: false, near: 134, band: 20)
        XCTAssertTrue(bottom.contains { abs($0 - card.maxY) <= 2 }, "got \(bottom)")
        XCTAssertTrue(try SmartSnap().edges(in: image, of: selection, vertical: true, near: 300, band: 20).isEmpty)
        let border = try SmartSnap().edges(in: image, of: selection, vertical: true, near: 394, band: 20)
        XCTAssertTrue(border.contains(400), "the image border is an edge within the band; got \(border)")
    }

    private func near(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat) -> Bool {
        abs(actual.minX - expected.minX) <= tolerance &&
            abs(actual.minY - expected.minY) <= tolerance &&
            abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
    }

    private func XCTAssertNoNearDuplicates(_ suggestions: [SnapSuggestion], file: StaticString = #filePath,
                                           line: UInt = #line) {
        for first in suggestions.indices {
            for second in suggestions.indices where second > first {
                XCTAssertLessThan(overlap(suggestions[first].bounds, suggestions[second].bounds), 0.98,
                                  "Suggestions should represent distinct crop choices", file: file, line: line)
            }
        }
    }

    private func overlap(_ first: CGRect, _ second: CGRect) -> Double {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height + second.width * second.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private func makeCanvas(width: Int, height: Int, draw: (Canvas) -> Void) -> CGImage {
        let canvas = Canvas(width: width, height: height)
        draw(canvas)
        let data = Data(canvas.bytes)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private final class Canvas {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            self.bytes = [UInt8](repeating: 250, count: width * height * 4)
            for pixel in 0..<(width * height) {
                bytes[pixel * 4 + 3] = 255
            }
        }

        func fill(_ rect: CGRect, color: UInt8) {
            let x0 = max(0, Int(rect.minX.rounded(.down)))
            let y0 = max(0, Int(rect.minY.rounded(.down)))
            let x1 = min(width, Int(rect.maxX.rounded(.up)))
            let y1 = min(height, Int(rect.maxY.rounded(.up)))
            guard x1 > x0, y1 > y0 else { return }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let offset = (y * width + x) * 4
                    bytes[offset] = color
                    bytes[offset + 1] = color
                    bytes[offset + 2] = color
                    bytes[offset + 3] = 255
                }
            }
        }

        func border(_ rect: CGRect, color: UInt8, thickness: Int) {
            let line = CGFloat(thickness)
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: line), color: color)
            fill(CGRect(x: rect.minX, y: rect.maxY - line, width: rect.width, height: line), color: color)
            fill(CGRect(x: rect.minX, y: rect.minY, width: line, height: rect.height), color: color)
            fill(CGRect(x: rect.maxX - line, y: rect.minY, width: line, height: rect.height), color: color)
        }
    }
}
