import AppKit
import ScreenshotCore

/// Loupe, rulers, and crosshair layers. Each is hidden when its toggle is off and costs nothing then.
@MainActor
final class Guides {
    static let loupeSize: CGFloat = 76
    static let loupePixels = 15
    static let rulerThickness: CGFloat = 22
    private static let readoutHeight: CGFloat = 18

    let root = CALayer()
    let crosshair = CAShapeLayer()
    let rulers = CALayer()
    let loupe = CALayer()
    /// The circular magnifier: the pixels, grid, and center box, clipped to a circle.
    let disc = CALayer()
    let magnified = CALayer()
    private let ring = CALayer()
    private let spans = CAShapeLayer()
    let bands = CAShapeLayer()
    private let ticks = CAShapeLayer()
    private let marks = CAShapeLayer()
    private let labelX = CATextLayer()
    private let labelY = CATextLayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let readout = CATextLayer()
    private var tickKey: [CGFloat] = []

    init() {
        for layer in [crosshair, rulers, loupe] {
            layer.isHidden = true
            root.addSublayer(layer)
        }
        crosshair.lineWidth = 1
        crosshair.fillColor = nil
        bands.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        ticks.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ticks.lineWidth = 1
        marks.lineWidth = 2
        for label in [labelX, labelY, readout] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.fontSize = 11
            label.foregroundColor = NSColor.white.cgColor
            label.contentsScale = NSScreen.main!.backingScaleFactor
        }
        spans.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        for layer in [bands, spans, ticks, marks, labelX, labelY] { rulers.addSublayer(layer) }

