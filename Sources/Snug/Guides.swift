import AppKit
import ScreenshotCore

/// How the loupe and rulers appear: `fade` fades the loupe in with a small scale and the rulers by opacity alone, `slide` also slides the rulers
/// in from the top and left edges, and `none` flips them at once. Read from `Pref.guidesAnimation` when a guide toggles.
enum GuidesAnimation: String {
    case fade, slide, none
}

/// Loupe, rulers, and crosshair layers. Each is hidden when its toggle is off and costs nothing then.
@MainActor
final class Guides {
    static let loupeSize: CGFloat = 104
    static let loupePixels = 11
    static let rulerThickness: CGFloat = 18
    private static let readoutHeight: CGFloat = 32
    private static let readoutGap: CGFloat = 8
    /// The readout sticks out this far on each side of the loupe's disc.
    private static let readoutOverhang: CGFloat = 8
    /// One duration and curve for every loupe and ruler transition. The outro plays the intro backward, so its curve is the intro's mirrored.
    static let transitionDuration: CFTimeInterval = 0.18
    private static let introCurve = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    private static let outroCurve = CAMediaTimingFunction(controlPoints: 1, 0, 0.8, 1)
    /// The transforms the loupe and rulers fade in from: a small scale, and a slide in from the top and left edges.
    static let loupeHiddenTransform = CATransform3DMakeScale(0.9, 0.9, 1)
    static let rulersHiddenTransform = CATransform3DMakeTranslation(-rulerThickness, rulerThickness, 0)
    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    private static let flagFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    private static let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width

    let root = CALayer()
    let crosshair = CAShapeLayer()
    let rulers = CALayer()
    let loupe = CALayer()
    /// The circular magnifier: the pixels, grid, selection edges, and center cell, clipped to a circle.
    let disc = CALayer()
    let magnified = CALayer()
    private let ring = CALayer()
    private let spans = CAShapeLayer()
    let bands = CAShapeLayer()
    private let hairline = CAShapeLayer()
    private let ticks = CAShapeLayer()
    let numbers = CALayer()
    private let marks = CAShapeLayer()
    private let carets = CAShapeLayer()
    let widthLabel = Guides.text(Guides.flagFont, .center)
    private let heightLabel = Guides.text(Guides.flagFont, .right)
    /// Start and end flags: x start, x end, y start, y end.
    let flags = (0..<4).map { _ in Guides.text(Guides.flagFont, .center) }
    private let grid = CAShapeLayer()
    let edges = CAShapeLayer()
    private let centerHalo = CAShapeLayer()
    private let centerWhite = CAShapeLayer()
    let centerAccent = CAShapeLayer()
    private let readout = CALayer()
    private let swatch = CALayer()
    private let hex = Guides.text(NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .left)
    private let hint = Guides.text(NSFont.systemFont(ofSize: 10, weight: .semibold), .right)
    private let coordinates = Guides.text(NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .left)
    private var tickKey: [CGFloat] = []
    /// Whether a change of the loupe's placement slides, and the loupe's offset from the pointer at the last update (nil until it first shows).
    var slidesPlacement = false
    var loupeOffset: CGPoint?
    /// The color of the crosshair, ruler marks, and loupe outline and center cell: the user's highlight color, set by the view.
    var accent = NSColor.controlAccentColor

