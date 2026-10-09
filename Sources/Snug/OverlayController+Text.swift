import AppKit
import ScreenshotCore
import Vision
@preconcurrency import VisionKit

/// Text state shared by both modes: where the "Reading text..." pill centers (image pixels), a dark pill that explains why
/// Option-Return did nothing or names the picked item, and Text mode's found items (nil until the first Tab) and the picked one.
struct TextSession {
    var reading: CGRect?
    var notice: String?
    var items: [FoundItem]?
    var picked: Int?
}

/// Live Text's own drag selection is word-granular and anchors at the start of the pressed word, so a drag that goes backward leaves
/// that word out (in the highlight while dragging and after), a drag inside one word selects nothing, and a press on the last few
/// points of a line, just past its last glyph, anchors at the start of all text.
///
/// With real pointer input Live Text's text view holds a press back until the pointer moves or lifts (text.log: `selectedRanges` at
/// mouseDown is still the previous caret or selection), so the anchor comes from the first selection change after the press.
extension OverlayWindow {
    /// Text mode's mouse events: a press up to 16 pt right of text moves onto it and clears the selection, and after Live Text handles
    /// each drag event and the release the selection grows to cover the pressed word (or the word or line a double or triple click
    /// picked), which `OverlayController.textSelectionDidChange` takes from Live Text's first caret or range after the press.
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
            if onText { liveText.selectedRanges = [] }
            textPress = onText ? (event.locationInWindow, nil) : nil
        }
        super.sendEvent(event)
        let text = liveText.text
        let raw = liveText.selectedRanges
        switch event.type {
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
            line += " anchor [\(offsets(textPress?.anchor.map { [$0] } ?? []))] build \(built.formatted(.iso8601))"
        }
        if event.type == .leftMouseUp {
            line += " anchor [\(offsets(textPress?.anchor.map { [$0] } ?? []))] selected \(liveText.selectedText.debugDescription)"
        }
        Pref.logHoverLine(line, key: Pref.logText, file: "text.log")
    }
}

