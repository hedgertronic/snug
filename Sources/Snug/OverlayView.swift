import AppKit
import ScreenshotCore
import VisionKit

/// Layer-backed view: the frozen image sits in one layer, set once; everything else is a shape layer.
@MainActor
final class OverlayView: NSView {
    /// Overlay geometry in image pixels with a top-left origin.
    struct Overlays {
        var selection, ghost, preview, hover, styleFrame: CGRect?
        /// Sides a resize snapped to, as zero-width or zero-height rectangles.
        var snappedEdges: [CGRect] = []
        var showsHandles = false
        /// Corner radii in image pixels of the selection (or the snap preview when there is no selection), and of the hovered rectangle.
        var radii = CornerRadii.zero
        var hoverRadii = CornerRadii.zero
    }

    weak var controller: OverlayController?
    /// Image pixels per point.
    var scale: CGFloat = 1
    var image: CGImage? { didSet { imageLayer.contents = image } }
    var overlays = Overlays() { didSet { layoutOverlays() } }
    /// The cursor over the whole overlay; the controller picks it from the pointer and the interaction.
    var cursor = NSCursor.crosshair {
        didSet { if cursor !== oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// Text mode's Live Text: selectable text laid exactly over the frozen image, shown only in Text mode.
    let liveText = ImageAnalysisOverlayView()
    let guides = Guides()
    private let imageLayer = CALayer()
    let dimLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let styleLayer = CAShapeLayer()
    private let ghostLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let snappedLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.addSublayer(imageLayer)
        for shape in [dimLayer, hoverLayer, styleLayer, ghostLayer, outlineLayer, previewLayer, snappedLayer, handlesLayer] {
            shape.fillColor = nil
            layer!.addSublayer(shape)
        }
        layer!.addSublayer(guides.root)
        liveText.preferredInteractionTypes = .textSelection
        // No Live Text button in the corner: Text mode is already the text view.
        liveText.isSupplementaryInterfaceHidden = true
        liveText.isHidden = true
        addSubview(liveText)
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimLayer.fillRule = .evenOdd
        styleLayer.strokeColor = NSColor.white.cgColor
        styleLayer.lineDashPattern = [5, 4]
        ghostLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outlineLayer.lineWidth = 2
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1.5
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
    override func keyDown(with event: NSEvent) { if controller?.handleKey(event) != true { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { controller?.keyUp(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && controller?.handleKey(event) == true
    }

    private func applyAccent() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            hoverLayer.strokeColor = accent.cgColor
            hoverLayer.fillColor = accent.withAlphaComponent(0.08).cgColor
            hoverLayer.lineWidth = 2
            previewLayer.strokeColor = accent.cgColor
            previewLayer.lineWidth = 2
            snappedLayer.strokeColor = accent.cgColor
            snappedLayer.lineWidth = 4
            outlineLayer.strokeColor = accent.cgColor
            handlesLayer.strokeColor = accent.cgColor
        }
    }

    private func layoutOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let o = overlays
        func path(_ rect: CGRect, radii: CornerRadii = .zero) -> CGPath {
            radii.scaled(by: 1 / scale).path(in: viewRect(rect))
        }
        let dim = CGMutablePath()
        if let cutout = o.selection ?? o.preview ?? o.ghost {
            dim.addRect(bounds)
            dim.addPath(path(cutout, radii: o.radii))
        } else if let hover = o.hover {
            dim.addRect(bounds)
            dim.addPath(path(hover, radii: o.hoverRadii))
        }
        dimLayer.path = dim
        hoverLayer.path = o.hover.map { path($0, radii: o.hoverRadii) }
        styleLayer.path = o.styleFrame.map { path($0) }
        ghostLayer.path = o.ghost.map { path($0) }
        outlineLayer.path = o.selection.map { path($0, radii: o.radii) }
        previewLayer.path = o.preview.map { path($0, radii: o.radii) }
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
    }
}
