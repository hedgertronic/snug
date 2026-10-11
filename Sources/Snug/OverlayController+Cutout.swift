import AppKit
import ScreenshotCore

/// K's cut-out preview: the subject shown in place of the selection, over a checkerboard where the cutout is transparent.
struct CutoutPreview {
    /// The cut-out area, image pixels.
    var rect: CGRect
    /// The selection K or Esc goes back to; nil when K came from a hover.
    var selection: AreaSelection?
    /// All instances first, then each one alone when there are several.
    var subjects: [CutoutSubject]
    var shown = 0
    let view: CutoutView

    /// "Subject" for a single instance, else "All 3 subjects" or "Subject 2 of 3".
    var label: String {
        let count = subjects.count - 1
        return count == 0 ? "Subject" : shown == 0 ? "All \(count) subjects" : "Subject \(shown) of \(count)"
    }
}

/// Covers the overlay below the chrome while the preview is open, so the pointer cannot edit the selection behind it, and draws the
/// shown subject over a checkerboard in the cut-out area.
final class CutoutView: NSView {
    let checker = CALayer()
    let subject = CALayer()

    /// 8 pt squares of light and mid gray.
    private static let checkerboard = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { _ in
        NSColor(white: 0.92, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSColor(white: 0.62, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 8, height: 8).fill()
        CGRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        checker.backgroundColor = NSColor(patternImage: Self.checkerboard).cgColor
        layer!.addSublayer(checker)
        layer!.addSublayer(subject)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

extension OverlayController {
    /// Opens the preview of `subjects` over `rect` (image pixels), showing all instances. The selection steps aside so the action bar and
    /// handles go away; K or Esc puts it back.
    func showCutout(_ subjects: [CutoutSubject], in rect: CGRect) {
        let preview = CutoutView(frame: view.bounds)
        view.addSubview(preview, positioned: .below, relativeTo: chrome.all.first)
        cutout = CutoutPreview(rect: rect, selection: selection, subjects: subjects, view: preview)
        selection = nil
        showCutoutSubject(0)
    }

    private func showCutoutSubject(_ index: Int) {
        cutout!.shown = index
        let preview = cutout!.view
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.checker.frame = view.viewRect(cutout!.rect)
        preview.subject.frame = preview.checker.frame
        preview.subject.contents = cutout!.subjects[index].preview
        CATransaction.commit()
        refresh()
    }

    func closeCutout() {
        cutout?.view.removeFromSuperview()
        cutout = nil
    }

    /// While the preview is open: Tab / Shift-Tab step through the subjects, Return copies the shown one, Cmd-S saves it, K or Esc go
    /// back to the selection or hover it came from. Other keys do nothing.
    func handleCutoutKey(_ event: NSEvent) -> Bool {
        let preview = cutout!
        switch (event.keyCode, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers ?? "") {
        case (53, _, _), (_, false, "k"):
            closeCutout()
            selection = preview.selection
        case (48, _, _) where preview.subjects.count > 1:
            let count = preview.subjects.count
            showCutoutSubject((preview.shown + (event.modifierFlags.contains(.shift) ? -1 : 1) + count) % count)
        case (36, _, _), (76, _, _): deliverCutout(copy: true, save: afterCaptureSaves)
        case (_, true, "s"): deliverCutout(copy: false, save: true)
        default: break
        }
        refresh()
        return true
    }

    /// Closes the overlay and delivers the shown subject, cropped to its extent, through the usual copy or save path with the toast.
    private func deliverCutout(copy: Bool, save: Bool) {
        let output = cutout!.subjects[cutout!.shown].output
        let (pasteboard, defaults) = (pasteboard, defaults)
        dismiss()
        commitTask = Task {
            do {
                try Output.publish(png: try await Output.png(output), detail: "\(output.width) x \(output.height)  cut out", copy: copy, save: save,
                                   pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }
}