/// Text mode is Live Text: the frozen image's text analysis is laid over it, and the user selects text as on a web page.
extension OverlayController: ImageAnalysisOverlayViewDelegate {
    /// Analyzes the frozen image for text once per capture and attaches the result; the pill covers the screen until then.
    func startLiveText() {
        view.liveText.preferredInteractionTypes = .textSelection
        view.liveText.selectableItemsHighlighted = false
        guard let image, view.liveText.analysis == nil else { return }
        text.reading = extent
        textTask = Task {
            do {
                let start = ContinuousClock.now
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode]))
                try Task.checkCancellation()
                lastLiveTextMilliseconds = start.duration(to: .now).milliseconds
                view.liveText.analysis = analysis
                text.reading = nil
                refresh()
                warmVision(image)
            } catch {
                report(error)
            }
        }
    }

    /// The first Text mode of a newly built binary runs Tab's accurate OCR and barcode requests on the frozen image at utility priority,
    /// so Vision compiles its models on device (35-90 s) while the user selects, not in the first Shift-Return or Tab. Text mode, not
    /// launch: the process keeps 35-75 MiB after the requests are released. `defaults` keeps the binary's modification date.
    private func warmVision(_ image: CGImage) {
        let built = try! Bundle.main.executableURL!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        guard visionWarm == nil, defaults.object(forKey: Pref.visionWarmedBuild) as? Date != built else { return }
        visionWarm = Task(priority: .utility) {
            do {
                _ = try await Self.findItems(in: image)
                defaults.set(built, forKey: Pref.visionWarmedBuild)
            } catch {
                report(error)
            }
        }
    }

    /// A click on a highlighted item does not open it behind the overlay; Cmd-Return opens the picked one.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint, forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        analysisType != .dataDetectors
    }

    /// Keys stay with the overlay: Return, Esc, and the mode keys must work after a click moves focus into the text.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool { false }

    /// The first caret or range after a press on text anchors that press: a caret anchors the word it sits before, a range (a double or
    /// triple click's word or line) anchors itself.
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        if let press = window.textPress, press.anchor == nil, let range = overlayView.selectedRanges.first {
            let text = overlayView.text
            var anchor = range
            if range.isEmpty {
                text.enumerateSubstrings(in: range.lowerBound..<text.endIndex, options: .byWords) { _, word, _, stop in
                    anchor = word
                    stop = true
                }
            }
            window.textPress!.anchor = anchor
        }
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

    /// Shift-Return: copies the selected text as rows, one visual row per line with columns tab-separated, from accurate OCR boxes
    /// matched to the Live Text selection.
    func copyTextRows() {
        let selected = view.liveText.selectedText
        guard !selected.isEmpty, text.reading == nil, let image else { return NSSound.beep() }
        text.reading = extent
        textTask = Task {
            do {
                let rows = TextLayout.rows(TextLayout.lines(of: selected, in: try await Self.recognize(image, crop: extent)))
                try Task.checkCancellation()
                text.reading = nil
                copyText(TextLayout.table(rows), message: "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")", translating: false, rect: nil)
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Tab / Shift-Tab: picks the next or previous found item, finding them on the first press. While one is picked, Live Text turns
    /// from text selection to its data detectors and highlights them (links, email addresses, phone numbers, codes).
    func stepItem(backward: Bool) {
        guard let items = text.items else {
            guard text.reading == nil, let image else { return NSSound.beep() }
            text.reading = extent
            textTask = Task {
                do {
                    let items = try await Self.findItems(in: image)
                    try Task.checkCancellation()
                    text.reading = nil
                    text.items = items
                    stepItem(backward: backward)
                    refresh()
                } catch {
                    report(error)
                }
            }
            return
        }
        guard !items.isEmpty else {
            text.notice = "No links, email addresses, phone numbers, or codes here."
            return
        }
        let picked = ((text.picked ?? (backward ? 0 : -1)) + (backward ? -1 : 1) + items.count) % items.count
        text.picked = picked
        view.liveText.preferredInteractionTypes = .dataDetectors
        view.liveText.selectableItemsHighlighted = true
        // Switching away from text selection drops Live Text's focus to the window, where keys would no longer reach the overlay.
        window.makeFirstResponder(view)
        text.notice = "\(items[picked].text)    \u{21A9} copy\(items[picked].url == nil ? "" : "    \u{2318}\u{21A9} open")"
    }

    /// Accurate OCR's links, email addresses and phone numbers (boxed to the matched characters) and barcode payloads, in reading order.
    @concurrent
    static func findItems(in image: CGImage) async throws -> [FoundItem] {
        let size = CGSize(width: image.width, height: image.height)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = ImageRequestHandler(image)
        var items: [FoundItem] = []
        for line in try await handler.perform(request) {
            let candidate = line.topCandidates(1)[0]
            for match in FoundItems.matches(in: candidate.string) {
                let box = candidate.boundingBox(for: match.range)?.boundingBox ?? line.boundingBox
                items.append(FoundItem(text: String(candidate.string[match.range]), url: match.url, bounds: box.toImageCoordinates(size, origin: .upperLeft)))
            }
        }
        for code in try await handler.perform(DetectBarcodesRequest()) {
            guard let payload = code.payloadString else { continue }
            items.append(FoundItem(text: payload, url: URL(string: payload).flatMap { $0.scheme == nil ? nil : $0 },
                                   bounds: code.boundingBox.toImageCoordinates(size, origin: .upperLeft)))
        }
        return FoundItems.readingOrder(items)
    }

    /// With an item picked: Return copies it, Cmd-Return opens it, Esc unpicks. Otherwise Esc: close. F: select all text. Return or
    /// Cmd-C: copy the selection; Shift-Return: copy it as rows; Option-Return: translate it. Tab / Shift-Tab: step through found items.
    func handleTextKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let liveText = view.liveText
        if let picked = text.picked, let item = text.items?[picked], [36, 76, 53].contains(event.keyCode) {
            switch (event.keyCode, flags.contains(.command)) {
            case (53, _):
                text.picked = nil
                liveText.preferredInteractionTypes = .textSelection
                liveText.selectableItemsHighlighted = false
            case (_, true):
                guard let url = item.url else { NSSound.beep(); break }
                dismiss()
                openURL(url)
            default:
                copyText(item.text, message: "Copied", translating: false, rect: item.bounds)
            }
            return true
        }
        switch (event.keyCode, flags.contains(.command), event.charactersIgnoringModifiers ?? "") {
        case (53, _, _):
            dismiss()
        case (48, false, _):
            stepItem(backward: flags.contains(.shift))
        case (_, false, "f"):
            liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex]
        case (36, false, _) where flags.contains(.shift):
            copyTextRows()
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
