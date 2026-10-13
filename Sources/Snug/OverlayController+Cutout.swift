import AppKit
import ScreenshotCore

/// K's cut-out preview, a ghost: checkerboard in the frame, the removed pixels faint over it, the subject on top with its edge outlined in
/// the highlight color.
struct CutoutPreview {
    /// The cut-out area, image pixels.
    var rect: CGRect
    /// The selection K or Esc goes back to; nil when K came from a hover.
    var selection: AreaSelection?
    /// The corner radii of the selection or hovered rectangle, which the output's canvas takes when it is not cropped.
    var radii: CornerRadii
    /// All instances first, then each one alone when there are several.
    var subjects: [CutoutSubject]
    var shown = 0
    /// Whether the output is trimmed to the shown subject's box (S, remembered in `Pref.cutoutCrop`).
    var cropped: Bool
    let view: CutoutView

    /// The output's frame in image pixels: the cut-out area, or the shown subject's box when cropped.
    var frame: CGRect { cropped ? subjects[shown].bounds.offsetBy(dx: rect.minX, dy: rect.minY) : rect }

    /// "Subject" for a single instance, else "All 3 subjects" or "Subject 2 of 3".
    var label: String {
        let count = subjects.count - 1
        return count == 0 ? "Subject" : shown == 0 ? "All \(count) subjects" : "Subject \(shown) of \(count)"
    }
}

/// Covers the overlay below the chrome while the preview is open, so the pointer cannot edit the selection behind it. Its `content`, in
/// the overlay view's layer under the guides so the loupe stays on top, fills the frame with a checkerboard (transparent), draws the
/// frozen image there at 20% (the removed pixels), then the outline (the highlight color through the subject's ring) and the subject's
/// own pixels on top. Outside the frame the overlay's usual dim stays.
final class CutoutView: NSView {
    let content = CALayer()
    let checker = CALayer()
    let ghost = CALayer()
    let outline = CALayer()
    let subject = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        outline.mask = CALayer()
        content.frame = frame
        let tile = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 8, height: 8).fill()
            CGRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        checker.backgroundColor = NSColor(patternImage: tile).cgColor
        ghost.opacity = 0.2
        for sublayer in [checker, ghost, outline, subject] { content.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

extension OverlayController {
    /// Opens the preview of `subjects` over `rect` (image pixels), showing all instances, cropped as last chosen. The selection steps aside
    /// so the action bar and handles go away; K or Esc puts it back.
    func showCutout(_ subjects: [CutoutSubject], in rect: CGRect, radii: CornerRadii) {
        let preview = CutoutView(frame: view.bounds)
        view.addSubview(preview, positioned: .below, relativeTo: chrome.all.first)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer!.insertSublayer(preview.content, below: view.guides.root)
        CATransaction.commit()
        let highlight = view.highlight
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            preview.outline.backgroundColor = (highlight?.color ?? .controlAccentColor).cgColor
        }
        cutout = CutoutPreview(rect: rect, selection: selection, radii: radii, subjects: subjects, cropped: defaults.bool(forKey: Pref.cutoutCrop), view: preview)
        selection = nil
        showCutoutSubject(0)
    }

    private func showCutoutSubject(_ index: Int) {
        cutout!.shown = index
        let preview = cutout!.view
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.checker.frame = view.viewRect(cutout!.frame)
        preview.ghost.frame = preview.checker.frame
        preview.ghost.contents = image!.cropping(to: cutout!.frame)
        preview.outline.frame = view.viewRect(cutout!.rect)
        preview.outline.mask!.frame = preview.outline.bounds
        preview.outline.mask!.contents = cutout!.subjects[index].outline
        preview.subject.frame = preview.outline.frame
        preview.subject.contents = cutout!.subjects[index].image
        CATransaction.commit()
        refresh()
    }

    func closeCutout() {
        cutout?.view.removeFromSuperview()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutout?.view.content.removeFromSuperlayer()
        CATransaction.commit()
        cutout = nil
    }

    /// While the preview is open: Tab / Shift-Tab step through the subjects, S crops to the subject or not, Return copies the shown one,
    /// Cmd-S saves it, C copies the color under the pointer (Shift-C cycles its format), K or Esc go back to the selection or hover it
    /// came from. Other keys do nothing.
    func handleCutoutKey(_ event: NSEvent) -> Bool {
        let preview = cutout!
        switch (event.keyCode, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers ?? "") {
        case (53, _, _), (_, false, "k"):
            closeCutout()
            selection = preview.selection
        case (48, _, _) where preview.subjects.count > 1:
            let count = preview.subjects.count
            showCutoutSubject((preview.shown + (event.modifierFlags.contains(.shift) ? -1 : 1) + count) % count)
        case (_, false, "s"):
            cutout!.cropped.toggle()
            defaults.set(cutout!.cropped, forKey: Pref.cutoutCrop)
            showCutoutSubject(preview.shown)
        case (36, _, _), (76, _, _): deliverCutout(copy: true, save: afterCaptureSaves)
        case (_, true, "s"): deliverCutout(copy: false, save: true)
        case (_, false, "c"): copyColor()
        case (_, false, "C"): cycleColorFormat()
        default: break
        }
        refresh()
        return true
    }

    /// Closes the overlay and delivers the shown subject through the usual copy or save path with the toast: cropped to its box or at
    /// the area's size with its corner radii, then framed or with the window shadow as a capture would be.
    private func deliverCutout(copy: Bool, save: Bool) {
        let preview = cutout!
        let subject = preview.subjects[preview.shown]
        let (bounds, radii) = (preview.cropped ? subject.bounds : nil, preview.radii)
        let (framed, shadow, scale) = (framed, defaults.bool(forKey: Pref.shadow), scale)
        let (pasteboard, defaults) = (pasteboard, defaults)
        dismiss()
        commitTask = Task {
            do {
                let output = try await Output.encodeCutout(subject.image, bounds: bounds, cornerRadii: radii, framed: framed, shadow: shadow, scale: scale)
                try Output.publish(png: output.png, detail: "\(output.width) x \(output.height)  cut out", copy: copy, save: save,
                                   pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }
}
