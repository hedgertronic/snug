import CoreGraphics
import Testing
@testable import ScreenshotCore

struct OutputFrameTests {
    let crop = CGRect(x: 100, y: 100, width: 200, height: 100)

    func image() -> CGImage {
        let context = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        return context.makeImage()!
    }

    @Test func aFrameAddsItsPaddingPerSide() {
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: nil) == crop)
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: 24) == CGRect(x: 52, y: 52, width: 296, height: 196))
        #expect(OutputFrame.rect(around: crop, scale: 2, padding: 16) == CGRect(x: 68, y: 68, width: 264, height: 164))
        #expect(OutputFrame.rect(around: crop, scale: 1, padding: 40) == CGRect(x: 60, y: 60, width: 280, height: 180))
    }

    @Test func renderedSizesMatchTheFrame() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, padding: nil)
        #expect((tight.width, tight.height) == (200, 100))
        for padding in [16.0, 24, 40] {
            let backdrop = try OutputFrame.render(source, crop: crop, scale: 2, padding: padding)
            #expect((backdrop.width, backdrop.height) == (200 + Int(4 * padding), 100 + Int(4 * padding)))
        }
    }

    @Test func unframedRadiusMasksCorners() throws {
        let source = image()
        let tight = try OutputFrame.render(source, crop: crop, scale: 2, padding: nil, cornerRadii: CornerRadii(24))
        var tightBytes = [UInt8](repeating: 0, count: tight.width * tight.height * 4)
        tightBytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: tight.width, height: tight.height,
                                    bitsPerComponent: 8, bytesPerRow: tight.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(tight, in: CGRect(x: 0, y: 0, width: tight.width, height: tight.height))
        }
        #expect(tightBytes[3] == 0)
        #expect(tightBytes[((tight.height / 2) * tight.width + tight.width / 2) * 4 + 3] == 255)
    }

    /// At each padding and scale the shadow falls just under the image, not above it, and fades out inside the canvas.
    @Test(arguments: [16.0, 24, 40], [1.0, 2])
    func aFrameIsTransparentPaddingWithASoftShadowBelow(padding: CGFloat, scale: CGFloat) throws {
        let backdrop = try OutputFrame.render(image(), crop: crop, scale: scale, padding: padding)
        var bytes = [UInt8](repeating: 0, count: backdrop.width * backdrop.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: backdrop.width, height: backdrop.height,
                                    bitsPerComponent: 8, bytesPerRow: backdrop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(backdrop, in: CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * backdrop.width + x) * 4 + 3] }
        let pad = Int(padding * scale)
        #expect(alpha(0, 0) == 0)
        #expect(alpha(backdrop.width - 1, 0) == 0)
        #expect(alpha(backdrop.width / 2, backdrop.height / 2) == 255)
        // Rows run top-left down: `pad` rows of padding below the image, with the shadow just under it and not above it.
        let below = alpha(backdrop.width / 2, backdrop.height - pad + pad / 8)
        #expect(below > 0 && below < 255)
        #expect(alpha(backdrop.width / 2, 0) == 0)
        // The shadow has faded out at the bottom row and the side columns, so the canvas does not clip it.
        #expect((0..<backdrop.width).allSatisfy { alpha($0, backdrop.height - 1) <= 2 })
        #expect((0..<backdrop.height).allSatisfy { alpha(0, $0) <= 2 && alpha(backdrop.width - 1, $0) <= 2 })
    }

    /// RGBA bytes of `image`, rows from the top.
    func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func shadow(blur: CGFloat, distance: CGFloat, angle: CGFloat, color: SRGBColor = SRGBColor(red: 0, green: 0, blue: 0)) -> OutputFrame.Shadow {
        OutputFrame.Shadow(opacity: 1, blur: blur, distance: distance, angle: angle, color: color)
    }

    /// The shadow falls toward its angle (0 right, 90 up, 180 left, 270 down): 6 px past the card on that side it is darker than 6 px
    /// past the opposite side, and the canvas grows on that side only.
    @Test(arguments: [(0.0, 1, 0), (90, 0, -1), (180, -1, 0), (270, 0, 1)])
    func aCustomShadowFallsTowardItsAngle(angle: CGFloat, dx: Int, dy: Int) throws {
        let custom = shadow(blur: 8, distance: 20, angle: angle)
        let output = try OutputFrame.render(image(), crop: crop, scale: 1, padding: 16, shadow: custom)
        let frame = OutputFrame.rect(around: crop, scale: 1, padding: 16, shadow: custom)
        #expect((output.width, output.height) == (Int(frame.width), Int(frame.height)))
        let bytes = pixels(output)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * output.width + x) * 4 + 3] }
        // The card's center and the point 6 px past its edge toward (dx, dy), rows running down.
        let card = crop.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let (centerX, centerY) = (Int(card.midX), Int(card.midY))
        let toward = (centerX + dx * (Int(card.width) / 2 + 6), centerY + dy * (Int(card.height) / 2 + 6))
        let away = (centerX - dx * (Int(card.width) / 2 + 6), centerY - dy * (Int(card.height) / 2 + 6))
        #expect(alpha(toward.0, toward.1) > 100 && alpha(away.0, away.1) < 10, "\(alpha(toward.0, toward.1)) toward, \(alpha(away.0, away.1)) away")
        let margins = custom.margins(padding: 16, scale: 1)
        let grown = [(1, 0, margins.right), (0, -1, margins.top), (-1, 0, margins.left), (0, 1, margins.bottom)]
        #expect(grown.allSatisfy { ($0.0, $0.1) == (dx, dy) ? $0.2 > 16 : $0.2 == 16 }, "\(margins)")
    }

    /// At the largest size and distance Settings allows, at full opacity, the shadow has faded out at every canvas edge in any direction,
    /// on a card and on a cut-out subject.
    @Test(arguments: [0.0, 45, 135, 270, 315])
    func aCustomShadowIsNeverClipped(angle: CGFloat) throws {
        let custom = shadow(blur: 100, distance: 64, angle: angle)
        let card = try OutputFrame.render(image(), crop: crop, scale: 2, padding: 0, shadow: custom)
        let subject = try OutputFrame.renderCutout(image().cropping(to: crop)!, bounds: nil, cornerRadii: .zero, framed: true, scale: 2, shadow: custom)
        for output in [card, subject] {
            let bytes = pixels(output)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * output.width + x) * 4 + 3] }
            let edges = (0..<output.width).flatMap { [alpha($0, 0), alpha($0, output.height - 1)] } + (0..<output.height).flatMap { [alpha(0, $0), alpha(output.width - 1, $0)] }
            #expect(edges.max()! <= 2, "edge alpha \(edges.max()!) at \(angle)")
            #expect(output.width > 200 && output.height > 100)
        }
    }

    /// The shadow takes its color: just below the card, a red shadow leaves red pixels only.
    @Test func aCustomShadowTakesItsColor() throws {
        let custom = shadow(blur: 6, distance: 12, angle: 270, color: SRGBColor(red: 1, green: 0, blue: 0))
        let output = try OutputFrame.render(image(), crop: crop, scale: 1, padding: 24, shadow: custom)
        let frame = OutputFrame.rect(around: crop, scale: 1, padding: 24, shadow: custom)
        let bytes = pixels(output)
        let below = (Int(crop.maxY - frame.minY) + 6) * output.width + Int(crop.midX - frame.minX)
        let (red, green, blue, alpha) = (bytes[below * 4], bytes[below * 4 + 1], bytes[below * 4 + 2], bytes[below * 4 + 3])
        #expect(alpha > 100 && red > 100 && green <= 1 && blue <= 1, "\(red) \(green) \(blue) \(alpha)")
    }
}
