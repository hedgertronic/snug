import AppKit

/// Loupe, rulers, and crosshair layers. Each is hidden when its toggle is off and costs nothing then.
@MainActor
final class Guides {
    static let loupeSize: CGFloat = 136
    static let loupePixels = 17
    static let rulerThickness: CGFloat = 16

    let root = CALayer()
    let crosshair = CAShapeLayer()
    let rulers = CALayer()
    let loupe = CALayer()
    let magnified = CALayer()
    private let bands = CAShapeLayer()
    private let ticks = CAShapeLayer()
    private let marks = CAShapeLayer()
    private let labelX = CATextLayer()
    private let labelY = CATextLayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let readout = CATextLayer()
    private var tickKey = CGSize.zero
    private var source: CGImage?

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
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.fontSize = 10
            label.foregroundColor = NSColor.white.cgColor
            label.contentsScale = NSScreen.main!.backingScaleFactor
        }
        for layer in [bands, ticks, marks, labelX, labelY] { rulers.addSublayer(layer) }

        loupe.bounds = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
        loupe.masksToBounds = true
        loupe.cornerRadius = 8
        loupe.borderWidth = 1
        loupe.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        loupe.backgroundColor = NSColor.black.cgColor
        magnified.frame = loupe.bounds
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
        readout.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: 15)
        readout.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        readout.alignmentMode = .center
        for layer in [magnified, grid, center, readout] { loupe.addSublayer(layer) }
    }

    /// Repositions the enabled guides. `point` is in view coordinates, `pixel` in image pixels with a top-left origin.
    func update(point: CGPoint, pixel: CGPoint, image: CGImage?, bounds: CGRect, scale: CGFloat) {
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
            if tickKey != bounds.size {
                tickKey = bounds.size
                bands.path = CGPath(rect: CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness), transform: nil)
                    .union(CGPath(rect: CGRect(x: 0, y: 0, width: thickness, height: bounds.height), transform: nil))
                let path = CGMutablePath()
                for pixels in stride(from: 0, through: Int(bounds.width * scale), by: 10) {
                    let x = CGFloat(pixels) / scale, length: CGFloat = pixels % 100 == 0 ? 10 : 5
                    path.move(to: CGPoint(x: x, y: bounds.height)); path.addLine(to: CGPoint(x: x, y: bounds.height - length))
                }
                for pixels in stride(from: 0, through: Int(bounds.height * scale), by: 10) {
                    let y = bounds.height - CGFloat(pixels) / scale, length: CGFloat = pixels % 100 == 0 ? 10 : 5
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: length, y: y))
                }
                ticks.path = path
            }
            marks.strokeColor = accent.cgColor
            let path = CGMutablePath()
            path.move(to: CGPoint(x: point.x, y: bounds.height)); path.addLine(to: CGPoint(x: point.x, y: bounds.height - thickness))
            path.move(to: CGPoint(x: 0, y: point.y)); path.addLine(to: CGPoint(x: thickness, y: point.y))
            marks.path = path
            labelX.string = "\(Int(pixel.x))"
            labelX.frame = CGRect(x: point.x + 4, y: bounds.height - thickness + 1, width: 48, height: 13)
            labelY.string = "\(Int(pixel.y))"
            labelY.frame = CGRect(x: thickness + 2, y: point.y + 2, width: 48, height: 13)
        }
        if !loupe.isHidden, let image {
            if source !== image {
                source = image
                magnified.contents = image
            }
            let half = Self.loupePixels / 2
            let column = Int(pixel.x), row = Int(pixel.y)
            // contentsRect's origin is the image's bottom left.
            let width = CGFloat(image.width), height = CGFloat(image.height)
            magnified.contentsRect = CGRect(x: CGFloat(column - half) / width, y: (height - CGFloat(row + half + 1)) / height,
                                            width: CGFloat(Self.loupePixels) / width, height: CGFloat(Self.loupePixels) / height)
            center.strokeColor = accent.cgColor
            readout.string = "\(column), \(row)"
            let size = Self.loupeSize
            let x = point.x + 20 + size > bounds.width ? point.x - 20 - size : point.x + 20
            let y = point.y - 20 - size < 0 ? point.y + 20 : point.y - 20 - size
            loupe.position = CGPoint(x: x + size / 2, y: y + size / 2)
        }
    }
}
