import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--verify-extras-ui`: modes, view toggles, color, help, and Element mode through synthesized events.
    /// The text of every visible label under `view`.
    static func texts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }

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
        require(defaults.bool(forKey: Pref.elementMode), "Element mode is on by default")
        defaults.set(false, forKey: Pref.elementMode)
        open()
        require(overlay.mode == .area, "the overlay opens in Area")
        key(17, "t")
        require(overlay.mode == .text, "T switches to Text")
        key(0, "a")
        require(overlay.mode == .area, "A switches back to Area")
        key(14, "e")
        require(overlay.mode == .area, "E does nothing while SnugElementMode is off")
        require(overlay.chrome.bottomBar.modes == [.area, .text], "the bottom bar hides Element while the flag is off")
        defaults.set(true, forKey: Pref.elementMode)
        key(1, "s")
        drag(rough)
        require(overlay.selection?.rect == rough, "a drag selects")
        key(17, "t")
        require(overlay.mode == .text && overlay.selection == nil, "changing mode clears the selection")
        overlay.chrome.bottomBar.click(.area)
        require(overlay.mode == .area, "clicking a bottom bar mode switches mode")
        require(overlay.chrome.bottomBar.modes == [.area, .element, .text], "the bottom bar shows Element once the flag is on")
        overlay.dismiss()

        // B toggles the bottom bar and remembers it.
        open()
        let bar = overlay.chrome.bottomBar
        require(!bar.isHidden, "the bottom bar starts visible")
        key(11, "b")
        require(bar.isHidden && !defaults.bool(forKey: Pref.modeBar), "B hides the bottom bar and remembers it")
        key(11, "b")
        require(!bar.isHidden && defaults.bool(forKey: Pref.modeBar), "B shows it again")

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
        guides.disc.render(in: context)
        let rendered = NSBitmapImageRep(cgImage: context.makeImage()!)
        let cell = Guides.loupeSize / CGFloat(Guides.loupePixels)
        var distinct = Set<[Int]>()
        for dy in -2...2 {
            for dx in -2...2 {
                let expected = pixel(Int(text.x) + dx, Int(text.y) + dy)
                distinct.insert(expected)
                let shown = bytes(rendered.colorAt(x: Int((CGFloat(Guides.loupePixels / 2 + dx) + 0.5) * cell), y: Int((CGFloat(Guides.loupePixels / 2 + dy) + 0.5) * cell))!)
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

        // ? shows and hides the keys sheet; Esc closes it without closing the overlay.
        open()
        let help = overlay.chrome.help
        key(44, "?", .shift)
        var sheet = texts(in: help)
        require(!help.isHidden && sheet.contains("Keys") && sheet.contains("Option-drag") && sheet.contains("Up / Down") && sheet.contains("Modes and view"),
                "? shows the keys sheet with every column: \(sheet.count) texts")
        require(sheet.contains("Esc or ? closes this.") || sheet.contains { $0.hasSuffix("Esc or ? closes this.") }, "the sheet says how to close it")
        let panel = help.panel.frame
        require(panel.width == 900 && help.bounds.insetBy(dx: 1, dy: 1).contains(panel), "the sheet panel is 900 pt wide and inside the screen \(panel)")
        key(44, "?", .shift)
        require(help.isHidden, "? hides the keys sheet")
        key(44, "?", .shift)
        key(53, "")
        require(help.isHidden && overlay.window.isVisible, "Esc closes the sheet and leaves the overlay open")
        overlay.dismiss()
        require(overlay.mode == .area, "closing the overlay resets the mode to Area")

        // Element mode.
        open()
        key(14, "e")
        require(overlay.mode == .element && overlay.elementTask != nil, "E enters Element and starts detection")
        require(overlay.session != nil && overlay.selection != nil && overlay.elementTask != nil, "Element mode has a session and selection while detection is still running")
        await overlay.elementTask?.value
        require(!overlay.elementCandidates.isEmpty, "the candidates arrive when detection finishes (\(overlay.elementCandidates.count))")
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
        let list = overlay.chrome.list
        require(!list.isHidden, "the candidate list shows in Element mode")
        sheet = texts(in: list)
        require(sheet.contains("1") && sheet.contains("1-5 or Up / Down, Return copies") && sheet.contains { $0.contains(" x ") }, "the list shows numbered rows and the footer: \(sheet)")
        require(list.frame.width == 240 && overlay.view.bounds.contains(list.frame), "the list is 240 pt wide and on screen")
        key(45, "n")
        require(list.isHidden, "N hides the list")
        key(45, "n")
        require(!list.isHidden, "N shows the list again")
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == first.size, "Return copies the element's pixels")

        // Element parity: Tab, parents, late results, click, drag, and accessibility without permission.
        open()
        key(14, "e")
        await overlay.elementTask?.value
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        let start = overlay.selection!.rect
        let startShortlist = overlay.session!.shortlist.map(\.id)
        key(48, "\t")
        let tabbed = overlay.selection!.rect
        require(tabbed != start && overlay.session!.shortlist.map(\.id) == startShortlist, "Tab selects the next candidate at this point without reordering the list")
        key(48, "\t", .shift)
        require(overlay.selection!.rect == start, "Shift-Tab goes back")
        sheet = texts(in: overlay.chrome.list)
        let parents = overlay.session!.parents
        require(!parents.isEmpty && sheet.contains("Parents") && sheet.contains("\(Int(parents[0].bounds.width)) x \(Int(parents[0].bounds.height))"), "the list shows the hovered region's parents: \(sheet)")
        require(parents.allSatisfy { $0.bounds.insetBy(dx: -1, dy: -1).contains(start) }, "every listed parent encloses the hovered region")
        key(18, "1")
        let pick = overlay.selection!.rect
        let pickList = overlay.session!.shortlist.map(\.id)
        let late = Candidate(id: "late", label: "Late", bounds: CGRect(x: 400, y: 570, width: 50, height: 30), score: 99, kind: .text)
        overlay.merge([late])
        require(overlay.session!.candidates.contains { $0.id == "late" }, "late results join the pool")
        require(overlay.selection?.rect == pick && overlay.session!.shortlist.map(\.id) == pickList, "late results do not change a picked region or the list order")
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == pick.size, "Return after late results still copies the picked region")

        open()
        key(14, "e")
        await overlay.elementTask?.value
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        let hoverRect = overlay.selection!.rect
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: 422, y: 585))
        mouse(.leftMouseUp, CGPoint(x: 422, y: 585))
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == hoverRect.size && !overlay.window.isVisible, "a click copies the highlighted region \(hoverRect)")

        open()
        key(14, "e")
        await overlay.elementTask?.value
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        key(1, "s")
        drag(rough)
        require(overlay.mode == .area && overlay.selection?.rect == rough, "a drag in Element mode becomes an Area drag (\(overlay.mode), \(String(describing: overlay.selection?.rect)))")
        key(1, "s")
        overlay.dismiss()

        open()
        key(14, "e")
        await overlay.elementTask?.value
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: [], ids: [1], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        require(overlay.accessibilityTask == nil && overlay.accessibilityStarted == nil, "a headless run never starts an accessibility lookup")
        require(!overlay.session!.candidates.contains { $0.id.hasPrefix("ax-") }, "no accessibility candidates in a headless run")
        require(!texts(in: overlay.chrome.list).contains("Allow Accessibility for app elements"), "the Allow Accessibility button never shows in a headless run")
        let axFrames = await Accessibility.frames(at: .zero, pid: getpid())
        require(AXIsProcessTrusted() || axFrames.isEmpty, "without Accessibility permission the lookup is empty and silent (trusted: \(AXIsProcessTrusted()))")
        overlay.dismiss()

        // Chrome: bottom bar, hints, badges, style bar, hover title, and the safe area.
        let chrome = overlay.chrome
        let guides2 = overlay.view.guides
        open()
        mouse(.mouseMoved, flat)
        require(["Area", "Element", "Text", "Loupe", "Rulers", "Snap", "Tight", "M"].allSatisfy(texts(in: chrome.bottomBar).contains), "the bottom bar shows modes, toggles, and style with key caps: \(texts(in: chrome.bottomBar))")
        require(chrome.bottomBar.modeButtons[.area]!.layer!.backgroundColor != nil && chrome.bottomBar.modeButtons[.text]!.layer!.backgroundColor == nil, "only the current mode is filled")
        require(abs(chrome.bottomBar.frame.midX - overlay.view.bounds.midX) <= 1 && chrome.bottomBar.frame.minY == 32, "the bottom bar is centered, 32 pt above the bottom edge")
        require(chrome.styleBar.isHidden && chrome.size.isHidden && chrome.hover.isHidden, "idle Area shows no style bar, badges, or hover title")
        require(texts(in: chrome.hints) == ["Pause to snap", "Return: copy", "Option: exact", "Click: window", "Option-click: no shadow", "F: full screen", "?: keys"], "idle Area hints: \(texts(in: chrome.hints))")
        require(chrome.hints.frame.minY >= chrome.bottomBar.frame.maxY, "the hint strip sits above the bar")
        key(1, "s")
        require(texts(in: chrome.hints).first == "S: snap back on" && chrome.bottomBar.toggles[2].1.layer!.backgroundColor == nil, "snap off changes the first hint and the Snap toggle")
        key(1, "s")
        chrome.bottomBar.toggles[0].1.onClick()
        require(defaults.bool(forKey: Pref.loupe) && !overlay.view.guides.loupe.isHidden && chrome.bottomBar.toggles[0].1.layer!.backgroundColor != nil, "clicking Loupe turns it on")
        chrome.bottomBar.toggles[0].1.onClick()
        chrome.bottomBar.toggles[2].1.onClick()
        require(!defaults.bool(forKey: Pref.snap), "clicking Snap turns snap off")
        chrome.bottomBar.toggles[2].1.onClick()
        chrome.bottomBar.styleButton.onClick()
        require(overlay.style == .margin && texts(in: chrome.bottomBar).contains("Margin"), "clicking the style button cycles the style")
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        overlay.setWindows([CGRect(x: 300, y: 300, width: 400, height: 200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(texts(in: chrome.hover) == ["Browser", "400 x 200  +  shadow", "Click to capture this window"], "hovering a window shows its title, size, and shadow: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        require(texts(in: chrome.hover)[1] == "400 x 200", "holding Option drops the shadow from the hover size line: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(chrome.hover.isHidden, "the hover title goes away off the window")
        mouse(.leftMouseDown, rough.origin)
        mouse(.leftMouseDragged, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status).isEmpty && !chrome.size.isHidden, "a quick drag shows only the size badge")
        for _ in 0..<300 where overlay.snapPreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        let fit = overlay.snapPreview!
        require(texts(in: chrome.size) == ["\(Int(fit.width)) x \(Int(fit.height))"] && texts(in: chrome.status) == ["Snap ready: release to take it, Tab for others"], "a snap preview shows its size and Snap ready")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status) == ["Snapped - Tab: other fits"], "after release on a fit: Snapped")
        require(chrome.bottomBar.isHidden && !chrome.styleBar.isHidden && texts(in: chrome.hints) == ["Handles: resize", "Arrows: nudge", "Tab: other fits", "Esc: cancel"], "the style bar replaces the bottom bar, with the released hints")
        require(["Tight", "Margin", "Backdrop", "\u{2318}1", "\u{2318}2", "\u{2318}3", "cycles", "Save", "\u{2318}S", "Copy", "Return"].allSatisfy(texts(in: chrome.styleBar).contains), "the style bar shows segments, Save, and Copy with key caps")
        require(chrome.hints.frame.maxY < chrome.styleBar.frame.minY, "the released hints sit below the style bar")
        chrome.styleBar.segments[2].onClick()
        require(overlay.style == .backdrop, "clicking a style segment sets the style")
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        for _ in 0..<overlay.selection!.fits.count where texts(in: chrome.status) != ["Exact - Tab: fits"] { key(48, "") }
        require(texts(in: chrome.status) == ["Exact - Tab: fits"], "Tab to the exact drag shows Exact")
        key(53, "")
        require(chrome.styleBar.isHidden && chrome.size.isHidden && chrome.status.isHidden, "Esc takes the style bar and badges away")

        // Safe area: with a simulated 38 pt inset, nothing sits under the camera housing.
        open()
        let width = overlay.view.bounds.width
        overlay.topInset = 38
        key(15, "r")
        key(37, "l")
        mouse(.mouseMoved, CGPoint(x: 1200, y: 20))
        let limit = overlay.view.bounds.height - 38
        require(guides2.bands.path!.boundingBox.maxY <= limit + 0.5 && guides2.bands.path!.boundingBox.maxY > limit - 1, "the top ruler sits just below the 38 pt inset")
        require(guides2.loupe.frame.maxY <= limit, "the loupe stays below the inset near the top edge")
        key(3, "f")
        for item in chrome.all where !item.isHidden && item !== chrome.help {
            require(item.frame.maxY <= limit + 0.5 && item.frame.minY >= 0 && item.frame.minX >= 0 && item.frame.maxX <= width, "\(type(of: item)) \(item.frame) lies inside the safe area")
        }
        require(!chrome.size.isHidden && !chrome.hints.isHidden && !chrome.styleBar.isHidden, "the full-screen state shows the size badge, hints, and style bar")
        overlay.topInset = 0
        overlay.refresh()
        require(guides2.bands.path!.boundingBox.maxY == overlay.view.bounds.height, "without an inset the top ruler sits at the top edge")
        overlay.dismiss()
        for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }

        print("Extras UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }
}