    private static func text(_ font: NSFont, _ alignment: CATextLayerAlignmentMode) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = font
        layer.fontSize = font.pointSize
        layer.alignmentMode = alignment
        layer.foregroundColor = NSColor.white.cgColor
        layer.contentsScale = NSScreen.main!.backingScaleFactor
        // New text shows at once, without the implicit cross-fade a redisplayed layer gets.
        layer.actions = ["contents": NSNull()]
        return layer
    }

    init() {
        for layer in [crosshair, rulers, loupe] {
            layer.isHidden = true
            root.addSublayer(layer)
        }
        crosshair.lineWidth = 1
        // X shows and hides the crosshair at once; only the loupe and rulers animate, per `GuidesAnimation`.
        crosshair.actions = ["hidden": NSNull()]
        crosshair.fillColor = nil
        bands.fillColor = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 26 / 255, alpha: 0.66).cgColor
        hairline.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        hairline.lineWidth = 0.5
        ticks.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ticks.lineWidth = 1
        marks.strokeColor = NSColor.white.cgColor
        marks.lineWidth = 1
        for flag in flags {
            flag.cornerRadius = 3
        }
        for layer in [bands, spans, hairline, ticks, numbers, widthLabel, heightLabel, marks, carets] + flags { rulers.addSublayer(layer) }

        let size = Self.loupeSize
        let tall = size + Self.readoutGap + Self.readoutHeight
        loupe.bounds = CGRect(x: 0, y: 0, width: size, height: tall)
        ring.frame = CGRect(x: -0.5, y: tall - size - 0.5, width: size + 1, height: size + 1)
        ring.cornerRadius = size / 2 + 0.5
        ring.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.5
        ring.shadowRadius = 9
        ring.shadowOffset = CGSize(width: 0, height: -6)
        disc.frame = CGRect(x: 0, y: tall - size, width: size, height: size)
        disc.masksToBounds = true
        disc.cornerRadius = size / 2
        disc.borderWidth = 2.5
        disc.borderColor = NSColor.white.cgColor
        magnified.frame = disc.bounds
        magnified.magnificationFilter = .nearest
        let cell = size / CGFloat(Self.loupePixels)
        grid.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
        grid.lineWidth = 1
        grid.isHidden = cell < 6
        let lines = CGMutablePath()
        for index in 0...Self.loupePixels {
            let offset = CGFloat(index) * cell
            lines.move(to: CGPoint(x: offset, y: 0)); lines.addLine(to: CGPoint(x: offset, y: size))
            lines.move(to: CGPoint(x: 0, y: offset)); lines.addLine(to: CGPoint(x: size, y: offset))
        }
        grid.path = lines
        edges.fillColor = nil
        edges.lineWidth = 2
        // The center cell: a hairline outside, a white ring, and an accent ring inside it.
        let middle = CGRect(x: cell * CGFloat(Self.loupePixels / 2), y: cell * CGFloat(Self.loupePixels / 2), width: cell, height: cell)
        for (layer, color, width, inset) in [(centerHalo, NSColor.black.withAlphaComponent(0.55), 1.0, -0.5), (centerWhite, .white, 2.0, 1.0)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.path = CGPath(rect: middle.insetBy(dx: inset, dy: inset), transform: nil)
        }
        centerAccent.fillColor = nil
        centerAccent.lineWidth = 1.5
        centerAccent.path = CGPath(rect: middle.insetBy(dx: 2.75, dy: 2.75), transform: nil)
        readout.frame = CGRect(x: -Self.readoutOverhang, y: 0, width: size + 2 * Self.readoutOverhang, height: Self.readoutHeight)
        readout.backgroundColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.88).cgColor
        readout.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        readout.borderWidth = 0.5
        readout.cornerRadius = 8
        swatch.frame = CGRect(x: 8, y: 17, width: 10, height: 10)
        swatch.cornerRadius = 3
        swatch.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        swatch.borderWidth = 0.5
        hex.frame = CGRect(x: 24, y: 16, width: 70, height: 13)
        hint.frame = CGRect(x: readout.bounds.width - 8 - 20, y: 16, width: 20, height: 13)
        hint.foregroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        hint.string = "C"
        coordinates.frame = CGRect(x: 8, y: 3, width: readout.bounds.width - 16, height: 12)
        coordinates.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        for layer in [swatch, hex, hint, coordinates] { readout.addSublayer(layer) }
        for layer in [magnified, grid, edges, centerHalo, centerWhite, centerAccent] { disc.addSublayer(layer) }
        for layer in [ring, disc, readout] { loupe.addSublayer(layer) }
    }

    /// Shows or hides a loupe or rulers layer. Animated, it fades in from `hidden` and out again along the same values on the mirrored curve,
    /// and the layer hides once the outro ends. Unanimated it flips at once.
    func setShown(_ layer: CALayer, _ shown: Bool, from hidden: CATransform3D, animated: Bool) {
        let visible = !layer.isHidden && layer.opacity == 1
        guard shown != visible else { return }
        if layer === loupe { loupeOffset = nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard animated else {
            layer.isHidden = !shown
            layer.opacity = shown ? 1 : 0
            CATransaction.commit()
            return
        }
        CATransaction.setCompletionBlock { if layer.opacity == 0 { layer.isHidden = true } }
        layer.isHidden = false
        layer.opacity = shown ? 1 : 0
        layer.add(Self.transition(from: hidden, showing: shown), forKey: "transition")
        CATransaction.commit()
    }

    /// The fade and transform animation for an intro (`showing`) or its exact reverse.
    static func transition(from hidden: CATransform3D, showing: Bool) -> CAAnimationGroup {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = showing ? 0 : 1
        fade.toValue = showing ? 1 : 0
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: showing ? hidden : CATransform3DIdentity)
        move.toValue = NSValue(caTransform3D: showing ? CATransform3DIdentity : hidden)
        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.duration = transitionDuration
        group.timingFunction = showing ? introCurve : outroCurve
        return group
    }

    /// The loupe's lower-left corner for a pointer at `point`: below and to the right of it, or the first of below-left, above-right and above-left
    /// whose frame, readout included, lies inside the view under the inset and clear of every `avoiding` frame. With none free it takes the first
    /// pushed inside the view. The result is on whole device pixels so the magnified cells stay crisp.
    static func loupeOrigin(point: CGPoint, bounds: CGRect, topInset: CGFloat, scale: CGFloat, avoiding: [CGRect]) -> CGPoint {
        let size = loupeSize, tall = size + readoutGap + readoutHeight, gap: CGFloat = 10
        let usable = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - topInset - 4)
        let xs = [point.x + gap, point.x - gap - size], ys = [point.y - gap - tall, point.y + gap]
        let frames = ys.flatMap { y in xs.map { CGRect(x: $0 - readoutOverhang, y: y, width: size + 2 * readoutOverhang, height: tall) } }
        let frame = frames.first { candidate in usable.contains(candidate) && !avoiding.contains { candidate.intersects($0) } }
            ?? frames[0].offsetBy(dx: max(usable.minX - frames[0].minX, min(usable.maxX - frames[0].maxX, 0)), dy: max(usable.minY - frames[0].minY, min(usable.maxY - frames[0].maxY, 0)))
        return CGPoint(x: ((frame.minX + readoutOverhang) * scale).rounded() / scale, y: (frame.minY * scale).rounded() / scale)
    }

    /// Repositions the enabled guides. `point` is in view coordinates, `pixel` and `selected` (the selection or the rectangle being drawn)
    /// in image pixels with a top-left origin, and `dragging` says a drag is changing `selected`.
    /// The top ruler sits below the `topInset` the camera housing covers, and the loupe keeps clear of the `avoiding` frames (the visible bars).
    /// Everything moves in one transaction with implicit actions off, so the loupe, its cells, and the outline never animate against each other.
    func update(point: CGPoint, pixel: CGPoint, image: CGImage?, bounds: CGRect, scale: CGFloat, topInset: CGFloat, selected: CGRect?, dragging: Bool, avoiding: [CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
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
            let digit = Self.digitWidth
            if tickKey != [bounds.width, bounds.height, topInset, scale] {
                tickKey = [bounds.width, bounds.height, topInset, scale]
                bands.path = CGPath(rect: CGRect(x: 0, y: bandBottom, width: bounds.width, height: thickness), transform: nil)
                    .union(CGPath(rect: CGRect(x: 0, y: 0, width: thickness, height: bandBottom), transform: nil))
                let edge = CGMutablePath()
                edge.move(to: CGPoint(x: 0, y: bandBottom)); edge.addLine(to: CGPoint(x: bounds.width, y: bandBottom))
                edge.move(to: CGPoint(x: thickness, y: 0)); edge.addLine(to: CGPoint(x: thickness, y: bandBottom))
                hairline.path = edge
                let path = CGMutablePath()
                numbers.sublayers = nil
                func number(_ pixels: Int) -> CATextLayer {
                    let label = Self.text(Self.numberFont, .left)
                    label.foregroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
                    label.string = "\(pixels)"
                    numbers.addSublayer(label)
                    return label
                }
                for pixels in stride(from: 0, through: Int(bounds.width * scale), by: 10) {
                    let x = CGFloat(pixels) / scale, major = pixels % 100 == 0
                    path.move(to: CGPoint(x: x, y: bandBottom)); path.addLine(to: CGPoint(x: x, y: bandBottom + (major ? 8 : 4)))
                    if major, pixels > 0 { number(pixels).frame = CGRect(x: x + 3, y: bandTop - 13, width: CGFloat("\(pixels)".count) * digit + 2, height: 12) }
                }
                // The left ruler's numbers read bottom to top, so four digits still fit in its 18 pt.
                for pixels in stride(from: 0, through: Int(bounds.height * scale), by: 10) {
                    let y = bounds.height - CGFloat(pixels) / scale, major = pixels % 100 == 0
                    guard y < bandBottom else { continue }
                    path.move(to: CGPoint(x: thickness, y: y)); path.addLine(to: CGPoint(x: thickness - (major ? 8 : 4), y: y))
                    if major, pixels > 0 {
                        let label = number(pixels)
                        label.alignmentMode = .right
                        label.bounds = CGRect(x: 0, y: 0, width: 28, height: 12)
                        label.position = CGPoint(x: 7, y: y - 17)
                        label.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
                    }
                }
                ticks.path = path
            }
            let band = CGMutablePath()
            for flag in flags + [widthLabel, heightLabel] { flag.isHidden = true }
            if let selected {
                let span = CGRect(x: selected.minX / scale, y: bounds.height - selected.maxY / scale, width: selected.width / scale, height: selected.height / scale)
                band.addRect(CGRect(x: span.minX, y: bandBottom, width: span.width, height: thickness))
                band.addRect(CGRect(x: 0, y: span.minY, width: thickness, height: span.height).intersection(CGRect(x: 0, y: 0, width: thickness, height: bandBottom)))
                // The crop's whole-pixel sides, as the loupe's outline draws them.
                let values = [selected.minX.rounded(.down), selected.maxX.rounded(.up), selected.minY.rounded(.down), selected.maxY.rounded(.up)].map { Int($0) }
                func flag(_ index: Int, at origin: (CGFloat) -> CGPoint) {
                    let width = CGFloat("\(values[index])".count) * digit + 6
                    flags[index].string = "\(values[index])"
                    flags[index].frame = CGRect(origin: origin(width), size: CGSize(width: width, height: 12))
                    flags[index].isHidden = false
                }
                let below = bandBottom - 16
                flag(0) { CGPoint(x: max(span.minX - $0, thickness + 2), y: below) }
                flag(1) { CGPoint(x: min(span.maxX, bounds.width - $0), y: below) }
                flag(2) { _ in CGPoint(x: thickness + 4, y: min(span.maxY, bandBottom - 12)) }
                flag(3) { _ in CGPoint(x: thickness + 4, y: max(span.minY - 12, 2)) }
                let across = CGFloat("\(values[1] - values[0])".count) * digit + 8
                if span.width > across {
                    widthLabel.string = "\(values[1] - values[0])"
                    widthLabel.frame = CGRect(x: span.midX - across / 2, y: bandTop - 14, width: across, height: 12)
                    widthLabel.isHidden = false
                }
                let along = CGFloat("\(values[3] - values[2])".count) * digit + 8
                if span.height > along {
                    heightLabel.string = "\(values[3] - values[2])"
                    heightLabel.bounds = CGRect(x: 0, y: 0, width: along, height: 12)
                    heightLabel.alignmentMode = .center
                    heightLabel.position = CGPoint(x: 9, y: span.midY)
                    heightLabel.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
                    heightLabel.isHidden = false
                }
            }
            // Tick numbers under the width or height label hide.
            let labels = [widthLabel, heightLabel].filter { !$0.isHidden }.map { $0.frame.insetBy(dx: -3, dy: -3) }
            for label in numbers.sublayers ?? [] { label.isHidden = labels.contains { $0.intersects(label.frame) } }
            spans.path = band
            let line = CGMutablePath()
            line.move(to: CGPoint(x: point.x, y: bandTop)); line.addLine(to: CGPoint(x: point.x, y: bandBottom))
            line.move(to: CGPoint(x: 0, y: point.y)); line.addLine(to: CGPoint(x: thickness, y: point.y))
            marks.path = line
            let caret = CGMutablePath()
            caret.addLines(between: [CGPoint(x: point.x - 4, y: bandBottom + 2), CGPoint(x: point.x + 4, y: bandBottom + 2), CGPoint(x: point.x, y: bandBottom - 3)])
            caret.closeSubpath()
            caret.addLines(between: [CGPoint(x: thickness - 2, y: point.y - 4), CGPoint(x: thickness - 2, y: point.y + 4), CGPoint(x: thickness + 3, y: point.y)])
            caret.closeSubpath()
            carets.path = caret
            carets.fillColor = accent.cgColor
            for flag in flags { flag.backgroundColor = accent.withAlphaComponent(0.9).cgColor }
            spans.fillColor = accent.withAlphaComponent(0.55).cgColor
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
            for layer in [edges, centerAccent] { layer.strokeColor = accent.cgColor }
            // The dragged rectangle's edges, in the loupe's cells, on the pixel boundaries the crop takes (`integral`: min sides round down,
            // max sides up), so the outline shows the pixels the capture will hold. The disc clips whatever lies outside the window.
            let cell = Self.loupeSize / CGFloat(side)
            edges.path = dragging ? selected.map {
                let left = $0.minX.rounded(.down), right = $0.maxX.rounded(.up), top = $0.minY.rounded(.down), bottom = $0.maxY.rounded(.up)
                return CGPath(rect: CGRect(x: (left - window.minX) * cell, y: Self.loupeSize - (bottom - window.minY) * cell, width: (right - left) * cell, height: (bottom - top) * cell), transform: nil)
            } : nil
            let color = ColorFormat.average(of: image, in: CGRect(x: column, y: row, width: 1, height: 1))
            swatch.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            hex.string = ColorFormat.hex.string(for: color)
            coordinates.string = "x \(column)  y \(row)"
            let origin = Self.loupeOrigin(point: point, bounds: bounds, topInset: topInset, scale: scale, avoiding: avoiding)
            let offset = CGPoint(x: origin.x - point.x, y: origin.y - point.y)
            // A flip to the pointer's other side (past a bar or a screen edge) slides from the old offset to the new one. Only the offset animates,
            // additively, so the loupe still tracks the pointer at once, and a flip during a slide adds to it. A loupe pushed inside the view keeps
            // its side, so following the pointer there never slides. Mid-slide frames sit between device pixels.
            if slidesPlacement, let previous = loupeOffset, (previous.x < 0) != (offset.x < 0) || (previous.y < 0) != (offset.y < 0) {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: CGPoint(x: previous.x - offset.x, y: previous.y - offset.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = Self.transitionDuration
                slide.timingFunction = Self.introCurve
                loupe.add(slide, forKey: "placement \(CACurrentMediaTime())")
            }
            loupeOffset = offset
            loupe.position = CGPoint(x: origin.x + Self.loupeSize / 2, y: origin.y + loupe.bounds.height / 2)
        }
    }
}
