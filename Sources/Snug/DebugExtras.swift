import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--verify-extras-ui`: modes, view toggles, color, help, and Capture hover through synthesized events.
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

        // Modes: A / T, E does nothing, mode changes clear the selection.
        open()
        require(overlay.mode == .capture, "the overlay opens in Capture")
        key(17, "t")
        require(overlay.mode == .text, "T switches to Text")
        key(0, "a")
        require(overlay.mode == .capture, "A switches back to Capture")
        key(14, "e")
        require(overlay.mode == .capture && overlay.session != nil, "E does nothing: there is no Element mode")
        key(1, "s")
        drag(rough)
        require(overlay.selection?.rect == rough, "a drag selects")
        key(17, "t")
        require(overlay.mode == .text && overlay.selection == nil, "changing mode clears the selection")
        overlay.chrome.bottomBar.click(.capture)
        require(overlay.mode == .capture, "clicking a bottom bar mode switches mode")
        require(overlay.chrome.bottomBar.modeButtons.count == 2 && !texts(in: overlay.chrome.bottomBar).contains("Element"), "the bottom bar has two modes, Capture and Text")
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
        let sheet = texts(in: help)
        require(!help.isHidden && sheet.contains("Keys") && sheet.contains("Option-drag") && sheet.contains("Up / Down") && sheet.contains("Shift-Return") && sheet.contains("Text: drag") && sheet.contains("Modes and view"),
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
        require(overlay.mode == .capture, "closing the overlay resets the mode to Capture")

        // Capture hover: geometry in the background, no text candidates, accessibility elements first.
        open()
        require(overlay.mode == .capture && overlay.detectionTask != nil, "Capture starts geometry analysis in the background")
        require(overlay.session != nil && overlay.view.overlays.hover == nil, "an idle Capture has a session and no hover rectangle")
        await overlay.detectionTask?.value
        require(!overlay.detected.isEmpty, "the geometry candidates arrive when analysis finishes (\(overlay.detected.count))")
        require(overlay.detected.allSatisfy { extent.insetBy(dx: -4, dy: -4).contains($0.bounds) },
                "geometry runs on the \(Int(overlay.scale))x copy and returns regions in full-resolution pixels")
        require(overlay.session!.candidates.allSatisfy { $0.kind != .text }, "Capture never reads text: no text-line or paragraph candidates")
        let screenWindow = CGRect(x: 10, y: 10, width: extent.width - 20, height: extent.height - 20)
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        require(overlay.session!.candidates.contains { $0.kind == .window }, "window rectangles become window candidates")
        var hoveredKinds = Set<CandidateKind>()
        for x in stride(from: 100, to: Int(extent.width), by: 260) {
            for y in stride(from: 100, to: Int(extent.height), by: 220) {
                mouse(.mouseMoved, CGPoint(x: x, y: y))
                hoveredKinds.insert(overlay.session!.selected!.kind)
            }
        }
        require(!hoveredKinds.contains(.text) && !hoveredKinds.isDisjoint(with: [.cell, .region, .table]), "hover picks pixel geometry and never text: \(hoveredKinds)")
        let target = overlay.detected.filter { $0.bounds.width < extent.width / 2 && $0.bounds.height < extent.height / 2 }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }!
        let aim = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        mouse(.mouseMoved, aim)
        let hovered = overlay.view.overlays.hover!
        require(hovered != screenWindow && ![CandidateKind.window, .display].contains(overlay.session!.selected!.kind), "hover over geometry selects it, not the window \(hovered)")
        require(texts(in: overlay.chrome.hover).count == 2 && texts(in: overlay.chrome.hover)[1] == "\(Int(hovered.width)) x \(Int(hovered.height))", "the hover label shows the name and size: \(texts(in: overlay.chrome.hover))")
        let element = Candidate(id: "ax-test", label: "button", bounds: CGRect(x: aim.x - 20, y: aim.y - 12, width: 40, height: 24), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.merge([element])
        require(overlay.view.overlays.hover == element.bounds && texts(in: overlay.chrome.hover)[0] == "Button", "an accessibility element outranks geometry and shows its role description")
        pasteboard.clearContents()
        mouse(.leftMouseDown, aim)
        mouse(.leftMouseUp, aim)
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == element.bounds.size && !overlay.window.isVisible, "a click on a hovered element crops it \(element.bounds)")

        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, aim)
        require(overlay.view.overlays.hover == hovered, "the same spot hovers the same geometry again")
        pasteboard.clearContents()
        mouse(.leftMouseDown, aim)
        mouse(.leftMouseUp, aim)
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == hovered.size && !overlay.window.isVisible, "a click on a hovered geometry region crops it \(hovered)")

        // Up walks out through the parents to the window, then the display; Down walks back in.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, aim)
        let inner = overlay.view.overlays.hover!
        var chain = [overlay.session!.selected!]
        for _ in 0..<20 where chain.last!.kind != .display { key(up, ""); chain.append(overlay.session!.selected!) }
        require(chain.last!.kind == .display && chain.dropLast().last!.kind == .window && chain.count > 2, "Up walks out to the window, then the display: \(chain.map(\.kind))")
        require(zip(chain, chain.dropFirst()).allSatisfy { $1.bounds.insetBy(dx: -1, dy: -1).contains($0.bounds) }, "every step out encloses the one before")
        require(overlay.view.overlays.hover == extent && overlay.chrome.hover.isHidden == false && texts(in: overlay.chrome.hover)[0] == "Full screen", "the display shows its outline once walked out to")
        for _ in 1..<chain.count { key(down, "") }
        require(overlay.view.overlays.hover == inner, "Down walks back in to \(inner)")
        key(48, "\t")
        key(48, "\t", .shift)
        require(overlay.view.overlays.hover == inner, "Tab walks out and Shift-Tab back in")
        let far = CGPoint(x: extent.width - 40, y: extent.height - 40)
        mouse(.mouseMoved, far)
        require(overlay.view.overlays.hover != inner, "moving the pointer out of the level a key picked hovers again")
        key(up, "")
        let outer = overlay.view.overlays.hover
        mouse(.mouseMoved, CGPoint(x: far.x - 1, y: far.y - 1))
        require(outer != nil && overlay.view.overlays.hover == outer, "a level a key picked holds while the pointer stays inside it")
        overlay.dismiss()

        // The candidate list: hidden until N, remembered; 1-5 pick from it.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, aim)
        let listed = overlay.view.overlays.hover
        let list = overlay.chrome.list
        require(list.isHidden && !defaults.bool(forKey: Pref.candidates), "the candidate list is hidden by default")
        key(18, "1")
        key(19, "2")
        require(overlay.view.overlays.hover == listed, "1-5 do nothing while the list is hidden")
        key(45, "n")
        require(!list.isHidden && defaults.bool(forKey: Pref.candidates), "N shows the list and remembers it")
        let rows = texts(in: list)
        require(rows.contains("1") && rows.contains("1-5 or Up / Down, click captures") && rows.contains { $0.contains(" x ") }, "the list shows numbered rows and the footer: \(rows)")
        require(list.frame.width == 240 && overlay.view.bounds.contains(list.frame), "the list is 240 pt wide and on screen")
        let shortlist = overlay.session!.shortlist
        key(19, "2")
        require(overlay.view.overlays.hover == shortlist[1].bounds, "2 picks the second candidate \(shortlist[1].bounds)")
        mouse(.mouseMoved, CGPoint(x: shortlist[1].bounds.midX, y: shortlist[1].bounds.midY))
        require(overlay.view.overlays.hover == shortlist[1].bounds, "a picked candidate stays while the pointer is inside it")
        key(45, "n")
        require(list.isHidden && !defaults.bool(forKey: Pref.candidates), "N hides the list again")
        overlay.dismiss()

        // Hover with no accessibility permission, a drag, and the display.
        open()
        overlay.detectionTask?.cancel()
        mouse(.mouseMoved, aim)
        key(1, "s")
        drag(rough)
        require(overlay.mode == .capture && overlay.selection?.rect == rough && overlay.view.overlays.hover == nil, "a drag from a hovered spot is the Capture drag, and the hover goes away (\(String(describing: overlay.selection?.rect)))")
        key(1, "s")
        overlay.dismiss()

        open()
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: [], ids: [1], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        require(overlay.accessibilityTask == nil && overlay.accessibilityStarted == nil, "a headless run never starts an accessibility lookup")
        require(!overlay.session!.candidates.contains { $0.kind == .element }, "no accessibility candidates in a headless run")
        require(!texts(in: overlay.chrome.list).contains("Allow Accessibility for app elements"), "the Allow Accessibility button never shows in a headless run")
        let axFrames = await Accessibility.frames(at: .zero, pid: getpid())
        require(AXIsProcessTrusted() || axFrames.isEmpty, "without Accessibility permission the lookup is empty and silent (trusted: \(AXIsProcessTrusted()))")
        overlay.dismiss()

        // Chrome: bottom bar, hints, badges, style bar, hover title, and the safe area.
        let chrome = overlay.chrome
        let width0 = overlay.view.bounds.width
        let guides2 = overlay.view.guides
        open()
        overlay.detectionTask?.cancel()
        mouse(.mouseMoved, flat)
        require(["Capture", "Text", "Loupe", "Rulers", "Snap", "Tight", "M", "Shadow", "D"].allSatisfy(texts(in: chrome.bottomBar).contains), "the bottom bar shows modes, toggles, style, and shadow with key caps: \(texts(in: chrome.bottomBar))")
        let bottom = chrome.bottomBar
        let barButtons = [.capture, .text].map { bottom.modeButtons[$0]! } + bottom.toggles.map { $0.1 } + [bottom.styleButton, bottom.shadowButton]
        func clipped() -> [String] {
            barButtons.filter { $0.title.cell!.cellSize.width > $0.title.frame.width || $0.title.frame.maxX > $0.frame.width }.map { $0.title.stringValue }
        }
        let barWidth = bottom.frame.width
        for style in OutputStyle.allCases {
            for mode in [OverlayController.Mode.capture, .text] {
                defaults.set(style.rawValue, forKey: Pref.style)
                bottom.click(mode)
                overlay.refresh()
                require(clipped().isEmpty && bottom.frame.width == barWidth, "no bar title clips and the bar keeps its width with \(style) and \(mode) selected: \(clipped()) \(bottom.frame.width)")
            }
        }
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        bottom.click(.capture)
        overlay.refresh()
        require(barButtons.allSatisfy { $0.cap.frame.maxY <= $0.title.frame.minY }, "every bar button shows its key cap below its title")
        bottom.layoutSubtreeIfNeeded()
        let d = bottom.dividers.map(\.frame.minX), toggles = bottom.toggles.map { $0.1 }
        require(bottom.modeButtons[.text]!.frame.maxX <= d[0] && d[0] <= toggles[0].frame.minX && toggles[2].frame.maxX <= d[1] && d[1] <= bottom.styleButton.frame.minX
                && bottom.styleButton.frame.maxX <= bottom.shadowButton.frame.minX, "the bar has three groups: modes | loupe, rulers, snap | style, shadow")
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        require(defaults.bool(forKey: Pref.shadow) && bottom.shadowButton.layer!.backgroundColor != nil, "the window shadow defaults to on")
        key(2, "d")
        require(!defaults.bool(forKey: Pref.shadow) && bottom.shadowButton.layer!.backgroundColor == nil, "D turns the window shadow off and the Shadow button follows")
        require(texts(in: chrome.hints).contains("Option-click: with shadow") && overlay.windowShadow(option: false) == false && overlay.windowShadow(option: true), "with the shadow off, Option-click puts it back")
        bottom.shadowButton.onClick()
        require(defaults.bool(forKey: Pref.shadow) && texts(in: chrome.hints).contains("Option-click: no shadow") && overlay.windowShadow(option: false) && !overlay.windowShadow(option: true), "the Shadow button turns it back on, and Option-click then drops it")
        overlay.setWindows([CGRect(x: 300, y: 300, width: 400, height: 200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(texts(in: chrome.hover) == ["Browser", "400 x 200  +  shadow", "Click to capture this window"], "hovering a window shows its title, size, and shadow: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        require(texts(in: chrome.hover)[1] == "400 x 200", "holding Option drops the shadow from the hover size line: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        defaults.set(false, forKey: Pref.shadow)
        overlay.refresh()
        require(texts(in: chrome.hover)[1] == "400 x 200", "with the shadow off, the hover size line has no shadow: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        require(texts(in: chrome.hover)[1] == "400 x 200  +  shadow", "with the shadow off, holding Option shows the shadow on the hover size line: \(texts(in: chrome.hover))")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        defaults.set(true, forKey: Pref.shadow)
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(chrome.hover.isHidden, "the hover title goes away off the window")
        mouse(.leftMouseDown, rough.origin)
        mouse(.leftMouseDragged, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status).isEmpty && !chrome.size.isHidden, "a quick drag shows only the size badge")
        for _ in 0..<9000 where overlay.snapPreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        let fit = overlay.snapPreview!
        require(texts(in: chrome.size) == ["\(Int(fit.width)) x \(Int(fit.height))"] && texts(in: chrome.status) == ["Snap ready: release to take it, Tab for others"], "a snap preview shows its size and Snap ready")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status) == ["Snapped - S: exact, Tab: other fits"], "after release on a fit: Snapped")
        require(chrome.bottomBar.isHidden && !chrome.styleBar.isHidden && texts(in: chrome.hints) == ["Handles: resize", "Arrows: nudge", "Shift-Return: copy text", "G: scroll capture", "Tab: other fits", "Esc: cancel"], "the style bar replaces the bottom bar, with the released hints")
        require(["Tight", "Margin", "Backdrop", "\u{2318}1", "\u{2318}2", "\u{2318}3", "cycles", "Save", "\u{2318}S", "Copy", "Return"].allSatisfy(texts(in: chrome.styleBar).contains), "the style bar shows segments, Save, and Copy with key caps")
        require(chrome.hints.frame.maxY < chrome.styleBar.frame.minY, "the released hints sit below the style bar")
        chrome.styleBar.segments[2].onClick()
        require(overlay.style == .backdrop, "clicking a style segment sets the style")
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        for _ in 0..<overlay.selection!.fits.count where texts(in: chrome.status) != ["Exact - Tab: fits"] { key(48, "") }
        require(texts(in: chrome.status) == ["Exact - Tab: fits"], "Tab to the exact drag shows Exact")
        key(53, "")
        require(chrome.styleBar.isHidden && chrome.size.isHidden && chrome.status.isHidden, "Esc takes the style bar and badges away")

        // G: scrolling capture of a released selection inside a window, with frames cut from the fixture as if the page scrolled 300 px.
        let page = CGRect(x: 400, y: 200, width: 1000, height: 600)
        var offsets = [0, 0, 150, 300]
        overlay.scrollFrames = { area in
            let offset = offsets.count > 1 ? offsets.removeFirst() : offsets[0]
            return image.cropping(to: area.offsetBy(dx: 0, dy: CGFloat(offset)))!
        }
        open()
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.selection = AreaSelection(extent: extent, exact: page)
        key(5, "g")
        require(overlay.scrollArea == page && overlay.selection == nil && overlay.view.image == nil && overlay.window.ignoresMouseEvents && chrome.bottomBar.isHidden,
                "G starts scrolling capture: the frozen image goes away and the pointer reaches the app below")
        for _ in 0..<3000 where overlay.scrollHeight < 900 { try await Task.sleep(for: .milliseconds(10)) }
        require(overlay.scrollHeight == 900 && texts(in: chrome.hints) == ["Scroll to capture more: 900 px", "Return: done", "Esc: cancel"],
                "frames stitch as the area scrolls, and the hint strip counts the height: \(overlay.scrollHeight) \(texts(in: chrome.hints))")
        key(5, "g")
        require(overlay.scrollArea == page, "other keys do nothing while scrolling")
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        let stitched = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(!overlay.window.isVisible && stitched.pixelsWide == 1000 && stitched.pixelsHigh == 900 && overlay.window.isOpaque,
                "Return copies the stitched image and closes: \(stitched.pixelsWide) x \(stitched.pixelsHigh)")
        offsets = [0]
        open()
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.selection = AreaSelection(extent: extent, exact: page)
        key(5, "g")
        pasteboard.clearContents()
        key(53, "")
        require(!overlay.window.isVisible && overlay.scrollArea == nil && pasteboard.data(forType: .png) == nil, "Esc cancels scrolling capture with the clipboard untouched")
        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 1700, y: 100, width: 300, height: 300))
        key(5, "g")
        require(overlay.scrollArea == nil, "G does nothing for an area outside every window")
        key(53, "")
        overlay.scrollFrames = nil

        // Hint strip: on a narrow screen it drops hints from the end and keeps "?: keys" last.
        open()
        let fullHints = texts(in: chrome.hints)
        overlay.view.setFrameSize(CGSize(width: 520, height: overlay.view.bounds.height))
        overlay.refresh()
        let narrowHints = texts(in: chrome.hints)
        require(chrome.hints.frame.width <= 520 - 16 && narrowHints.count < fullHints.count && narrowHints.first == fullHints.first && narrowHints.last == "?: keys", "a 520 pt screen drops hints from the end and keeps ?: keys last: \(narrowHints)")
        overlay.view.setFrameSize(CGSize(width: width0, height: overlay.view.bounds.height))
        overlay.dismiss()

        // The bar and hints move to the top when the pointer, a drag, the hover, or the selection nears them, and come back.
        open()
        overlay.detectionTask?.cancel()
        let halfHeight = overlay.view.bounds.height / 2
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.midY))
        require(bar.frame.maxY < halfHeight && chrome.hints.frame.maxY < halfHeight && !chrome.atTop, "with the pointer mid-screen the bar and hints sit at the bottom")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(bar.frame.minY > halfHeight && chrome.hints.frame.minY > halfHeight && chrome.atTop && chrome.hints.frame.maxY < bar.frame.minY,
                "with the pointer near the bottom the bar and hints move to the top, bar nearest the edge")
        require(bar.frame.maxY <= overlay.view.bounds.height - overlay.topInset, "at the top they stay below the menu bar or notch")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.midY))
        require(bar.frame.maxY < halfHeight && !chrome.atTop, "they return when the pointer leaves the bottom area")
        mouse(.mouseMoved, CGPoint(x: 40, y: extent.height - 20))
        require(bar.frame.maxY < halfHeight, "a pointer at the bottom but far to the side of the bar leaves it there")
        overlay.setWindows([CGRect(x: 600, y: extent.height - 420, width: 1200, height: 410)], names: ["Low window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 700, y: extent.height - 400))
        require(!chrome.hover.isHidden && chrome.atTop && bar.frame.minY > halfHeight, "a hovered window that reaches the bar moves it to the top")
        mouse(.mouseMoved, CGPoint(x: 100, y: 100))
        require(!chrome.atTop, "and it returns when the hover leaves")
        let low = CGRect(x: 800, y: extent.height - 300, width: 600, height: 290)
        mouse(.leftMouseDown, low.origin)
        mouse(.leftMouseDragged, CGPoint(x: low.maxX, y: low.maxY))
        require(chrome.atTop, "a drag that reaches the bar moves it to the top")
        mouse(.leftMouseUp, CGPoint(x: low.maxX, y: low.maxY))
        require(!chrome.styleBar.isHidden && chrome.styleBar.frame.minY > halfHeight && chrome.hints.frame.minY > chrome.styleBar.frame.maxY,
                "a released selection that reaches the bottom puts the style bar and hints at the top")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(chrome.atTop, "the pointer at the bottom does not pull the style bar back down")
        key(53, "")
        open()
        drag(rough)
        require(!chrome.styleBar.isHidden && chrome.styleBar.frame.maxY < halfHeight, "a selection well above the bottom keeps the style bar at the bottom")
        overlay.dismiss()

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
