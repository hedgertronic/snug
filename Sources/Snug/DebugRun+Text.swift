import AppKit
import ScreenshotCore
import CoreImage.CIFilterBuiltins
import Translation
import Vision

extension DebugRun {
    /// `--verify-text-ui`: drives Live Text in Text mode and Capture's Shift-Return through synthesized events on form-test.png.
    static func verifyText(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        try await verifyWarmVisionChild()
        try await warmVision(image)
        await OverlayController.visionWarmUp?.value
        let folder = privateSetup(overlay)
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

        func fixtureImage(_ path: String) -> CGImage {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../\(path)").standardized
            return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        }
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
        /// The pasteboard's text once the read and any translation it starts are done.
        func copied() async -> String? {
            await overlay.textTask?.value
            await overlay.textTask?.value
            return pasteboard.string(forType: .string)
        }

        // Entering Text mode starts the analysis; the pill covers the wait.
        overlay.present(image: image, frame: frame, displayID: nil)
        require(overlay.mode == .capture && liveText.isHidden && liveText.analysis == nil, "the overlay opens in Capture with Live Text hidden and nothing analyzed")
        key(tKey, "t")
        let entered = ContinuousClock.now
        require(overlay.mode == .text && !liveText.isHidden, "T enters Text mode and shows Live Text")
        require(overlay.chrome.strip.isHidden && texts(in: overlay.chrome.topBar) == ["Capture", "A", "Text", "T", "Loupe", "L", "Rulers", "R", "Crosshair", "X", "?"],
                "Text mode with nothing selected shows no strip, and the bar has the modes, view and the keys button: \(texts(in: overlay.chrome.topBar))")
        require(!overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."], "a Reading text... pill shows while the analysis runs")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        print("Live Text analysis: \(String(format: "%.1f", overlay.lastLiveTextMilliseconds)) ms (first in this process)")
        require(overlay.chrome.reading.isHidden, "the Reading text... pill goes away when the analysis attaches")
        // Entering Text mode flashes the lines fast recognition read as pills, and turns them off by itself about 1.25 s later.
        try await waitFor("the found-text flash shows") { !overlay.view.overlays.flashPills.isEmpty }
        let flashed = overlay.view.overlays.flashPills
        print("Found-text flash: \(String(format: "%.1f", overlay.lastFlashMilliseconds)) ms to \(flashed.count) recognized lines (first in this process)")
        require(flashed.count > 20 && flashed.allSatisfy { overlay.extent.contains($0) } && !liveText.selectableItemsHighlighted && liveText.preferredInteractionTypes == .textSelection,
                "entering Text mode flashes pills on the recognized lines, not Live Text's own highlight: \(flashed.count)")
        try await waitFor("the found-text flash goes off") { overlay.view.overlays.flashPills.isEmpty }
        let flashTime = entered.duration(to: .now).milliseconds
        require(flashTime > 1150 && flashTime < 2000 && overlay.foundTextHighlight == nil, "the found-text flash goes off by itself about 1.25 s after entering: \(Int(flashTime)) ms")
        require(liveText.frame == overlay.view.bounds && liveText.superview === overlay.view, "Live Text covers the frozen image exactly")
        require(liveText.isSupplementaryInterfaceHidden, "no Live Text button sits in the corner")
        require(liveText.text.contains("Product name") && liveText.text.contains("Billing address"), "the analysis reads the screen's text")
        let textPoint = windowPoint(CGPoint(x: productName.midX, y: productName.midY))
        func topLeft(_ pixel: CGPoint) -> CGPoint { CGPoint(x: pixel.x / overlay.scale, y: pixel.y / overlay.scale) }
        require(liveText.hasText(at: topLeft(CGPoint(x: productName.midX, y: productName.midY))) && !liveText.hasText(at: topLeft(blank))
                && !liveText.hasText(at: topLeft(CGPoint(x: productName.midX, y: productName.maxY + 45))), "Live Text's text sits under the same pixels as the image")
        require(overlay.view.hitTest(textPoint)?.isDescendant(of: liveText) == true, "a press on the image reaches Live Text")
        let button = overlay.chrome.modeButtons[.capture]!
        let buttonPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: overlay.view)
        require(overlay.view.hitTest(buttonPoint)?.isDescendant(of: button) == true, "the top bar stays clickable above Live Text")
        mouse(.mouseMoved, CGPoint(x: productName.midX, y: productName.midY))
        require(overlay.view.cursor == .iBeam, "the cursor is an I-beam over text")
        mouse(.mouseMoved, blank)
        require(overlay.view.cursor == .crosshair, "the cursor is the crosshair away from text")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(overlay.window.isVisible && pasteboard.string(forType: .string) == nil, "Return with nothing selected copies nothing and keeps the overlay open")
        overlay.dismiss()
        require(liveText.analysis == nil, "closing drops the analysis")

        // With the loupe on, Text mode shows no loupe or readout; Capture shows them again.
        overlay.defaults.set(true, forKey: Pref.loupe)
        let guides = overlay.view.guides
        func loupeHidden() -> Bool { (guides.loupe.isHidden || guides.loupe.opacity == 0) && guides.readout.isHidden }
        try await open()
        mouse(.mouseMoved, CGPoint(x: productName.midX, y: productName.midY))
        require(loupeHidden(), "Text mode hides the loupe and its readout with the loupe on")
        key(aKey, "a")
        mouse(.mouseMoved, blank)
        require(!guides.loupe.isHidden && guides.loupe.opacity == 1 && !guides.readout.isHidden, "A back to Capture shows the loupe again")
        key(tKey, "t")
        mouse(.mouseMoved, CGPoint(x: productName.midX, y: productName.midY))
        require(loupeHidden(), "T hides the loupe again")
        overlay.defaults.set(false, forKey: Pref.loupe)
        overlay.dismiss()

        // A key or a press turns the found-text flash off at once, and A then T back into Text mode flashes it again.
        try await open()
        try await waitFor("the found-text flash shows") { !overlay.view.overlays.flashPills.isEmpty }
        key(fKey, "f")
        require(overlay.view.overlays.flashPills.isEmpty && overlay.foundTextHighlight == nil, "a key turns the found-text flash off at once")
        key(aKey, "a")
        key(tKey, "t")
        try await waitFor("the found-text flash shows again") { !overlay.view.overlays.flashPills.isEmpty }
        require(liveText.analysis != nil, "A then T, reusing the analysis, flashes the found text again")
        mouse(.leftMouseDown, CGPoint(x: productName.minX + 40, y: productName.midY))
        require(overlay.view.overlays.flashPills.isEmpty, "a press turns the found-text flash off before its release")
        mouse(.leftMouseUp, CGPoint(x: productName.minX + 40, y: productName.midY))
        overlay.dismiss()

        // While Vision's warm-up child runs (a 2 s sleep stands in for it), Text mode says text recognition is getting ready, and
        // Shift-Return and Tab say they will run when it is, then run.
        func warmUpChild() throws {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["2"]
            try child.run()
            OverlayController.watchWarmUp(child)
        }
        let ready = OverlayController.warmUpNotice
        try warmUpChild()
        try await open()
        require(texts(in: overlay.chrome.status) == [ready], "while the warm-up child runs, Text mode says text recognition is getting ready: \(texts(in: overlay.chrome.status))")
        key(fKey, "f")
        require(texts(in: overlay.chrome.status) == [ready], "the getting-ready notice stays after a key: \(texts(in: overlay.chrome.status))")
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        require(texts(in: overlay.chrome.status) == ["Shift-Return will run when text recognition is ready."] && overlay.text.reading == nil && overlay.window.isVisible,
                "Shift-Return during the warm-up says it will run when ready, and waits: \(texts(in: overlay.chrome.status))")
        await overlay.textTask?.value
        require(OverlayController.visionWarmUp == nil && overlay.text.reading != nil, "when the warm-up child exits, the queued Shift-Return runs")
        await overlay.textTask?.value
        let queuedRows = await copied() ?? ""
        require(queuedRows.contains("Product name\t$12") && !overlay.window.isVisible, "the queued Shift-Return copies the rows: \(queuedRows.debugDescription)")
        try warmUpChild()
        try await open()
        key(48, "\t")
        require(texts(in: overlay.chrome.status) == ["Tab will run when text recognition is ready."] && overlay.text.items == nil,
                "Tab during the warm-up says it will run when ready, and waits: \(texts(in: overlay.chrome.status))")
        try await waitFor("the queued Tab finds the items") { overlay.text.items != nil }
        overlay.dismiss()
        try warmUpChild()
        try await open()
        require(texts(in: overlay.chrome.status) == [ready], "Text mode opened during the warm-up says it is getting ready")
        try await waitFor("the getting-ready notice goes away when the warm-up ends") { OverlayController.visionWarmUp == nil && overlay.chrome.status.isHidden }
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
            require(overlay.text.reading != nil, "Return after a drag reaches the overlay and reads the boxes")
            let line = await copied() ?? ""
            require(!overlay.window.isVisible, "Return closes the overlay once it copies")
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
                // Once the whole image is read Snug draws the highlight in Live Text's place, from where the selection starts.
                try await waitFor("the whole image's accurate OCR finishes") { overlay.text.ocrLines != nil }
                let pills = overlay.view.overlays.textPills
                require(pills.count == 1 && pills[0].minX > billing.minX + 100 && pills[0].maxX <= billing.maxX + 4 && liveText.alphaValue == 0,
                        "Snug's highlight covers only \"address\", and Live Text's is hidden: \(pills) \(liveText.alphaValue)")
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

            // The round 8 fixture: a drag from the first row of a numbered list to the last selects every row in between, the long
            // wrapped one too. Rows on the fixture, image pixels at 2x.
            let rowsImage = fixtureImage("Tests/Fixtures/text-select-row-skipped.png")
            overlay.present(image: rowsImage, frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(rowsImage.width) / 2, height: CGFloat(rowsImage.height) / 2), displayID: nil)
            key(tKey, "t")
            // The flash marks recognized lines only: not the toolbar's icons top right (text rectangle detection boxed them), and the
            // short wrapped row too (it missed that).
            try await waitFor("the rows fixture's found-text flash shows") { !overlay.view.overlays.flashPills.isEmpty }
            let rowsFlash = overlay.view.overlays.flashPills
            require(!rowsFlash.contains { $0.intersects(CGRect(x: 1700, y: 0, width: 190, height: 34)) } && rowsFlash.contains { abs($0.minY - 176) < 6 && abs($0.minX - 276) < 6 },
                    "the flash marks recognized lines, not the toolbar's icons, and includes the short wrapped row: \(rowsFlash)")
            try await waitFor("the rows fixture's Live Text analysis attaches") { liveText.analysis != nil }
            if let selectionView = textView(in: liveText), !selectionView.gestureRecognizers.contains(hold) { selectionView.addGestureRecognizer(hold) }
            textDrag(from: CGPoint(x: 250, y: 81), to: CGPoint(x: 1455, y: 224))
            let transcript = liveText.text
            let selected = liveText.selectedRanges
            for marker in ["Decisions for you", "Theme setting", "cleaner version", "loose dots", "Hint label", "almost never", "intro animation", "Cleanup"] {
                let line = transcript.lineRange(for: transcript.range(of: marker)!)
                let words = transcript[line].trimmingCharacters(in: .whitespacesAndNewlines)
                let inner = transcript.range(of: words, range: line)!
                require(selected.contains { $0.lowerBound <= inner.lowerBound && inner.upperBound <= $0.upperBound },
                        "a drag down the list selects the row with \"\(marker)\": selected \(selected.map { transcript[$0].debugDescription }), transcript \(transcript.debugDescription)")
            }
            // A drag that ends past the end of the short wrapped row, near or far, selects through that row and not into the next item.
            // (Live Text reads a stray line, "match your rea...", right of the short row and after it.)
            for endX in [900.0, 1455] {
                textDrag(from: CGPoint(x: 250, y: 101), to: CGPoint(x: endX, y: 183))
                let text = liveText.selectedText
                require(text.hasPrefix("1. Theme setting") && text.contains("which is almost never.") && !text.contains("3. An intro"),
                        "a drag that ends at x \(Int(endX)), right of the short row, selects through it: \(text.debugDescription)")
            }
            // Return copies the list with each item and sub-bullet on its own line and the wrapped item joined into one.
            textDrag(from: CGPoint(x: 250, y: 81), to: CGPoint(x: 1455, y: 224))
            pasteboard.clearContents()
            key(returnKey, "\r")
            let list = (await copied() ?? "").split(separator: "\n")
            require(["1. Theme setting", "- A is the cleaner", "- D at 1x", "2. Hint", "3. An intro", "4. Cleanup"].allSatisfy { start in list.filter { $0.hasPrefix(start) }.count == 1 }
                    && list.contains { $0.hasPrefix("2. Hint") && $0.hasSuffix("real alternative, which is almost never.") } && !overlay.window.isVisible,
                    "Return on the list copies one line per item and sub-bullet, the wrapped item joined: \(list)")
        }
        // The rest runs with presses reaching Live Text at once: a held press in the found-items fixture started a drag session that waits
        // for a real mouse up.
        hold.isEnabled = false
        suffix = ""

        // A terminal's list over a busy blurred wallpaper, 2560 x 1600: accurate OCR of the whole screen in one pass drops some items'
        // "- " markers; read in bands it keeps every one. Return on a box over the whole screen, and F then Return (whose rows between
        // the selection's ends take OCR's text, not Live Text's, which drops a marker too), copy each item and sub-item on its own line
        // with its marker.
        let terminal = fixtureImage("Tests/Fixtures/terminal-list-blurred.png")
        let listItems = ["watering interval", "sun exposure (hours)", "pot size of the plant", "soil mix for the pot", "Default: medium pot",
                         "Small keeps the plant", "Large leaves room", "Custom: the four values", "does the soil mix follow", "should the pot scale", "is a moisture sensor"]
        func unmarked(_ copied: String?) -> [String] {
            listItems.filter { item in !(copied ?? "").split(separator: "\n").contains { $0.hasPrefix("- " + item) } }
        }
        for boxed in [true, false] {
            overlay.present(image: terminal, frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(terminal.width) / 2, height: CGFloat(terminal.height) / 2), displayID: nil)
            key(tKey, "t")
            try await waitFor("the terminal fixture's Live Text analysis attaches") { liveText.analysis != nil }
            if boxed {
                mouse(.leftMouseDown, CGPoint(x: 4, y: 4))
                mouse(.leftMouseDragged, CGPoint(x: 2556, y: 1596))
                mouse(.leftMouseUp, CGPoint(x: 2556, y: 1596))
                await overlay.textTask?.value
            } else {
                let transcript = liveText.text.split(separator: "\n")
                print("Terminal fixture: Live Text reads \(listItems.filter { item in transcript.contains { $0.contains(item) } }.count) of \(listItems.count) items, "
                      + "\(listItems.filter { item in transcript.contains { $0.hasPrefix("- " + item) } }.count) with their marker")
                key(fKey, "f")
                // Snug's highlight covers each item from its marker, which Live Text's own highlight leaves out on one of them.
                try await waitFor("the terminal fixture's accurate OCR finishes") { overlay.text.ocrLines != nil }
                let pills = overlay.view.overlays.textPills
                let unlit = listItems.filter { item in
                    let line = overlay.text.ocrLines!.first { $0.text.hasPrefix("- " + item) }
                    return line == nil || !pills.contains { $0.intersects(line!.bounds) && $0.minX <= line!.bounds.minX + 1 }
                }
                require(unlit.isEmpty, "Snug's highlight covers every list item from its \"- \" marker: missing \(unlit)")
                // Live Text puts the last row's wrap ("then run the frame") last, above the row it selects after it; the row stays lit.
                let last = overlay.text.ocrLines!.first { $0.text.hasPrefix("checks and render") }!
                require(pills.contains { $0.intersects(last.bounds) && $0.width >= last.bounds.width - 1 }, "Snug's highlight covers the last row whole: \(last.bounds) \(pills)")
            }
            pasteboard.clearContents()
            key(returnKey, "\r")
            let copiedTerminal = await copied()
            require(unmarked(copiedTerminal).isEmpty && !overlay.window.isVisible,
                    "\(boxed ? "Return on a box over the whole terminal screen" : "F then Return on the terminal screen") copies every list item on its own line with its \"- \" marker: "
                    + "missing \(unmarked(copiedTerminal)) in \(copiedTerminal.debugDescription)")
        }

        // Esc with focus in Live Text closes.
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: productName.maxX - 10, y: productName.midY))
        require(overlay.window.firstResponder !== overlay.view, "focus is in Live Text before Esc")
        key(escape)
        require(!overlay.window.isVisible, "Esc after a drag in the text closes")

        // A drag that starts off text draws a box like Capture's drag, never a Live Text selection, and on release keeps it as a
        // selection and reads it. Here the box starts left of the Address label and covers that block's four lines.
        let boxStart = CGPoint(x: 300, y: 900), boxEnd = CGPoint(x: 1590, y: 1230)
        try await open()
        mouse(.mouseMoved, boxStart)
        require(!liveText.hasText(at: topLeft(boxStart)) && overlay.view.cursor == .crosshair, "the box starts off text, under the crosshair")
        let selectedBefore = liveText.selectedText
        mouse(.leftMouseDown, boxStart)
        var boxGhosts: [CGRect?] = [], boxSelected: [String] = []
        for step in 1...10 {
            let t = CGFloat(step) / 10
            mouse(.leftMouseDragged, CGPoint(x: boxStart.x + (boxEnd.x - boxStart.x) * t, y: boxStart.y + (boxEnd.y - boxStart.y) * t))
            boxGhosts.append(overlay.view.overlays.ghost)
            if liveText.selectedText != selectedBefore || overlay.window.textPress != nil { boxSelected.append("\(liveText.selectedRanges.count) ranges \(liveText.selectedText.debugDescription), press \(String(describing: overlay.window.textPress))") }
        }
        require(boxGhosts.last == CGRect(x: boxStart.x, y: boxStart.y, width: boxEnd.x - boxStart.x, height: boxEnd.y - boxStart.y) && !boxGhosts.contains(nil),
                "a drag from off text draws the box as Capture's drag does: \(boxGhosts)")
        require(boxSelected.isEmpty && overlay.view.cursor == .crosshair, "a box drag leaves Live Text's selection as it was (\(selectedBefore.debugDescription)) and the cursor the crosshair: \(boxSelected)")
        pasteboard.clearContents()
        mouse(.leftMouseUp, boxEnd)
        let addressBox = CGRect(x: boxStart.x, y: boxStart.y, width: boxEnd.x - boxStart.x, height: boxEnd.y - boxStart.y)
        let o = { overlay.view.overlays }
        require(overlay.selection?.rect == addressBox && o().selection == addressBox && o().showsHandles && !o().showsCornerDots && o().ghost == nil && overlay.window.isVisible
                    && pasteboard.string(forType: .string) == nil && !overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."],
                "on release the box stays as a selection with Capture's outline and handles but no corner dots, copies nothing, and a Reading text... pill shows while it is read")
        await overlay.textTask?.value
        /// The box's pills and its chip agree with the lines read, all inside it.
        func requireBoxRead(_ rect: CGRect, _ message: String) {
            let pills = o().textPills, count = overlay.text.box?.lines?.count ?? -1
            require(overlay.selection?.rect == rect && overlay.text.box?.rect == rect && pills.count == count && count > 0
                        && pills.allSatisfy { rect.insetBy(dx: -1, dy: -1).contains($0) } && texts(in: overlay.chrome.size) == ["\(count) \(count == 1 ? "line" : "lines")"]
                        && overlay.chrome.size.isHidden == false && overlay.chrome.reading.isHidden && !overlay.chrome.strip.isHidden,
                    "\(message): \(count) lines, \(pills.count) pills, chip \(texts(in: overlay.chrome.size))")
        }
        requireBoxRead(addressBox, "once read, the box's lines show as pills, the chip counts them and the Text strip shows")
        require(o().textPills.count == 4, "the box holds the Address block's four lines: \(overlay.text.box?.lines?.map(\.text) ?? [])")
        // The box moves from inside off text and resizes from its handles, as a Capture selection does, and each change reads it again.
        let inside = CGPoint(x: boxStart.x + 30, y: boxStart.y + 75)
        mouse(.mouseMoved, inside)
        require(!liveText.hasText(at: topLeft(inside)) && overlay.view.cursor == .openHand, "inside the box off text the cursor is the open hand")
        mouse(.mouseMoved, CGPoint(x: addressBox.maxX, y: addressBox.maxY))
        require(overlay.view.cursor == OverlayController.resizeCursors[.bottomRight], "on the box's corner handle the cursor resizes")
        mouse(.leftMouseDown, inside)
        mouse(.leftMouseDragged, CGPoint(x: inside.x, y: inside.y + 40))
        mouse(.leftMouseDragged, CGPoint(x: inside.x, y: inside.y + 80))
        mouse(.leftMouseUp, CGPoint(x: inside.x, y: inside.y + 80))
        let moved = addressBox.offsetBy(dx: 0, dy: 80)
        require(overlay.selection?.rect == moved && liveText.selectedText.isEmpty && overlay.text.box?.rect == moved
                    && (!overlay.chrome.reading.isHidden || overlay.text.box?.lines != nil),
                "a drag inside the box off text moves it and reads it again (already read when the pause in the drag outlasted 150 ms): \(String(describing: overlay.selection?.rect)), read \(String(describing: overlay.text.box?.rect)) \(overlay.text.box?.lines?.count ?? -1) lines, reading pill \(!overlay.chrome.reading.isHidden), selected \(liveText.selectedText.debugDescription)")
        await overlay.textTask?.value
        requireBoxRead(moved, "the moved box shows its own lines")
        mouse(.leftMouseDown, CGPoint(x: moved.midX, y: moved.maxY))
        mouse(.leftMouseDragged, CGPoint(x: moved.midX, y: moved.maxY - 120))
        mouse(.leftMouseUp, CGPoint(x: moved.midX, y: moved.maxY - 120))
        let resized = CGRect(x: moved.minX, y: moved.minY, width: moved.width, height: moved.height - 120)
        require(overlay.selection?.rect == resized, "the bottom handle resizes the box exactly, with no snap: \(String(describing: overlay.selection?.rect))")
        await overlay.textTask?.value
        requireBoxRead(resized, "the resized box shows its own lines")
        // Esc clears the box and keeps the overlay; a second Esc closes it.
        key(escape)
        require(overlay.selection == nil && o().textPills.isEmpty && overlay.window.isVisible && overlay.chrome.size.isHidden, "Esc clears the box and keeps the overlay")
        key(escape)
        require(!overlay.window.isVisible, "a second Esc closes the overlay")
        /// Opens Text mode with the Address block boxed and read.
        func openBox() async throws {
            try await open()
            mouse(.leftMouseDown, boxStart)
            mouse(.leftMouseDragged, boxEnd)
            mouse(.leftMouseUp, boxEnd)
            await overlay.textTask?.value
            requireBoxRead(addressBox, "the Address block boxed and read")
        }
        let block = "Address\n1234 Main St\nAddress 2 (Optional)\nApartment or suite"
        for (name, keyCode, characters, flags) in [("Return", returnKey, "\r", NSEvent.ModifierFlags()), ("keypad Enter", 76, "\u{3}", []), ("Cmd-C", cKey, "c", .command),
                                                  ("Shift-Return", returnKey, "\r", .shift)] {
            try await openBox()
            pasteboard.clearContents()
            key(keyCode, characters, flags)
            let boxed = await copied()
            require(boxed == block && !overlay.window.isVisible,
                    "\(name) with a box copies its lines (Shift-Return as a table, one row per line here) and closes: \(boxed.debugDescription)")
        }
        // On the cart's two columns Shift-Return copies a table and Return the rows, each title (larger) on its own line over its
        // smaller description, which is no soft wrap of it.
        for (flags, expected) in [(NSEvent.ModifierFlags.shift, "Product name\t$12\n"), ([], "Product name $12\nBrief description")] {
            try await open()
            mouse(.leftMouseDown, CGPoint(x: cart.minX, y: cart.minY))
            mouse(.leftMouseDragged, CGPoint(x: cart.maxX, y: cart.maxY))
            mouse(.leftMouseUp, CGPoint(x: cart.maxX, y: cart.maxY))
            await overlay.textTask?.value
            pasteboard.clearContents()
            key(returnKey, "\r", flags)
            let copiedCart = await copied() ?? ""
            require(copiedCart.hasPrefix(expected) && copiedCart.contains("\t") == flags.contains(.shift),
                    "\(flags.contains(.shift) ? "Shift-Return" : "Return") on a box over the cart copies \(flags.contains(.shift) ? "a table" : "rows, titles apart from their descriptions"): \(copiedCart.debugDescription)")
        }
        try await openBox()
        overlay.targetLanguage = Locale.Language(identifier: "de")
        overlay.translationStatus = { _, _ in .installed }
        var boxSent: String?
        overlay.translate = { text, _, _ in boxSent = text; return "UEBERSETZT" }
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        require(await copied() == "UEBERSETZT" && boxSent == block && !overlay.window.isVisible, "Option-Return with a box translates its lines: \(boxSent.debugDescription)")
        overlay.targetLanguage = Locale.current.language
        overlay.translationStatus = { await LanguageAvailability().status(from: $0, to: $1) }
        overlay.translate = { try await TranslationSession(installedSource: $1, target: $2).translate($0).targetText }
        // A new press off text outside the box starts a new box; a drag on text inside it selects that text and clears the box.
        try await openBox()
        mouse(.leftMouseDown, CGPoint(x: 300, y: 1450))
        mouse(.leftMouseDragged, CGPoint(x: 1200, y: 1600))
        mouse(.leftMouseUp, CGPoint(x: 1200, y: 1600))
        require(overlay.selection?.rect == CGRect(x: 300, y: 1450, width: 900, height: 150), "a press off text outside the box starts a new box: \(String(describing: overlay.selection?.rect))")
        await overlay.textTask?.value
        mouse(.leftMouseDown, boxStart)
        mouse(.leftMouseDragged, boxEnd)
        mouse(.leftMouseUp, boxEnd)
        await overlay.textTask?.value
        let address = CGPoint(x: 345, y: 932)
        require(liveText.hasText(at: topLeft(address)), "the Address label is text inside the box")
        textDrag(from: address, to: CGPoint(x: 460, y: 932))
        require(overlay.selection == nil && !o().textPills.isEmpty && o().textPills.allSatisfy { $0.minY <= address.y && $0.maxY >= address.y }
                    && liveText.selectedText.hasPrefix("Address"),
                "a drag on text inside the box selects that text, clears the box, and highlights only its row: \(liveText.selectedText.debugDescription) \(o().textPills)")
        overlay.dismiss()
        // A drag that starts on text never draws a box.
        try await open()
        mouse(.leftMouseDown, CGPoint(x: productName.minX + 10, y: productName.midY))
        var textGhost = false
        for step in 1...10 {
            mouse(.leftMouseDragged, CGPoint(x: productName.minX + 10 + 400 * CGFloat(step) / 10, y: productName.midY + 200 * CGFloat(step) / 10))
            textGhost = textGhost || overlay.view.overlays.ghost != nil
        }
        mouse(.leftMouseUp, CGPoint(x: productName.minX + 410, y: productName.midY + 200))
        require(!textGhost && liveText.selectedText.hasPrefix("Product name") && overlay.window.isVisible && overlay.text.reading == nil,
                "a drag from text selects words as before and draws no box: \(liveText.selectedText.debugDescription)")
        // A click off text, or a drag off text under Capture's 8 px click size, still reaches Live Text: it clears the selection.
        for (name, end) in [("click", boxStart), ("7 px drag", CGPoint(x: boxStart.x + 7, y: boxStart.y + 7))] {
            textDrag(from: CGPoint(x: billing.minX + 4, y: billing.midY), to: CGPoint(x: billing.maxX - 2, y: billing.midY))
            pasteboard.clearContents()
            mouse(.leftMouseDown, boxStart)
            if end != boxStart { mouse(.leftMouseDragged, end) }
            mouse(.leftMouseUp, end)
            require(liveText.selectedText.isEmpty && overlay.view.overlays.ghost == nil && overlay.text.reading == nil && overlay.window.isVisible,
                    "a \(name) off text clears the selection as before and reads nothing: \(liveText.selectedText.debugDescription)")
        }
        overlay.dismiss()

        // A drag down across lines selects them all, in order.
        try await open()
        textDrag(from: CGPoint(x: productName.minX + 10, y: productName.midY), to: CGPoint(x: 1900, y: 600))
        let lines = liveText.selectedText
        try await waitFor("the whole image's accurate OCR finishes") { overlay.text.ocrLines != nil }
        let cartPills = overlay.view.overlays.textPills
        require(cartPills.contains { $0.minY < 470 && $0.maxY > 470 } && cartPills.contains { $0.minY < 548 && $0.maxY > 548 } && cartPills.allSatisfy { $0.minX >= 1600 },
                "the highlight covers the cart rows the copy takes, the descriptions between included, and not the other column: \(cartPills)")
        require(lines.contains("Product name") && lines.contains("Second product") && lines.range(of: "Product name")!.lowerBound < lines.range(of: "Second product")!.lowerBound,
                "a drag down selects across lines in order: \(lines.debugDescription)")
        pasteboard.clearContents()
        key(cKey, "c", .command)
        let joined = await copied()
        require(!overlay.window.isVisible && joined == "Product name $12\nBrief description\n\nSecond product $8\nBrief description",
                "Cmd-C copies the cart rows the selection spans, prices in their rows and the other column left out, and closes: \(joined.debugDescription) (Live Text: \(lines.debugDescription))")

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
        let allCopied = await copied() ?? ""
        require(allCopied.hasPrefix("Below is an example form") && allCopied.hasSuffix("Save this information for next time") && allCopied.contains("Product name $12"),
                "Return copies all of it; the form beside the cart is no prose, so rows stay whole with their prices: \(allCopied.debugDescription)")

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
        require(await copied() == "UEBERSETZT" && sent == allCopied && !overlay.window.isVisible, "an installed pair translates the text Return copies and copies the translation")
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
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        require(texts(in: overlay.chrome.copy) == ["Text", "\u{21E7}", "\u{21A9}"] && overlay.chrome.copy.key == "\u{21E7}\u{21A9}",
                "with Shift held the strip's Copy reads Text and names Shift-Return: \(texts(in: overlay.chrome.copy))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
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

        // Shift-Return on a hovered element copies its text, as on a selection, not the image.
        overlay.present(image: image, frame: frame, displayID: nil)
        overlay.detectionTask?.cancel()
        overlay.setWindows([email], names: ["Email"], pointer: CGPoint(x: frame.minX + email.midX / overlay.scale, y: frame.maxY - email.midY / overlay.scale))
        require(overlay.selection == nil && overlay.hoverRect == email, "the email field is hovered: \(String(describing: overlay.hoverRect))")
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        await overlay.textTask?.value
        let hoverText = await copied()
        require(hoverText == "you@example.com" && pasteboard.data(forType: .png) == nil && !overlay.window.isVisible,
                "Shift-Return on the hovered element copies its text, not an image: \(hoverText.debugDescription)")

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
        require(reading != nil && reading!.isCancelled && overlay.selection == nil && pasteboard.string(forType: .string) == nil, "Esc during the read cancels it, drops the selection to hover, and copies nothing")
        key(escape)
        require(!overlay.window.isVisible, "a second Esc closes the overlay")

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
        let returned = await copied()
        require(returned == "Product name $12\nBrief description\n\nSecond product",
                "Return copies the rows the selection spans in reading order, not Live Text's: \(returned.debugDescription) (Live Text: \(liveOrder.debugDescription))")

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
        require(liveText.selectableItemsHighlighted && liveText.preferredInteractionTypes == .dataDetectors && liveText.alphaValue == 1,
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
        try await waitFor("the found-text flash goes off") { overlay.foundTextHighlight == nil && overlay.view.overlays.flashPills.isEmpty }
        require(liveText.preferredInteractionTypes == .textSelection && !liveText.selectableItemsHighlighted,
                "the next Text mode starts with text selection and no item highlight, and its found-text flash goes off")
        overlay.dismiss()
        require(opened == [URL(string: "https://example.com/snug")!] && !overlay.window.isVisible, "Cmd-Return closes and opens the picked item: \(opened)")
        try await openFixture()
        let tabStart = ContinuousClock.now
        key(48, "\t")
        try await waitFor("Tab finds the items") { overlay.text.picked != nil }
        let tabTime = tabStart.duration(to: .now).milliseconds
        try await Task.sleep(for: .milliseconds(1200))
        require(liveText.selectableItemsHighlighted && liveText.preferredInteractionTypes == .dataDetectors,
                "a Tab right after entering Text mode keeps its item highlight past the found-text highlight's 1 s (picked after \(Int(tabTime)) ms)")
        key(escape)
        require(overlay.window.isVisible && overlay.text.picked == nil && overlay.view.overlays.hover == nil && !liveText.selectableItemsHighlighted
                && liveText.preferredInteractionTypes == .textSelection, "Esc with an item picked unpicks it and keeps the overlay")
        textDrag(from: CGPoint(x: 203, y: 440), to: CGPoint(x: 330, y: 440))
        require(liveText.selectedText.hasPrefix("Mail"), "after unpicking, a drag selects text again: \(liveText.selectedText.debugDescription)")
        key(escape)
        require(!overlay.window.isVisible, "Esc again closes")

        // K cuts the selection or the hovered element out with Vision's foreground mask and previews it in place: the area outside the
        // subject dimmed and the subject outlined in the highlight color, S crops to the subject, C copies the color, Return copies, Cmd-S saves, K or Esc go
        // back. With no subject the overlay stays open with a notice. The fixtures are the background removal spike's (Tests/Fixtures/cutout).
        // Frame starts off, so the output is the area's size until a check turns it on.
        suffix = ""
        for key in [Pref.frame, Pref.cutoutCrop] { overlay.defaults.set(false, forKey: key) }
        overlay.defaults.set("#E5484D", forKey: Pref.highlightColor)
        let kKey: UInt16 = 40, sKey: UInt16 = 1, tab: UInt16 = 48
        func spikeFixture(_ name: String) -> CGImage { fixtureImage("Tests/Fixtures/cutout/\(name)") }
        func pixels(_ image: CGImage) -> (rgba: [UInt8], width: Int) {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)), image.width)
        }
        /// K, timed from the key to the preview (or the notice), with the footprint after.
        func previewCutout() async -> (milliseconds: Double, footprint: String) {
            let start = ContinuousClock.now
            key(kKey, "k")
            await overlay.textTask?.value
            return (start.duration(to: .now).milliseconds, footprint())
        }
        func copiedPNG() async -> CGImage? {
            await overlay.commitTask?.value
            return pasteboard.data(forType: .png).map { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData($0 as CFData, nil)!, 0, nil)! }
        }
        overlay.defaults.set(false, forKey: Pref.snap)
        let icon = spikeFixture("icon-flat-composite.png")
        let iconRect = CGRect(x: 110, y: 60, width: 180, height: 180)
        let iconFrame = CGRect(x: frame.minX, y: frame.minY, width: CGFloat(icon.width) / 2, height: CGFloat(icon.height) / 2)
        overlay.present(image: icon, frame: iconFrame, displayID: nil)
        mouse(.leftMouseDown, iconRect.origin)
        mouse(.leftMouseDragged, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        mouse(.leftMouseUp, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        require(overlay.selection?.rect == iconRect, "with snap off a drag selects the icon's rect exactly: \(String(describing: overlay.selection?.rect))")
        pasteboard.clearContents()
        let beforeCutout = footprint()
        let firstK = await previewCutout()
        let preview = overlay.cutout
        require(overlay.window.isVisible && preview != nil && pasteboard.data(forType: .png) == nil, "K on a selection opens the preview and copies nothing")
        require(preview?.rect == iconRect && preview?.subjects.count == 1 && preview!.view.superview === overlay.view
                && preview!.view.checker.frame == overlay.view.viewRect(iconRect) && preview!.view.subject.frame == preview!.view.checker.frame
                && preview!.view.ghost.frame == preview!.view.checker.frame && preview!.view.outline.frame == preview!.view.checker.frame && (preview!.view.subject.contents as! CGImage).width == Int(iconRect.width)
                && preview!.view.outline.mask!.contents as! CGImage === preview!.subjects[0].outline,
                "the preview fills the area with the checkerboard and the faint removed pixels under the subject's own pixels, and outlines the subject")
        let sublayers = overlay.view.layer!.sublayers!
        require(sublayers.firstIndex(of: preview!.view.content)! < sublayers.firstIndex(of: overlay.view.guides.root)!,
                "the preview draws under the guides, so the loupe stays on top of the subject")
        require(preview!.view.outline.backgroundColor == Highlight.color(hex: "#E5484D").cgColor && preview!.view.ghost.opacity == 0.2
                    && (preview!.view.ghost.contents as! CGImage).width == Int(iconRect.width) && preview!.view.checker.backgroundColor != nil,
                "the ghost: a checkerboard, the removed pixels at 20%, the outline in the highlight color: \(String(describing: preview!.view.outline.backgroundColor))")
        let ring = preview!.subjects[0].outline
        let ringData = ring.dataProvider!.data!
        let ringAlpha = CFDataGetBytePtr(ringData)!
        let ringPixels = (0..<ring.height).reduce(0) { sum, y in sum + (0..<ring.width).count { ringAlpha[y * ring.bytesPerRow + $0 * 2 + 1] > 0 } }
        require(ringAlpha[(ring.height / 2) * ring.bytesPerRow + ring.width / 2 * 2 + 1] == 0 && ringPixels > 0 && ringPixels < ring.width * ring.height / 10,
                "the outline is a thin ring outside the subject: \(ringPixels) of \(ring.width * ring.height) pixels, center clear")
        require(overlay.selection == nil && texts(in: overlay.chrome.topBar).last == "?" && !texts(in: overlay.chrome.topBar).contains("Capture") && overlay.view.overlays.selection == iconRect
                && !overlay.view.overlays.showsHandles, "while previewing, the top bar has no modes, the handles stay hidden and the area stays outlined")
        require(texts(in: overlay.chrome.strip) == ["Snap to subject", "S", "Save", "\u{2318}", "S", "Copy", "\u{21A9}"] && !overlay.chrome.crop.lit
                    && texts(in: overlay.chrome.status) == ["back", "K", "esc"] && overlay.chrome.status.frame.minY == overlay.chrome.size.frame.minY
                    && overlay.chrome.status.frame.minX == overlay.chrome.size.frame.maxX + 6,
                "the strip has the preview's controls, Snap to subject plain, and a status chip after the size chip says K back: \(texts(in: overlay.chrome.strip)) \(texts(in: overlay.chrome.status))")
        let (previewPixels, previewWidth) = pixels(preview!.subjects[0].image)
        require(previewPixels[3] == 0 && previewPixels[(previewWidth / 2 + previewWidth * previewWidth / 2) * 4 + 3] == 255, "the preview is transparent at the corner and opaque at the center")
        // The press is near the area's top, off the strip, which this small view lays across its middle.
        mouse(.leftMouseDown, CGPoint(x: iconRect.midX, y: iconRect.minY + 20))
        mouse(.leftMouseDragged, CGPoint(x: iconRect.midX + 40, y: iconRect.minY + 20 + 40))
        mouse(.leftMouseUp, CGPoint(x: iconRect.midX + 40, y: iconRect.minY + 20 + 40))
        key(fKey, "f")
        require(overlay.cutout != nil && overlay.selection == nil && overlay.view.overlays.selection == iconRect, "the pointer and other keys do nothing while previewing: \(overlay.cutout != nil) \(String(describing: overlay.selection)) \(String(describing: overlay.view.overlays.selection)) \(iconRect)")
        // S crops to the subject's box: the outlined frame and the dim move to it, and the choice is remembered; Snap stays as it was.
        let box = preview!.subjects[0].bounds.offsetBy(dx: iconRect.minX, dy: iconRect.minY)
        key(sKey, "s")
        require(!overlay.defaults.bool(forKey: Pref.snap), "S in the preview leaves Snap off")
        require(overlay.cutout?.cropped == true && overlay.defaults.bool(forKey: Pref.cutoutCrop) && overlay.view.overlays.selection == box
                && overlay.cutout!.view.checker.frame == overlay.view.viewRect(box) && overlay.cutout!.view.ghost.frame == overlay.view.viewRect(box) && overlay.chrome.crop.lit,
                "S crops to the subject's box \(box) and lights Snap to subject: outlined \(String(describing: overlay.view.overlays.selection))")
        key(kKey, "k")
        require(overlay.cutout == nil && preview!.view.superview == nil && preview!.view.content.superlayer == nil && overlay.selection?.rect == iconRect && texts(in: overlay.chrome.strip).contains("Edit"),
                "K again goes back to the selection: preview \(overlay.cutout != nil), view in overlay \(preview!.view.superview != nil), selection \(String(describing: overlay.selection?.rect)), strip \(texts(in: overlay.chrome.strip))")
        let secondK = await previewCutout()
        require(overlay.cutout != nil, "K opens the preview again")
        require(overlay.cutout!.cropped && overlay.view.overlays.selection == box, "the preview opens cropped as last chosen")
        key(sKey, "s")
        require(overlay.cutout?.cropped == false && !overlay.defaults.bool(forKey: Pref.cutoutCrop) && overlay.view.overlays.selection == iconRect,
                "S again shows the whole area: \(String(describing: overlay.view.overlays.selection))")
        key(escape)
        // A second K while the mask runs replaces the first run: one preview, and K goes back to the selection.
        key(kKey, "k")
        let firstRun = overlay.textTask
        key(kKey, "k")
        await firstRun?.value
        await overlay.textTask?.value
        require(overlay.view.subviews.count { $0 is CutoutView } == 1, "two quick K presses open one preview: \(overlay.view.subviews.count { $0 is CutoutView })")
        key(kKey, "k")
        require(overlay.view.subviews.allSatisfy { !($0 is CutoutView) } && overlay.selection?.rect == iconRect, "K after two quick K presses goes back to the selection")
        key(kKey, "k")
        await overlay.textTask?.value
        key(escape)
        require(overlay.cutout == nil && overlay.selection?.rect == iconRect && overlay.window.isVisible, "Esc in the preview goes back to the selection")
        print("Cutout preview: first K \(String(format: "%.1f", firstK.milliseconds)) ms to the preview, footprint \(beforeCutout) before, \(firstK.footprint) after; "
              + "second K \(String(format: "%.1f", secondK.milliseconds)) ms, footprint \(secondK.footprint) after")
        _ = await previewCutout()
        key(returnKey, "\r")
        let iconCut = await copiedPNG()
        require(!overlay.window.isVisible && iconCut != nil, "Return in the preview closes the overlay and copies a PNG")
        let (cut, cutWidth) = pixels(iconCut!)
        let (source, sourceWidth) = pixels(icon)
        let center = ((iconCut!.height / 2) * cutWidth + cutWidth / 2) * 4
        let sourceCenter = ((Int(iconRect.midY)) * sourceWidth + Int(iconRect.midX)) * 4
        require(abs(iconCut!.width - 180) <= 2 && abs(iconCut!.height - 180) <= 2, "the cutout is the icon's size: \(iconCut!.width)x\(iconCut!.height)")
        require(cut[3] == 0 && cut[(cutWidth - 1) * 4 + 3] == 0, "the cutout's rounded corners are transparent (alpha \(cut[3]), \(cut[(cutWidth - 1) * 4 + 3]))")
        require(cut[center + 3] == 255 && (0..<3).allSatisfy { abs(Int(cut[center + $0]) - Int(source[sourceCenter + $0])) <= 3 },
                "the cutout's center is opaque and keeps the source color: \(Array(cut[center..<center + 4])) vs \(Array(source[sourceCenter..<sourceCenter + 4]))")
        try await Task.sleep(for: .seconds(2))
        print("Cutout footprint: \(footprint()) 2 s after delivery")

        // M applies to the cutout as to a capture: the window shadow grows the canvas 52 pt to the sides, 35 above and 70 below and
        // falls under the subject. The canvas takes the area's corner radii, here edited with ].
        let (grown, below) = ((208, 210), 140)
        overlay.defaults.set(true, forKey: Pref.frame)
        overlay.present(image: icon, frame: iconFrame, displayID: nil)
        mouse(.leftMouseDown, iconRect.origin)
        mouse(.leftMouseDragged, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        mouse(.leftMouseUp, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        key(30, "]")
        _ = await previewCutout()
        require(overlay.cutout?.radii == overlay.cornerRadii(of: iconRect) && overlay.cutout?.radii.isSquare == false,
                "the preview keeps the area's corner radii for the output: \(String(describing: overlay.cutout?.radii))")
        let framedCutout = overlay.cutout!, clip = framedCutout.view.clip.path!
        require(overlay.view.overlays.radii == framedCutout.frameRadii && clip.boundingBoxOfPath == framedCutout.view.checker.frame && clip.contains(framedCutout.view.checker.frame.origin) == framedCutout.cropped,
                "the preview and the dim hole clip to the frame's corner radii: \(framedCutout.frameRadii) \(clip.boundingBoxOfPath)")
        pasteboard.clearContents()
        let chip = texts(in: overlay.chrome.size)
        key(returnKey, "\r")
        let grownCut = await copiedPNG()
        require(grownCut.map { ($0.width, $0.height) == (180 + grown.0, 180 + grown.1) } == true,
                "Frame on grows the cutout by \(grown): \(String(describing: grownCut.map { "\($0.width)x\($0.height)" }))")
        require(chip == ["180 x 180  + frame \(grownCut!.width - 180) x \(grownCut!.height - 180)"],
                "the size chip adds what Frame adds to the delivered cutout: \(chip)")
        let (grownPixels, grownWidth) = pixels(grownCut!)
        let shade = grownPixels[((grownCut!.height - below + 20) * grownWidth + grownWidth / 2) * 4 + 3]
        require(shade > 0 && shade < 255, "Frame on: a soft shadow falls 20 px under the area (alpha \(shade))")
        overlay.defaults.set(false, forKey: Pref.frame)

        // Cmd-S in the preview saves the cutout and leaves the clipboard alone.
        overlay.present(image: icon, frame: iconFrame, displayID: nil)
        mouse(.leftMouseDown, iconRect.origin)
        mouse(.leftMouseDragged, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        mouse(.leftMouseUp, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        let savedBefore = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        pasteboard.clearContents()
        _ = await previewCutout()
        key(sKey, "s", .command)
        await overlay.commitTask?.value
        let saved = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)).subtracting(savedBefore)
        let savedSize = saved.first.flatMap { pngSize(try? Data(contentsOf: folder.appending(path: $0))) }
        require(!overlay.window.isVisible && saved.count == 1 && savedSize.map { abs($0.width - 180) <= 2 } == true && pasteboard.data(forType: .png) == nil,
                "Cmd-S in the preview saves the cutout and leaves the clipboard alone: \(saved), \(String(describing: savedSize))")

        overlay.defaults.set(true, forKey: Pref.snap)
        overlay.present(image: icon, frame: iconFrame, displayID: nil)
        await overlay.detectionTask?.value
        // Geometry finds only the arch inside the tile, so the tile comes in as a window rectangle, as a live capture lists it.
        overlay.setWindows([iconRect], names: ["Icon"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: iconRect.minX + 20, y: iconRect.maxY - 20))
        let hovered = overlay.hoverRect
        require(hovered == iconRect, "hovering the icon tile picks it: \(String(describing: hovered))")
        _ = await previewCutout()
        require(overlay.cutout?.rect == iconRect && overlay.view.overlays.hover == nil, "K on the hovered element previews its cutout")
        key(kKey, "k")
        require(overlay.cutout == nil && overlay.selection == nil && overlay.hoverRect == iconRect, "K in a preview opened from a hover goes back to the hover")
        _ = await previewCutout()
        pasteboard.clearContents()
        key(returnKey, "\r")
        let tileCut = await copiedPNG()
        require(!overlay.window.isVisible && tileCut.map { CGFloat($0.width) <= hovered!.width && pixels($0).rgba[3] == 0 } == true,
                "Return copies the hovered element's cutout with transparent corners: \(String(describing: tileCut.map { "\($0.width)x\($0.height)" }))")

        // Several subjects: Tab and Shift-Tab step through all of them, then each one alone.
        overlay.defaults.set(false, forKey: Pref.snap)
        let group = subjectsFixture([icon, spikeFixture("dock-tile-composite.png"), spikeFixture("badge-real.png")])
        overlay.present(image: group, frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(group.width) / 2, height: CGFloat(group.height) / 2), displayID: nil)
        overlay.selection = AreaSelection(extent: overlay.extent, exact: overlay.extent)
        _ = await previewCutout()
        let count = (overlay.cutout?.subjects.count ?? 1) - 1
        print("Subjects fixture: \(count) instances")
        require(count > 1, "the subjects fixture has more than one instance: \(count)")
        require(texts(in: overlay.chrome.strip).prefix(2) == ["All \(count) subjects", "tab"], "the strip says all subjects are shown and names tab: \(texts(in: overlay.chrome.strip))")
        key(tab, "\t")
        require(overlay.cutout?.shown == 1 && texts(in: overlay.chrome.strip).first == "Subject 1 of \(count)"
                && overlay.cutout!.view.subject.contents as! CGImage === overlay.cutout!.subjects[1].image, "Tab shows the first subject alone: \(texts(in: overlay.chrome.strip))")
        key(sKey, "s")
        key(tab, "\t", .shift)
        key(tab, "\t", .shift)
        require(overlay.cutout?.shown == count && texts(in: overlay.chrome.strip).first == "Subject \(count) of \(count)", "Shift-Tab steps back and wraps to the last subject")
        let alone = overlay.cutout!.subjects[count].bounds
        require(overlay.view.overlays.selection == alone && alone.width < CGFloat(group.width) / 2,
                "cropped, the outlined frame follows the shown subject's box \(alone): \(String(describing: overlay.view.overlays.selection))")
        pasteboard.clearContents()
        key(returnKey, "\r")
        let one = await copiedPNG()
        require(one.map { CGFloat($0.width) == alone.width && CGFloat($0.height) == alone.height } == true,
                "Return copies only the shown subject, cropped to its box: \(String(describing: one.map { "\($0.width)x\($0.height)" }))")
        overlay.defaults.set(false, forKey: Pref.cutoutCrop)

        // C in the preview copies the color under the pointer, as everywhere, and closes the overlay.
        overlay.present(image: icon, frame: iconFrame, displayID: nil)
        mouse(.leftMouseDown, iconRect.origin)
        mouse(.leftMouseDragged, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        mouse(.leftMouseUp, CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        _ = await previewCutout()
        let colorPoint = CGPoint(x: iconRect.minX + 4, y: iconRect.minY + 4)
        mouse(.mouseMoved, colorPoint)
        overlay.defaults.set(ColorFormat.hex.rawValue, forKey: Pref.colorFormat)
        pasteboard.clearContents()
        key(cKey, "c")
        let pointColor = ColorFormat.hex.string(for: ColorFormat.average(of: icon, in: CGRect(origin: colorPoint, size: CGSize(width: 1, height: 1))))
        require(!overlay.window.isVisible && overlay.cutout == nil && pasteboard.string(forType: .string) == pointColor,
                "C in the preview copies the color under the pointer \(pointColor): \(pasteboard.string(forType: .string) ?? "nothing")")

        overlay.present(image: image, frame: frame, displayID: nil)
        overlay.selection = AreaSelection(extent: overlay.extent, exact: overlay.extent)
        pasteboard.clearContents()
        _ = await previewCutout()
        require(overlay.window.isVisible && overlay.cutout == nil && pasteboard.data(forType: .png) == nil && overlay.selection != nil,
                "K on a whole page finds no subject: no preview, nothing copied, and the overlay stays open")
        require(texts(in: overlay.chrome.status) == ["No subject found"], "a No subject found notice shows: \(texts(in: overlay.chrome.status))")
        overlay.dismiss()

        // Last, the Text strip: these selections leave Live Text selecting the word under a later single click, even in a new
        // overlay, which the click checks above would trip on.
        // A text selection gets a strip under it: Copy with Return alone, relabeled by Shift and Option, whose caps show only while held (Shift: Rows, Option: Translate).
        // Its box is Live Text's: the selected glyphs' union, which lands on accurate OCR's line boxes within 3 pt.
        try await open()
        func textFlags(_ modifiers: NSEvent.ModifierFlags) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        }
        func pointBox(_ pixels: CGRect) -> CGRect {
            CGRect(x: pixels.minX / overlay.scale, y: overlay.view.bounds.height - pixels.maxY / overlay.scale, width: pixels.width / overlay.scale, height: pixels.height / overlay.scale)
        }
        func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 3) -> Bool {
            abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
        }
        let strip = overlay.chrome.strip
        let fullText = liveText.text
        liveText.selectedRanges = [fullText.range(of: "Product name")!]
        overlay.refresh()
        let productBox = overlay.textSelectionBox!
        require(near(productBox, pointBox(productName)) && !strip.isHidden && texts(in: strip) == ["Copy", "\u{21A9}"] && strip.frame.maxY == productBox.minY - 8 && strip.frame.minX == productBox.minX,
                "a text selection's box is its line and a strip hangs under it, Copy with Return alone: \(productBox) \(pointBox(productName)) \(texts(in: strip)) \(strip.frame)")
        let restLeft = strip.frame.minX
        for (held, title, glyph) in [(NSEvent.ModifierFlags.shift, "Rows", "\u{21E7}"), (.option, "Translate", "\u{2325}")] {
            textFlags(held)
            require(texts(in: strip) == [title, glyph, "\u{21A9}"] && overlay.chrome.copy.isEnabled && overlay.chrome.copy.caps.first!.pressed && strip.frame.minX == restLeft,
                    "holding \(glyph) relabels Copy \(title), lights its cap and keeps the strip's left edge: \(texts(in: strip))")
        }
        textFlags(.command)
        require(!overlay.chrome.copy.isEnabled && texts(in: strip) == ["Copy", "\u{21A9}"], "Command has no Text meaning: Copy dims")
        textFlags([])
        require(texts(in: strip) == ["Copy", "\u{21A9}"] && overlay.chrome.copy.isEnabled, "releasing restores the strip")
        // Real drags, forward and backward.
        for (from, to) in [(CGPoint(x: billing.minX + 4, y: billing.midY), CGPoint(x: billing.maxX - 2, y: billing.midY)),
                           (CGPoint(x: billing.maxX - 2, y: billing.midY), CGPoint(x: billing.minX + 4, y: billing.midY))] {
            textDrag(from: from, to: to)
            let box = overlay.textSelectionBox
            require(liveText.selectedText == "Billing address" && box.map { near($0, pointBox(billing), 4) } == true && !strip.isHidden,
                    "a drag \(from.x < to.x ? "forward" : "backward") over Billing address boxes its line: \(liveText.selectedText.debugDescription) \(String(describing: box)) \(pointBox(billing))")
        }
        // A click on Copy with Shift held, the strip over text, copies the selection as rows; the click never reaches Live Text.
        textDrag(from: CGPoint(x: billing.minX + 4, y: billing.midY), to: CGPoint(x: billing.maxX - 2, y: billing.midY))
        textFlags(.shift)
        let copyCenter = overlay.chrome.copy.convert(CGPoint(x: overlay.chrome.copy.bounds.midX, y: overlay.chrome.copy.bounds.midY), to: overlay.view)
        let copyPixel = CGPoint(x: copyCenter.x * overlay.scale, y: (overlay.view.bounds.height - copyCenter.y) * overlay.scale)
        require(liveText.hasText(at: topLeft(copyPixel)), "the strip's Copy under Billing address lies over text: \(strip.frame) \(copyPixel)")
        pasteboard.clearContents()
        mouse(.leftMouseDown, copyPixel, .shift)
        mouse(.leftMouseUp, copyPixel, .shift)
        await overlay.textTask?.value
        let clicked = pasteboard.string(forType: .string)
        textFlags([])
        overlay.dismiss()
        try await open()
        textDrag(from: CGPoint(x: billing.minX + 4, y: billing.midY), to: CGPoint(x: billing.maxX - 2, y: billing.midY))
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        await overlay.textTask?.value
        require(clicked?.hasPrefix("Billing address") == true && clicked == pasteboard.string(forType: .string),
                "a Shift-click on the strip's Rows copies what Shift-Return copies: \(String(describing: clicked)) \(String(describing: pasteboard.string(forType: .string)))")
        overlay.dismiss()
        try await open()
        // A drag down over several lines shows no strip until the release, so the strip never lands under the pointer mid-drag.
        let downTo = CGPoint(x: billing.minX + 120, y: billing.maxY + 300)
        mouse(.leftMouseDown, CGPoint(x: billing.minX + 4, y: billing.midY))
        var stripMidDrag = false
        for step in 1...10 {
            let t = CGFloat(step) / 10
            mouse(.leftMouseDragged, CGPoint(x: billing.minX + 4 + (downTo.x - billing.minX - 4) * t, y: billing.midY + (downTo.y - billing.midY) * t))
            stripMidDrag = stripMidDrag || !strip.isHidden
        }
        mouse(.leftMouseUp, downTo)
        require(!stripMidDrag && liveText.selectedText.hasPrefix("Billing address") && liveText.selectedText.contains("\n") && !strip.isHidden,
                "a drag down over lines shows no strip until the release, then shows it: \(liveText.selectedText.debugDescription) \(stripMidDrag)")
        liveText.selectedRanges = [fullText.range(of: "Billing address")!.lowerBound..<fullText.range(of: "Product name")!.upperBound]
        overlay.refresh()
        let columns = overlay.textSelectionBox!
        require(columns.minX <= pointBox(billing).minX + 3 && columns.maxX >= pointBox(productName).maxX - 3 && columns.maxY >= pointBox(billing).maxY - 3,
                "a selection across both columns boxes both: \(columns)")
        overlay.dismiss()

        requireBackground(overlay)
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

    /// Launch's Vision warm-up on private defaults, before anything in this process loads Vision: the first call starts a `--warm-vision`
    /// child that records this binary's date once it exits cleanly, and a second call starts nothing. Prints the child's time and this
    /// process's footprint before and after, which the child's compile and memory leave alone.
    static func verifyWarmVisionChild() async throws {
        let defaults = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "snug-warm-\(UUID().uuidString)").path)!
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Vision warm-up verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            print("- \(message)")
        }
        let built = try Bundle.main.executableURL!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let (start, before) = (ContinuousClock.now, footprint())
        let child = OverlayController.warmVisionInChild(defaults: defaults)
        require(child?.arguments == ["--warm-vision"] && child!.qualityOfService == .utility && defaults.object(forKey: Pref.visionWarmedBuild) == nil,
                "launch on a binary with no warmed date starts a utility-priority --warm-vision child")
        require(OverlayController.visionWarmUp != nil, "the overlay tracks the child as Vision's warm-up")
        for _ in 0..<6000 where child!.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        // The termination handler runs on its own thread, just after the exit is visible here.
        for _ in 0..<20 where defaults.object(forKey: Pref.visionWarmedBuild) == nil { try await Task.sleep(for: .milliseconds(50)) }
        require(child!.terminationStatus == 0 && defaults.object(forKey: Pref.visionWarmedBuild) as? Date == built, "the child exits with status 0 and records this binary's date")
        await OverlayController.visionWarmUp?.value
        require(OverlayController.visionWarmUp == nil, "the warm-up ends when the child exits")
        require(OverlayController.warmVisionInChild(defaults: defaults) == nil, "with this binary's date stored, launch starts no child")
        print("Vision warm-up child: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms, this process's footprint \(before) before, \(footprint()) after")
    }

    /// `--warm-vision`: runs Tab's accurate OCR and barcode requests on the warm-up page, then Shift-Return's accurate OCR on each of its
    /// script rows alone, and exits. Vision compiles each model into the on-disk cache on a binary's first use of it: the text detector,
    /// orientation, the barcode networks, and one recognizer per script, which automatic language detection only reaches for a row on its
    /// own. A child process pays that once per binary and takes the requests' memory with it when it exits. Prints the time, the items
    /// found, and the footprint before and after.
    static func warmVisionAndExit() async throws {
        let before = footprint()
        let start = ContinuousClock.now
        let (page, cells) = warmFixture()
        let items = try await OverlayController.findItems(in: page)
        for cell in cells { _ = try await OverlayController.recognize(page, crop: cell) }
        print("warm-vision: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms, \(items.count) items, footprint \(before) before, \(footprint()) after")
        exit(EXIT_SUCCESS)
    }

    /// The found-items page at 2000 x 1100 px with an Arabic and a Devanagari row of text above it, and each row's rect (top-left origin,
    /// pixels). Those two scripts have recognizers of their own; Cyrillic, Chinese, Japanese, Korean and Thai rows compiled nothing more.
    static func warmFixture() -> (page: CGImage, cells: [CGRect]) {
        let (width, height) = (2000, 1100)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(itemsFixture(width: width, height: height), in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = ["مرحبا بك في التطبيق", "नमस्ते, आप कैसे हैं"]
        var cells: [CGRect] = []
        for (index, text) in rows.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]))
            let baseline = CGPoint(x: 40 + index * 640, y: 1050)
            context.textPosition = baseline
            CTLineDraw(line, context)
            cells.append(CGRect(x: baseline.x - 20, y: CGFloat(height) - baseline.y - 38, width: 640, height: 50))
        }
        return (context.makeImage()!, cells)
    }

    /// `images` side by side on a white page, 20 px apart and from the edges, centered vertically. With the icon, Dock tile and badge
    /// fixtures Vision finds 3 instances; 120 px apart it finds none, as on a whole page.
    static func subjectsFixture(_ images: [CGImage]) -> CGImage {
        let (width, height) = (images.reduce(20) { $0 + $1.width + 20 }, images.map(\.height).max()! + 40)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 20
        for image in images {
            context.draw(image, in: CGRect(x: x, y: (height - image.height) / 2, width: image.width, height: image.height))
            x += image.width + 20
        }
        return context.makeImage()!
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
