import AppKit
import ScreenshotCore
import Vision

/// Text mode state: the drag in progress, the released region, its OCR result, and the picked found item.
struct TextSession {
    var drag: AreaDrag?
    var rect: CGRect?
    var result: (lines: [TextLine], items: [FoundItem])?
    var picked: Int?
}

/// Faint boxes around recognized lines and a stronger box around the picked found item.
@MainActor
final class TextOverlay {
    let layer = CALayer()
    private let lines = CAShapeLayer()
    private let pick = CAShapeLayer()

    init() {
        let accent = NSColor.controlAccentColor
        lines.fillColor = accent.withAlphaComponent(0.12).cgColor
        lines.strokeColor = accent.withAlphaComponent(0.6).cgColor
        pick.fillColor = accent.withAlphaComponent(0.3).cgColor
        pick.strokeColor = accent.cgColor
        pick.lineWidth = 2
        layer.addSublayer(lines)
        layer.addSublayer(pick)
    }

    /// Takes view-space rectangles.
    func show(lines rects: [CGRect], pick rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.isHidden = false
        let path = CGMutablePath()
        path.addRects(rects)
        lines.path = path
        pick.path = rect.map { CGPath(rect: $0, transform: nil) }
    }
}

extension OverlayController {
    func textMouseDown(_ event: NSEvent) {
        cancelWork()
        text = TextSession(drag: AreaDrag(extent: extent, origin: view.pixelPoint(event)))
        refresh()
    }

    func textMouseDragged(_ event: NSEvent) {
        text.drag?.update(to: view.pixelPoint(event), moving: false)
        refresh()
    }

    func textMouseUp(_ event: NSEvent) {
        guard var drag = text.drag else { return }
        drag.update(to: view.pixelPoint(event), moving: false)
        text.drag = nil
        let rect = drag.rect
        if rect.width >= AreaSelection.minimumSize && rect.height >= AreaSelection.minimumSize, let image {
            text.rect = rect
            textTask = Task {
                do {
                    let result = try await Self.recognize(image, crop: rect)
                    try Task.checkCancellation()
                    text.result = result
                    refresh()
                } catch {
                    report(error)
                }
            }
        }
        refresh()
    }

    /// Runs OCR and barcode detection on the crop only; boxes come back in full-image pixels.
    @concurrent
    private static func recognize(_ image: CGImage, crop: CGRect) async throws -> (lines: [TextLine], items: [FoundItem]) {
        let region = crop.integral
        let cropped = image.cropping(to: region)!
        let size = CGSize(width: cropped.width, height: cropped.height)
        func inImage(_ box: NormalizedRect) -> CGRect {
            box.toImageCoordinates(size, origin: .upperLeft).offsetBy(dx: region.minX, dy: region.minY)
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = ImageRequestHandler(cropped)
        let lines = try await handler.perform(request).map {
            TextLine(text: $0.topCandidates(1)[0].string, bounds: inImage($0.boundingBox))
        }
        let barcodes = try await handler.perform(DetectBarcodesRequest()).compactMap { observation in
            observation.payloadString.map {
                FoundItem(kind: .barcode, text: $0, bounds: inImage(observation.boundingBox), url: TextLayout.openable(URL(string: $0)))
            }
        }
        return (lines, try TextLayout.foundItems(in: lines) + barcodes)
    }

    /// Esc: back to the whole text, then close. Tab / Shift-Tab: step through found items.
    /// Return: copy; Shift-Return: copy as a table; Cmd-Return: open the picked item's link.
    func handleTextKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 53:
            if text.picked == nil { dismiss() } else { text.picked = nil }
        case 48:
            let count = text.result?.items.count ?? 0
            guard count > 0 else { break }
            let step = flags.contains(.shift) ? -1 : 1
            text.picked = text.picked.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        case 36, 76:
            guard let result = text.result, let rect = text.rect, let image else { NSSound.beep(); break }
            if flags.contains(.command) {
                guard let url = text.picked.flatMap({ result.items[$0].url }) else { NSSound.beep(); break }
                openURL(url)
                dismiss()
                break
            }
            let rows = TextLayout.rows(result.lines)
            let copied: String, message: String
            if let picked = text.picked {
                copied = result.items[picked].text
                message = "Copied \(result.items[picked].kind.rawValue)"
            } else if flags.contains(.shift) {
                copied = TextLayout.table(rows)
                message = "Copied as table, \(rows.count) rows"
            } else {
                copied = TextLayout.readingOrder(rows)
                message = "Copied \(rows.count) lines"
            }
            guard !copied.isEmpty else { NSSound.beep(); break }
            pasteboard.clearContents()
            pasteboard.setString(copied, forType: .string)
            let scale = scale
            dismiss()
            commitTask = Task {
                do {
                    let png = try await Output.encode(image, crop: rect, style: .tight, scale: scale).png
                    Toast.show(png: png, message: message, file: nil)
                } catch {
                    report(error)
                }
            }
        default:
            return false
        }
        return true
    }

    func refreshText() {
        var overlays = OverlayView.Overlays()
        if let drag = text.drag, drag.rect.width > 0 || drag.rect.height > 0 { overlays.ghost = drag.rect }
        overlays.selection = text.rect
        view.overlays = overlays
        view.textOverlay.show(lines: text.result?.lines.map { view.viewRect($0.bounds) } ?? [],
                              pick: text.picked.map { view.viewRect(text.result!.items[$0].bounds) })
        refreshExtras()
    }
}
