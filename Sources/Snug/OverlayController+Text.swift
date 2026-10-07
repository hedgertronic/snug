import AppKit
import ScreenshotCore
import Vision

/// Text mode state: the drag or handle edit in progress, the released region, its OCR result, and the picked found item.
struct TextSession {
    enum Edit {
        case resizing(Handle)
        case moving(last: CGPoint, moved: Bool)
    }

    var drag: AreaDrag?
    var edit: Edit?
    /// The press landed with a region on screen, so a click without a drag only clears it.
    var hadRegion = false
    /// A dark pill that explains why Option-Return did nothing.
    var notice: String?
    var rect: CGRect?
    /// Where a click with no region is waiting on the whole-page OCR.
    var reading: CGPoint?
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
        lines.fillColor = accent.withAlphaComponent(0.18).cgColor
        lines.strokeColor = accent.cgColor
        lines.lineWidth = 1
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
        for rect in rects { path.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 4) }
        lines.path = path
        pick.path = rect.map { CGPath(rect: $0, transform: nil) }
    }
}

typealias TextResult = (lines: [TextLine], items: [FoundItem])

extension OverlayController {
    func textMouseDown(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        text.notice = nil
        if let rect = text.rect {
            if let handle = AreaSelection(extent: extent, exact: rect).handle(at: point, tolerance: 8 * scale) {
                text.edit = .resizing(handle)
                return
            }
            if rect.contains(point) {
                text.edit = .moving(last: point, moved: false)
                return
            }
        }
        let hadRegion = text.rect != nil
        cancelWork()
        text = TextSession(drag: AreaDrag(extent: extent, origin: point), hadRegion: hadRegion)
        refresh()
    }

