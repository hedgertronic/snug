import AppKit
import ScreenshotCore
import VisionKit

/// The configurable look of the hover highlight and everything drawn in the accent, read from the defaults on each `present`.
struct Highlight {
    var color: NSColor
    /// Opacity of the fill inside the hovered rectangle, 0...0.3.
    var fill: CGFloat
    /// Opacity of the dim outside the highlight, 0...0.6.
    var fade: CGFloat
    /// Strength of the glow around the hovered rectangle, 0 (none)...1.
    var glow: CGFloat

    /// The color choices, in order: the system accent ("" hex), then the macOS accent colors.
    static let presets: [(name: String, hex: String)] = [
        ("System accent", ""), ("Blue", "#007AFF"), ("Purple", "#A550A7"), ("Pink", "#F74F9E"), ("Red", "#FF5257"),
        ("Orange", "#F7821B"), ("Yellow", "#FFC600"), ("Green", "#62BA46"), ("Graphite", "#8C8C8C")
    ]

    init(defaults: UserDefaults) {
        color = Self.color(hex: defaults.string(forKey: Pref.highlightColor)!)
        fill = defaults.double(forKey: Pref.highlightFill)
        fade = defaults.double(forKey: Pref.highlightFade)
        glow = defaults.double(forKey: Pref.highlightGlow)
    }