        let size = Self.loupeSize
        loupe.bounds = CGRect(x: 0, y: 0, width: size, height: size + 6 + Self.readoutHeight)
        ring.frame = CGRect(x: 0, y: Self.readoutHeight + 6, width: size, height: size)
        ring.cornerRadius = size / 2
        ring.backgroundColor = NSColor.black.cgColor
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.45
        ring.shadowRadius = 8
        ring.shadowOffset = CGSize(width: 0, height: -3)
        disc.frame = ring.frame
        disc.masksToBounds = true
        disc.cornerRadius = size / 2
        disc.borderWidth = 2
        disc.borderColor = NSColor.white.cgColor
        magnified.frame = disc.bounds
        magnified.magnificationFilter = .nearest
        grid.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
        grid.lineWidth = 1
        let cell = Self.loupeSize / CGFloat(Self.loupePixels)
        let lines = CGMutablePath()
        for index in 0...Self.loupePixels {
            let offset = CGFloat(index) * cell
            lines.move(to: CGPoint(x: offset, y: 0)); lines.addLine(to: CGPoint(x: offset, y: Self.loupeSize))
            lines.move(to: CGPoint(x: 0, y: offset)); lines.addLine(to: CGPoint(x: Self.loupeSize, y: offset))
        }
        grid.path = lines
        center.fillColor = nil
        center.lineWidth = 2
        center.path = CGPath(rect: CGRect(x: cell * CGFloat(Self.loupePixels / 2), y: cell * CGFloat(Self.loupePixels / 2), width: cell, height: cell), transform: nil)
        readout.frame = CGRect(x: (size - 84) / 2, y: 0, width: 84, height: Self.readoutHeight)
        readout.backgroundColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.86).cgColor
        readout.cornerRadius = 6
        readout.alignmentMode = .center
        for layer in [magnified, grid, center] { disc.addSublayer(layer) }
        for layer in [ring, disc, readout] { loupe.addSublayer(layer) }
    }

    /// Repositions the enabled guides. `point` and `span` (the selection) are in view coordinates, `pixel` in image pixels with a top-left origin.
    /// The top ruler sits below the `topInset` the camera housing covers.
    func update(point: CGPoint, pixel: CGPoint, image: CGImage?, bounds: CGRect, scale: CGFloat, topInset: CGFloat, span: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
        let accent = NSColor.controlAccentColor
        if !crosshair.isHidden {
            crosshair.strokeColor = accent.withAlphaComponent(0.8).cgColor
            let lines = CGMutablePath()
            lines.move(to: CGPoint(x: 0, y: point.y)); lines.addLine(to: CGPoint(x: bounds.width, y: point.y))
            lines.move(to: CGPoint(x: point.x, y: 0)); lines.addLine(to: CGPoint(x: point.x, y: bounds.height))
            crosshair.path = lines
        }
        if !rulers.isHidden {
            rulers.frame = bounds
            let thickness = Self.rulerThickness
            let bandTop = bounds.height - topInset, bandBottom = bandTop - thickness
            if tickKey != [bounds.width, bounds.height, topInset, scale] {
                tickKey = [bounds.width, bounds.height, topInset, scale]
                bands.path = CGPath(rect: CGRect(x: 0, y: bandBottom, width: bounds.width, height: thickness), transform: nil)
                    .union(CGPath(rect: CGRect(x: 0, y: 0, width: thickness, height: bandBottom), transform: nil))
                let path = CGMutablePath()
                for pixels in stride(from: 0, through: Int(bounds.width * scale), by: 10) {
                    let x = CGFloat(pixels) / scale, length: CGFloat = pixels % 100 == 0 ? 10 : 5
                    path.move(to: CGPoint(x: x, y: bandBottom)); path.addLine(to: CGPoint(x: x, y: bandBottom + length))
                }
                for pixels in stride(from: 0, through: Int(bounds.height * scale), by: 10) {
                    let y = bounds.height - CGFloat(pixels) / scale, length: CGFloat = pixels % 100 == 0 ? 10 : 5
                    guard y < bandBottom else { continue }
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: length, y: y))
                }
                ticks.path = path
            }
            let band = CGMutablePath()
            if let span {
                band.addRect(CGRect(x: span.minX, y: bandBottom, width: span.width, height: thickness))
                band.addRect(CGRect(x: 0, y: span.minY, width: thickness, height: span.height).intersection(CGRect(x: 0, y: 0, width: thickness, height: bandBottom)))
            }
            spans.path = band
            marks.strokeColor = accent.cgColor
            let path = CGMutablePath()
            path.move(to: CGPoint(x: point.x, y: bandTop)); path.addLine(to: CGPoint(x: point.x, y: bandBottom))
            path.move(to: CGPoint(x: 0, y: point.y)); path.addLine(to: CGPoint(x: thickness, y: point.y))
            marks.path = path
            labelX.string = "\(Int(pixel.x))"
            labelX.frame = CGRect(x: point.x + 4, y: bandBottom + 3, width: 48, height: 14)
            labelY.string = "\(Int(pixel.y))"
            labelY.frame = CGRect(x: thickness + 3, y: point.y + 2, width: 48, height: 14)
        }
        if !loupe.isHidden, let image {
            let half = Self.loupePixels / 2
            let column = Int(pixel.x), row = Int(pixel.y)
            // Only a copy of the pixels around the pointer goes to the layer, so the loupe never holds the capture after the overlay closes.
            // Pixels past the image's edge stay clear.
            let side = Self.loupePixels
            let window = CGRect(x: column - half, y: row - half, width: side, height: side)
            let inside = window.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image.cropping(to: inside)!, in: CGRect(x: inside.minX - window.minX, y: window.maxY - inside.maxY, width: inside.width, height: inside.height))
            magnified.contents = context.makeImage()
            center.strokeColor = accent.cgColor
            let color = ColorFormat.hex.string(for: ColorFormat.average(of: image, in: CGRect(x: column, y: row, width: 1, height: 1)))
            readout.string = "\(color)  C"
            let size = Self.loupeSize, tall = loupe.bounds.height, gap: CGFloat = 10
            let x = point.x + gap + size > bounds.width ? point.x - gap - size : point.x + gap
            let y = min(point.y - gap - tall < 0 ? point.y + gap : point.y - gap - tall, bounds.height - topInset - 4 - tall)
            loupe.position = CGPoint(x: x + size / 2, y: y + tall / 2)
        }
    }
}
