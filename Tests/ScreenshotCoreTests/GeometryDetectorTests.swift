import CoreGraphics
import ImageIO
import XCTest
@testable import ScreenshotCore

final class GeometryDetectorTests: XCTestCase {
    func testFindsNestedCardAndTableInSourceCoordinates() async throws {
        let image = makeDashboard(width: 400, height: 300, scale: 1)
        let candidates = try await GeometryDetector().detect(in: image)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThanOrEqual(candidates.count, 450)
        XCTAssertTrue(candidates.contains { candidate in
            candidate.kind == .region && near(candidate.bounds, CGRect(x: 40, y: 30, width: 320, height: 220), tolerance: 6)
        })
        XCTAssertTrue(candidates.contains { candidate in
            candidate.kind == .table && near(candidate.bounds, CGRect(x: 70, y: 90, width: 250, height: 120), tolerance: 8)
        })
        let highestScoringTable = candidates.filter { $0.kind == .table }.max { $0.score < $1.score }
        XCTAssertNotNil(highestScoringTable)
        XCTAssertTrue(near(highestScoringTable!.bounds, CGRect(x: 70, y: 90, width: 250, height: 120), tolerance: 8))

        let repeated = try await GeometryDetector().detect(in: image)
        XCTAssertEqual(candidates, repeated)
    }

