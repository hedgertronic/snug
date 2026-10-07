import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--verify-extras-ui`: modes, view toggles, color, help, and Element mode through synthesized events.
    static func verifyExtras(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        let pasteboard = overlay.pasteboard
        let defaults = overlay.defaults
        var passed: [String] = []

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Extras UI verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        func open() { overlay.present(image: image, frame: frame, displayID: nil) }
        func drag(_ rect: CGRect) {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY))
            mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY))
        }
        let source = NSBitmapImageRep(cgImage: image)
        func bytes(_ color: NSColor) -> [Int] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        // Raw file bytes: the fixture is 8-bit sRGB, so they are the expected sRGB values with no color-management math.
        let raw = source.bitmapData!
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(raw[y * source.bytesPerRow + x * source.samplesPerPixel + $0]) } }
        func parse(_ hex: String) -> [Int] { [1, 3, 5].map { Int(hex.dropFirst($0).prefix(2), radix: 16)! } }
        func close(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }
        let returnKey: UInt16 = 36, up: UInt16 = 126, down: UInt16 = 125
        require(source.bitsPerSample == 8 && image.colorSpace?.name == CGColorSpace.sRGB, "the fixture is 8-bit sRGB (\(String(describing: image.colorSpace?.name)))")
        let flat = CGPoint(x: 2185, y: 1024)
        let flatBytes = pixel(Int(flat.x), Int(flat.y))
        require(flatBytes != [0, 0, 0] && flatBytes != [255, 255, 255], "the flat test pixel is a real color \(flatBytes)")
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)

        // Modes: A / E / T, E only with the flag, mode changes clear the selection.
        open()
        require(overlay.mode == .area, "the overlay opens in Area")
        key(17, "t")
        require(overlay.mode == .text, "T switches to Text")
        key(0, "a")
        require(overlay.mode == .area, "A switches back to Area")
        key(14, "e")
        require(overlay.mode == .area, "E does nothing while SnugElementMode is off")
        require(overlay.modeBar.modes == [.area, .text], "the mode bar hides Element while the flag is off")
        defaults.set(true, forKey: Pref.elementMode)
        key(1, "s")
        drag(rough)
        require(overlay.selection?.rect == rough, "a drag selects")
        key(17, "t")
        require(overlay.mode == .text && overlay.selection == nil, "changing mode clears the selection")
        overlay.modeBar.click(.area)
        require(overlay.mode == .area, "clicking a mode bar segment switches mode")
        require(overlay.modeBar.modes == [.area, .element, .text], "the mode bar shows Element once the flag is on")
        overlay.dismiss()

        // B toggles the mode bar and remembers it.
        open()
        require(!overlay.modeBar.isHidden, "the mode bar starts visible")
        key(11, "b")
        require(overlay.modeBar.isHidden && !defaults.bool(forKey: Pref.modeBar), "B hides the mode bar and remembers it")
        key(11, "b")
        require(!overlay.modeBar.isHidden && defaults.bool(forKey: Pref.modeBar), "B shows it again")

        // L / R / X toggle their layers, remembered.
        let guides = overlay.view.guides
        require(guides.loupe.isHidden && guides.rulers.isHidden && guides.crosshair.isHidden, "loupe, rulers, and crosshair start off")
        let text = CGPoint(x: 2061, y: 1024)
        mouse(.mouseMoved, text)
        for (code, character, layer, preference) in [(37, "l", guides.loupe, Pref.loupe), (15, "r", guides.rulers, Pref.rulers), (7, "x", guides.crosshair, Pref.crosshair)] {
            key(UInt16(code), character)
            require(!layer.isHidden && defaults.bool(forKey: preference), "\(character.uppercased()) shows its layer and remembers it")
        }
        let view = overlay.view
        require(guides.crosshair.path!.boundingBox.size == view.bounds.size, "the crosshair spans the view")
        let before = guides.loupe.position
        mouse(.mouseMoved, CGPoint(x: text.x - 300, y: text.y - 200))
        require(guides.loupe.position != before, "the loupe follows the pointer")
        mouse(.mouseMoved, text)

        // The loupe shows the right magnified pixels: render it and compare cells to the source.
        // render(in:) filters slightly, so cell centers match within a few levels, not exactly.
        let size = Int(Guides.loupeSize)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guides.loupe.render(in: context)
        let rendered = NSBitmapImageRep(cgImage: context.makeImage()!)
        let cell = Guides.loupeSize / CGFloat(Guides.loupePixels)
        var distinct = Set<[Int]>()
        for dy in -2...2 {
            for dx in -2...2 {
                let expected = pixel(Int(text.x) + dx, Int(text.y) + dy)
                distinct.insert(expected)
                let shown = bytes(rendered.colorAt(x: Int((CGFloat(8 + dx) + 0.5) * cell), y: Int((CGFloat(8 + dy) + 0.5) * cell))!)
                require(close(shown, expected, 12), "loupe cell (\(dx), \(dy)) shows source pixel \(expected) (shows \(shown))")
            }
        }
        require(distinct.count > 2, "the loupe test region has several distinct colors")
        for (code, character) in [(37, "l"), (15, "r"), (7, "x")] { key(UInt16(code), character) }
        require(guides.loupe.isHidden && guides.rulers.isHidden && guides.crosshair.isHidden, "L, R, X hide the layers again")
        overlay.dismiss()

        // C copies the pixel color; Shift-C cycles the format.
        open()
        mouse(.mouseMoved, flat)
        let hex = String(format: "#%02X%02X%02X", flatBytes[0], flatBytes[1], flatBytes[2])
        key(8, "c")
        require(pasteboard.string(forType: .string) == hex, "C copies \(hex) for the pixel under the pointer (copied \(pasteboard.string(forType: .string) ?? "nothing"))")
        require(!overlay.window.isVisible, "C closes the overlay")
        open()
        mouse(.mouseMoved, flat)
        key(8, "C", .shift)
        require(defaults.string(forKey: Pref.colorFormat) == "rgb", "Shift-C cycles to RGB")
        require(overlay.window.isVisible, "Shift-C leaves the overlay open")
        key(8, "c")
        require(pasteboard.string(forType: .string) == "rgb(\(flatBytes[0]), \(flatBytes[1]), \(flatBytes[2]))", "C copies in RGB after Shift-C")
        for expected in ["hsl", "swift", "hex"] {
            open()
            key(8, "C", .shift)
            require(defaults.string(forKey: Pref.colorFormat) == expected, "Shift-C cycles to \(expected)")
            overlay.dismiss()
        }
        open()
        let average = CGRect(x: 2040, y: 1000, width: 60, height: 40)
        key(1, "s")
        drag(average)
        key(8, "c")
        var sums = [0, 0, 0]
        for y in 1000..<1040 { for x in 2040..<2100 { for (i, value) in pixel(x, y).enumerated() { sums[i] += value } } }
        let mean = sums.map { Int((Double($0) / 2400).rounded()) }
        require(close(parse(pasteboard.string(forType: .string)!), mean, 1), "C with a selection copies the selection average \(mean)")

        // ? shows and hides the help sheet for the current mode.
        open()
        key(44, "?", .shift)
        require(!overlay.helpPanel.isHidden && overlay.helpPanel.text.contains("Option-drag") && !overlay.helpPanel.text.contains("Up / Down"), "? shows the Area keys")
        key(44, "?", .shift)
        require(overlay.helpPanel.isHidden, "? hides the help sheet")
        key(14, "e")
        key(44, "?", .shift)
        require(overlay.helpPanel.text.contains("Up / Down") && !overlay.helpPanel.text.contains("Option-drag"), "the help sheet follows the mode")
        key(44, "?", .shift)
        overlay.dismiss()
        require(overlay.mode == .area, "closing the overlay resets the mode to Area")

        // Element mode.
        open()
        key(14, "e")
        require(overlay.mode == .element && overlay.elementTask != nil, "E enters Element and starts detection")
        await overlay.elementTask?.value
        let detected = overlay.session!.candidates.filter { $0.kind != .display && $0.kind != .window }
        require(!detected.isEmpty, "detection supplied \(detected.count) candidates")
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        require(overlay.session!.candidates.contains { $0.kind == .window }, "window rectangles become window candidates")
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        let hovered = overlay.selection!.rect
        require(hovered != extent && overlay.session!.selected?.bounds == hovered, "hover selects an element \(hovered)")
        key(up, "")
        let grown = overlay.selection!.rect
        require(grown != hovered && grown.contains(hovered), "Up grows the selection \(hovered) to \(grown)")
        key(down, "")
        require(overlay.selection?.rect == hovered, "Down shrinks back")
        key(up, "")
        key(18, "1")
        let first = overlay.session!.shortlist[0].bounds
        require(overlay.selection?.rect == first && first != grown, "1 picks the first shortlist candidate \(first)")
        mouse(.mouseMoved, CGPoint(x: 1500, y: 1400))
        require(overlay.selection?.rect == first, "a picked candidate stays while the pointer moves")
        key(45, "n")
        require(!overlay.listPanel.isHidden && overlay.listPanel.text.contains("1  "), "N shows the numbered list")
        key(45, "n")
        require(overlay.listPanel.isHidden, "N hides the list")
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == first.size, "Return copies the element's pixels")

        print("Extras UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }
}
