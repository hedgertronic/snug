import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

struct CornerRadiiTests {
    /// An opaque 200 x 160 screen of blue wallpaper with a white window of rounded corners at (20, 20, 160 x 120), top-left origin.
    private func screen(radius: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 20, y: 20, width: 160, height: 120), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return context.makeImage()!
    }

    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    @Test func uniformRadiiAreEqualAndOnlyZeroIsSquare() {
        #expect(CornerRadii(12) == CornerRadii(topLeft: 12, topRight: 12, bottomLeft: 12, bottomRight: 12))
        #expect(CornerRadii(0).isSquare && CornerRadii.zero.isSquare)
        #expect(!CornerRadii(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 1).isSquare)
    }

    @Test func offsetChangesEveryCornerAndClampsToHalfTheShortSide() {
        let radii = CornerRadii(topLeft: 0, topRight: 2, bottomLeft: 10, bottomRight: 30)
        #expect(radii.offset(by: 4, in: CGSize(width: 100, height: 40)) == CornerRadii(topLeft: 4, topRight: 6, bottomLeft: 14, bottomRight: 20))
        #expect(radii.offset(by: -4, in: CGSize(width: 100, height: 40)) == CornerRadii(topLeft: 0, topRight: 0, bottomLeft: 6, bottomRight: 20))
        #expect(radii.scaled(by: 0.5) == CornerRadii(topLeft: 0, topRight: 1, bottomLeft: 5, bottomRight: 15))
    }

    @Test func subscriptReadsAndWritesEachCorner() {
        var radii = CornerRadii(topLeft: 1, topRight: 2, bottomLeft: 3, bottomRight: 4)
        #expect(CornerRadii.corners.map { radii[$0] } == [1, 2, 3, 4])
        radii[.bottomLeft] = 9
        #expect(radii == CornerRadii(topLeft: 1, topRight: 2, bottomLeft: 9, bottomRight: 4))
    }

    @Test func dotSitsOnTheArcAtItsFortyFiveDegreePointAndNeverNearerThanTheInset() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let onArc = 40 * (1 - 1 / 2.0.squareRoot())
        let radii = CornerRadii(topLeft: 40, topRight: 40, bottomLeft: 40, bottomRight: 40)
        let topLeft = radii.dot(of: .topLeft, in: rect, minimumInset: 8)
        #expect(abs(topLeft.x - (100 + onArc)) < 1e-9 && abs(topLeft.y - (50 + onArc)) < 1e-9)
        let bottomRight = radii.dot(of: .bottomRight, in: rect, minimumInset: 8)
        #expect(abs(bottomRight.x - (300 - onArc)) < 1e-9 && abs(bottomRight.y - (150 - onArc)) < 1e-9)
        // Square: 8 along the diagonal is 8 / sqrt 2 on each axis. Small radii stay at the inset.
        let inset = 8 / 2.0.squareRoot()
        for radius in [0, 3] as [CGFloat] {
            let dot = CornerRadii(radius).dot(of: .topRight, in: rect, minimumInset: 8)
            #expect(abs(dot.x - (300 - inset)) < 1e-9 && abs(dot.y - (50 + inset)) < 1e-9)
        }
        // A radius past half the short side is drawn clamped, and so is its dot.
        let clamped = CornerRadii(90).dot(of: .topLeft, in: rect, minimumInset: 8)
        #expect(abs(clamped.x - (100 + 50 * (1 - 1 / 2.0.squareRoot()))) < 1e-9)
    }

    @Test func cornerHitTestPicksTheNearestDotWithinTolerance() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let radii = CornerRadii(topLeft: 0, topRight: 30, bottomLeft: 0, bottomRight: 0)
        let dot = radii.dot(of: .topRight, in: rect, minimumInset: 8)
        #expect(radii.corner(at: dot, in: rect, tolerance: 6, minimumInset: 8) == .topRight)
        #expect(radii.corner(at: CGPoint(x: dot.x + 5, y: dot.y), in: rect, tolerance: 6, minimumInset: 8) == .topRight)
        #expect(radii.corner(at: CGPoint(x: dot.x + 7, y: dot.y), in: rect, tolerance: 6, minimumInset: 8) == nil)
        // The corner itself is 8 pt along the diagonal from a square corner's dot: the resize handle keeps it.
        #expect(radii.corner(at: CGPoint(x: 0, y: 0), in: rect, tolerance: 6, minimumInset: 8) == nil)
    }

    @Test func inwardDistanceIsTheDragAlongTheDiagonalTowardTheCenter() {
        let step = CGPoint(x: 10, y: 10), root = 2.0.squareRoot()
        #expect(abs(CornerRadii.inwardDistance(of: step, from: .topLeft) - 10 * root) < 1e-9)
        #expect(abs(CornerRadii.inwardDistance(of: step, from: .bottomRight) + 10 * root) < 1e-9)
        #expect(abs(CornerRadii.inwardDistance(of: CGPoint(x: -10, y: 10), from: .topRight) - 10 * root) < 1e-9)
        #expect(CornerRadii.inwardDistance(of: CGPoint(x: 10, y: -10), from: .topLeft) == 0)
    }

    @Test func movingChangesAllCornersOrOneAndClamps() {
        let radii = CornerRadii(topLeft: 0, topRight: 10, bottomLeft: 4, bottomRight: 30)
        let size = CGSize(width: 100, height: 40)
        #expect(radii.moving(.topLeft, by: 6, alone: false, in: size) == CornerRadii(topLeft: 6, topRight: 16, bottomLeft: 10, bottomRight: 20))
        #expect(radii.moving(.bottomLeft, by: 6, alone: true, in: size) == CornerRadii(topLeft: 0, topRight: 10, bottomLeft: 10, bottomRight: 30))
        #expect(radii.moving(.topRight, by: 50, alone: true, in: size) == CornerRadii(topLeft: 0, topRight: 20, bottomLeft: 4, bottomRight: 30))
        #expect(radii.moving(.topLeft, by: -5, alone: true, in: size) == radii)
    }

    @Test func cornersWithinTwoPixelsOfTheWindowsCornersTakeItsRadius() {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120)
        let bottomHalf = CGRect(x: 20, y: 60, width: 160, height: 80)
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: bottomHalf, with: 16)
                == CornerRadii(topLeft: 3, topRight: 3, bottomLeft: 16, bottomRight: 16))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 22, y: 18, width: 158, height: 122), with: 16)
                == CornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 40, y: 40, width: 100, height: 60), with: 16) == CornerRadii(3))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 20, y: 20, width: 80, height: 60), with: 16)
                == CornerRadii(topLeft: 16, topRight: 3, bottomLeft: 3, bottomRight: 3))
    }

    @Test func unframedRenderRoundsOnlyTheBottomCornersOfACropOnAWindow() throws {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120), crop = CGRect(x: 20, y: 60, width: 160, height: 80)
        let radii = CornerRadii(0).replacingCorners(sharedWith: window, in: crop, with: 16)
        let plain = try OutputFrame.render(screen(radius: 16), crop: crop, scale: 1, framed: false)
        #expect(alpha(plain, 0, 79) == 255 && alpha(plain, 159, 79) == 255) // opaque wallpaper before rounding
        let rounded = try OutputFrame.render(screen(radius: 16), crop: crop, scale: 1, framed: false, cornerRadii: radii)
        #expect((rounded.width, rounded.height) == (160, 80))
        #expect(alpha(rounded, 0, 79) == 0 && alpha(rounded, 159, 79) == 0)
        #expect(alpha(rounded, 0, 0) == 255 && alpha(rounded, 159, 0) == 255 && alpha(rounded, 80, 40) == 255 && alpha(rounded, 80, 79) == 255)
        // A point inside the bottom arc stays opaque: 8 px in from the corner along the diagonal is within the 16 px circle.
        #expect(alpha(rounded, 8, 71) == 255 && alpha(rounded, 151, 71) == 255)
    }

    @Test func cornersInsideTheWindowsArcButOutsideItsShapeTakeTheArcLessTheirInset() {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120)
        // 10 px in on both sides of the bottom-right corner, where a 40 px arc still cuts in: 40 less the 8 px past the 2 px tolerance.
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 60, y: 60, width: 110, height: 70), with: 40)
                == CornerRadii(topLeft: 3, topRight: 3, bottomLeft: 3, bottomRight: 32))
        // 20 px in on both sides: the square corner is inside the arc, so nothing outside the window shows and the corner keeps its radius.
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 60, y: 60, width: 100, height: 60), with: 40) == CornerRadii(3))
        // A corner on the window's corner takes its radius however small, 0 included (a square window, or one still being measured).
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 20, y: 60, width: 160, height: 80), with: 0)
                == CornerRadii(topLeft: 3, topRight: 3, bottomLeft: 0, bottomRight: 0))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 22, y: 60, width: 156, height: 78), with: 5)
                == CornerRadii(topLeft: 3, topRight: 3, bottomLeft: 5, bottomRight: 5))
    }

    @Test func aCropCornerOnAPanelInsideTheWindowTakesThePanelsArc() throws {
        // The user's capture of the Slack composer's row (962, 1648, 1680 x 284 px, as logged), 10 px inside the bottom-right corner of the
        // Slack window (168, 88, 2484 x 1854), whose arc fits a 58.5 px circle. The crop's corner sits on the corner of Slack's dark content
        // panel; the teal past the panel's arc is Slack's own frame. The corner takes the panel's arc, not the window's arc less the inset.
        let url = try #require(Bundle.module.url(forResource: "SlackComposerRow", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = CGRect(x: 0, y: 0, width: 1680, height: 284), window = CGRect(x: 168 - 962, y: 88 - 1648, width: 2484, height: 1854)
        let arcs = cornerArcs(in: image, rect: crop)
        // Only one corner follows an arc, so the crop measures no radius of its own.
        #expect(arcs.agreed == 0)
        let radii = CornerRadii(0).replacingCorners(sharedWith: window, in: crop, with: 58, arcs: arcs)
        #expect(radii.topLeft == 0 && radii.topRight == 0 && radii.bottomLeft == 0 && abs(radii.bottomRight - 20) <= 3, "\(radii)")
        let rounded = try OutputFrame.render(image, crop: crop, scale: 2, framed: false, cornerRadii: radii)
        let pixels = image.dataProvider!.data! as Data
        // Clearly teal pixels are at least half cut; the arc's edge pixels blend teal and panel.
        var frame = 0
        for y in 200..<284 {
            for x in 1580..<1680 {
                let offset = y * image.bytesPerRow + x * 4
                guard Int(pixels[offset + 1]) - Int(pixels[offset]) > 24 else { continue }
                frame += 1
                #expect(alpha(rounded, x, y) < 128, "Slack's teal frame at \(x), \(y) stays in the capture: alpha \(alpha(rounded, x, y))")
            }
        }
        #expect(frame > 20)
        // 11 px in from the corner on both sides: inside the panel's arc, outside the 50 px arc the window's radius less the inset gave.
        #expect(alpha(rounded, 1668, 272) == 255)
        #expect(alpha(rounded, 0, 0) == 255 && alpha(rounded, 1679, 0) == 255 && alpha(rounded, 0, 283) == 255 && alpha(rounded, 1640, 250) == 255)
    }

    @Test func aCaptureOnTheWindowsCornerKeepsTheWindowsRadius() throws {
        // A synthetic capture of a whole dark window over a wallpaper, like a large Slack capture: every corner is the window's, already
        // cut by its 58 px arc.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/dark-window-corners.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let radii = CornerRadii(cornerRadius(in: image, rect: crop)).replacingCorners(sharedWith: crop, in: crop, with: 58, arcs: cornerArcs(in: image, rect: crop))
        #expect(radii == CornerRadii(58), "\(radii)")
    }

    @Test func eachCornerKeepsItsOwnRadius() throws {
        let radii = CornerRadii(topLeft: 0, topRight: 30, bottomLeft: 10, bottomRight: 0)
        let rounded = try OutputFrame.render(screen(radius: 0), crop: CGRect(x: 0, y: 0, width: 200, height: 160), scale: 1, framed: false, cornerRadii: radii)
        #expect(alpha(rounded, 0, 0) == 255 && alpha(rounded, 199, 159) == 255)
        #expect(alpha(rounded, 199, 0) == 0 && alpha(rounded, 0, 159) == 0)
        #expect(alpha(rounded, 190, 3) == 0 && alpha(rounded, 1, 150) == 255)
    }
}
