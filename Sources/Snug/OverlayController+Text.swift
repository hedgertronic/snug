import AppKit
import ScreenshotCore
import Vision
@preconcurrency import VisionKit

/// Text state shared by both modes: where the "Reading text..." pill centers (image pixels) and a dark pill that explains why
/// Option-Return did nothing.
struct TextSession {
    var reading: CGRect?
    var notice: String?
}

/// Live Text's own drag selection is word-granular and anchors at the start of the pressed word, so a drag that goes backward leaves
/// that word out (in the highlight while dragging and after), a drag inside one word selects nothing, and a press on the last few
/// points of a line, just past its last glyph, anchors at the start of all text.
extension OverlayWindow {
    /// Text mode's mouse events: a press up to 16 pt right of text moves onto it, and after Live Text handles each drag event and the
    /// release the selection grows to cover the pressed word (or the word or line a double or triple click picked).
    func sendTextMouse(_ event: NSEvent) {
        let liveText = (contentView as! OverlayView).liveText
        var event = event
        var snapped = ""
        var onText = false
        if event.type == .leftMouseDown {
            // `hasText(at:)` takes points from the top-left corner.
            let local = liveText.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x, y: liveText.bounds.height - local.y)
            onText = liveText.hasText(at: point)
            if !onText, contentView!.hitTest(event.locationInWindow)?.isDescendant(of: liveText) == true,
               let dx = stride(from: 2.0, through: 16, by: 2).first(where: { liveText.hasText(at: CGPoint(x: point.x - $0, y: point.y)) }) {
                event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: event.locationInWindow.x - dx, y: event.locationInWindow.y),
                                           modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                                           context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)!
                snapped = " moved \(-dx) pt onto text"
                onText = true
            }
        }
        super.sendEvent(event)
        let text = liveText.text
        let raw = liveText.selectedRanges
        switch event.type {
        case .leftMouseDown:
            var anchor = raw.first.flatMap { $0.isEmpty ? nil : $0 }
            if onText, event.clickCount == 1, let caret = raw.first?.lowerBound {
                text.enumerateSubstrings(in: caret..<text.endIndex, options: .byWords) { _, word, _, stop in
                    anchor = word
                    stop = true
                }
            }
            textPress = (event.locationInWindow, onText ? anchor : nil)
        case .leftMouseDragged, .leftMouseUp:
            guard let press = textPress, let anchor = press.anchor, raw.count <= 1,
                  hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y) >= 3 else { break }
            let range = raw.first ?? anchor
            let grown = min(range.lowerBound, anchor.lowerBound)..<max(range.upperBound, anchor.upperBound)
            if grown != range || raw.isEmpty { liveText.selectedRanges = [grown] }
        default:
            break
        }
        guard UserDefaults.standard.bool(forKey: Pref.logText) else { return }
        func offsets(_ ranges: [Range<String.Index>]) -> String {
            ranges.map { "\(text.distance(from: text.startIndex, to: $0.lowerBound))..<\(text.distance(from: text.startIndex, to: $0.upperBound))" }
                .joined(separator: ",")
        }
        let point = event.locationInWindow
        var line = "\(event.type == .leftMouseDown ? "down" : event.type == .leftMouseUp ? "up" : "drag") clicks \(event.clickCount)"
            + " at \(Int(point.x)),\(Int(point.y))\(snapped) live text [\(offsets(raw))] now [\(offsets(liveText.selectedRanges))]"
        if event.type == .leftMouseDown {
            let built = try! Bundle.main.executableURL!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            line += " anchor [\(offsets(textPress!.anchor.map { [$0] } ?? []))] build \(built.formatted(.iso8601))"
        }
        if event.type == .leftMouseUp { line += " selected \(liveText.selectedText.debugDescription)" }
        Pref.logHoverLine(line, key: Pref.logText, file: "text.log")
    }
}

/// Text mode is Live Text: the frozen image's text analysis is laid over it, and the user selects text as on a web page.
extension OverlayController: ImageAnalysisOverlayViewDelegate {
    /// Analyzes the frozen image for text once per capture and attaches the result; the pill covers the screen until then.
    func startLiveText() {
        guard let image, view.liveText.analysis == nil else { return }
        text.reading = extent
        textTask = Task {
            do {
                let start = ContinuousClock.now
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration(.text))
                try Task.checkCancellation()
                lastLiveTextMilliseconds = start.duration(to: .now).milliseconds
                view.liveText.analysis = analysis
                text.reading = nil
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Keys stay with the overlay: Return, Esc, and the mode keys must work after a click moves focus into the text.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool { false }

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        text.notice = nil
        refresh()
    }

    /// Puts text on the pasteboard, closes the overlay, and toasts, with a thumbnail of `rect` when there is one.
    private func deliverText(_ copied: String, message: String, detail: String = "", rect: CGRect?) {
        guard !copied.isEmpty, let image else { return NSSound.beep() }
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
        guard let rect else {
            dismiss()
            return Toast.show(message: message, detail: detail)
        }
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

    /// Copies `string`, or with `translating` translates it into the target language and copies the translation.
    func copyText(_ string: String, message: String, translating: Bool, rect: CGRect?) {
        guard translating else { return deliverText(string, message: message, rect: rect) }
        guard let source = TextTranslation.language(of: string) else {
            text.notice = "Could not tell the language of this text."
            return refresh()
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

    /// Capture, Shift-Return / Option-Return on a released selection: reads its text, then copies it (tab-separated when it has
    /// columns) or its translation.
    func copySelectionText(translating: Bool) {
        guard let rect = selection?.rect, let image else { return }
        text.reading = rect
        textTask = Task {
            do {
                let rows = TextLayout.rows(try await Self.recognize(image, crop: rect))
                try Task.checkCancellation()
                text.reading = nil
                let table = TextLayout.table(rows)
                let isTable = table.contains("\t") && !translating
                let lines = "\(rows.count) \(rows.count == 1 ? "line" : "lines")"
                copyText(isTable ? table : TextLayout.readingOrder(rows), message: isTable ? "Copied as table, \(rows.count) rows" : "Copied \(lines)",
                         translating: translating, rect: rect)
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Runs accurate OCR on the crop only; boxes come back in full-image pixels.
    @concurrent
    static func recognize(_ image: CGImage, crop: CGRect) async throws -> [TextLine] {
        let region = crop.integral
        let cropped = image.cropping(to: region)!
        let size = CGSize(width: cropped.width, height: cropped.height)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return try await ImageRequestHandler(cropped).perform(request).map {
            TextLine(text: $0.topCandidates(1)[0].string,
                     bounds: $0.boundingBox.toImageCoordinates(size, origin: .upperLeft).offsetBy(dx: region.minX, dy: region.minY))
        }
    }

    /// Esc: close. F: select all text. Return or Cmd-C: copy the selection; Option-Return: translate it.
    func handleTextKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let liveText = view.liveText
        switch (event.keyCode, flags.contains(.command), event.charactersIgnoringModifiers ?? "") {
        case (53, _, _):
            dismiss()
        case (_, false, "f"):
            liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex]
        case (36, _, _), (76, _, _), (_, true, "c"):
            let selected = liveText.selectedText
            guard !selected.isEmpty else { NSSound.beep(); break }
            let lines = selected.split(whereSeparator: \.isNewline).count
            copyText(selected, message: "Copied \(lines) \(lines == 1 ? "line" : "lines")", translating: flags.contains(.option), rect: nil)
        default:
            return false
        }
        return true
    }
}
