import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

struct CornerRadiusTests {
    private let shapeRect = CGRect(x: 20, y: 20, width: 140, height: 120)
    private let dimensions = (180, 160)

    private func image(radius: CGFloat, background: Int, rim: CGFloat = 0) -> CGImage {
        let width = dimensions.0, height = dimensions.1, bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state: UInt32 = 0x12345678
        for pixel in 0..<(width * height) {
            let index = pixel * 4
            if background == 1 {
                state = state &* 1664525 &+ 1013904223
                bytes[index] = UInt8(40 + (state >> 24) % 176)
                state = state &* 1664525 &+ 1013904223
                bytes[index + 1] = UInt8(40 + (state >> 24) % 176)
                state = state &* 1664525 &+ 1013904223
                bytes[index + 2] = UInt8(40 + (state >> 24) % 176)
            } else if background == 3 {
                bytes[index] = UInt8(60 + (pixel % width) * 120 / width)
                bytes[index + 1] = UInt8(90 + (pixel / width) * 100 / height)
                bytes[index + 2] = 140
            } else if background == 4 {
                state = state &* 1664525 &+ 1013904223
                let level = UInt8(48 + (state >> 24) % 5)
                bytes[index] = level
                bytes[index + 1] = level
                bytes[index + 2] = level + 12
            } else if background == 5 {
                let block = UInt32(pixel % width / 7 * 31 + pixel / width / 7 * 17)
                let level = UInt8(truncatingIfNeeded: (block &* 2654435761) >> 24)
                bytes[index] = level
                bytes[index + 1] = level &+ 90
                bytes[index + 2] = level &* 3
            } else if background == 2 {
                bytes[index] = 245
                bytes[index + 1] = 244
                bytes[index + 2] = 242
            } else {
                bytes[index] = 250
                bytes[index + 1] = 250
                bytes[index + 2] = 250
            }
            bytes[index + 3] = 255
        }
        let result = bytes.withUnsafeMutableBytes { storage -> CGImage? in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.setShouldAntialias(true)
            let path = radius == 0
                ? CGPath(rect: shapeRect, transform: nil)
                : CGPath(roundedRect: shapeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(CGColor(red: 220 / 255, green: 220 / 255, blue: 220 / 255, alpha: 1))
            if rim > 0 { context.setFillColor(CGColor(red: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1)) }
            context.fillPath()
            if rim > 0 {
                context.addPath(radius == 0
                    ? CGPath(rect: shapeRect.insetBy(dx: rim / 2, dy: rim / 2), transform: nil)
                    : CGPath(roundedRect: shapeRect.insetBy(dx: rim / 2, dy: rim / 2), cornerWidth: radius - rim / 2, cornerHeight: radius - rim / 2, transform: nil))
                context.setStrokeColor(CGColor(red: 200 / 255, green: 200 / 255, blue: 205 / 255, alpha: 1))
                context.setLineWidth(rim)
                context.strokePath()
            }
            return context.makeImage()
        }
        return result!
    }

    @Test func estimatesSyntheticCornerRadiiAcrossBackgrounds() {
        let backgrounds = [("flat", 0), ("close", 2), ("gradient", 3)]
        for (name, background) in backgrounds {
            for radius: CGFloat in [0, 8, 20, 40, 60] {
                let estimate = cornerRadius(in: image(radius: radius, background: background), rect: shapeRect)
                print("corner-radius case=\(name) true=\(Int(radius)) estimated=\(estimate)")
                if radius == 0 {
                    #expect(estimate == 0)
                } else {
                    #expect(abs(estimate - radius) <= max(2, radius * 0.05))
                }
            }
        }
    }

    @Test func rejectsRectangleOverNonuniformBackground() {
        #expect(cornerRadius(in: image(radius: 0, background: 1), rect: shapeRect) == 0)
    }

    @Test func estimatesRimmedShapeOverDarkAndGradientBackgrounds() {
        for (name, background) in [("dark noise", 4), ("gradient", 3)] {
            for radius: CGFloat in [12, 24, 50] {
                let estimate = cornerRadius(in: image(radius: radius, background: background, rim: 1), rect: shapeRect)
                print("corner-radius case=rim \(name) true=\(Int(radius)) estimated=\(estimate)")
                #expect(abs(estimate - radius) <= max(2, radius * 0.1))
            }
        }
    }

    @Test func rejectsRectangleOverBusyBackground() {
        #expect(cornerRadius(in: image(radius: 0, background: 5), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 5, rim: 1), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 4, rim: 1), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 4, rim: 2), rect: shapeRect) == 0)
        #expect(cornerRadius(in: image(radius: 0, background: 0, rim: 2), rect: shapeRect) == 0)
    }
    @Test func estimatesRadiusOfShapeWithSoftShadow() {
        let shapeRect = CGRect(x: 40, y: 40, width: 200, height: 160)
        for radius: CGFloat in [12, 20, 30] {
            let context = CGContext(data: nil, width: 280, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.26, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 280, height: 240))
            context.setShadow(offset: .zero, blur: 16, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
            context.addPath(CGPath(roundedRect: shapeRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillPath()
            let estimate = cornerRadius(in: context.makeImage()!, rect: shapeRect)
            #expect(abs(estimate - radius) <= max(2, radius * 0.1), "radius \(radius) estimated \(estimate)")
        }
    }

    @Test func noCornerFollowsAnArcOverBusyOrSquareContent() {
        for (background, rim): (Int, CGFloat) in [(1, 0), (5, 0), (5, 1), (4, 1), (4, 2), (0, 2), (0, 0)] {
            #expect(cornerArcs(in: image(radius: 0, background: background, rim: rim), rect: shapeRect) == .zero, "background \(background) rim \(rim)")
        }
    }

    @Test func aTableGridCornerFollowsNoArc() throws {
        // A Wikipedia table's cells at a grid corner: the first edges along the rays fit a 195 px circle to within 19 px, a tenth of it.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("notes/real-web/wiki-test.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cornerArcs(in: image, rect: CGRect(x: 990, y: 590, width: 908, height: 1010)) == .zero)
    }

    @Test func aCropCornerOnSlacksContentPanelFollowsThePanelsArc() throws {
        // The user's Slack composer crop: its bottom-right corner sits on the corner of Slack's dark content panel, whose arc shows the
        // teal of Slack's frame past it. The other three corners are on plain panel or the composer's border.
        let url = try #require(Bundle.module.url(forResource: "SlackComposerRow", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let arcs = cornerArcs(in: image, rect: CGRect(x: 0, y: 0, width: 1680, height: 284))
        #expect(arcs.topLeft == 0 && arcs.topRight == 0 && arcs.bottomLeft == 0, "\(arcs)")
        #expect(abs(arcs.bottomRight - 20) <= 3, "\(arcs)")
    }

    @Test func finderToolbarCapsuleInItsAccessibilityFrame() throws {
        // The fixture is the crop of the view-mode capsule's AXRadioGroup frame (162 x 38 pt at 2x). The glass capsule is drawn 1 px inside
        // it horizontally and 2 px vertically, 322 x 72 px with a 36 px radius; on the frame, the concentric circle has the frame's half height.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("notes/fixtures/round13/finder-toolbar-capsules.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cornerArcs(in: image, rect: CGRect(x: 0, y: 0, width: 324, height: 76)) == CornerRadii(38))
        // The capsule's own rectangle and the selected segment's pill keep their tight fits.
        #expect(cornerArcs(in: image, rect: CGRect(x: 1, y: 2, width: 322, height: 72)) == CornerRadii(36))
        #expect(abs(cornerRadius(in: image, rect: CGRect(x: 168, y: 12, width: 70, height: 52)) - 24) <= 1)
    }

    @Test func measuresTheLogosRoundedSquare() throws {
        // The rounded square that a snap finds in the user's logo fixture (see SmartSnapTests).
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("notes/fixtures/round9/logo-inner-squircle-snap.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let radius = cornerRadius(in: image, rect: CGRect(x: 40, y: 40, width: 320, height: 320))
        // Its corners are Apple's continuous curve; the circle that fits them spans the same 80 px of each side.
        #expect(abs(radius - 79) <= 3, "measured \(radius)")
    }

    @Test func aWindowRadiusFollowsWhereTheWindowColorStarts() {
        // A dark window with a 28 px radius and a darker 1 px rim on a near-black desktop: the fit lands on the window's color,
        // inside the rim, where the ray measurement finds the rim's outer edge.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = CGRect(x: 40, y: 30, width: 320, height: 240)
        context.addPath(CGPath(roundedRect: window, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        context.fillPath()
        context.addPath(CGPath(roundedRect: window.insetBy(dx: 1, dy: 1), cornerWidth: 27, cornerHeight: 27, transform: nil))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fillPath()
        let radius = windowCornerRadius(in: context.makeImage()!, rect: window)
        #expect(abs(radius - 28) <= 1.5, "fitted \(radius)")
    }
}
