import AppKit
import CoreImage
import ScreenshotCore

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
        let tab: UInt16 = 48, returnKey: UInt16 = 36, escape: UInt16 = 53, tKey: UInt16 = 17

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
        overlay.dismiss()

        // Region over the cart: reading order, then table.
        open()
        try await select(cart)
        require(overlay.snapPreview == nil && overlay.text.rect == cart, "a Text drag selects exactly the dragged region without snapping")
        let chrome = overlay.chrome
        require(texts(in: chrome.hints) == ["Return: copy text", "Shift-Return: copy as table", "Tab: links", "A: back to area"], "Text mode shows its hint strip")
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

        print("Text UI verification passed:")
        passed.forEach { print("- \($0)") }
        exit(EXIT_SUCCESS)
    }
}