    func testFindsTheCellsOfAOneRowStrip() async throws {
        // A board rank: 8 alternating green squares in one row on a dark page, too short for the whole-image column profile.
        let context = CGContext(data: nil, width: 1000, height: 680, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 680))
        for index in 0..<8 {
            let light = index % 2 == 0
            context.setFillColor(CGColor(red: light ? 0.47 : 0.33, green: light ? 0.6 : 0.5, blue: light ? 0.4 : 0.34, alpha: 1))
            context.fill(CGRect(x: 520 + index * 47, y: 680 - 84, width: 47, height: 33))
        }
        let candidates = try await GeometryDetector().detect(in: context.makeImage()!)
        let cells = candidates.filter { $0.kind == .cell && near($0.bounds, CGRect(x: $0.bounds.minX, y: 51, width: 47, height: 33), tolerance: 3) }
        XCTAssertEqual(cells.count, 8, "\(candidates.map(\.bounds))")
        XCTAssertTrue(candidates.contains { near($0.bounds, CGRect(x: 520, y: 51, width: 376, height: 33), tolerance: 3) })
    }

    func testARegularGridKeepsOnlyItsCellsRowsAndWhole() async throws {
        // An 8x8 board of 60 px squares on a dark page: no subrectangle of squares survives, and Up walks square, rank, board.
        let context = CGContext(data: nil, width: 1000, height: 680, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 680))
        for row in 0..<8 {
            for column in 0..<8 {
                let light = (row + column) % 2 == 0
                context.setFillColor(CGColor(red: light ? 0.47 : 0.33, green: light ? 0.6 : 0.5, blue: light ? 0.4 : 0.34, alpha: 1))
                context.fill(CGRect(x: 480 + column * 60, y: 100 + row * 60, width: 60, height: 60))
            }
        }
        let board = CGRect(x: 480, y: 100, width: 480, height: 480)
        let candidates = try await GeometryDetector().detect(in: context.makeImage()!)
        XCTAssertTrue(candidates.contains { near($0.bounds, board, tolerance: 3) }, "\(candidates.map(\.bounds))")
        XCTAssertEqual(candidates.filter { $0.label == GeometryDetector.gridCellLabel }.count, 64)
        let inside = candidates.filter { $0.kind != .cell && board.insetBy(dx: -3, dy: -3).contains($0.bounds) && !near($0.bounds, board, tolerance: 3) }
        XCTAssertTrue(inside.allSatisfy { abs($0.bounds.width - 480) <= 3 && abs($0.bounds.height - 60) <= 3 }, "\(inside.map(\.bounds))")

        let page = Candidate(id: "ax-page", label: "Group", bounds: CGRect(x: 0, y: 0, width: 1000, height: 680), score: 2, kind: .element)
        var session = SelectionSession(candidates: candidates + [page], extent: CGRect(x: 0, y: 0, width: 1000, height: 680), anchor: CGPoint(x: 630, y: 250))
        XCTAssertTrue(near(session.selected!.bounds, CGRect(x: 600, y: 220, width: 60, height: 60), tolerance: 3), "\(session.selected!)")
        session.expand()
        XCTAssertTrue(near(session.selected!.bounds, CGRect(x: 480, y: 220, width: 480, height: 60), tolerance: 3), "\(session.selected!)")
        session.expand()
        XCTAssertTrue(near(session.selected!.bounds, board, tolerance: 3), "\(session.selected!)")
    }

    func testMapsDownscaledAnalysisBackToOriginalPixels() async throws {
        let image = makeDashboard(width: 1600, height: 1200, scale: 4)
        let candidates = try await GeometryDetector().detect(in: image)
        XCTAssertTrue(candidates.contains { candidate in
            candidate.kind == .region && near(candidate.bounds, CGRect(x: 160, y: 120, width: 1280, height: 880), tolerance: 28)
        })
    }

    func testFullSidebarIsReachableFromHoverAndKeyboard() async throws {
        for rightSide in [false, true] {
            for top in [0, 24] {
                let expected = CGRect(x: rightSide ? 320 : 0, y: top, width: 80, height: 300 - top)
                let image = makeDashboard(width: 400, height: 300, scale: 1, sidebar: expected)
                let candidates = try await GeometryDetector().detect(in: image)
                XCTAssertTrue(candidates.contains { near($0.bounds, expected, tolerance: 3) })
                var session = SelectionSession(candidates: candidates,
                    extent: CGRect(x: 0, y: 0, width: 400, height: 300),
                    anchor: CGPoint(x: expected.midX, y: 150))
                var reachable = false
                for _ in 0..<8 {
                    if let selected = session.selected, near(selected.bounds, expected, tolerance: 3) {
                        reachable = true
                    }
                    session.cycle()
                }
                XCTAssertTrue(reachable, "Full sidebar must be in the keyboard shortlist")
            }
        }
    }

    func testDemoSidebarSurvivesTableProposalLimit() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Sidebar", withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let candidates = try await GeometryDetector().detect(in: image)
        let spurious = CGRect(x: 220, y: 96, width: 942, height: 506)
        XCTAssertFalse(candidates.contains { near($0.bounds, spurious, tolerance: 5) })
        let tableExtent = CGRect(x: 277, y: 195, width: 890, height: 412)
        XCTAssertTrue(candidates.filter { $0.kind == .table }.allSatisfy { tableExtent.contains($0.bounds) })
        let cells = candidates.filter { $0.kind == .cell }
        XCTAssertEqual(cells.count, 32)
        XCTAssertTrue(cells.allSatisfy { abs($0.bounds.width - 220) <= 5 && abs($0.bounds.height - 50) <= 5 })
        let cell = try XCTUnwrap(candidates.first { $0.kind == .cell && $0.bounds.contains(CGPoint(x: 350, y: 275)) })
        XCTAssertTrue(near(cell.bounds, CGRect(x: 280, y: 250, width: 220, height: 50), tolerance: 5))
        let expected = CGRect(x: 0, y: 0, width: 220, height: 800)
        let session = SelectionSession(candidates: candidates,
            extent: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            anchor: CGPoint(x: 100, y: 400))
        XCTAssertTrue(near(try XCTUnwrap(session.selected).bounds, expected, tolerance: 2))
    }

    private func near(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat) -> Bool {
        abs(actual.minX - expected.minX) <= tolerance &&
            abs(actual.minY - expected.minY) <= tolerance &&
            abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
    }

    private func makeDashboard(width: Int, height: Int, scale: Int, sidebar: CGRect? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 246, count: width * height * 4)
        for pixel in 0..<(width * height) {
            bytes[pixel * 4 + 3] = 255
        }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ value: UInt8) {
            for row in max(0, y)..<min(height, y + h) {
                for column in max(0, x)..<min(width, x + w) {
                    let offset = (row * width + column) * 4
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                    bytes[offset + 3] = 255
                }
            }
        }
        func border(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            let line = 2 * scale
            fill(x, y, w, line, 35)
            fill(x, y + h - line, w, line, 35)
            fill(x, y, line, h, 35)
            fill(x + w - line, y, line, h, 35)
        }

        let s = scale
        fill(40 * s, 30 * s, 320 * s, 220 * s, 255)
        border(40 * s, 30 * s, 320 * s, 220 * s)
        fill(70 * s, 90 * s, 250 * s, 120 * s, 252)
        border(70 * s, 90 * s, 250 * s, 120 * s)
        for column in [150, 235] {
            fill(column * s, 91 * s, 2 * s, 118 * s, 45)
        }
        for row in [130, 170] {
            fill(71 * s, row * s, 248 * s, 2 * s, 45)
        }

        if let sidebar {
            fill(Int(sidebar.minX), Int(sidebar.minY), Int(sidebar.width), Int(sidebar.height), 226)
            for row in [70, 110, 150, 190] {
                fill(Int(sidebar.minX) + 12, row, 48, 6, 80)
            }
        }

        let data = Data(bytes)
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
}
