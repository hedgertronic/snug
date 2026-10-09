import AppKit
import ScreenshotCore
import Translation

extension DebugRun {
    /// `--verify-text-ui`: drives Live Text in Text mode and Capture's Shift-Return through synthesized events on form-test.png.
    static func verifyText(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        let pasteboard = overlay.pasteboard
        let liveText = overlay.view.liveText
        var passed: [String] = []

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Text UI verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
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

        func open() async throws {
            overlay.present(image: image, frame: frame, displayID: nil)
            key(tKey, "t")
            try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
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
        require(texts(in: overlay.chrome.hints) == ["Drag", "select text", "\u{21A9}", "copy", "\u{2325}", "\u{21A9}", "translate", "F", "all text", "C", "color", "?", "all keys"],
                "Text mode shows its hint row: \(texts(in: overlay.chrome.hints))")
        require(!overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."], "a Reading text... pill shows while the analysis runs")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        print("Live Text analysis: \(String(format: "%.1f", overlay.lastLiveTextMilliseconds)) ms (first in this process)")
        require(overlay.chrome.reading.isHidden, "the Reading text... pill goes away when the analysis attaches")
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

        print("Text UI verification passed (\(passed.count) checks):")
        passed.forEach { print("- \($0)") }
        exit(EXIT_SUCCESS)
    }
}
