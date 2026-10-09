import AppKit
import ScreenshotCore
import CoreImage.CIFilterBuiltins
import Translation
import Vision

extension DebugRun {
    /// `--verify-text-ui`: drives Live Text in Text mode and Capture's Shift-Return through synthesized events on form-test.png.
    static func verifyText(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        try await warmVision(image)
        _ = privateSetup(overlay)
        let pasteboard = overlay.pasteboard
        let liveText = overlay.view.liveText
        var passed: [String] = []
        var suffix = ""

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Text UI verification failed: \(message)\(suffix)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message + suffix)
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<10000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            require(condition(), message)
        }
        func windowPoint(_ pixel: CGPoint) -> CGPoint {
            CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: windowPoint(pixel), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!)
        }
        /// A press inside text, ten drag steps, and a release, as a pointer would send them. A press outside text selects nothing.
        func textDrag(from start: CGPoint, to end: CGPoint) {
            mouse(.leftMouseDown, start)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            mouse(.leftMouseUp, end)
        }
        func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        let returnKey: UInt16 = 36, escape: UInt16 = 53, tKey: UInt16 = 17, fKey: UInt16 = 3, cKey: UInt16 = 8, aKey: UInt16 = 0
        // Line boxes on form-test.png, image pixels (accurate OCR).
        let productName = CGRect(x: 1688, y: 414, width: 213, height: 37)
        let billing = CGRect(x: 342, y: 308, width: 316, height: 53)
        let blank = CGPoint(x: 1000, y: 1150)
        let cart = CGRect(x: 1645, y: 384, width: 582, height: 557)
        let email = CGRect(x: 326, y: 800, width: 660, height: 70)

        func textView(in view: NSView) -> NSView? {
            view.gestureRecognizers.contains { "\(type(of: $0))" == "NSImmediateActionGestureRecognizer" } ? view : view.subviews.lazy.compactMap(textView).first
        }
        let hold = HeldPress()
        func open() async throws {
            overlay.present(image: image, frame: frame, displayID: nil)
            key(tKey, "t")
            try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
            let selectionView = textView(in: liveText)!
            if !selectionView.gestureRecognizers.contains(hold) { selectionView.addGestureRecognizer(hold) }
        }
        func copied() async -> String? {
            await overlay.commitTask?.value
            return pasteboard.string(forType: .string)
        }

        // Entering Text mode starts the analysis; the pill covers the wait.
        overlay.present(image: image, frame: frame, displayID: nil)
        require(overlay.mode == .capture && liveText.isHidden && liveText.analysis == nil, "the overlay opens in Capture with Live Text hidden and nothing analyzed")
        key(tKey, "t")
        require(overlay.mode == .text && !liveText.isHidden, "T enters Text mode and shows Live Text")
        require(texts(in: overlay.chrome.hints) == ["Drag", "select text", "\u{21A9}", "copy", "\u{21E7}", "\u{21A9}", "rows", "Tab", "links, codes", "\u{2325}", "\u{21A9}", "translate", "F", "all text", "C", "color", "?", "all keys"],
                "Text mode shows its hint row: \(texts(in: overlay.chrome.hints))")
        require(!overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."], "a Reading text... pill shows while the analysis runs")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        print("Live Text analysis: \(String(format: "%.1f", overlay.lastLiveTextMilliseconds)) ms (first in this process)")
        require(overlay.chrome.reading.isHidden, "the Reading text... pill goes away when the analysis attaches")
        let built = try Bundle.main.executableURL!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        require(overlay.visionWarm != nil && overlay.defaults.object(forKey: Pref.visionWarmedBuild) == nil, "the first Text mode of a new binary starts the Vision warm-up")
        await overlay.visionWarm!.value
        require(overlay.defaults.object(forKey: Pref.visionWarmedBuild) as? Date == built, "the warm-up records the binary's date when it finishes")
        require(liveText.frame == overlay.view.bounds && liveText.superview === overlay.view, "Live Text covers the frozen image exactly")
        require(liveText.isSupplementaryInterfaceHidden, "no Live Text button sits in the corner")
        require(liveText.text.contains("Product name") && liveText.text.contains("Billing address"), "the analysis reads the screen's text")
        let textPoint = windowPoint(CGPoint(x: productName.midX, y: productName.midY))
        func topLeft(_ pixel: CGPoint) -> CGPoint { CGPoint(x: pixel.x / overlay.scale, y: pixel.y / overlay.scale) }
        require(liveText.hasText(at: topLeft(CGPoint(x: productName.midX, y: productName.midY))) && !liveText.hasText(at: topLeft(blank))
                && !liveText.hasText(at: topLeft(CGPoint(x: productName.midX, y: productName.maxY + 45))), "Live Text's text sits under the same pixels as the image")
        require(overlay.view.hitTest(textPoint)?.isDescendant(of: liveText) == true, "a press on the image reaches Live Text")
        let button = overlay.chrome.bottomBar.modeButtons[.capture]!
        let buttonPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: overlay.view)
        require(overlay.view.hitTest(buttonPoint)?.isDescendant(of: button) == true, "the bottom bar stays clickable above Live Text")
        mouse(.mouseMoved, CGPoint(x: productName.midX, y: productName.midY))
        require(overlay.view.cursor == .iBeam, "the cursor is an I-beam over text")
        mouse(.mouseMoved, blank)
        require(overlay.view.cursor == .arrow, "the cursor is an arrow away from text")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(overlay.window.isVisible && pasteboard.string(forType: .string) == nil, "Return with nothing selected copies nothing and keeps the overlay open")
        overlay.dismiss()
        require(liveText.analysis == nil, "closing drops the analysis")
        overlay.visionWarm = nil
        try await open()
        require(overlay.visionWarm == nil, "with this binary's date stored, Text mode does not warm Vision again")
        overlay.dismiss()

        // Every drag and click case runs twice: with the press reaching Live Text at once, and held back as real pointer input is.
        for held in [false, true] {
            hold.isEnabled = held
            suffix = held ? " (held press)" : ""
            // A drag across a line selects its text; Return copies it and closes.
            try await open()
            textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: productName.maxX - 10, y: productName.midY))
            require(overlay.window.firstResponder !== overlay.view, "the press moved focus into Live Text, so the next keys test the routing back to the overlay")
            require(liveText.selectedText.contains("Product name"), "a drag across a line selects its text: \(liveText.selectedText.debugDescription)")
            require(!liveText.selectedText.contains("Billing"), "the drag selects only what it covers")
            pasteboard.clearContents()
            key(returnKey, "\r")
            require(!overlay.window.isVisible, "Return after a drag reaches the overlay and closes it")
            let line = await copied() ?? ""
            require(line.contains("Product name") && !line.contains("Billing"), "Return copies the selected text: \(line.debugDescription)")

            // A drag across a whole line reaches its last word, and a double click on the last word selects exactly that word.
            for (box, whole, last) in [(productName, "Product name", "name"), (billing, "Billing address", "address")] {
                try await open()
                textDrag(from: CGPoint(x: box.minX + 3, y: box.midY), to: CGPoint(x: box.maxX - 3, y: box.midY))
                require(liveText.selectedText == whole, "a drag across \"\(whole)\" selects the whole line: \(liveText.selectedText.debugDescription)")
                overlay.dismiss()
                try await open()
                let lastWord = CGPoint(x: box.maxX - 15, y: box.midY)
                for clicks in 1...2 {
                    mouse(.leftMouseDown, lastWord, clicks: clicks)
                    mouse(.leftMouseUp, lastWord, clicks: clicks)
                }
                require(liveText.selectedText == last, "a double click on the last word of \"\(whole)\" selects exactly it: \(liveText.selectedText.debugDescription)")
                overlay.dismiss()
            }

            // The word under the press is part of the selection whichever way the drag goes.
            try await open()
            textDrag(from: CGPoint(x: billing.maxX - 5, y: billing.midY), to: CGPoint(x: billing.minX + 3, y: billing.midY))
            require(liveText.selectedText == "Billing address", "a backward drag from the end of the last word selects the whole line: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            try await open()
            textDrag(from: CGPoint(x: billing.maxX - 5, y: billing.midY), to: CGPoint(x: billing.minX + 40, y: billing.midY))
            require(liveText.selectedText == "Billing address", "a backward drag from the last word into the first selects both: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            try await open()
            textDrag(from: CGPoint(x: billing.minX + 40, y: billing.midY), to: CGPoint(x: billing.maxX - 5, y: billing.midY))
            require(liveText.selectedText == "Billing address", "a forward drag from mid-word includes the word it started in: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            try await open()
            textDrag(from: CGPoint(x: productName.maxX - 5, y: productName.midY), to: CGPoint(x: productName.minX + 3, y: productName.midY))
            require(liveText.selectedText == "Product name", "a backward drag across \"Product name\" selects the whole line: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            // Close lines: a drag from "description" in the line below back up into "Product name", and the same drag forward.
            let below = CGPoint(x: productName.minX + 150, y: productName.maxY + 20)
            try await open()
            textDrag(from: below, to: CGPoint(x: productName.minX + 3, y: productName.midY))
            require(liveText.selectedText == "Product name\nBrief description", "a backward drag across two close lines includes the word it started on: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            try await open()
            textDrag(from: CGPoint(x: productName.minX + 3, y: productName.midY), to: below)
            require(liveText.selectedText == "Product name\nBrief description", "a forward drag across two close lines selects both: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()

            // Live Text anchors a press at the start of its word; the highlight covers the pressed word while a backward drag is still going.
            let addressEnd = CGPoint(x: billing.maxX - 5, y: billing.midY), addressStart = CGPoint(x: billing.maxX - 60, y: billing.midY)
            let billingStart = CGPoint(x: billing.minX + 3, y: billing.midY)
            try await open()
            mouse(.leftMouseDown, addressEnd)
            for step in 1...10 {
                mouse(.leftMouseDragged, CGPoint(x: addressEnd.x + (billingStart.x - addressEnd.x) * CGFloat(step) / 10, y: billing.midY))
            }
            require(liveText.selectedText == "Billing address", "while a backward drag goes on, the highlight covers the word it started on: \(liveText.selectedText.debugDescription)")
            mouse(.leftMouseUp, billingStart)
            overlay.dismiss()
            // A drag inside the last word selects that word, either way.
            for (from, to) in [(addressStart, addressEnd), (addressEnd, addressStart)] {
                try await open()
                textDrag(from: from, to: to)
                require(liveText.selectedText == "address", "a drag inside one word selects it: \(liveText.selectedText.debugDescription)")
                overlay.dismiss()
            }
            // A press on the line's last pixels or just past its last glyph, then a drag back, selects the whole line.
            for x in [billing.maxX - 2, billing.maxX + 8] {
                try await open()
                textDrag(from: CGPoint(x: x, y: billing.midY), to: billingStart)
                require(liveText.selectedText == "Billing address", "a backward drag from \(Int(x - billing.maxX)) px past the line's end selects the line: \(liveText.selectedText.debugDescription)")
                overlay.dismiss()
            }
            // A double click on the last word, then a drag back, keeps that word.
            try await open()
            mouse(.leftMouseDown, addressEnd)
            mouse(.leftMouseUp, addressEnd)
            mouse(.leftMouseDown, addressEnd, clicks: 2)
            for step in 1...10 {
                mouse(.leftMouseDragged, CGPoint(x: addressEnd.x + (billingStart.x - addressEnd.x) * CGFloat(step) / 10, y: billing.midY), clicks: 2)
            }
            mouse(.leftMouseUp, billingStart, clicks: 2)
            require(liveText.selectedText == "Billing address", "a double click on the last word and a drag back select the line: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            // A click without a drag selects nothing.
            try await open()
            mouse(.leftMouseDown, addressEnd)
            mouse(.leftMouseUp, addressEnd)
            require(liveText.selectedText.isEmpty, "a click on a word selects nothing: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
            // Live Text keeps the previous caret or selection until the pointer moves, so a press elsewhere must not anchor at the old one:
            // after a click on "Product" or a selection of "Billing address", a press in "name" and a drag back into "Product" select the line.
            let nameEnd = CGPoint(x: productName.maxX - 5, y: productName.midY), productWord = CGPoint(x: productName.minX + 40, y: productName.midY)
            for (prior, before): (String, () -> Void) in [("caret", { mouse(.leftMouseDown, productWord); mouse(.leftMouseUp, productWord) }),
                                                          ("selection", { textDrag(from: billingStart, to: addressEnd) })] {
                try await open()
                before()
                mouse(.leftMouseDown, nameEnd)
                for step in 1...10 {
                    mouse(.leftMouseDragged, CGPoint(x: nameEnd.x + (productWord.x - nameEnd.x) * CGFloat(step) / 10, y: productName.midY))
                }
                require(liveText.selectedText == "Product name", "with a prior \(prior), a backward drag from the last word keeps it while dragging: \(liveText.selectedText.debugDescription)")
                mouse(.leftMouseUp, productWord)
                require(liveText.selectedText == "Product name", "with a prior \(prior), a backward drag from the last word keeps it after release: \(liveText.selectedText.debugDescription)")
                overlay.dismiss()
            }
            // A triple click selects the line.
            try await open()
            for clicks in 1...3 {
                mouse(.leftMouseDown, productWord, clicks: clicks)
                mouse(.leftMouseUp, productWord, clicks: clicks)
            }
            require(liveText.selectedText.hasPrefix("Product name"), "a triple click selects the line: \(liveText.selectedText.debugDescription)")
            overlay.dismiss()
        }
        // The rest runs with presses reaching Live Text at once: a held press in the found-items fixture started a drag session that waits
        // for a real mouse up.
        hold.isEnabled = false
        suffix = ""

        // Esc with focus in Live Text closes.
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: productName.maxX - 10, y: productName.midY))
        require(overlay.window.firstResponder !== overlay.view, "focus is in Live Text before Esc")
        key(escape)
        require(!overlay.window.isVisible, "Esc after a drag in the text closes")

        // A drag down across lines selects them all, in order.
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: 1900, y: 600))
        let lines = liveText.selectedText
        require(lines.contains("Product name") && lines.contains("Second product") && lines.range(of: "Product name")!.lowerBound < lines.range(of: "Second product")!.lowerBound,
                "a drag down selects across lines in order: \(lines.debugDescription)")
        pasteboard.clearContents()
        key(cKey, "c", .command)
        require(!overlay.window.isVisible && pasteboard.string(forType: .string) == lines, "Cmd-C copies the selection and closes")

        // Double click selects a word, triple click the line.
        try await open()
        let word = CGPoint(x: billing.minX + 40, y: billing.midY)
        for clicks in 1...3 {
            mouse(.leftMouseDown, word, clicks: clicks)
            mouse(.leftMouseUp, word, clicks: clicks)
            if clicks == 2 { require(liveText.selectedText == "Billing", "a double click selects the word: \(liveText.selectedText.debugDescription)") }
        }
        require(liveText.selectedText.hasPrefix("Billing address"), "a triple click selects the line: \(liveText.selectedText.debugDescription)")

        // Mode keys still work after a click put focus in Live Text.
        key(aKey, "a")
        require(overlay.mode == .capture && liveText.isHidden && liveText.selectedText.isEmpty, "A goes back to Capture after a click in the text, hides Live Text, and clears the selection")
        key(tKey, "t")
        require(overlay.mode == .text && liveText.analysis != nil && overlay.chrome.reading.isHidden, "T returns to Text mode and reuses the analysis")
        key(escape)
        require(!overlay.window.isVisible, "Esc closes")

        // F selects all text.
        try await open()
        key(fKey, "f")
        let all = liveText.text
        require(liveText.selectedText == all && all.count > 100, "F selects all text on screen")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(await copied() == all, "Return copies all of it")

        // C copies the color under the pointer.
        try await open()
        mouse(.mouseMoved, blank)
        pasteboard.clearContents()
        key(cKey, "c")
        let color = pasteboard.string(forType: .string) ?? ""
        require(color.hasPrefix("#") && !overlay.window.isVisible, "C copies the color in Text mode: \(color)")

        // Closing before the analysis finishes drops it.
        overlay.present(image: image, frame: frame, displayID: nil)
        key(tKey, "t")
        let inFlight = overlay.textTask
        key(escape)
        await inFlight?.value
        require(liveText.analysis == nil && overlay.textTask == nil, "dismiss cancels an in-flight analysis")

        // The menu's Copy Text path starts the analysis too.
        overlay.present(image: image, frame: frame, displayID: nil)
        overlay.setMode(.text)
        try await waitFor("the analysis after setMode") { liveText.analysis != nil }
        overlay.dismiss()

        // Option-Return: the language-pair decision, with injected status and translation.
        let german = Locale.Language(identifier: "de")
        let notInstalled = "\(TextTranslation.name(Locale.Language(identifier: "en"))) to \(TextTranslation.name(german)) is not installed. Add it in System Settings > General > Language & Region > Translation Languages."
        overlay.targetLanguage = german
        overlay.translationStatus = { _, _ in .supported }
        overlay.translate = { _, _, _ in fatalError("translate must not run for a pair that is not installed") }
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: 1900, y: 600))
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        try await waitFor("the not-installed notice") { overlay.text.notice != nil }
        require(overlay.text.notice == notInstalled && texts(in: overlay.chrome.status) == [notInstalled], "Option-Return shows the not-installed pill: \(overlay.text.notice ?? "")")
        require(overlay.window.isVisible && pasteboard.string(forType: .string) == nil, "a missing language pair keeps the overlay open and copies nothing")
        key(fKey, "f")
        require(overlay.text.notice == nil && overlay.chrome.status.isHidden, "the pill goes away on the next key")
        overlay.translationStatus = { _, _ in .unsupported }
        key(returnKey, "\r", .option)
        try await waitFor("the unsupported notice") { overlay.text.notice != nil }
        require(overlay.text.notice!.hasSuffix("is not supported by system translation."), "an unsupported pair says so")
        overlay.translationStatus = { _, _ in .installed }
        var sent: String?
        overlay.translate = { text, _, _ in sent = text; return "UEBERSETZT" }
        key(returnKey, "\r", .option)
        await overlay.textTask?.value
        require(await copied() == "UEBERSETZT" && sent == all && !overlay.window.isVisible, "an installed pair translates the selected text and copies the translation")
        overlay.targetLanguage = Locale.Language(identifier: "en")
        try await open()
        key(fKey, "f")
        key(returnKey, "\r", .option)
        try await waitFor("the same-language notice") { overlay.text.notice != nil }
        require(overlay.text.notice == "Text is already in \(TextTranslation.name(overlay.targetLanguage)).", "Option-Return on text already in the target language says so")
        overlay.dismiss()

        // Capture: Shift-Return copies the text in a released selection, tab-separated when it has columns.
        func capture(_ rect: CGRect) {
            overlay.present(image: image, frame: frame, displayID: nil)
            overlay.detectionTask?.cancel()
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY), .option)
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), .option)
            mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY), .option)
        }
        capture(cart)
        require(overlay.selection?.rect == cart, "an Option-drag releases the exact cart selection")
        require(texts(in: overlay.chrome.actionBar).contains("\u{21E7}\u{21A9}"), "the action bar's Text button names Shift-Return")
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        require(!overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."], "a Reading text... pill shows while the selection is read")
        await overlay.textTask?.value
        let table = await copied() ?? ""
        require(table.contains("Product name\t$12\nBrief description\nSecond product\t$8"), "Shift-Return copies a two-column selection tab-separated: \(table.debugDescription)")
        require(pasteboard.data(forType: .png) == nil && !overlay.window.isVisible, "Shift-Return copies text, not an image, and closes")

        capture(email)
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        await overlay.textTask?.value
        let plain = await copied()
        require(plain == "you@example.com", "Shift-Return on one column copies plain text: \(plain.debugDescription)")

        overlay.targetLanguage = german
        overlay.translationStatus = { _, _ in .installed }
        sent = nil
        capture(cart)
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        await overlay.textTask?.value
        await overlay.textTask?.value
        require(await copied() == "UEBERSETZT" && sent?.contains("Product name $12") == true, "Option-Return in Capture translates the selection's text in reading order: \(sent.debugDescription)")

        capture(cart)
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        let reading = overlay.textTask
        key(escape)
        await reading?.value
        require(reading != nil && reading!.isCancelled && !overlay.window.isVisible && pasteboard.string(forType: .string) == nil, "Esc during the read cancels it and copies nothing")

        // The real pair on this Mac: either the notice or a real translation, never a prompt.
        let spanish = Locale.Language(identifier: "es")
        let realStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: spanish)
        overlay.targetLanguage = spanish
        overlay.translationStatus = { await LanguageAvailability().status(from: $0, to: $1) }
        overlay.translate = { try await TranslationSession(installedSource: $1, target: $2).translate($0).targetText }
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: 1900, y: 600))
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        if realStatus == .installed {
            await overlay.textTask?.value
            let real = await copied() ?? ""
            require(!real.isEmpty && real != lines, "REAL translation ran (en to es installed): \(real.debugDescription)")
        } else {
            try await waitFor("the real notice") { overlay.text.notice != nil }
            require(overlay.text.notice!.contains("English to Spanish is not"), "REAL status for en to es is \(realStatus): the notice shows, no prompt")
        }
        overlay.dismiss()

        // Shift-Return in Text mode copies the selection as rows: columns tab-separated, one visual row per line.
        try await open()
        let transcript = liveText.text
        liveText.selectedRanges = [transcript.range(of: "Product name")!.lowerBound..<transcript.range(of: "Second product")!.upperBound]
        let liveOrder = liveText.selectedText
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        require(overlay.text.reading != nil, "Shift-Return in Text mode reads the boxes first")
        await overlay.textTask?.value
        let rows = await copied() ?? ""
        require(rows.hasPrefix("Product name\t$12\nBrief description\nSecond product") && !overlay.window.isVisible,
                "Shift-Return in Text mode copies rows, columns tab-separated: \(rows.debugDescription) (Live Text order: \(liveOrder.debugDescription))")
        try await open()
        liveText.selectedRanges = [transcript.range(of: "Product name")!.lowerBound..<transcript.range(of: "Second product")!.upperBound]
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(await copied() == liveOrder, "Return still copies in Live Text's order")

        // Found items on a generated page: a link, an email address, a phone number, and a QR code.
        let fixture = itemsFixture(width: image.width, height: image.height)
        let qrBounds = CGRect(x: image.width - 700, y: image.height - 700, width: 500, height: 500)
        var opened: [URL] = []
        overlay.openURL = { opened.append($0) }
        func openFixture() async throws {
            overlay.present(image: fixture, frame: frame, displayID: nil)
            key(tKey, "t")
            try await waitFor("the fixture's Live Text analysis attaches") { liveText.analysis != nil }
        }
        try await openFixture()
        textDrag(from: CGPoint(x: 203, y: 280), to: CGPoint(x: 330, y: 280))
        require(overlay.window.firstResponder !== overlay.view, "focus is in Live Text before Tab")
        key(48, "\t")
        try await waitFor("Tab finds the items") { overlay.text.picked != nil }
        let items = overlay.text.items!
        require(items.map(\.text) == ["https://example.com/snug", "you@example.com", "+1 (555) 010-4477", "https://example.org/qr"],
                "Tab finds the link, email, phone number and QR payload in reading order: \(items.map(\.text))")
        require(items.map { $0.url?.absoluteString } == ["https://example.com/snug", "mailto:you@example.com", "tel:+15550104477", "https://example.org/qr"],
                "each item opens its URL: \(items.map { $0.url?.absoluteString })")
        require(items[0].bounds.minX > 330 && items[0].bounds.minY > 200 && items[0].bounds.maxY < 340,
                "the link's box covers the link, not the whole line: \(items[0].bounds)")
        require(abs(items[3].bounds.minX - qrBounds.minX) < 20 && abs(items[3].bounds.maxY - qrBounds.maxY) < 20, "the QR code's box is the code: \(items[3].bounds)")
        require(overlay.text.picked == 0 && overlay.view.overlays.hover == items[0].bounds, "the first Tab picks the first item and outlines it")
        require(liveText.selectableItemsHighlighted && liveText.preferredInteractionTypes == .dataDetectors,
                "while an item is picked Live Text highlights its data detectors")
        require(overlay.text.notice?.hasPrefix("https://example.com/snug") == true, "a pill names the picked item: \(overlay.text.notice.debugDescription)")
        key(48, "\t")
        require(overlay.text.picked == 1, "Tab steps to the next item")
        key(48, "\t", .shift)
        key(48, "\t", .shift)
        require(overlay.text.picked == 3 && overlay.view.overlays.hover == items[3].bounds, "Shift-Tab steps back and wraps to the last item")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(await copied() == "https://example.org/qr" && !overlay.window.isVisible, "Return copies the picked item and closes")
        try await openFixture()
        key(48, "\t")
        try await waitFor("Tab finds the items") { overlay.text.picked != nil }
        key(returnKey, "\r", .command)
        try await openFixture()
        require(liveText.preferredInteractionTypes == .textSelection && !liveText.selectableItemsHighlighted, "the next Text mode starts with text selection")
        overlay.dismiss()
        require(opened == [URL(string: "https://example.com/snug")!] && !overlay.window.isVisible, "Cmd-Return closes and opens the picked item: \(opened)")
        try await openFixture()
        key(48, "\t")
        try await waitFor("Tab finds the items") { overlay.text.picked != nil }
        key(escape)
        require(overlay.window.isVisible && overlay.text.picked == nil && overlay.view.overlays.hover == nil && !liveText.selectableItemsHighlighted
                && liveText.preferredInteractionTypes == .textSelection, "Esc with an item picked unpicks it and keeps the overlay")
        textDrag(from: CGPoint(x: 203, y: 440), to: CGPoint(x: 330, y: 440))
        require(liveText.selectedText.hasPrefix("Mail"), "after unpicking, a drag selects text again: \(liveText.selectedText.debugDescription)")
        key(escape)
        require(!overlay.window.isVisible, "Esc again closes")

        print("Text UI verification passed (\(passed.count) checks):")
        passed.forEach { print("- \($0)") }
        exit(EXIT_SUCCESS)
    }

    /// The first accurate OCR or barcode request of a newly built binary compiles Vision's models into ~/Library/Caches/Snug (35 s idle,
    /// over a minute under load). Runs Text mode's warm-up (Tab's requests) on `image`, then on the found-items fixture, whose QR code
    /// reaches the barcode decoder, before the 120 s watchdog starts, so a slow compile is not killed halfway; fails after 600 s. Prints
    /// the footprint before, the peak (sampled every 100 ms) while the warm-up's requests and handler are alive, and right after and 2 s
    /// and 10 s after they are released.
    static func warmVision(_ image: CGImage) async throws {
        FileHandle.standardError.write(Data("Warming Vision's accurate OCR and barcode models...\n".utf8))
        let watchdog = Task {
            try await Task.sleep(for: .seconds(600))
            FileHandle.standardError.write(Data("Vision warm-up timed out after 600 s\n".utf8))
            exit(EXIT_FAILURE)
        }
        defer { watchdog.cancel() }
        let (start, before) = (ContinuousClock.now, footprint())
        let poll = Task {
            var peak = 0.0
            while !Task.isCancelled {
                peak = max(peak, Double(footprint().split(separator: " ")[0])!)
                try? await Task.sleep(for: .milliseconds(100))
            }
            return peak
        }
        _ = try await OverlayController.findItems(in: image)
        let (warmed, released) = (ContinuousClock.now, footprint())
        poll.cancel()
        let peak = max(await poll.value, Double(released.split(separator: " ")[0])!)
        try await Task.sleep(for: .seconds(2))
        let settled = footprint()
        try await Task.sleep(for: .seconds(8))
        print("Vision warm-up: \(String(format: "%.1f", start.duration(to: warmed).milliseconds)) ms, footprint \(before) before, "
              + "\(String(format: "%.1f", peak)) MiB peak, \(released) after, \(settled) 2 s after, \(footprint()) 10 s after")
        _ = try await OverlayController.findItems(in: itemsFixture(width: image.width, height: image.height))
    }

    /// A white page of `width` x `height` pixels with a link, an email address and a phone number in large text from the top left, and a
    /// 500 px QR code of a URL 200 px from the bottom-right corner.
    static func itemsFixture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, text) in ["Docs: https://example.com/snug", "Mail you@example.com", "Call +1 (555) 010-4477"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 200, y: CGFloat(height - 300 - index * 160))
            CTLineDraw(line, context)
        }
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data("https://example.org/qr".utf8)
        let code = CIContext().createCGImage(qr.outputImage!, from: qr.outputImage!.extent)!
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: width - 700, y: 200, width: 500, height: 500))
        return context.makeImage()!
    }
}

/// Holds a press back from Live Text's text view until the pointer moves 2 pt or lifts, as the immediate action recognizer VisionKit puts on
/// that view does with real pointer input (text.log: the selection moves only on the first drag or the release). That recognizer stays
/// inert in these unfocused runs, so without this a synthesized press reaches Live Text at once.
final class HeldPress: NSGestureRecognizer {
    private var start = CGPoint.zero

    init() {
        super.init(target: nil, action: nil)
        delaysPrimaryMouseButtonEvents = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 2 { state = .failed }
    }

    override func mouseUp(with event: NSEvent) { state = .failed }
}
