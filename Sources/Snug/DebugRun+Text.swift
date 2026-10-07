import AppKit
import CoreImage
import ScreenshotCore
import Translation

extension DebugRun {
    /// `--verify-text-ui`: drives Text mode through synthesized events on form-test.png with a QR code drawn in.
    static func verifyText(image source: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        let pasteboard = overlay.pasteboard
        var passed: [String] = []
        var opened: [URL] = []
        overlay.openURL = { opened.append($0) }

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
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: windowPoint(pixel), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        let tab: UInt16 = 48, returnKey: UInt16 = 36, escape: UInt16 = 53, tKey: UInt16 = 17, fKey: UInt16 = 3, space: UInt16 = 49, cKey: UInt16 = 8
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125

        // The fixture plus a QR code in an empty area.
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/snug".utf8)])!.outputImage!
            .samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let code = CIContext().createCGImage(qr, from: qr.extent)!
        let origin = CGPoint(x: 1700, y: 1150)
        let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let codeRect = CGRect(x: origin.x, y: CGFloat(source.height) - origin.y - CGFloat(code.height), width: CGFloat(code.width), height: CGFloat(code.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(codeRect.insetBy(dx: -40, dy: -40))
        context.draw(code, in: codeRect)
        let image = context.makeImage()!

        let cart = CGRect(x: 1645, y: 384, width: 582, height: 557)
        let email = CGRect(x: 326, y: 730, width: 660, height: 153)
        let barcode = CGRect(x: origin.x - 60, y: origin.y - 60, width: CGFloat(code.width) + 120, height: CGFloat(code.height) + 120)

        func open() {
            overlay.present(image: image, frame: frame, displayID: nil)
            key(tKey, "t")
        }
        func select(_ rect: CGRect) async throws {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY))
            mouse(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY))
            require(overlay.text.result == nil && overlay.textTask == nil, "no OCR while dragging")
            mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY))
            require(!overlay.chrome.reading.isHidden && texts(in: overlay.chrome.reading) == ["Reading text..."], "a Reading text... pill shows while OCR runs")
            try await waitFor("OCR finishes after release") { overlay.text.result != nil }
            require(overlay.chrome.reading.isHidden, "the Reading text... pill goes away when OCR finishes")
        }
        func copied() async -> String? {
            await overlay.commitTask?.value
            return pasteboard.string(forType: .string)
        }

        overlay.present(image: image, frame: frame, displayID: nil)
        require(overlay.mode == .area, "the overlay opens in Area mode")
        key(tKey, "t")
        require(overlay.mode == .text, "T enters Text mode")
        require(texts(in: overlay.chrome.hints) == ["Drag: select text", "Click: copy text block", "F: all text", "C: color", "A: back to area", "?: keys"], "Text mode with no region shows its hint strip")
        require(overlay.textPage == nil, "nothing is recognized until Text mode needs it")
        overlay.dismiss()

        // Region over the cart: reading order, then table.
        open()
        try await select(cart)
        require(overlay.snapPreview == nil && overlay.text.rect == cart, "a Text drag selects exactly the dragged region without snapping")
        let chrome = overlay.chrome
        require(texts(in: chrome.hints) == ["Handles: resize", "Arrows: nudge", "Return: copy text", "Option-Return: translate", "Tab: links", "F: all text", "C: color"], "a Text region shows its hint strip")
        require(chrome.styleBar.isHidden && !chrome.bottomBar.isHidden && chrome.bottomBar.modeButtons[.text]!.layer!.backgroundColor != nil, "Text mode keeps the bottom bar with Text filled")
        let counts = texts(in: chrome.count)
        require(!chrome.count.isHidden && counts.count == 1 && counts[0].hasPrefix("9 lines, 2 columns"), "the region badge counts lines and columns: \(counts)")
        require(texts(in: chrome.table) == ["Looks like a table"], "a two-column region shows Looks like a table")
        let regionBox = overlay.view.viewRect(cart)
        require(chrome.count.frame.minY >= regionBox.maxY && chrome.count.frame.maxY <= overlay.view.bounds.height - overlay.topInset, "the badge sits above the region, inside the screen")
        let lines = overlay.text.result!.lines
        require(lines.contains { $0.text.contains("Product name") } && lines.allSatisfy { cart.insetBy(dx: -4, dy: -4).contains($0.bounds) },
                "OCR finds the cart text and maps boxes back into full-image pixels")
        require(!lines.contains { $0.text.contains("Billing") }, "OCR ran on the crop only")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(!overlay.window.isVisible, "Return closes the overlay")
        let reading = await copied() ?? ""
        require(reading.contains("Product name $12\nBrief description\nSecond product $8"), "Return copies lines in reading order: \(reading.debugDescription)")

        open()
        try await select(cart)
        pasteboard.clearContents()
        key(returnKey, "\r", .shift)
        let table = await copied() ?? ""
        require(table.contains("Product name\t$12\nBrief description\nSecond product\t$8"), "Shift-Return copies tab-separated rows: \(table.debugDescription)")

        // Found items: a link in the email field.
        open()
        try await select(email)
        require(overlay.chrome.table.isHidden, "a one-line region shows no table badge")
        let items = overlay.text.result!.items
        require(items.contains { $0.text == "you@example.com" && $0.kind == .link }, "found items include the email link: \(items.map(\.text))")
        pasteboard.clearContents()
        key(tab)
        let linkIndex = overlay.text.picked
        require(linkIndex.map { items[$0].text == "you@example.com" } == true, "Tab picks the first found item")
        key(tab, "", .shift)
        key(tab)
        require(overlay.text.picked == linkIndex, "Shift-Tab and Tab step back and forth")
        key(returnKey, "\r")
        require(opened.isEmpty, "plain Return opens nothing")
        let item = await copied()
        require(item == "you@example.com", "Return with an item picked copies that item: \(item.debugDescription)")

        open()
        try await select(email)
        key(tab)
        key(returnKey, "\r", .command)
        require(opened.map(\.absoluteString) == ["mailto:you@example.com"] && !overlay.window.isVisible, "Cmd-Return opens the picked link")

        // Esc returns to the whole text, then closes.
        open()
        try await select(email)
        key(tab)
        key(escape)
        require(overlay.text.picked == nil && overlay.window.isVisible && overlay.text.result != nil, "Esc with an item picked returns to the whole text")
        key(escape)
        require(!overlay.window.isVisible, "Esc again closes")

        // Barcode payload.
        open()
        try await select(barcode)
        let payload = overlay.text.result!.items.first { $0.kind == .barcode }
        require(payload?.text == "https://example.com/snug" && barcode.contains(payload!.bounds), "barcode payload is found inside the region")
        opened = []
        repeat { key(tab) } while overlay.text.result!.items[overlay.text.picked!].kind != .barcode
        key(returnKey, "\r", .command)
        require(opened.map(\.absoluteString) == ["https://example.com/snug"], "Cmd-Return opens the barcode URL")

        // Closing before OCR finishes drops the result.
        open()
        mouse(.leftMouseDown, CGPoint(x: cart.minX, y: cart.minY))
        mouse(.leftMouseDragged, CGPoint(x: cart.maxX, y: cart.maxY))
        mouse(.leftMouseUp, CGPoint(x: cart.maxX, y: cart.maxY))
        key(escape)
        try await Task.sleep(for: .seconds(2))
        require(overlay.text.result == nil && overlay.textTask == nil, "dismiss cancels in-flight OCR")


        // Click with no region copies the text block under the pointer; the page OCR is lazy and reused.
        open()
        let dead = CGPoint(x: 1000, y: 1250)
        pasteboard.clearContents()
        mouse(.leftMouseDown, dead)
        mouse(.leftMouseUp, dead)
        await overlay.textTask?.value
        let page = overlay.textPage
        require(page != nil && pasteboard.string(forType: .string) == nil && overlay.window.isVisible, "a click on empty space starts the page OCR and copies nothing")
        let lineAt = try await page!.value.lines.first { $0.text.contains("Brief description") }!
        let spot = CGPoint(x: lineAt.bounds.midX, y: lineAt.bounds.midY)
        mouse(.leftMouseDown, spot)
        mouse(.leftMouseUp, spot)
        require(overlay.textPage == page, "the second click reuses the page OCR instead of starting another")
        await overlay.textTask?.value
        let block = await copied() ?? ""
        require(!overlay.window.isVisible, "a click on text closes the overlay")
        require(block.contains("Brief description") && block.contains("\n") && !block.contains("Billing"), "a click copies the text block under the pointer: \(block.debugDescription)")

        // F selects all text on screen using the same page OCR.
        open()
        key(fKey, "f")
        require(overlay.text.rect == overlay.extent, "F selects the whole screen as the region")
        try await waitFor("whole-screen OCR") { overlay.text.result != nil }
        require(overlay.text.result!.lines.contains { $0.text.contains("Billing") } && overlay.text.result!.lines.contains { $0.text.contains("Product name") }, "F recognizes text across the whole screen")
        require(overlay.chrome.hints.frame.width > 0 && texts(in: overlay.chrome.hints).contains("Arrows: nudge"), "the whole-screen region is editable")

        // The region stays editable: arrows, handles, move, Space-drag.
        open()
        try await select(cart)
        let one = overlay.scale
        key(right, "")
        key(right, "")
        require(overlay.text.rect == cart.offsetBy(dx: 2 * one, dy: 0) && overlay.text.result == nil, "arrows nudge the region and drop the stale OCR")
        key(down, "", .shift)
        require(overlay.text.rect == cart.offsetBy(dx: 2 * one, dy: 10 * one), "Shift-arrow nudges 10 pt")
        let nudged = overlay.text.rect!
        try await waitFor("OCR after nudges") { overlay.text.result != nil }
        require(overlay.text.result!.lines.allSatisfy { nudged.insetBy(dx: -4, dy: -4).contains($0.bounds) }, "OCR re-runs once for the final nudged region")
        overlay.dismiss()
        open()
        try await select(cart)

        let before = overlay.text.rect!
        mouse(.leftMouseDown, CGPoint(x: before.maxX, y: before.maxY))
        mouse(.leftMouseDragged, CGPoint(x: before.maxX, y: before.midY))
        mouse(.leftMouseUp, CGPoint(x: before.maxX, y: before.midY))
        let shrunk = overlay.text.rect!
        require(shrunk.maxY == before.midY && shrunk.minY == before.minY && overlay.text.result == nil, "dragging a handle resizes the region")
        try await waitFor("OCR after resize") { overlay.text.result != nil }
        require(overlay.text.result!.lines.count < lines.count && overlay.text.result!.lines.allSatisfy { shrunk.insetBy(dx: -4, dy: -4).contains($0.bounds) }, "OCR re-runs for the resized region")

        mouse(.leftMouseDown, CGPoint(x: shrunk.midX, y: shrunk.midY))
        mouse(.leftMouseDragged, CGPoint(x: shrunk.midX - 60, y: shrunk.midY + 30))
        mouse(.leftMouseUp, CGPoint(x: shrunk.midX - 60, y: shrunk.midY + 30))
        require(overlay.text.rect == shrunk.offsetBy(dx: -60, dy: 30), "dragging inside moves the region")
        try await waitFor("OCR after move") { overlay.text.result != nil }
        overlay.dismiss()

        open()
        let start = CGPoint(x: 400, y: 300)
        mouse(.leftMouseDown, start)
        mouse(.leftMouseDragged, CGPoint(x: 700, y: 500))
        overlay.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: space)!)
        mouse(.leftMouseDragged, CGPoint(x: 800, y: 560))
        mouse(.leftMouseUp, CGPoint(x: 800, y: 560))
        require(overlay.text.rect == CGRect(x: 500, y: 360, width: 300, height: 200), "holding Space while dragging moves the region instead of resizing it")
        overlay.dismiss()

        // Clicking inside an unmoved region copies its text; clicking outside clears it.
        open()
        try await select(cart)
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: cart.midX, y: cart.midY))
        mouse(.leftMouseUp, CGPoint(x: cart.midX, y: cart.midY))
        let inside = await copied() ?? ""
        require(inside.contains("Product name $12") && !overlay.window.isVisible, "a click inside the region copies its text")
        open()
        try await select(cart)
        mouse(.leftMouseDown, CGPoint(x: 200, y: 1300))
        mouse(.leftMouseUp, CGPoint(x: 200, y: 1300))
        require(overlay.text.rect == nil && overlay.window.isVisible, "a click outside the region clears it without copying a block")
        overlay.dismiss()

        // C and Shift-C.
        open()
        try await select(cart)
        pasteboard.clearContents()
        let format = overlay.defaults.string(forKey: Pref.colorFormat)
        key(cKey, "C", .shift)
        require(overlay.defaults.string(forKey: Pref.colorFormat) != format && overlay.window.isVisible, "Shift-C cycles the color format in Text mode")
        key(cKey, "c")
        let color = pasteboard.string(forType: .string) ?? ""
        require(!color.isEmpty && !color.contains("Product") && !overlay.window.isVisible, "C copies the region's color in Text mode: \(color)")

        // Option-Return: the language-pair decision, with injected status and translation.
        let german = Locale.Language(identifier: "de")
        let notInstalled = "\(TextTranslation.name(Locale.Language(identifier: "en"))) to \(TextTranslation.name(german)) is not installed. Add it in System Settings > General > Language & Region > Translation Languages."
        overlay.targetLanguage = german
        overlay.translationStatus = { _, _ in .supported }
        overlay.translate = { _, _, _ in fatalError("translate must not run for a pair that is not installed") }
        open()
        try await select(cart)
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        try await waitFor("the not-installed notice") { overlay.text.notice != nil }
        require(overlay.text.notice == notInstalled && texts(in: overlay.chrome.status) == [notInstalled], "Option-Return shows the not-installed pill: \(overlay.text.notice ?? "")")
        require(overlay.window.isVisible && pasteboard.string(forType: .string) == nil, "a missing language pair keeps the overlay open and copies nothing")
        key(tab)
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
        let translated = await copied()
        require(translated == "UEBERSETZT" && sent?.contains("Product name") == true && !overlay.window.isVisible, "an installed pair translates the region's text and copies the translation")
        overlay.translationStatus = { _, _ in .installed }
        overlay.targetLanguage = Locale.Language(identifier: "en")
        open()
        try await select(cart)
        key(returnKey, "\r", .option)
        try await waitFor("the same-language notice") { overlay.text.notice != nil }
        require(overlay.text.notice == "Text is already in \(TextTranslation.name(overlay.targetLanguage)).", "Option-Return on text already in the target language says so")
        overlay.dismiss()

        // The real pair on this Mac: either the notice or a real translation, never a prompt.
        let spanish = Locale.Language(identifier: "es")
        let realStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: spanish)
        overlay.targetLanguage = spanish
        overlay.translationStatus = { await LanguageAvailability().status(from: $0, to: $1) }
        overlay.translate = { try await TranslationSession(installedSource: $1, target: $2).translate($0).targetText }
        open()
        try await select(cart)
        pasteboard.clearContents()
        key(returnKey, "\r", .option)
        if realStatus == .installed {
            await overlay.textTask?.value
            let real = await copied() ?? ""
            require(!real.isEmpty && real != reading, "REAL translation ran (en to es installed): \(real.debugDescription)")
        } else {
            try await waitFor("the real notice") { overlay.text.notice != nil }
            require(overlay.text.notice!.contains("English to Spanish is not"), "REAL status for en to es is \(realStatus): the notice shows, no prompt")
        }
        overlay.dismiss()

        print("Text UI verification passed:")
        passed.forEach { print("- \($0)") }
        exit(EXIT_SUCCESS)
    }
}