    /// The color for a stored "#RRGGBB"; the system accent for "".
    static func color(hex: String) -> NSColor {
        guard !hex.isEmpty else { return .controlAccentColor }
        let value = Int(hex.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Layer-backed view: the frozen image sits in one layer, set once; everything else is a shape layer.
@MainActor
final class OverlayView: NSView {
    /// Overlay geometry in image pixels with a top-left origin.
    struct Overlays {
        var selection, ghost, preview, hover, styleFrame: CGRect?
        /// What Up and Down would select from the hovered element, drawn as faint outlines.
        var upHint, downHint: CGRect?
        /// Sides a resize snapped to, as zero-width or zero-height rectangles.
        var snappedEdges: [CGRect] = []
        var showsHandles = false
        /// The corner Tab focused: its radius dot is drawn lit.
        var focusedCorner: Handle?
        /// Capture with nothing targeted: the whole screen dims, since none of it is the target.
        var dimsAll = false
        /// The first hover target (or nothing) has resolved since the overlay opened; until then the dim stays off, and that first dim applies without a crossfade.
        var dimResolved = false
        /// The selection's accent outline; armed to record, the red outline takes its place.
        var showsOutline = true
        /// Corner radii in image pixels of the selection (or the snap preview when there is no selection), and of the hovered rectangle.
        var radii = CornerRadii.zero
        var hoverRadii = CornerRadii.zero
        var upHintRadii = CornerRadii.zero
        var downHintRadii = CornerRadii.zero
    }

    weak var controller: OverlayController?
    /// Image pixels per point.
    var scale: CGFloat = 1
    /// Set with implicit actions off, so the frozen image replaces the black window at once.
    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            CATransaction.commit()
        }
    }
    var overlays = Overlays() { didSet { layoutOverlays() } }
    var highlight: Highlight? { didSet { applyAccent() } }
    /// The cursor over the whole overlay; the controller picks it from the pointer and the interaction.
    var cursor = NSCursor.crosshair {
        didSet { if cursor !== oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// Text mode's Live Text: selectable text laid exactly over the frozen image, shown only in Text mode.
    let liveText = ImageAnalysisOverlayView()
    let guides = Guides()
    private let imageLayer = CALayer()
    /// The hovered rectangle the dim was last cut around (the inner nil with none) while nothing is dragged or selected; nil until the first target resolves.
    private var dimTarget: CGRect??
    let dimLayer = CAShapeLayer()
    let hoverLayer = CAShapeLayer()
    /// The glow: the shadow of the hovered rectangle's filled shape, masked to the outside of it so the inside stays clear.
    let glowLayer = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let hoverRingLayer = CAShapeLayer()
    let levelHintLayer = CAShapeLayer()
    /// The fade-in of the Up and Down outlines and their caps after a key's jump, in seconds.
    static let hintFadeDuration = 0.08
    private let styleLayer = CAShapeLayer()
    private let ghostLayer = CAShapeLayer()
    let outlineLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    let handlesLayer = CAShapeLayer()
    private let snappedLayer = CAShapeLayer()
    /// The corner-radius dots, drawn over the resize handles.
    private let cornerDotsLayer = CAShapeLayer()
    /// The focused corner's dot, larger and filled white.
    private let focusedDotLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.addSublayer(imageLayer)
        for shape in [dimLayer, levelHintLayer, hoverRingLayer, glowLayer, hoverLayer, styleLayer, ghostLayer, outlineLayer, previewLayer, snappedLayer, handlesLayer] {
            shape.fillColor = nil
            layer!.addSublayer(shape)
        }
        layer!.addSublayer(guides.root)
        liveText.preferredInteractionTypes = .textSelection
        // No Live Text button in the corner: Text mode is already the text view.
        liveText.isSupplementaryInterfaceHidden = true
        liveText.isHidden = true
        addSubview(liveText)
        dimLayer.fillRule = .evenOdd
        styleLayer.strokeColor = NSColor.white.cgColor
        styleLayer.lineDashPattern = [5, 4]
        ghostLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outlineLayer.lineWidth = 1.5
        levelHintLayer.strokeColor = NSColor.white.withAlphaComponent(0.38).cgColor
        levelHintLayer.lineWidth = 1
        levelHintLayer.lineDashPattern = [4, 3]
        hoverRingLayer.lineWidth = 3
        glowLayer.shadowOffset = .zero
        glowMask.fillRule = .evenOdd
        glowLayer.mask = glowMask
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1.5
        cornerDotsLayer.strokeColor = NSColor.white.cgColor
        cornerDotsLayer.lineWidth = 1.5
        handlesLayer.addSublayer(cornerDotsLayer)
        focusedDotLayer.fillColor = NSColor.white.cgColor
        focusedDotLayer.lineWidth = 2
        handlesLayer.addSublayer(focusedDotLayer)
        applyAccent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        liveText.frame = bounds
        guides.host.frame = bounds
        layoutOverlays()
    }

    override func viewDidChangeEffectiveAppearance() { applyAccent() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    func pixelPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * scale, y: (bounds.height - point.y) * scale)
    }

    func viewRect(_ pixels: CGRect) -> CGRect {
        CGRect(x: pixels.minX / scale, y: bounds.height - pixels.maxY / scale, width: pixels.width / scale, height: pixels.height / scale)
    }

    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(event) }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func flagsChanged(with event: NSEvent) { controller?.flagsChanged(event) }
    override func keyDown(with event: NSEvent) { if controller?.handleKey(event) == false, controller?.isHeadless == false { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { controller?.keyUp(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && controller?.handleKey(event) == true
    }

    private func applyAccent() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = highlight?.color ?? .controlAccentColor
            guides.accent = accent
            // The hover: a hairline with a 3 pt ring just outside it, an optional soft glow, and an optional fill.
            hoverLayer.strokeColor = accent.cgColor
            hoverLayer.lineWidth = 1.5
            glowLayer.shadowColor = accent.cgColor
            let glow = highlight?.glow ?? 0.2
            glowLayer.shadowOpacity = Float(min(1, glow * 1.6))
            glowLayer.shadowRadius = 4 + 14 * glow
            let fill = highlight?.fill ?? 0.1
            hoverLayer.fillColor = fill > 0 ? accent.withAlphaComponent(fill).cgColor : nil
            dimLayer.fillColor = NSColor.black.withAlphaComponent(highlight?.fade ?? 0.5).cgColor
            hoverRingLayer.strokeColor = accent.withAlphaComponent(0.28).cgColor
            previewLayer.strokeColor = accent.cgColor
            previewLayer.lineWidth = 1.5
            snappedLayer.strokeColor = accent.cgColor
            snappedLayer.lineWidth = 4
            outlineLayer.strokeColor = accent.cgColor
            handlesLayer.strokeColor = accent.cgColor
            cornerDotsLayer.fillColor = accent.cgColor
            focusedDotLayer.strokeColor = accent.cgColor
        }
    }

    private func layoutOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let o = overlays
        // A key's jump to another candidate moves each outline path from its old shape to the new one over the jump's duration, ease out
        // (an explicit animation: implicit ones are not added to layers of a window that is not on screen); anything else changes at once.
        let jumping = controller?.jumping == true
        func slide(_ layer: CALayer, _ keyPath: String, to path: CGPath?) {
            let old = layer.value(forKey: keyPath) as! CGPath?
            layer.setValue(path, forKey: keyPath)
            guard jumping, let old, let path else { return }
            let move = CABasicAnimation(keyPath: keyPath)
            move.fromValue = (layer.presentation()?.value(forKey: keyPath) as! CGPath?) ?? old
            move.toValue = path
            move.duration = OverlayController.jumpDuration
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(move, forKey: keyPath)
        }
        /// The outline of `rect`, moved in by `inset` on any side at the view's edge so a stroke there shows its full width
        /// (a full-screen outline), and grown by `outset` elsewhere with its radii.
        func path(_ rect: CGRect, radii: CornerRadii = .zero, inset: CGFloat = 0, outset: CGFloat = 0) -> CGPath {
            var box = viewRect(rect)
            let left = box.minX <= bounds.minX + 0.5, right = box.maxX >= bounds.maxX - 0.5
            let bottom = box.minY <= bounds.minY + 0.5, top = box.maxY >= bounds.maxY - 0.5
            box = CGRect(x: box.minX + (left ? inset : -outset), y: box.minY + (bottom ? inset : -outset),
                         width: box.width - (left ? inset : -outset) - (right ? inset : -outset),
                         height: box.height - (bottom ? inset : -outset) - (top ? inset : -outset))
            var corners = radii.scaled(by: 1 / scale)
            if outset > 0 { corners = CornerRadii(topLeft: corners.topLeft > 0 ? corners.topLeft + outset : 0, topRight: corners.topRight > 0 ? corners.topRight + outset : 0,
                                                  bottomLeft: corners.bottomLeft > 0 ? corners.bottomLeft + outset : 0, bottomRight: corners.bottomRight > 0 ? corners.bottomRight + outset : 0) }
            return corners.path(in: box)
        }
        // Dim = not part of the target: everything outside it, nothing when it is the whole screen, everything when there is none.
        let dim = CGMutablePath()
        if let cutout = o.selection ?? o.preview ?? o.ghost {
            if viewRect(cutout) != bounds {
                dim.addRect(bounds)
                dim.addPath(path(cutout, radii: o.radii))
            }
        } else if let hover = o.hover {
            if viewRect(hover) != bounds {
                dim.addRect(bounds)
                dim.addPath(path(hover, radii: o.hoverRadii))
            }
        } else if o.dimsAll {
            dim.addRect(bounds)
        }
        // A new hover target, or none, crossfades the dim in 150 ms; a drag or selection changes it at once.
        let hovering = o.selection == nil && o.preview == nil && o.ghost == nil
        if hovering, let previous = dimTarget, previous != o.hover, !jumping, controller?.animates == true {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimLayer.add(fade, forKey: "dim")
        }
        dimTarget = o.dimResolved ? .some(hovering ? o.hover : nil) : nil
        slide(dimLayer, "path", to: dim)
        let hoverPath = o.hover.map { path($0, radii: o.hoverRadii, inset: 0.75) }
        slide(hoverLayer, "path", to: hoverPath)
        slide(glowLayer, "path", to: hoverPath)
        // Core Animation scales a shadow by its layer's content alpha, so the shape is filled opaque; the mask hides the fill.
        glowLayer.fillColor = NSColor.black.cgColor
        glowLayer.frame = bounds
        glowMask.frame = bounds
        slide(glowLayer, "shadowPath", to: o.hover.map { path($0, radii: o.hoverRadii) })
        let outside = CGMutablePath()
        if let shape = glowLayer.shadowPath {
            outside.addRect(bounds.insetBy(dx: -64, dy: -64))
            outside.addPath(shape)
        }
        slide(glowMask, "path", to: outside)
        slide(hoverRingLayer, "path", to: o.hover.map { path($0, radii: o.hoverRadii, inset: 3, outset: 2.25) })
        // The Up and Down outlines never morph: at a jump they take their new path at once, hidden, and fade in once the outline lands.
        let hints = CGMutablePath()
        if let rect = o.upHint { hints.addPath(path(rect, radii: o.upHintRadii, inset: 0.5)) }
        if let rect = o.downHint { hints.addPath(path(rect, radii: o.downHintRadii, inset: 0.5)) }
        levelHintLayer.path = hints
        if jumping {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = levelHintLayer.convertTime(CACurrentMediaTime(), from: nil) + OverlayController.jumpDuration
            fade.duration = Self.hintFadeDuration
            fade.fillMode = .backwards
            levelHintLayer.add(fade, forKey: "opacity")
        }
        styleLayer.path = o.styleFrame.map { path($0) }
        ghostLayer.path = o.ghost.map { path($0) }
        outlineLayer.path = o.showsOutline ? o.selection.map { path($0, radii: o.radii, inset: 0.75) } : nil
        previewLayer.path = o.preview.map { path($0, radii: o.radii, inset: 0.75) }
        let snapped = CGMutablePath()
        for edge in o.snappedEdges {
            let line = viewRect(edge)
            snapped.move(to: CGPoint(x: line.minX, y: line.minY))
            snapped.addLine(to: CGPoint(x: line.maxX, y: line.maxY))
        }
        snappedLayer.path = snapped
        let handles = CGMutablePath()
        if o.showsHandles, let selection = o.selection {
            for handle in Handle.allCases {
                let point = handle.position(on: selection)
                handles.addEllipse(in: CGRect(x: point.x / scale - 4, y: bounds.height - point.y / scale - 4, width: 8, height: 8))
            }
        }
        handlesLayer.path = handles
        let dots = CGMutablePath()
        if o.showsHandles, let selection = o.selection {
            for corner in CornerRadii.corners {
                let point = o.radii.dot(of: corner, in: selection, minimumInset: 8 * scale)
                dots.addEllipse(in: CGRect(x: point.x / scale - 3, y: bounds.height - point.y / scale - 3, width: 6, height: 6))
            }
        }
        cornerDotsLayer.path = dots
        focusedDotLayer.path = o.showsHandles && o.selection != nil ? o.focusedCorner.map {
            let point = o.radii.dot(of: $0, in: o.selection!, minimumInset: 8 * scale)
            return CGPath(ellipseIn: CGRect(x: point.x / scale - 5, y: bounds.height - point.y / scale - 5, width: 10, height: 10), transform: nil)
        } : nil
    }
}
