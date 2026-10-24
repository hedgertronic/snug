import AppKit
import ScreenshotCore
import Vision
@preconcurrency import VisionKit

/// Text state shared by both modes: where the "Reading text..." pill centers (image pixels), a dark pill that explains why
/// Option-Return did nothing or names the picked item, Text mode's found items (nil until the first Tab) and the picked one, a key
/// pressed while Vision's warm-up child runs: what the notice says about it and the action that runs once the child exits, Text
/// mode's box with the lines read in it (nil while they are read), and the lines the found-text flash shows (image pixels).
struct TextSession {
    var reading: CGRect?
    var notice: String?
    var items: [FoundItem]?
    var picked: Int?
    var queued: (notice: String, run: @MainActor () -> Void)?
    var box: (rect: CGRect, lines: [TextLine]?)?
    var flash: [CGRect]?
    /// The selection in a terminal's text (an index into `OverlayController.terminals`): where its press began and where it is now.
    var terminalSelection: (terminal: Int, anchor: TerminalText.Position, focus: TerminalText.Position)?
}

/// Live Text's own drag selection is word-granular and anchors at the start of the pressed word, so a drag that goes backward leaves
/// that word out (in the highlight while dragging and after), a drag inside one word selects nothing, and a press on the last few
/// points of a line, just past its last glyph, anchors at the start of all text.
///
/// With real pointer input Live Text's text view holds a press back until the pointer moves or lifts (text.log: `selectedRanges` at
/// mouseDown is still the previous caret or selection), so the anchor comes from the first selection change after the press.
extension OverlayWindow {
    /// Text mode's mouse events: a press up to 16 pt right of text moves onto it and clears the selection, a drag or release off text
    /// moves sideways onto the nearest text on its row, and after Live Text handles each drag event and the release the selection grows
    /// to cover the pressed word (or the word or line a double or triple click picked), which `OverlayController.textSelectionDidChange`
    /// takes from Live Text's first caret or range after the press.
    ///
    /// A press off text past that 16 pt, once the analysis is attached and nothing else is being read, and a press on the box's
    /// handles or inside it off text, never reach Live Text: the controller draws, resizes or moves the box (its selection) as
    /// Capture does. A release within Capture's click size that leaves no box sends the press and the release on to Live Text, as a
    /// click. Any other press clears the box.
    func sendTextMouse(_ event: NSEvent) {
        let view = contentView as! OverlayView
        let controller = view.controller!
        let liveText = view.liveText
        // A press in a terminal's text area, and its drag and release, select in the terminal's text instead of Live Text's.
        if event.type == .leftMouseDown, let terminal = controller.terminal(at: view.pixelPoint(event)) {
            textPress = nil
            liveText.selectedRanges = []
            controller.clearTextBox()
            terminalPress = true
            return controller.pressTerminalText(terminal, event: event)
        }
        if terminalPress {
            terminalPress = event.type != .leftMouseUp
            return controller.dragTerminalText(event)
        }
        if event.type == .leftMouseDown, controller.text.terminalSelection != nil {
            controller.text.terminalSelection = nil
            controller.refresh()
        }
        // `hasText(at:)` takes points from the top-left corner.
        let local = liveText.convert(event.locationInWindow, from: nil)
        let textPoint = CGPoint(x: local.x, y: liveText.bounds.height - local.y)
        var onText = liveText.hasText(at: textPoint)
        var dx: CGFloat?
        if event.type == .leftMouseDown {
            let onLiveText = contentView!.hitTest(event.locationInWindow)?.isDescendant(of: liveText) == true
            let onHandle = controller.selection?.handle(at: view.pixelPoint(event), tolerance: 8 * controller.scale) != nil
            if !onText, !onHandle, onLiveText {
                dx = stride(from: 2.0, through: 16, by: 2).first { liveText.hasText(at: CGPoint(x: textPoint.x - $0, y: textPoint.y)) }.map { -$0 }
            }
            if onHandle || !onText && dx == nil && onLiveText && liveText.analysis != nil && (controller.text.reading == nil || controller.selection != nil) {
                textPress = nil
                textBox = event
                return controller.mouseDown(event)
            }
            controller.clearTextBox()
        } else if let press = textBox {
            guard event.type == .leftMouseUp else { return controller.mouseDragged(event) }
            controller.mouseUp(event)
            textBox = nil
            if controller.selection == nil {
                super.sendEvent(press)
                super.sendEvent(event)
            }
            return
        } else if textPress != nil, !onText {
            // Live Text ends a drag off text on the glyph nearest it anywhere, which right of a short row is a longer row above it, so
            // the rows between would drop out of the selection. It ends a drag inside a word at that word's end, so 8 pt steps (each
            // `hasText` costs 10-30 us) land on the row's last word unless that word is narrower.
            dx = stride(from: 8.0, through: liveText.bounds.width, by: 8).lazy.flatMap { [$0, -$0] }
                .first { (0...liveText.bounds.width).contains(textPoint.x + $0) && liveText.hasText(at: CGPoint(x: textPoint.x + $0, y: textPoint.y)) }
        }
        var event = event
        var snapped = ""
        if let dx {
            event = NSEvent.mouseEvent(with: event.type, location: CGPoint(x: event.locationInWindow.x + dx, y: event.locationInWindow.y),
                                       modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                                       context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)!
            snapped = " moved \(dx) pt onto text"
            onText = true
        }
        if event.type == .leftMouseDown {
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
    /// Analyzes the frozen image for text once per capture and attaches the result; the pill covers the screen until then. Meanwhile
    /// the found-text flash shows where the text is (see `highlightFoundText`).
    func startLiveText() {
        view.liveText.preferredInteractionTypes = .textSelection
        view.liveText.selectableItemsHighlighted = false
        highlightFoundText()
        if let warmUp = Self.visionWarmUp {
            Task {
                await warmUp.value
                if text.notice == Self.warmUpNotice { text.notice = nil }
                refresh()
            }
        }
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
            } catch {
                report(error)
            }
        }
    }