    func textMouseDragged(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        pointer = point
        switch text.edit {
        case .resizing(let handle):
            var selection = AreaSelection(extent: extent, exact: text.rect!)
            selection.resize(handle, to: point)
            setTextRegion(selection.rect)
        case .moving(let last, _):
            var selection = AreaSelection(extent: extent, exact: text.rect!)
            selection.move(by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            text.edit = .moving(last: point, moved: true)
            setTextRegion(selection.rect)
        case nil:
            text.drag?.update(to: point, moving: spaceHeld)
        }
        refresh()
    }

    func textMouseUp(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        if let edit = text.edit {
            text.edit = nil
            if case .moving(_, false) = edit {
                copyText(translating: false)
            } else if text.result == nil {
                recognizeRegion()
            }
            return refresh()
        }
        guard var drag = text.drag else { return }
        drag.update(to: point, moving: false)
        text.drag = nil
        let rect = drag.rect
        if rect.width >= AreaSelection.minimumSize && rect.height >= AreaSelection.minimumSize {
            setTextRegion(rect)
            recognizeRegion()
        } else if !text.hadRegion {
            copyBlock(at: point)
        }
        refresh()
    }

    /// Replaces the region; the old result and OCR no longer describe it.
    private func setTextRegion(_ rect: CGRect) {
        textTask?.cancel()
        textTask = nil
        text.rect = rect
        text.result = nil
        text.picked = nil
    }

    /// OCRs the region after a short pause; a newer edit cancels it. The whole screen reuses the one-per-session page result.
    private func recognizeRegion() {
        guard let rect = text.rect, let image else { return }
        textTask?.cancel()
        textTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = rect == extent ? try await pageText().value : try await Self.recognize(image, crop: rect)
                try Task.checkCancellation()
                text.result = result
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// The whole frozen image, recognized once per capture and only when first needed.
    private func pageText() -> Task<TextResult, any Error> {
        if let textPage { return textPage }
        let image = image!, extent = extent
        let task = Task { try await Self.recognize(image, crop: extent) }
        textPage = task
        return task
    }

    /// A click with no region: copies the text block under the pointer.
    private func copyBlock(at point: CGPoint) {
        text.reading = point
        textTask = Task {
            defer {
                if !Task.isCancelled {
                    text.reading = nil
                    refresh()
                }
            }
            do {
                let page = try await pageText().value
                try Task.checkCancellation()
                let block = TextLayout.block(at: point, in: page.lines)
                guard !block.isEmpty else { return NSSound.beep() }
                let rows = TextLayout.rows(block)
                deliverText(TextLayout.readingOrder(rows), message: "Copied \(rows.count) \(rows.count == 1 ? "line" : "lines")",
                            rect: block.dropFirst().reduce(block[0].bounds) { $0.union($1.bounds) })
            } catch {
                report(error)
            }
        }
    }

    /// Puts text on the pasteboard, closes the overlay, and toasts with a thumbnail of `rect`.
    private func deliverText(_ copied: String, message: String, detail: String = "", rect: CGRect) {
        guard !copied.isEmpty, let image else { return NSSound.beep() }
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
        let scale = scale
        dismiss()
        commitTask = Task {
            do {
                let png = try await Output.encode(image, crop: rect, style: .tight, scale: scale).png
                Toast.show(png: png, message: message, detail: detail, file: nil)
            } catch {
                report(error)
            }
        }
    }

    /// Copies, or with `translating` translates and copies, the picked item or the region's text.
    private func copyText(translating: Bool, asTable: Bool = false) {
        guard let result = text.result, let rect = text.rect else { return NSSound.beep() }
        let rows = TextLayout.rows(result.lines)
        let string: String, message: String
        if let picked = text.picked {
            string = result.items[picked].text
            message = "Copied \(result.items[picked].kind.rawValue)"
        } else if asTable {
            string = TextLayout.table(rows)
            message = "Copied as table, \(rows.count) rows"
        } else {
            string = TextLayout.readingOrder(rows)
            message = "Copied \(rows.count) lines"
        }
        guard translating else { return deliverText(string, message: message, rect: rect) }
        guard let source = TextTranslation.language(of: string) else {
            text.notice = "Could not tell the language of this text."
            return
        }
        let target = targetLanguage
        textTask = Task {
            do {
                let status = await translationStatus(source, target)
                switch TextTranslation.plan(source: source, target: target, status: status) {
                case .sameLanguage(let notice), .unavailable(let notice):
                    text.notice = notice
                    refresh()
                case .translate:
                    let translated = try await translate(string, source, target)
                    try Task.checkCancellation()
                    deliverText(translated, message: "Copied translation", detail: TextTranslation.name(target), rect: rect)
                }
            } catch {
                report(error)
            }
        }
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

    /// Esc: back to the whole text, then close. Tab / Shift-Tab: step through found items. F: all text on screen.
    /// Arrows nudge the region (Shift: 10 pt); Space while dragging moves it.
    /// Return: copy; Shift-Return: copy as a table; Option-Return: translate; Cmd-Return: open the picked item's link.
    func handleTextKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        text.notice = nil
        switch event.keyCode {
        case 53:
            if text.picked == nil { dismiss() } else { text.picked = nil }
        case 49:
            spaceHeld = true
        case 3 where !flags.contains(.command):
            cancelWork()
            setTextRegion(extent)
            recognizeRegion()
        case 123...126 where text.rect != nil:
            let step = (flags.contains(.shift) ? 10 : 1) * scale
            let delta = switch event.keyCode {
            case 123: CGPoint(x: -step, y: 0)
            case 124: CGPoint(x: step, y: 0)
            case 125: CGPoint(x: 0, y: step)
            default: CGPoint(x: 0, y: -step)
            }
            var selection = AreaSelection(extent: extent, exact: text.rect!)
            selection.move(by: delta)
            setTextRegion(selection.rect)
            recognizeRegion()
        case 48:
            let count = text.result?.items.count ?? 0
            guard count > 0 else { break }
            let step = flags.contains(.shift) ? -1 : 1
            text.picked = text.picked.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        case 36, 76:
            if flags.contains(.command) {
                guard let result = text.result, let url = text.picked.flatMap({ result.items[$0].url }) else { NSSound.beep(); break }
                openURL(url)
                dismiss()
            } else {
                copyText(translating: flags.contains(.option), asTable: flags.contains(.shift))
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
        overlays.showsHandles = text.rect != nil
        view.overlays = overlays
        view.textOverlay.show(lines: text.result?.lines.map { view.viewRect($0.bounds) } ?? [],
                              pick: text.picked.map { view.viewRect(text.result!.items[$0].bounds) })
        refreshExtras()
    }
}