    /// Entering Text mode: the lines fast text recognition reads flash as pills in the highlight color, sweeping in from the top, for
    /// 1.25 s. Text rectangle detection was faster but also boxed icons, avatars and emoji, and the new API's fast recognition reads
    /// nothing on macOS 27, so this is the old API's.
    func highlightFoundText() {
        guard let image else { return }
        foundTextHighlight?.cancel()
        let start = ContinuousClock.now
        foundTextHighlight = Task {
            do {
                let lines = try await Task.detached {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let (width, height) = (CGFloat(image.width), CGFloat(image.height))
                    return request.results!.map { CGRect(x: $0.boundingBox.minX * width, y: (1 - $0.boundingBox.maxY) * height,
                                                         width: $0.boundingBox.width * width, height: $0.boundingBox.height * height) }
                }.value
                try Task.checkCancellation()
                lastFlashMilliseconds = start.duration(to: .now).milliseconds
                text.flash = lines
                refresh()
                try await Task.sleep(for: .seconds(1.25))
                endFoundTextHighlight()
            } catch {
                report(error)
            }
        }
    }

    /// Turns the found-text flash off while it is on; the first press or key does this at once, so it never covers a selection.
    func endFoundTextHighlight() {
        guard let foundTextHighlight else { return }
        foundTextHighlight.cancel()
        self.foundTextHighlight = nil
        text.flash = nil
        refresh()
    }

    /// Drops Text mode's box and stops reading it.
    func clearTextBox() {
        guard selection != nil else { return }
        selection = nil
        if text.box != nil {
            textTask?.cancel()
            text.box = nil
            text.reading = nil
        }
    }

    /// Reads the lines in Text mode's box with accurate OCR, after Vision's warm-up, unless they are read or being read: at once with
    /// the Reading text... pill (a release), or after `delay` without it (a pause in a drag).
    func readTextBox(after delay: Duration = .zero) {
        guard let rect = selection?.rect, let image else { return }
        if text.box?.rect == rect, delay > .zero || text.box?.lines != nil || text.reading != nil { return }
        textTask?.cancel()
        text.box = (rect, nil)
        text.reading = delay == .zero ? rect : nil
        textTask = Task {
            do {
                try await Task.sleep(for: delay)
                await Self.visionWarmUp?.value
                let lines = try await Self.recognize(image, crop: rect)
                try Task.checkCancellation()
                text.box = (rect, lines)
                text.reading = nil
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// With a box: Return copies its lines with soft wraps joined, Shift-Return as a table, Option-Return translates them; lines not
    /// yet read for the box as it is now are read first.
    func copyTextBox(table: Bool, translating: Bool) {
        guard let rect = selection?.rect, let image else { return beep() }
        let read = text.box?.rect == rect ? text.box?.lines : nil
        textTask?.cancel()
        text.reading = read == nil ? rect : nil
        textTask = Task {
            do {
                await Self.visionWarmUp?.value
                let lines = if let read { read } else { try await Self.recognize(image, crop: rect) }
                try Task.checkCancellation()
                text.reading = nil
                let rows = TextLayout.rows(lines)
                let copied = table ? TextLayout.table(rows) : TextLayout.paragraphs(rows)
                let count = copied.split(whereSeparator: \.isNewline).count
                copyText(copied, message: table ? "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")" : "Copied \(count) \(count == 1 ? "line" : "lines")",
                         translating: translating)
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Once per newly built binary, runs this binary with `--warm-vision` as a child process at utility priority, so Vision compiles the
    /// accurate OCR and barcode models that Tab and Shift-Return use into the on-disk cache (35-90 s) before their first use, and the
    /// 50-90 MiB the requests leave behind goes away when the child exits. `defaults` keeps the binary's modification date once the child
    /// exits with status 0. Returns the child, or nil when this binary is already warmed.
    static func warmVisionInChild(defaults: UserDefaults) -> Process? {
        let executable = Bundle.main.executableURL!
        let built = try! executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        guard defaults.object(forKey: Pref.visionWarmedBuild) as? Date != built else { return nil }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--warm-vision"]
        child.qualityOfService = .utility
        child.standardOutput = FileHandle.nullDevice
        // UserDefaults is thread-safe; the termination handler runs on a background thread.
        nonisolated(unsafe) let defaults = defaults
        child.terminationHandler = { child in
            guard child.terminationReason == .exit, child.terminationStatus == 0 else { return }
            defaults.set(built, forKey: Pref.visionWarmedBuild)
        }
        try! child.run()
        watchWarmUp(child)
        return child
    }

    /// Vision's warm-up while its child runs; nil once the child exits, whatever its status.
    static var visionWarmUp: Task<Void, Never>?
    static let warmUpNotice = "Getting text recognition ready. This runs once after each update."

    /// Tracks `child` as Vision's warm-up until it exits, checking every 250 ms.
    static func watchWarmUp(_ child: Process) {
        visionWarmUp = Task {
            while child.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            visionWarmUp = nil
        }
    }

    /// While the warm-up runs, Text mode, or a key waiting for it, shows a notice saying so when no other notice is showing.
    func showWarmUpNotice() {
        guard text.notice == nil, Self.visionWarmUp != nil, mode == .text || text.queued != nil else { return }
        text.notice = text.queued?.notice ?? Self.warmUpNotice
    }

    /// While the warm-up runs, accurate OCR would wait for its compile (35-90 s): queues `action`, named by `key`, to run once the child
    /// exits, says so, and returns true. Returns false when there is no warm-up running.
    private func waitsForWarmUp(_ key: String, _ action: @escaping @MainActor () -> Void) -> Bool {
        guard let warmUp = Self.visionWarmUp else { return false }
        text.queued = ("\(key) will run when text recognition is ready.", action)
        textTask = Task {
            await warmUp.value
            guard let queued = text.queued else { return }
            text.queued = nil
            text.notice = nil
            queued.run()
            refresh()
        }
        return true
    }

    /// The selected text's bounds in view points, nil with nothing selected or an item picked. Live Text's text view (its subview that
    /// is an `NSTextInputClient`) answers `firstRect(forCharacterRange:actualRange:)` for the selected range with the union of the
    /// selected glyphs' boxes, in its own points from the top-left corner (measured on form-test.png), not the first line's screen rect
    /// the protocol names. The text view covers Live Text, which covers the overlay view.
    var textSelectionBox: CGRect? {
        guard text.picked == nil, !view.liveText.selectedText.isEmpty else { return nil }
        func client(in view: NSView) -> NSTextInputClient? { (view as? NSTextInputClient) ?? view.subviews.lazy.compactMap(client).first }
        let selection = client(in: view.liveText)!
        let rect = selection.firstRect(forCharacterRange: selection.selectedRange(), actualRange: nil)
        return CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
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

    /// Puts text on the pasteboard, closes the overlay, and toasts with the text's first line.
    private func deliverText(_ copied: String, message: String) {
        guard !copied.isEmpty else { return beep() }
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
        dismiss()
        Toast.show(message: message, text: copied)
    }

    /// Copies `string`, or with `translating` translates it into the target language and copies the translation.
    func copyText(_ string: String, message: String, translating: Bool) {
        guard translating else { return deliverText(string, message: message) }
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
                    deliverText(translated, message: "Copied \(TextTranslation.name(target)) translation")
                }
            } catch {
                report(error)
            }
        }
    }

    /// Capture, Shift-Return / Option-Return on a released selection (Shift-Return also on the hovered element): reads the text of the
    /// selection or element, then copies it (tab-separated when it has columns) or its translation.
    func copySelectionText(translating: Bool) {
        guard let rect = selection?.rect ?? hoverRect, let image else { return beep() }
        guard !waitsForWarmUp(translating ? "Option-Return" : "Shift-Return", { self.copySelectionText(translating: translating) }) else { return }
        text.reading = rect
        textTask = Task {
            do {
                let rows = TextLayout.rows(try await Self.recognize(image, crop: rect))
                try Task.checkCancellation()
                text.reading = nil
                let table = TextLayout.table(rows)
                let isTable = table.contains("\t") && !translating
                let paragraphs = TextLayout.paragraphs(rows)
                let lines = paragraphs.split(whereSeparator: \.isNewline).count
                copyText(isTable ? table : paragraphs, message: isTable ? "Copied as table, \(rows.count) rows" : "Copied \(lines) \(lines == 1 ? "line" : "lines")",
                         translating: translating)
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Runs accurate OCR on the crop only, in 432 px bands read at once when it is taller than 648 px (`TextLayout.bands`); boxes come
    /// back in full-image pixels.
    @concurrent
    static func recognize(_ image: CGImage, crop: CGRect) async throws -> [TextLine] {
        let region = crop.integral
        let reads = try await withThrowingTaskGroup(of: (band: CGRect, lines: [TextLine]).self) { group in
            for band in TextLayout.bands(region, height: 432) {
                group.addTask {
                    let cropped = image.cropping(to: band)!
                    let size = CGSize(width: cropped.width, height: cropped.height)
                    var request = RecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    return (band, try await ImageRequestHandler(cropped).perform(request).map {
                        TextLine(text: $0.topCandidates(1)[0].string,
                                 bounds: $0.boundingBox.toImageCoordinates(size, origin: .upperLeft).offsetBy(dx: band.minX, dy: band.minY))
                    })
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        return TextLayout.merge(reads, in: region)
    }

    /// Shift-Return: copies the selected text as rows, one visual row per line with columns tab-separated, from accurate OCR boxes
    /// matched to the Live Text selection.
    func copyTextRows() {
        if let lines = terminalLines {
            let rows = TextLayout.rows(lines)
            return copyText(TextLayout.table(rows), message: "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")", translating: false)
        }
        let selected = view.liveText.selectedText
        guard !selected.isEmpty, text.reading == nil, let image else { return beep() }
        guard !waitsForWarmUp("Shift-Return", { self.copyTextRows() }) else { return }
        text.reading = extent
        textTask = Task {
            do {
                let rows = TextLayout.rows(TextLayout.lines(of: selected, in: try await Self.recognize(image, crop: extent)))
                try Task.checkCancellation()
                text.reading = nil
                copyText(TextLayout.table(rows), message: "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")", translating: false)
                refresh()
            } catch {
                report(error)
            }
        }
    }

    /// Return / Cmd-C / Option-Return: copies the selected text, or its translation, as accurate OCR reads the span the selection
    /// covers, with soft wraps joined.
    func copySelectedText(translating: Bool, key: String) {
        if let lines = terminalLines {
            let copied = TextLayout.paragraphs(TextLayout.rows(lines))
            let count = copied.split(whereSeparator: \.isNewline).count
            return copyText(copied, message: "Copied \(count) \(count == 1 ? "line" : "lines")", translating: translating)
        }
        let selected = view.liveText.selectedText
        guard !selected.isEmpty, text.reading == nil, let image else { return beep() }
        guard !waitsForWarmUp(key, { self.copySelectedText(translating: translating, key: key) }) else { return }
        text.reading = extent
        textTask = Task {
            do {
                let lines = TextLayout.selection(selected, in: try await Self.recognize(image, crop: extent))
                try Task.checkCancellation()
                text.reading = nil
                let copied = TextLayout.paragraphs(TextLayout.rows(lines))
                let count = copied.split(whereSeparator: \.isNewline).count
                copyText(copied, message: "Copied \(count) \(count == 1 ? "line" : "lines")", translating: translating)
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
            guard text.reading == nil, let image else { return beep() }
            guard !waitsForWarmUp("Tab", { self.stepItem(backward: backward) }) else { return }
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

    /// With an item picked: Return copies it, Cmd-Return opens it, Esc unpicks. With a box: Esc clears it, and Return, Cmd-C,
    /// Shift-Return and Option-Return copy or translate its lines. Otherwise Esc: close. F: select all text. Return or Cmd-C: copy the
    /// selection with soft wraps joined; Shift-Return: copy it as rows; Option-Return: translate it. Tab / Shift-Tab: step through
    /// found items.
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
                guard let url = item.url else { beep(); break }
                dismiss()
                openURL(url)
            default:
                copyText(item.text, message: "Copied", translating: false)
            }
            return true
        }
        let boxed = selection != nil
        switch (event.keyCode, flags.contains(.command), event.charactersIgnoringModifiers ?? "") {
        case (53, _, _) where boxed:
            clearTextBox()
        case (53, _, _):
            dismiss()
        case (36, _, _) where boxed, (76, _, _) where boxed, (_, true, "c") where boxed:
            copyTextBox(table: flags.contains(.shift) && !flags.contains(.option), translating: flags.contains(.option))
        case (48, false, _):
            stepItem(backward: flags.contains(.shift))
        case (_, false, "f"):
            liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex]
        case (36, false, _) where flags.contains(.shift):
            copyTextRows()
        case (36, _, _), (76, _, _), (_, true, "c"):
            copySelectedText(translating: flags.contains(.option), key: flags.contains(.option) ? "Option-Return" : event.keyCode == 8 ? "Cmd-C" : "Return")
        default:
            return false
        }
        return true
    }
}
