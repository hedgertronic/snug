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

        // Modes: A / T, mode changes clear the selection.
        open()
        require(overlay.mode == .capture, "the overlay opens in Capture")
        key(17, "t")
        require(overlay.mode == .text, "T switches to Text")
        key(0, "a")
        require(overlay.mode == .capture, "A switches back to Capture")
        key(1, "s")
        drag(rough)
        require(overlay.selection?.rect == rough, "a drag selects: \(String(describing: overlay.selection)) snap \(defaults.bool(forKey: Pref.snap))")
        key(17, "t")
        require(overlay.mode == .text && overlay.selection == nil, "changing mode clears the selection")
        overlay.chrome.bottomBar.click(.capture)
        require(overlay.mode == .capture, "clicking a bottom bar mode switches mode")
        require(overlay.chrome.bottomBar.modeButtons.count == 2 && !texts(in: overlay.chrome.bottomBar).contains("Element"), "the bottom bar has two modes, Capture and Text")
        overlay.dismiss()

        // Opening draws at once: no layer under the view animates implicitly, so the frozen image replaces the black window in one frame.
        func animations(_ layer: CALayer) -> [String] { (layer.animationKeys() ?? []).map { "\(type(of: layer)) \($0)" } + (layer.sublayers ?? []).flatMap(animations) }
        open()
        require(animations(overlay.view.layer!).isEmpty, "opening animates no layer: \(animations(overlay.view.layer!))")

        // B toggles the bottom bar and remembers it.
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
        // The loupe's readout and the rulers' text change without a cross-fade once displayed.
        CATransaction.flush()
        require(animations(guides.root).isEmpty, "moving the pointer animates no guide layer: \(animations(guides.root))")

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

        // Mid-drag the selection's edges run through the loupe's center cell and the rulers flag the span; after release the edges go.
        mouse(.leftMouseDown, CGPoint(x: rough.minX, y: rough.minY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        let loupeCell = Guides.loupeSize / CGFloat(Guides.loupePixels), middle = loupeCell * CGFloat(Guides.loupePixels / 2)
        let edgeBox = guides.edges.path!.boundingBox
        require(abs(edgeBox.maxX - middle - loupeCell) < 0.01 && abs(edgeBox.minY - (Guides.loupeSize - middle - loupeCell)) < 0.01,
                "mid-drag the selection's right and bottom edges run along the loupe's center cell, the last pixel inside the crop: \(edgeBox)")
        require(guides.flags.map { $0.string as! String } == ["\(Int(rough.minX))", "\(Int(rough.maxX))", "\(Int(rough.minY))", "\(Int(rough.maxY))"], "the rulers flag the span's start and end")
        require(guides.widthLabel.string as? String == "\(Int(rough.width))" && !guides.widthLabel.isHidden, "the ruler shows the span's width")
        require(!(guides.numbers.sublayers!.contains { !$0.isHidden && $0.frame.intersects(guides.widthLabel.frame) }) && guides.numbers.sublayers!.contains { $0.isHidden },
                "no tick number shows under the span's width")
        // Sub-pixel pointer moves mid-drag, through whole, half and other fractions of a pixel: the outline's right and bottom edges stay on
        // the center cell's far side, the rulers flag the same sides, and the loupe sits on whole device pixels.
        for step in 1...12 {
            let offset = CGFloat(step) * [0.5, 0.17, 0.33][step % 3]
            let tip = CGPoint(x: rough.maxX + offset, y: rough.maxY + offset / 2)
            mouse(.leftMouseDragged, tip)
            let box = guides.edges.path!.boundingBox
            let right = (box.maxX - middle) / loupeCell, bottom = (Guides.loupeSize - box.minY - middle) / loupeCell
            require([right, bottom].allSatisfy { abs($0 - 1) < 0.001 }, "step \(step): the outline's right and bottom edges run along the center cell's far side: \(right) \(bottom)")
            require(guides.flags[1].string as? String == "\(Int(tip.x.rounded(.up)))" && guides.flags[3].string as? String == "\(Int(tip.y.rounded(.up)))",
                    "step \(step): the rulers flag the crop's whole-pixel right and bottom sides")
            let corner = CGPoint(x: guides.loupe.frame.minX * overlay.scale, y: guides.loupe.frame.minY * overlay.scale)
            require(abs(corner.x - corner.x.rounded()) < 0.001 && abs(corner.y - corner.y.rounded()) < 0.001, "step \(step): the loupe sits on whole device pixels: \(corner)")
        }
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(guides.edges.path == nil, "the loupe draws no selection edges once the drag ends")

        // The loupe flips away from a bar it would cover and stays on screen.
        let viewBounds = overlay.view.bounds, barBox = CGRect(x: 300, y: 0, width: 600, height: 44)
        let pointNearBar = CGPoint(x: 500, y: barBox.maxY + 30)
        let flipped = Guides.loupeOrigin(point: pointNearBar, bounds: viewBounds, topInset: 0, scale: overlay.scale, avoiding: [barBox])
        let flippedFrame = CGRect(x: flipped.x - 8, y: flipped.y, width: Guides.loupeSize + 16, height: Guides.loupeSize + 40)
        require(!flippedFrame.intersects(barBox) && flipped.y > pointNearBar.y, "near a bar at the bottom the loupe goes above the pointer: \(flippedFrame)")
        let cornerPoint = CGPoint(x: viewBounds.width - 4, y: viewBounds.height - 4)
        let cornerOrigin = Guides.loupeOrigin(point: cornerPoint, bounds: viewBounds, topInset: 0, scale: overlay.scale, avoiding: [])
        require(cornerOrigin.x + Guides.loupeSize + 8 <= viewBounds.width && cornerOrigin.x < cornerPoint.x, "at the right edge the loupe goes left of the pointer")

        // The loupe and rulers use one duration and curve, and each outro is its intro backward.
        for hidden in [Guides.loupeHiddenTransform, Guides.rulersHiddenTransform] {
            let intro = Guides.transition(from: hidden, showing: true), outro = Guides.transition(from: hidden, showing: false)
            func points(_ function: CAMediaTimingFunction?) -> [Float] {
                (0..<4).flatMap { index -> [Float] in
                    var point: [Float] = [0, 0]
                    function!.getControlPoint(at: index, values: &point)
                    return point
                }
            }
            let forward = points(intro.timingFunction), backward = points(outro.timingFunction)
            require(intro.duration == outro.duration && intro.duration == Guides.transitionDuration, "the intro and outro share one duration")
            require([(2, 4), (3, 5), (4, 2), (5, 3)].allSatisfy { abs(backward[$0] - (1 - forward[$1])) < 0.001 }, "the outro's curve mirrors the intro's: \(forward) \(backward)")
            let forwardValues = intro.animations!.map { ($0 as! CABasicAnimation) }, backwardValues = outro.animations!.map { ($0 as! CABasicAnimation) }
            require(zip(forwardValues, backwardValues).allSatisfy { ($0.fromValue as! NSObject) == ($1.toValue as! NSObject) && ($0.toValue as! NSObject) == ($1.fromValue as! NSObject) }, "the outro runs the intro's values backward")
        }
        for (code, character) in [(37, "l"), (15, "r"), (7, "x")] { key(UInt16(code), character) }
        require(guides.loupe.isHidden && guides.rulers.isHidden && guides.crosshair.isHidden, "L, R, X hide the layers again")
        overlay.dismiss()

        // End to end: a pointer just above the visible bars never gets a loupe over them.
        open()
        let barChrome = overlay.chrome
        defaults.set(true, forKey: Pref.loupe)
        for y in stride(from: barChrome.bottomBar.frame.maxY + 4, through: barChrome.bottomBar.frame.maxY + 140, by: 12) {
            mouse(.mouseMoved, CGPoint(x: barChrome.bottomBar.frame.midX * overlay.scale, y: (viewBounds.height - y) * overlay.scale))
            let covered = [barChrome.bottomBar, barChrome.hints, barChrome.actionBar].filter { !$0.isHidden && guides.loupe.frame.intersects($0.frame) }
            require(covered.isEmpty, "the loupe with the pointer at y \(y) covers no bar: \(guides.loupe.frame) \(covered.map(\.frame))")
        }
        // A flip at the screen's right edge slides: the model position follows the pointer at once, and an additive animation carries the
        // loupe from its old offset to the new one. A move that keeps the placement adds no slide, and nothing slides while sliding is off.
        func place(_ point: CGPoint) {
            guides.update(point: point, pixel: CGPoint(x: 800, y: 600), image: image, bounds: viewBounds, scale: overlay.scale, topInset: 0, selected: nil, dragging: false, avoiding: [])
        }
        func slides() -> [CABasicAnimation] {
            (guides.loupe.animationKeys() ?? []).compactMap { guides.loupe.animation(forKey: $0) as? CABasicAnimation }.filter { $0.keyPath == "position" && $0.isAdditive }
        }
        guides.loupe.removeAllAnimations()
        require(!guides.slidesPlacement, "headless runs never slide the loupe")
        place(CGPoint(x: 400, y: 300))
        place(CGPoint(x: viewBounds.width - 20, y: 300))
        require(slides().isEmpty, "with sliding off a flip moves the loupe at once")
        guides.slidesPlacement = true
        place(CGPoint(x: 400, y: 300))
        let slid = slides()
        let jump = (slid.first?.fromValue as? NSValue)?.pointValue ?? .zero
        require(slid.count == 1 && abs(jump.x - (-Guides.loupeSize - 20)) <= 0.5 && abs(jump.y) <= 0.5 && (slid[0].toValue as! NSValue).pointValue == .zero,
                "a flip back to the pointer's right slides from the old offset: \(slid.map { ($0.fromValue, $0.toValue) })")
        require(abs(guides.loupe.frame.minX - 410) <= 0.5, "the loupe's model position follows the pointer at once: \(guides.loupe.frame)")
        place(CGPoint(x: 401, y: 301))
        require(slides().count == 1, "a move that keeps the placement adds no slide")
        // With no free placement the loupe is pushed inside the view and pinned on one axis; following the pointer there is no flip.
        guides.loupe.removeAllAnimations()
        guides.update(point: CGPoint(x: 400, y: 60), pixel: CGPoint(x: 800, y: 600), image: image, bounds: viewBounds, scale: overlay.scale, topInset: 0, selected: nil, dragging: false, avoiding: [viewBounds])
        guides.update(point: CGPoint(x: 400, y: 70), pixel: CGPoint(x: 800, y: 600), image: image, bounds: viewBounds, scale: overlay.scale, topInset: 0, selected: nil, dragging: false, avoiding: [viewBounds])
        require(guides.loupe.frame.minY == 0 && slides().isEmpty, "a loupe pinned at the bottom edge follows the pointer without sliding: \(guides.loupe.frame) \(slides().count)")
        guides.slidesPlacement = false
        guides.loupe.removeAllAnimations()
        overlay.dismiss()

        // Animation variants: fade (the default) scales the loupe and fades the rulers without a slide, slide moves them in, none flips at once.
        require(defaults.string(forKey: Pref.guidesAnimation) == "fade", "the guides animation defaults to fade")
        for (animation, slides, animates) in [(GuidesAnimation.fade, false, true), (.slide, true, true), (.none, false, false)] {
            defaults.set(animation.rawValue, forKey: Pref.guidesAnimation)
            for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }
            open()
            overlay.updateGuides()
            for layer in [guides.rulers, guides.loupe] { layer.removeAllAnimations() }
            overlay.isHeadless = false
            for key in [Pref.rulers, Pref.loupe] { defaults.set(true, forKey: key) }
            overlay.updateGuides()
            overlay.isHeadless = true
            let rulersGroup = guides.rulers.animation(forKey: "transition") as? CAAnimationGroup
            require((rulersGroup != nil) == animates && (guides.loupe.animation(forKey: "transition") != nil) == animates, "\(animation): the layers \(animates ? "animate" : "flip at once")")
            require(animates || (guides.rulers.animationKeys() == nil && guides.loupe.animationKeys() == nil), "none: no implicit animation runs either")
            let slide = (rulersGroup?.animations?.first { ($0 as? CABasicAnimation)?.keyPath == "transform" } as? CABasicAnimation)?.fromValue as? NSValue
            require((slide.map { $0.caTransform3DValue.m41 != 0 } ?? false) == slides, "\(animation): the rulers \(slides ? "slide in" : "do not slide")")
            overlay.dismiss()
        }
        defaults.set(GuidesAnimation.fade.rawValue, forKey: Pref.guidesAnimation)
        for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }

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
        require(!help.isHidden && sheet.contains("Keys") && sheet.contains("Option-drag") && sheet.contains("Up / Down") && sheet.contains("Shift-Return") && sheet.contains("Text: drag") && sheet.contains("Modes, view, recording"),
                "? shows the keys sheet with every column: \(sheet.count) texts")
        let helpRows = HelpSheet.columns.flatMap(\.rows)
        require(["[ ]", "Shift-[ ]", "=", "Option-drag dot", "V", "K"].allSatisfy(helpRows.map(\.keys).contains) && helpRows.contains { $0.keys == "Arrows" && $0.action.contains("1 px") && $0.action.contains("10 px") },
                "the sheet lists the corner radius keys, V, K, and arrows in pixels")
        let helpActions = Dictionary(helpRows.map { ($0.keys, $0.action) }, uniquingKeysWith: { $1 })
        require(helpActions["P"] == "Ratio menu" && helpActions["Shift-P"] == "Lock the ratio" && helpActions["W"] == "Capture the window"
                    && helpActions["K"] == "Cut-out preview" && helpActions["Cut-out: Tab"] == "Next subject (Shift: back)" && helpActions["V"] == "Arm recording, hover or selection"
                    && helpActions["Armed: Return / V"] == "Start recording" && helpActions["Armed: H"] == "Cursor on / off" && helpActions["Armed: C"] == "Count-in off, 3 s, 5 s"
                    && helpActions["Capture hotkey"] == "Stop recording" && helpActions["G"] == "Scrolling capture, hover or selection" && helpActions["Cut-out: C"] == "Crop to subject"
                    && helpActions["Tab"] == "Walk out (Shift: in)"
                    && !helpRows.contains { $0.action.contains("Aspect ratio lock") },
                "the sheet lists the ratio menu and lock, W, the cut-out keys, G and V on a hover, the recording keys, Tab without other fits, and no P cycle")
        require(sheet.contains("Esc or ? closes this.") || sheet.contains { $0.hasSuffix("Esc or ? closes this.") }, "the sheet says how to close it")
        let panel = help.panel.frame
        require(panel.width == 900 && help.bounds.insetBy(dx: 1, dy: 1).contains(panel), "the sheet panel is 900 pt wide and inside the screen \(panel)")
        let caps = help.panel.subviews.compactMap { $0 as? KeyCap }, labels = help.panel.subviews.compactMap { $0 as? NSTextField }
        let crowded = caps.flatMap { cap in labels.filter { $0.frame.minY < cap.frame.maxY && $0.frame.maxY > cap.frame.minY && $0.frame.minX < cap.frame.minX && $0.frame.maxX > cap.frame.minX - 8 }.map(\.stringValue) }
        require(!caps.isEmpty && crowded.isEmpty, "no help label comes within 8 pt of its key cap: \(crowded)")
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
        require(Array(texts(in: overlay.chrome.hover).dropFirst()) == ["\(Int(hovered.width)) x \(Int(hovered.height))", "copy", "\u{21A9}", "save", "\u{2318}S"],
                "the hover label shows the name, the size, and the Return and Cmd-S keys: \(texts(in: overlay.chrome.hover))")
        let hoverBox = overlay.view.viewRect(hovered)
        require(overlay.chrome.hover.frame.maxY == hoverBox.minY - 8 || overlay.chrome.hover.frame.minY == hoverBox.maxY + 8 || hoverBox.contains(overlay.chrome.hover.frame),
                "the hover label is attached to the hovered element: \(overlay.chrome.hover.frame) \(hoverBox)")
        let element = Candidate(id: "ax-test", label: "Button", bounds: CGRect(x: aim.x - 20, y: aim.y - 12, width: 40, height: 24), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.merge([element])
        require(overlay.view.overlays.hover == element.bounds && texts(in: overlay.chrome.hover)[0] == "Button", "an accessibility element outranks geometry and shows its role description")
        // Faint outlines show where Up and Down go, each with its key cap at the top-left corner.
        let upLevel = overlay.session!.parents.first!.bounds
        require(overlay.view.overlays.upHint == upLevel && overlay.view.overlays.downHint == nil && !overlay.chrome.upHint.isHidden && overlay.chrome.downHint.isHidden,
                "the Up outline is the element's parent and there is no Down outline: \(String(describing: overlay.view.overlays.upHint)) \(upLevel)")
        let upBox = overlay.view.viewRect(upLevel)
        require(overlay.chrome.upHint.frame.minX == upBox.minX + 4 && overlay.chrome.upHint.frame.maxY == upBox.maxY - 4, "the Up key cap sits in the outline's top-left corner")
        key(126, "")
        require(overlay.view.overlays.hover == upLevel && overlay.view.overlays.downHint == element.bounds && !overlay.chrome.downHint.isHidden,
                "after Up, the Down outline is the element it came from: \(String(describing: overlay.view.overlays.downHint))")
        key(125, "")
        require(overlay.view.overlays.hover == element.bounds, "Down returns to the element")
        pasteboard.clearContents()
        mouse(.leftMouseDown, aim)
        mouse(.leftMouseUp, aim)
        await overlay.commitTask?.value
        require(pngSize(pasteboard.data(forType: .png)) == element.bounds.size && !overlay.window.isVisible, "a click on a hovered element crops it \(element.bounds)")

        // The Up and Down outlines take their rectangle's corner radii, and a level within 4 pt of the hover shows no outline.
        let scale = overlay.scale
        let hintIn = Candidate(id: "hint-hintIn", label: "Inner", bounds: CGRect(x: 600, y: 500, width: 400, height: 240), score: AccessibilityBounds.baseScore, kind: .element)
        let hintOut = Candidate(id: "hint-hintOut", label: "Outer", bounds: hintIn.bounds.insetBy(dx: -200, dy: -150), score: AccessibilityBounds.baseScore, kind: .element)
        let center = CGPoint(x: hintIn.bounds.midX, y: hintIn.bounds.midY)
        open()
        overlay.detectionTask?.cancel()
        overlay.radii[hintOut.bounds] = 24
        overlay.radii[hintIn.bounds] = 10
        overlay.session = SelectionSession(candidates: [hintIn, hintOut], extent: extent, anchor: center)
        mouse(.mouseMoved, center)
        require(overlay.view.overlays.hover == hintIn.bounds && overlay.view.overlays.upHint == hintOut.bounds, "the Up outline is the parent rectangle")
        require(overlay.view.overlays.upHintRadii == CornerRadii(24), "the Up outline takes its rectangle's radii: \(overlay.view.overlays.upHintRadii)")
        key(126, "")
        require(overlay.view.overlays.downHint == hintIn.bounds && overlay.view.overlays.downHintRadii == CornerRadii(10), "the Down outline takes its rectangle's radii: \(overlay.view.overlays.downHintRadii)")
        overlay.dismiss()
        let near = Candidate(id: "hint-near", label: "Near", bounds: hintIn.bounds.insetBy(dx: -3 * scale, dy: -3 * scale), score: AccessibilityBounds.baseScore, kind: .element)
        let apart = Candidate(id: "hint-apart", label: "Apart", bounds: hintIn.bounds.insetBy(dx: -8 * scale, dy: -8 * scale), score: AccessibilityBounds.baseScore, kind: .element)
        for (parent, shows) in [(near, false), (apart, true)] {
            open()
            overlay.detectionTask?.cancel()
            overlay.session = SelectionSession(candidates: [hintIn, parent], extent: extent, anchor: center)
            mouse(.mouseMoved, center)
            require(overlay.session!.parents.first?.bounds == parent.bounds && overlay.view.overlays.hover == hintIn.bounds, "\(parent.label): the level above the hover is \(parent.bounds)")
            require((overlay.view.overlays.upHint == parent.bounds) == shows && overlay.chrome.upHint.isHidden == !shows,
                    "a level \(shows ? "8" : "3") pt from the hover on every side \(shows ? "keeps" : "loses") its outline: \(String(describing: overlay.view.overlays.upHint))")
            overlay.dismiss()
        }

        // The highlight reads its settings on each present.
        defaults.set("#FF0000", forKey: Pref.highlightColor)
        defaults.set(0.2, forKey: Pref.highlightFill)
        defaults.set(0.6, forKey: Pref.highlightFade)
        defaults.set(0.0, forKey: Pref.highlightGlow)
        open()
        let dim = overlay.view.dimLayer.fillColor.flatMap(NSColor.init(cgColor:))!
        let hoverFill = overlay.view.hoverLayer.fillColor.flatMap(NSColor.init(cgColor:))
        require(abs(dim.alphaComponent - 0.6) < 0.001, "the background fade follows the setting: \(dim.alphaComponent)")
        require(hoverFill.map { abs($0.alphaComponent - 0.2) < 0.001 && $0.redComponent > 0.99 } == true, "the fill uses the picked color at the set opacity: \(String(describing: hoverFill))")
        require(overlay.view.glowLayer.shadowOpacity == 0, "glow off removes the hover's shadow")
        overlay.dismiss()
        for key in [Pref.highlightColor, Pref.highlightFill, Pref.highlightFade, Pref.highlightGlow] { defaults.removeObject(forKey: key) }
        open()
        require(abs(overlay.view.dimLayer.fillColor.flatMap(NSColor.init(cgColor:))!.alphaComponent - 0.42) < 0.001 && overlay.view.hoverLayer.fillColor == nil && overlay.view.glowLayer.shadowOpacity > 0,
                "the defaults are a 42% fade, no fill, and a glow")
        overlay.dismiss()

        // The glow, sampled on rendered pixels 3, 6 and 10 pt outside the hover's right edge, against the same frame with no glow.
        defaults.set("#007AFF", forKey: Pref.highlightColor)
        let sampleBox = CGRect(x: 600, y: 400, width: 800, height: 500)
        for (page, gray) in [("light", 0.96), ("dark", 0.12)] {
            let flatPage = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            flatPage.setFillColor(gray: gray, alpha: 1)
            flatPage.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for fade in [0.0, 0.42] {
                defaults.set(fade, forKey: Pref.highlightFade)
                var samples: [Double: [[Int]]] = [:]
                for glow in [0.0, 0.5, 1.0] {
                    defaults.set(glow, forKey: Pref.highlightGlow)
                    overlay.present(image: flatPage.makeImage()!, frame: frame, displayID: nil)
                    overlay.detectionTask?.cancel()
                    overlay.setWindows([sampleBox], names: ["Sample"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
                    mouse(.mouseMoved, CGPoint(x: sampleBox.midX, y: sampleBox.midY))
                    let view = overlay.view
                    view.layoutSubtreeIfNeeded()
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let density = CGFloat(rep.pixelsWide) / view.bounds.width
                    let edge = sampleBox.maxX / overlay.scale, row = Int(sampleBox.midY / overlay.scale * density)
                    samples[glow] = [3, 6, 10].map { distance in
                        bytes(rep.colorAt(x: Int((edge + CGFloat(distance)) * density), y: row)!)
                    }
                    overlay.dismiss()
                }
                print("glow, \(page) page, fade \(fade), RGB at 3/6/10 pt outside the edge: off \(samples[0]!), 0.5 \(samples[0.5]!), 1 \(samples[1]!)")
                func change(_ glow: Double, _ index: Int) -> Int { zip(samples[glow]![index], samples[0]![index]).map { abs($0 - $1) }.max()! }
                require(change(0.5, 0) >= 12, "\(page) page, fade \(fade): glow 0.5 changes a channel by at least 12/255 at 3 pt: \(change(0.5, 0))")
                require((0..<3).allSatisfy { change(1, $0) > change(0.5, $0) && change(0.5, $0) > 0 }, "\(page) page, fade \(fade): the glow rises with intensity at 3, 6 and 10 pt")
            }
        }
        for key in [Pref.highlightColor, Pref.highlightFill, Pref.highlightFade, Pref.highlightGlow] { defaults.removeObject(forKey: key) }

        // The toast's preview, position, and lifetime.
        let capture = try await Output.png(image.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 400))!)
        func toast(_ setup: (UserDefaults) -> Void = { _ in }) -> Toast {
            let toastDefaults = UserDefaults(suiteName: "snug-toast-\(UUID().uuidString)")!
            Pref.register(in: toastDefaults)
            setup(toastDefaults)
            return Toast(png: capture, message: "Copied", detail: "1200 x 400", file: nil, color: nil, defaults: toastDefaults)
        }
        let withPreview = toast(), without = toast { $0.set(false, forKey: Pref.toastPreview) }
        let thumbnail = withPreview.preview!.frame.size
        require(withPreview.preview != nil && without.preview == nil, "the preview setting adds or removes the thumbnail card")
        require(thumbnail.width <= 240 && thumbnail.height <= 160 && abs(thumbnail.width / thumbnail.height - 3) < 0.02, "the thumbnail is aspect-fit within 240 x 160: \(thumbnail)")
        require(withPreview.frame.height - without.frame.height >= thumbnail.height + 8 && withPreview.lifetime == .seconds(4) && without.lifetime == .seconds(2), "the thumbnail card sits apart from the pill and lasts 4 s")
        let card = withPreview.card, thumbnailFrame = withPreview.preview!.frame
        require(card.frame.size == without.card.frame.size && thumbnailFrame.minY - card.frame.maxY == 8 && thumbnailFrame.width <= withPreview.contentView!.bounds.width,
                "the thumbnail is its own card, a gap above the pill, and the pill is the same size without it: \(thumbnailFrame) \(card.frame)")
        require(card.layer!.cornerRadius * 2 == card.frame.height && card.layer!.borderWidth == 1 && card.layer!.masksToBounds && card.subviews.allSatisfy { $0.layer?.cornerRadius ?? 0 == 0 }
                    && withPreview.preview!.layer!.cornerRadius == 12 && withPreview.preview!.layer!.masksToBounds && withPreview.preview!.layer!.borderWidth == 1,
                "the pill is a capsule and the thumbnail a rounded card, each clipped and outlined on its own")
        require(without.card.layer!.cornerRadius * 2 >= without.card.frame.height, "the preview-off toast is a fully rounded pill: \(without.frame.height)")
        let bottomRight = toast { $0.set("bottomRight", forKey: Pref.toastPosition) }, topRight = toast { $0.set("topRight", forKey: Pref.toastPosition) }
        require(bottomRight.frame.minX > withPreview.frame.minX && bottomRight.frame.minY == withPreview.frame.minY && topRight.frame.minX == bottomRight.frame.minX && topRight.frame.minY > bottomRight.frame.minY,
                "the position setting moves the toast: \(withPreview.frame) \(bottomRight.frame) \(topRight.frame)")
        require(topRight.preview!.frame.maxY + 8 == topRight.card.frame.minY && bottomRight.preview!.frame.minY == bottomRight.card.frame.maxY + 8,
                "the preview is below the pill at the top right and above it elsewhere: \(topRight.preview!.frame) \(topRight.card.frame)")
        // The pill's blur is masked to its capsule, so no square edges show behind it: the mask is transparent in the corners outside the
        // radius and opaque inside. In a render of the whole toast, the pixel just inside each piece's square corner is clear, and so is the margin.
        for shown in [withPreview, without] {
            let mask = shown.card.maskImage!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let maskRep = NSBitmapImageRep(cgImage: mask)
            let last = (maskRep.pixelsWide - 1, maskRep.pixelsHigh - 1)
            require([(0, 0), (last.0, 0), (0, last.1), (last.0, last.1)].allSatisfy { maskRep.colorAt(x: $0, y: $1)!.alphaComponent == 0 }
                        && maskRep.colorAt(x: maskRep.pixelsWide / 2, y: maskRep.pixelsHigh / 2)!.alphaComponent == 1,
                    "the pill's mask clears all four corner pixels and keeps the middle: \(shown.card.frame)")
            let root = shown.contentView!
            let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / root.bounds.width
            for piece in [shown.card.frame, shown.preview?.frame].compactMap({ $0 }) {
                let (left, right, top, bottom) = (Int(piece.minX * scale) + 1, Int(piece.maxX * scale) - 2, Int((root.bounds.height - piece.maxY) * scale) + 1, Int((root.bounds.height - piece.minY) * scale) - 2)
                require([(left, top), (right, top), (left, bottom), (right, bottom)].allSatisfy { rep.colorAt(x: $0, y: $1)!.alphaComponent == 0 }
                            && rep.colorAt(x: (left + right) / 2, y: (top + bottom) / 2)!.alphaComponent > 0.5,
                        "a render of the toast is clear at all four corners of the piece \(piece) and filled in its middle")
            }
            require(rep.colorAt(x: 1, y: 1)!.alphaComponent == 0 && rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh - 2)!.alphaComponent == 0, "a render of the toast is transparent in the margin")
        }
        require(!withPreview.isOpaque && withPreview.backgroundColor == .clear && withPreview.hasShadow, "the toast window is transparent with a shadow")

        // Hovering shows the close button, and with a capture the actions; leaving hides them again.
        let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: withPreview.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        require(withPreview.closeButton.isHidden && withPreview.openInPreview.superview!.isHidden, "the close button and actions are hidden until the pointer is over the toast")
        withPreview.mouseEntered(with: hoverEvent)
        require(!withPreview.closeButton.isHidden && !withPreview.openInPreview.superview!.isHidden && !withPreview.shareButton.isHidden && !withPreview.saveButton.isHidden && withPreview.trashButton.isHidden,
                "hovering an unsaved capture shows the close button, Share, Save and Open, and no Trash")
        require(withPreview.openInPreview.superview!.frame.minX >= 0 && withPreview.openInPreview.superview!.frame.maxX <= withPreview.card.bounds.width && withPreview.openInPreview.superview!.superview === withPreview.card,
                "the actions sit inside the pill, not on the thumbnail")
        require([withPreview.shareButton, withPreview.saveButton, withPreview.openInPreview].allSatisfy { $0.toolTip != nil } && withPreview.openInPreview.toolTip == "Open in Preview",
                "the action buttons have tooltips")
        let corner = withPreview.closeButton.frame, thumbnailCorner = withPreview.preview!.frame
        require(corner.midX < thumbnailCorner.minX + 12 && corner.midY > thumbnailCorner.maxY - 12, "the close button sits on the top-left corner of the top piece: \(corner) \(thumbnailCorner)")
        let belowCorner = topRight.closeButton.frame
        require(belowCorner.midX < topRight.card.frame.minX + 12 && belowCorner.midY > topRight.card.frame.maxY - 12, "at the top right the top piece is the pill: \(belowCorner) \(topRight.card.frame)")
        withPreview.mouseExited(with: hoverEvent)
        require(withPreview.closeButton.isHidden && withPreview.openInPreview.superview!.isHidden, "leaving hides the close button and actions")
        withPreview.dismissal?.cancel()
        let pillOnly = toast { $0.set(false, forKey: Pref.toastPreview) }
        pillOnly.mouseEntered(with: hoverEvent)
        require(!pillOnly.openInPreview.superview!.isHidden && pillOnly.openInPreview.superview!.frame.width <= pillOnly.card.frame.width, "a toast without a thumbnail shows the actions in its pill")
        pillOnly.dismissal?.cancel()

        // Open in Preview writes a temporary PNG when the capture was not saved (the debug run suppresses the launch); Save writes to the save
        // folder and shows the saved state.
        let saveFolder = FileManager.default.temporaryDirectory.appending(path: "snug-toast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let saving = toast { $0.set(saveFolder.path, forKey: Pref.saveFolder) }
        require(saving.file == nil, "an unsaved capture has no file")
        saving.openInPreview.performClick(nil)
        let previewFile = try Data(contentsOf: saving.file!)
        require(previewFile == capture, "Open in Preview writes the capture to a temporary PNG")
        saving.shareButton.performClick(nil)
        require(saving.file != nil, "Share has a file to share")
        let fresh = toast { $0.set(saveFolder.path, forKey: Pref.saveFolder) }
        fresh.saveButton.performClick(nil)
        let saved = try FileManager.default.contentsOfDirectory(atPath: saveFolder.path)
        let savedData = try Data(contentsOf: saveFolder.appending(path: saved[0]))
        require(saved.count == 1 && savedData == capture, "Save writes the capture to the save location: \(saved)")
        require(fresh.message.stringValue == "Saved to \(saveFolder.lastPathComponent)" && fresh.saveButton.isHidden && !fresh.trashButton.isHidden && fresh.file?.lastPathComponent == saved[0], "Save shows the saved state with Trash: \(fresh.message.stringValue)")
        fresh.dismissal?.cancel()

        // The capture is held only while the toast is visible: closing releases the PNG, the thumbnail, and the toast itself.
        weak var weakToast: Toast?
        weak var weakThumbnail: NSView?
        do {
            let closing = toast()
            weakToast = closing
            let thumbnailView = closing.preview!
            weakThumbnail = thumbnailView
            closing.scheduleDismissal()
            require(closing.png != nil && thumbnailView.layer!.contents != nil, "a visible toast holds the capture and its thumbnail")
            closing.closeButton.performClick(nil)
            require(closing.png == nil && thumbnailView.layer!.contents == nil, "the close button releases the capture and the thumbnail image")
        }
        try await Task.sleep(for: .milliseconds(200))
        print("toast after close: toast released \(weakToast == nil), thumbnail view released \(weakThumbnail == nil)")
        require(weakToast == nil, "the toast is freed once closed")

        withPreview.scheduleDismissal()
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: withPreview.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        withPreview.mouseEntered(with: enter)
        require(withPreview.dismissal!.isCancelled, "the toast stays while the pointer is over it")
        withPreview.mouseExited(with: enter)
        require(!withPreview.dismissal!.isCancelled, "the toast's timer restarts when the pointer leaves")
        withPreview.dismissal?.cancel()

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

        // Accessibility lookups at different pointer positions score the same frame differently; the smallest frame at the pointer is the one hovered.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        let outerRow = Candidate(id: "ax-test-row", label: "Group", bounds: CGRect(x: aim.x - 40, y: aim.y - 24, width: 80, height: 48), score: AccessibilityBounds.baseScore, kind: .element)
        let innerLink = Candidate(id: "ax-test-link", label: "Link", bounds: CGRect(x: aim.x - 20, y: aim.y - 12, width: 40, height: 24), score: AccessibilityBounds.baseScore - 0.01, kind: .element)
        overlay.merge([outerRow, innerLink])
        mouse(.mouseMoved, aim)
        require(overlay.view.overlays.hover == innerLink.bounds && overlay.view.overlays.upHint == outerRow.bounds,
                "the smaller accessibility frame at the pointer is hovered although a larger one scored higher, and Up reaches the larger: \(String(describing: overlay.view.overlays.hover))")

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
        key(up, "")
        let walked = overlay.view.overlays.hover!
        mouse(.mouseMoved, CGPoint(x: aim.x + 2 * overlay.scale, y: aim.y))
        require(overlay.view.overlays.hover == walked, "a walked-to level holds while the pointer moves 2 pt")
        mouse(.mouseMoved, CGPoint(x: aim.x + 2 * overlay.scale, y: aim.y + 4 * overlay.scale))
        require(walked.contains(CGPoint(x: aim.x + 2 * overlay.scale, y: aim.y + 4 * overlay.scale)) && !overlay.session!.isLocked,
                "moving more than 4 pt from where Up walked returns to normal hover, though still inside the bigger element")
        mouse(.mouseMoved, aim)
        require(overlay.view.overlays.hover == inner, "back at the start the smaller element is hovered again")
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
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier
        let axFrames = await Accessibility.frames(at: .zero, pid: dock)
        require(AXIsProcessTrusted() || axFrames.isEmpty, "without Accessibility permission the lookup is empty and silent (trusted: \(AXIsProcessTrusted()))")
        let overlayCenter = CGPoint(x: overlay.window.frame.midX, y: NSScreen.screens[0].frame.height - overlay.window.frame.midY)
        require(await Accessibility.frames(at: overlayCenter, pid: getpid()).isEmpty, "Snug's own windows are never looked up (trusted: \(AXIsProcessTrusted()))")
        overlay.dismiss()

        // Chrome: bottom bar, hints, badges, style bar, hover title, and the safe area.
        let chrome = overlay.chrome
        let width0 = overlay.view.bounds.width
        let guides2 = overlay.view.guides
        open()
        overlay.detectionTask?.cancel()
        mouse(.mouseMoved, flat)
        require(texts(in: chrome.bottomBar) == ["Mode", "Capture", "A", "Text", "T", "View", "Loupe", "L", "Rulers", "R", "Output", "Snap", "S", "Rounded", "O", "Frame", "M", "Shadow", "D"], "the bottom bar shows three titled groups with key caps: \(texts(in: chrome.bottomBar))")
        let bottom = chrome.bottomBar
        let barButtons = [.capture, .text].map { bottom.modeButtons[$0]! } + bottom.toggles.map { $0.1 } + [bottom.shadowButton]
        func clipped() -> [String] {
            barButtons.filter { $0.title.cell!.cellSize.width > $0.title.frame.width || $0.title.frame.maxX > $0.frame.width }.map { $0.title.stringValue }
        }
        let frameButton = bottom.toggles[4].1
        for framed in [false, true] {
            for mode in [OverlayController.Mode.capture, .text] {
                defaults.set(framed, forKey: Pref.frame)
                bottom.click(mode)
                overlay.refresh()
                require(clipped().isEmpty && abs(frameButton.cap!.frame.minX - frameButton.title.frame.maxX - 7) < 0.01 && abs(frameButton.bounds.maxX - frameButton.cap!.frame.maxX - 10) < 0.01,
                        "no bar title clips and the Frame button hugs its cap with Frame \(framed) and \(mode) selected: \(clipped()) \(frameButton.frame)")
            }
        }
        defaults.set(false, forKey: Pref.frame)
        bottom.click(.capture)
        overlay.refresh()
        require(barButtons.allSatisfy { $0.cap!.frame.minX >= $0.title.frame.maxX }, "every bar button shows its key cap after its title")
        bottom.layoutSubtreeIfNeeded()
        func box(_ view: NSView) -> CGRect { bottom.convert(view.bounds, from: view) }
        let d = bottom.dividers.map { box($0).minX }, toggles = bottom.toggles.map { box($0.1) }
        require(box(bottom.modeButtons[.text]!).maxX <= d[0] && d[0] <= toggles[0].minX && toggles[1].maxX <= d[1] && d[1] <= toggles[2].minX
                && toggles[3].maxX <= toggles[4].minX && toggles[4].maxX <= box(bottom.shadowButton).minX,
                "the bar has three groups: Capture, Text | Loupe, Rulers | Snap, Rounded, Frame, Shadow")
        let titles = bottom.groups.map { box($0.arrangedSubviews[0]) }, buttonRows = bottom.groups.map { box($0.arrangedSubviews[1]) }
        require(zip(titles, buttonRows).allSatisfy { $0.minY >= $1.maxY } && titles.allSatisfy { $0.height < 14 } && bottom.frame.height < 66,
                "each group title sits above its buttons and the bar stays compact: \(titles) \(buttonRows) \(bottom.frame.height)")
        let titleFonts = bottom.groups.map { ($0.arrangedSubviews[0] as! NSTextField).font! }
        let gaps = zip(titles, buttonRows).map { $0.minY - $1.maxY }
        require(titleFonts.allSatisfy { $0.pointSize == 10 && NSFontManager.shared.weight(of: $0) >= 8 } && gaps.allSatisfy { $0 == 5 },
                "group titles are 10 pt semibold with 5 pt clear above the button capsules: \(titleFonts) \(gaps)")
        defaults.set(false, forKey: Pref.roundCorners)
        overlay.refresh()
        require(bottom.toggles[3].1.layer!.backgroundColor == nil, "with Rounded off its button is not highlighted")
        bottom.toggles[3].1.onClick()
        require(defaults.bool(forKey: Pref.roundCorners) && bottom.toggles[3].1.layer!.backgroundColor != nil, "the Rounded button turns rounded corners on and highlights")
        bottom.toggles[3].1.onClick()
        require(!defaults.bool(forKey: Pref.roundCorners), "the Rounded button turns rounded corners off")
        defaults.set(true, forKey: Pref.roundCorners)
        require(!defaults.bool(forKey: Pref.frame) && frameButton.layer!.backgroundColor == nil, "Frame defaults to off and its button is not highlighted")
        key(46, "m")
        require(defaults.bool(forKey: Pref.frame) && frameButton.layer!.backgroundColor != nil, "M turns Frame on and the Frame button highlights")
        frameButton.onClick()
        require(!defaults.bool(forKey: Pref.frame) && frameButton.layer!.backgroundColor == nil, "the Frame button turns Frame off")
        require(defaults.bool(forKey: Pref.shadow) && bottom.shadowButton.layer!.backgroundColor != nil, "the window shadow defaults to on")
        key(2, "d")
        require(!defaults.bool(forKey: Pref.shadow) && bottom.shadowButton.layer!.backgroundColor == nil, "D turns the window shadow off and the Shadow button follows")
        require(overlay.windowShadow(option: false) == false && overlay.windowShadow(option: true), "with the shadow off, Option-click puts it back")
        bottom.shadowButton.onClick()
        require(defaults.bool(forKey: Pref.shadow) && overlay.windowShadow(option: false) && !overlay.windowShadow(option: true), "the Shadow button turns it back on, and Option-click then drops it")
        overlay.setWindows([CGRect(x: 300, y: 300, width: 400, height: 200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(texts(in: chrome.hover) == ["Browser", "400 x 200  +  shadow", "copy", "\u{21A9}", "save", "\u{2318}S"], "hovering a window shows its title, size, and shadow: \(texts(in: chrome.hover))")
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
        require(texts(in: chrome.hints) == ["capture", "Click", "edit", "E", "bigger / smaller", "\u{2191}", "\u{2193}", "full screen", "F", "window", "W", "all keys", "?"],
                "the capture strip names W window after F full screen: \(texts(in: chrome.hints))")
        mouse(.leftMouseDown, rough.origin)
        mouse(.leftMouseDragged, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status).isEmpty && !chrome.size.isHidden, "a quick drag shows only the size badge")
        for _ in 0..<9000 where overlay.snapPreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        let fit = overlay.snapPreview!
        require(texts(in: chrome.size) == ["\(Int(fit.width)) x \(Int(fit.height))"] && texts(in: chrome.status) == ["Snap ready: release to take it, Tab for others"], "a snap preview shows its size and Snap ready")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.status) == ["Snapped"], "after release on a fit: Snapped")
        require(chrome.bottomBar.isHidden && !chrome.actionBar.isHidden && texts(in: chrome.hints)
                    == ["resize", "\u{2325}", "keep ratio, axis", "\u{21E7}", "cancel", "esc"],
                "the action bar replaces the bottom bar, with the released hints, each label before its keys: \(texts(in: chrome.hints))")
        require(chrome.hints.frame.height < 40 && chrome.hints.frame.width <= overlay.view.bounds.width - 16, "the released hint strip is one line and fits: \(chrome.hints.frame) in \(overlay.view.bounds.width)")
        require(texts(in: chrome.actionBar) == ["Frame", "M", "Snap", "S", "Rounded", "O", "Shadow", "D", "Scroll", "G", "Record", "V", "Cut out", "K", "Save", "\u{2318}S", "Copy", "\u{21A9}"],
                "the action bar shows Frame, Snap, Rounded, Shadow, Scroll, Record, Cut out, Save, and Copy with key caps: \(texts(in: chrome.actionBar))")
        // Rounded and Shadow on the action bar are toggles like Frame and Snap: they follow O and D, and clicks flip the preferences.
        let roundedButton = chrome.actionBar.roundedButton, shadowButton = chrome.actionBar.shadowButton
        require(defaults.bool(forKey: Pref.roundCorners) && roundedButton.layer!.backgroundColor != nil && defaults.bool(forKey: Pref.shadow) && shadowButton.layer!.backgroundColor != nil,
                "with rounded corners and the shadow on, the action bar's Rounded and Shadow are highlighted")
        key(31, "o")
        require(!defaults.bool(forKey: Pref.roundCorners) && roundedButton.layer!.backgroundColor == nil, "O turns rounded corners off and the action bar's Rounded follows")
        roundedButton.onClick()
        require(defaults.bool(forKey: Pref.roundCorners) && roundedButton.layer!.backgroundColor != nil, "clicking the action bar's Rounded turns rounded corners back on")
        key(2, "d")
        require(!defaults.bool(forKey: Pref.shadow) && shadowButton.layer!.backgroundColor == nil, "D turns the shadow off and the action bar's Shadow follows")
        shadowButton.onClick()
        require(defaults.bool(forKey: Pref.shadow) && shadowButton.layer!.backgroundColor != nil, "clicking the action bar's Shadow turns the shadow back on")
        // The ratio chip above the selection's top-right corner: the readout with P opens the ratio menu, the lock with Shift-P toggles
        // the lock. Both take clicks through the otherwise click-through chip.
        func ratioButtons() -> [BarButton] { chrome.ratio.subviews.compactMap { $0 as? BarButton } }
        let lockedBefore = overlay.ratioLocked, rectBefore = overlay.selection!.rect
        let roughBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.ratio.isHidden && ratioButtons().count == 2 && ratioButtons()[0].title.stringValue == "ratio \(overlay.ratioReadout)"
                    && ratioButtons()[1].symbol?.image?.accessibilityDescription == (lockedBefore ? "Ratio locked" : "Ratio unlocked"),
                "the ratio chip shows the readout, then a lock that follows ratioLocked: \(ratioButtons().map { texts(in: $0) })")
        require(chrome.ratio.frame.minY > roughBox.maxY && abs(chrome.ratio.frame.midY - chrome.size.frame.midY) < 1 && !chrome.ratio.frame.intersects(chrome.size.frame) && !chrome.ratio.frame.intersects(chrome.status.frame),
                "the ratio chip sits above the selection on the badges' row, clear of them: \(chrome.ratio.frame) \(roughBox) \(chrome.size.frame) \(chrome.status.frame)")
        for button in ratioButtons() {
            let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: overlay.view)
            require(overlay.view.hitTest(center) === button, "a click on the ratio chip's \(texts(in: button)) reaches it")
        }
        ratioButtons()[1].onClick()
        require(overlay.ratioLocked != lockedBefore && overlay.selection!.rect == rectBefore
                    && ratioButtons()[1].symbol?.image?.accessibilityDescription == (lockedBefore ? "Ratio unlocked" : "Ratio locked"),
                "clicking the lock toggles the lock, keeps the selection, and swaps the icon")
        ratioButtons()[1].onClick()
        require(overlay.ratioLocked == lockedBefore && overlay.selection!.rect == rectBefore, "clicking the lock again puts it back")
        // The ratio menu: a panel under the chip, right edges aligned, taking the keys and the pointer while open.
        let menu = chrome.ratioMenu, beforeMenu = overlay.selection!
        func viewPixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * overlay.scale, y: (overlay.view.bounds.height - point.y) * overlay.scale) }
        func rowCenter(_ title: String) -> CGPoint {
            let row = menu.rows[menu.items.firstIndex { $0.title == title }!]
            return row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: overlay.view)
        }
        ratioButtons()[0].onClick()
        require(!menu.isHidden && overlay.window.firstResponder === menu && menu.panel.frame.maxX == chrome.ratio.frame.maxX && menu.panel.frame.maxY <= chrome.ratio.frame.minY,
                "clicking the readout opens the ratio panel under the chip, right edges aligned: \(menu.panel.frame) \(chrome.ratio.frame)")
        require(menu.items.map(\.title) == ["Free", "Original", "1:1", "4:3", "3:2", "16:10", "16:9", "21:9", "", "Portrait"] && menu.items.filter(\.on).map(\.title) == (overlay.ratioLocked ? [] : ["Free"]),
                "the panel lists the presets and checks Free while unlocked: \(menu.items.map(\.title))")
        key(53, "\u{1B}")
        require(menu.isHidden && overlay.window.isVisible && overlay.selection?.rect == rectBefore && overlay.window.firstResponder === overlay.view,
                "Esc closes the panel and leaves the selection and the overlay")
        key(35, "p")
        key(down, "")
        key(down, "")
        key(up, "")
        key(up, "")
        require(menu.highlighted == menu.items.count - 1 && overlay.selection?.rect == rectBefore, "Up and Down move the highlight, wrapping and skipping the separator, without nudging")
        key(down, "")
        key(down, "")
        key(down, "")
        require(menu.highlighted == 2, "Down steps to 1:1")
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(menu.isHidden && overlay.ratioLocked && overlay.selection!.rect.width == overlay.selection!.rect.height && pasteboard.data(forType: .png) == nil && overlay.window.isVisible,
                "Return picks the highlighted 1:1, which conforms and locks, without copying: \(overlay.selection!.rect)")
        key(35, "p")
        require(menu.items.filter(\.on).map(\.title) == ["1:1"], "the panel checks the lock it applied")
        mouse(.mouseMoved, viewPixel(rowCenter("Free")))
        require(menu.highlighted == 0, "the pointer highlights the row under it: \(String(describing: menu.highlighted))")
        mouse(.leftMouseDown, viewPixel(rowCenter("Free")))
        mouse(.leftMouseUp, viewPixel(rowCenter("Free")))
        require(menu.isHidden && !overlay.ratioLocked, "a click on Free picks it and closes the panel: hidden \(menu.isHidden) locked \(overlay.ratioLocked) hit \(String(describing: overlay.view.hitTest(rowCenter("Free"))))")
        let squared = overlay.selection!.rect
        key(35, "p")
        mouse(.leftMouseDown, CGPoint(x: 40, y: 40))
        mouse(.leftMouseUp, CGPoint(x: 40, y: 40))
        require(menu.isHidden && overlay.selection?.rect == squared, "a click outside the panel closes it and leaves the selection")
        key(35, "p")
        key(124, "")
        require(menu.isHidden && overlay.selection?.rect == squared.offsetBy(dx: 1, dy: 0), "another key closes the panel and goes on to the overlay: Right nudges")
        overlay.selection = beforeMenu
        overlay.lockedRatio = nil
        overlay.ratioBase = nil
        overlay.refresh()
        require(overlay.selection?.rect == rectBefore && texts(in: chrome.status) == ["Snapped"], "the snapped selection is back for the next checks")
        let snapButton = chrome.actionBar.snapButton
        require(snapButton.layer!.backgroundColor != nil, "with snap on the action bar's Snap is highlighted")
        snapButton.onClick()
        require(!defaults.bool(forKey: Pref.snap) && snapButton.layer!.backgroundColor == nil, "clicking the action bar's Snap turns snap off and unhighlights it")
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap) && snapButton.layer!.backgroundColor != nil, "S turns snap back on and the Snap button follows")
        /// The key caps under `view` whose glyph is `text`.
        func keyCaps(_ text: String, in view: NSView) -> [KeyCap] {
            ((view as? KeyCap).map { cap in texts(in: cap) == [text] ? [cap] : [] } ?? []) + view.subviews.flatMap { keyCaps(text, in: $0) }
        }
        func flags(_ modifiers: NSEvent.ModifierFlags) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        }
        // The edge keys: the side arrows and the radius keys show while the pointer rests inside the selection, and go when it leaves.
        let insideSelection = CGPoint(x: overlay.selection!.rect.midX, y: overlay.selection!.rect.midY)
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(chrome.sideHints.allSatisfy(\.isHidden) && chrome.radiusHint.isHidden, "with the pointer outside the selection no edge keys show")
        mouse(.mouseMoved, insideSelection)
        require(chrome.sideHints.map { texts(in: $0) } == [["\u{2190}"], ["\u{2192}"], ["\u{2191}"], ["\u{2193}"]] && chrome.sideHints.allSatisfy { !$0.isHidden }
                    && texts(in: chrome.radiusHint) == ["radius", "[", "]"] && !chrome.radiusHint.isHidden,
                "with the pointer inside the selection the side arrows and the radius keys show: \(chrome.sideHints.map(\.isHidden)) \(chrome.radiusHint.isHidden)")
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(chrome.sideHints.allSatisfy(\.isHidden) && chrome.radiusHint.isHidden, "moving the pointer out of the selection hides the edge keys")
        let selected = overlay.view.viewRect(overlay.selection!.rect)
        require(chrome.sideHints.allSatisfy(\.isHidden) && keyCaps("\u{2325}", in: chrome.hints).allSatisfy { !$0.held }, "without Option no side arrows show and the Option cap is gray")
        flags(.option)
        let sides = chrome.sideHints
        require(keyCaps("\u{2325}", in: chrome.hints).count == 1 && keyCaps("\u{2325}", in: chrome.hints).allSatisfy(\.held) && keyCaps("\u{2318}", in: chrome.hints).isEmpty
                && texts(in: chrome.hints).contains("grow") && !texts(in: chrome.hints).contains("resize"),
                "holding Option fills the Option cap and the resize hint reads grow: \(texts(in: chrome.hints))")
        require(sides.map { texts(in: $0) } == [["\u{2190}"], ["\u{2192}"], ["\u{2191}"], ["\u{2193}"]] && sides.allSatisfy { !$0.isHidden }
                && sides[0].frame.maxX <= selected.minX && sides[1].frame.minX >= selected.maxX && sides[2].frame.minY >= selected.maxY
                && abs(sides[0].frame.midY - selected.midY) < 1 && abs(sides[2].frame.midX - selected.midX) < 1
                && !sides[3].frame.intersects(chrome.actionBar.frame),
                "holding Option puts an arrow cap outside each side's midpoint, clear of the action bar: \(sides.map(\.frame)) \(selected)")
        flags([.option, .command])
        require(keyCaps("\u{2318}", in: chrome.hints).count == 1 && (keyCaps("\u{2318}", in: chrome.hints) + keyCaps("\u{2325}", in: chrome.hints)).allSatisfy(\.held)
                && texts(in: chrome.hints).contains("shrink") && !texts(in: chrome.hints).contains("grow") && sides.allSatisfy { !$0.isHidden },
                "holding Option-Command makes the hint shrink with both caps filled and keeps the side arrows: \(texts(in: chrome.hints))")
        flags(.shift)
        require(keyCaps("\u{21E7}", in: chrome.hints).count == 1 && keyCaps("\u{21E7}", in: chrome.hints).allSatisfy(\.held) && sides.allSatisfy(\.isHidden) && texts(in: chrome.hints).contains("resize"),
                "holding Shift fills the Shift cap, and without Option the side arrows go and the strip reads resize")
        flags([])
        require(keyCaps("\u{21E7}", in: chrome.hints).count == 1 && keyCaps("\u{21E7}", in: chrome.hints).allSatisfy { !$0.held }, "releasing Shift turns its cap gray")
        let snapped = overlay.selection!
        overlay.selection = AreaSelection(extent: extent, exact: snapped.exact)
        overlay.refresh()
        require(!overlay.hasOtherFits && !texts(in: chrome.hints).contains("next snap"), "a selection with no other fits hides Tab next snap: \(texts(in: chrome.hints))")
        overlay.selection = snapped
        overlay.refresh()
        overlay.editedRadii[snapped.rect] = CornerRadii(12 * overlay.scale)
        mouse(.mouseMoved, overlay.cornerRadii(of: snapped.rect).dot(of: .topLeft, in: snapped.rect, minimumInset: 8 * overlay.scale))
        let cornerKeys = chrome.cornerKeys, cornerChip = overlay.cornerChip
        require(!cornerChip.isHidden && texts(in: cornerKeys) == ["radius", "[", "]", "one corner", "\u{2325}"]
                && cornerKeys.frame.maxY <= cornerChip.frame.minY && abs(cornerKeys.frame.maxX - cornerChip.frame.maxX) < 0.5,
                "hovering a corner dot shows radius [ ] and Option for one corner under the All corners chip: \(texts(in: cornerKeys)) \(cornerKeys.frame) \(cornerChip.frame)")
        flags(.option)
        require(keyCaps("\u{2325}", in: cornerKeys).allSatisfy(\.held) && !keyCaps("\u{2325}", in: cornerKeys).isEmpty, "holding Option fills the in-place Option cap by the corner")
        flags([])
        mouse(.mouseMoved, CGPoint(x: snapped.rect.midX, y: snapped.rect.midY))
        require(cornerKeys.isHidden, "leaving the corner dot hides its keys")
        let released = overlay.view.viewRect(overlay.selection!.rect)
        require(chrome.actionBar.frame.maxY == released.minY - 8 && chrome.actionBar.frame.minX == min(max(released.minX, 8), overlay.view.bounds.width - chrome.actionBar.frame.width - 8),
                "the action bar is attached under the selection: \(chrome.actionBar.frame) \(released)")
        require(chrome.size.frame.minY == released.maxY + 8, "the size badge sits above the selection")
        chrome.actionBar.frameButton.onClick()
        require(overlay.framed && chrome.actionBar.frameButton.layer!.backgroundColor != nil, "clicking the action bar's Frame turns Frame on and highlights it")
        key(46, "m")
        require(!overlay.framed && chrome.actionBar.frameButton.layer!.backgroundColor == nil, "M turns Frame off on a released selection")
        for _ in 0..<overlay.selection!.fits.count where texts(in: chrome.status) != ["Exact"] { key(48, "") }
        require(texts(in: chrome.status) == ["Exact"], "Tab to the exact drag shows Exact")
        key(53, "")
        require(chrome.actionBar.isHidden && chrome.size.isHidden && chrome.status.isHidden, "Esc takes the action bar and badges away")

        // The Live Text button: inside a large selection's bottom-right corner, past the corner dot and clear of the edge handles. A click
        // runs Shift-Return, queued here behind a warm-up that never ends so no text recognition runs. A small selection has none.
        open()
        let large = CGRect(x: 600, y: 300, width: 1000, height: 600)
        overlay.selection = AreaSelection(extent: extent, exact: large)
        overlay.editedRadii[large] = CornerRadii(40 * overlay.scale)
        overlay.refresh()
        let largeBox = overlay.view.viewRect(large), textFrame = chrome.textButton.frame
        let dot = overlay.view.viewRect(CGRect(origin: overlay.cornerRadii(of: large).dot(of: .bottomRight, in: large, minimumInset: 8 * overlay.scale), size: .zero)).origin
        require(!chrome.textButton.isHidden && largeBox.contains(textFrame) && textFrame.maxX <= largeBox.maxX - 8 && textFrame.minY >= largeBox.minY + 8
                    && textFrame.maxX < dot.x - 6 && textFrame.minY > dot.y + 6,
                "the Live Text button sits inside the bottom-right corner, past its corner dot and the edge handles: \(textFrame) \(largeBox) dot \(dot)")
        require(texts(in: chrome.textButton) == ["\u{21E7}\u{21A9}"] && chrome.textButton.button.symbol?.image?.accessibilityDescription == "Live Text",
                "the Live Text button shows the Live Text glyph and Shift-Return: \(texts(in: chrome.textButton))")
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        require(overlay.view.hitTest(textCenter) === chrome.textButton.button, "a click on the Live Text button reaches it")
        OverlayController.visionWarmUp = Task { try? await Task.sleep(for: .seconds(3600)) }
        mouse(.leftMouseDown, viewPixel(textCenter))
        mouse(.leftMouseUp, viewPixel(textCenter))
        require(overlay.text.queued?.notice.hasPrefix("Shift-Return") == true, "clicking the Live Text button runs Shift-Return: \(String(describing: overlay.text.queued?.notice))")
        overlay.text.queued = nil
        OverlayController.visionWarmUp!.cancel()
        await OverlayController.visionWarmUp!.value
        await overlay.textTask?.value
        OverlayController.visionWarmUp = nil
        overlay.text.notice = nil
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 600, y: 300, width: 120, height: 80))
        overlay.refresh()
        require(chrome.textButton.isHidden, "a selection too small for the Live Text button hides it")

        // Released chrome never overlaps or leaves the screen: a large and a small selection, one at each screen edge, and the full
        // screen with a 38 pt inset, each with the pointer inside so the edge keys show.
        let edgeCases = [("large", large), ("small", CGRect(x: 600, y: 300, width: 120, height: 80)), ("left", CGRect(x: 0, y: 600, width: 500, height: 300)),
                         ("right", CGRect(x: extent.width - 500, y: 600, width: 500, height: 300)), ("top", CGRect(x: 900, y: 0, width: 700, height: 300)),
                         ("bottom", CGRect(x: 900, y: extent.height - 300, width: 700, height: 300)), ("full", extent)]
        for (name, rect) in edgeCases {
            overlay.topInset = name == "full" ? 38 : 0
            overlay.selection = AreaSelection(extent: extent, exact: rect)
            overlay.refresh()
            mouse(.mouseMoved, CGPoint(x: 40, y: 40))
            mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
            let pieces: [(String, NSView)] = [("hints", chrome.hints), ("action bar", chrome.actionBar), ("text button", chrome.textButton), ("ratio", chrome.ratio),
                                               ("size", chrome.size), ("status", chrome.status), ("radius", chrome.radiusHint)]
                + chrome.sideHints.enumerated().map { ("side \($0.offset)", $0.element) }
            let shown = pieces.filter { !$0.1.isHidden }
            let overlaps = shown.indices.flatMap { i in shown.indices.filter { $0 > i && shown[i].1.frame.intersects(shown[$0].1.frame) }.map { "\(shown[i].0) x \(shown[$0].0)" } }
            let screen = CGRect(x: 0, y: 0, width: overlay.view.bounds.width, height: overlay.view.bounds.height - overlay.topInset)
            let outside = shown.filter { !screen.contains($0.1.frame) }.map { "\($0.0) \($0.1.frame) in \(screen)" }
            require(overlaps.isEmpty && outside.isEmpty && !chrome.ratio.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden },
                    "the \(name) selection's chrome does not overlap or leave the screen: overlaps \(overlaps), outside \(outside)")
        }
        overlay.topInset = 0

        // Armed to record, the selection keeps none of the editing chrome; Esc brings it back.
        overlay.dismiss()
        overlay.present(image: image, frame: frame, displayID: CGMainDisplayID())
        overlay.detectionTask?.cancel()
        overlay.selection = AreaSelection(extent: extent, exact: large)
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        mouse(.mouseMoved, CGPoint(x: large.midX, y: large.midY))
        require(!chrome.textButton.isHidden && !chrome.ratio.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden }, "before arming, the editing chrome shows")
        key(9, "v")
        require(overlay.armedRecording != nil && chrome.textButton.isHidden && chrome.ratio.isHidden && chrome.radiusHint.isHidden && chrome.sideHints.allSatisfy(\.isHidden),
                "armed to record, the Live Text button, ratio chip, and edge keys hide")
        key(53, "\u{1B}")
        require(overlay.armedRecording == nil && !chrome.textButton.isHidden && !chrome.ratio.isHidden, "Esc disarms and brings the editing chrome back")
        overlay.dismiss()

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
        require(overlay.scrollHeight == 900 && texts(in: chrome.hints) == ["Scroll to capture more: 900 px", "done", "\u{21A9}", "cancel", "esc"],
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
        overlay.refresh()
        chrome.actionBar.scroll.onClick()
        require(overlay.scrollArea == page, "the action bar's Scroll starts scrolling capture as G does")
        pasteboard.clearContents()
        key(53, "")
        require(!overlay.window.isVisible && overlay.scrollArea == nil && pasteboard.data(forType: .png) == nil, "Esc cancels scrolling capture with the clipboard untouched")
        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 1700, y: 100, width: 300, height: 300))
        key(5, "g")
        require(overlay.scrollArea == nil, "G does nothing for an area outside every window")
        key(53, "")
        overlay.scrollFrames = nil

        // Hint row: on a narrow screen it drops hints from the end and keeps "all keys" last.
        open()
        let fullHints = texts(in: chrome.hints)
        overlay.view.setFrameSize(CGSize(width: 520, height: overlay.view.bounds.height))
        overlay.refresh()
        let narrowHints = texts(in: chrome.hints)
        require(chrome.hints.frame.width <= 520 - 16 && narrowHints.count < fullHints.count && narrowHints.first == fullHints.first && narrowHints.suffix(2) == ["all keys", "?"], "a 520 pt screen drops hints from the end and keeps all keys last: \(narrowHints)")
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
        let lowBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.actionBar.isHidden && chrome.actionBar.frame.minY == lowBox.maxY + 8 && chrome.hints.frame.minY > halfHeight,
                "a released selection at the bottom puts the action bar above it and the hints at the top: \(chrome.actionBar.frame) \(lowBox)")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(chrome.atTop, "the pointer at the bottom does not pull the hints back down")
        key(53, "")
        open()
        drag(rough)
        require(!chrome.actionBar.isHidden && chrome.hints.frame.maxY < halfHeight, "a selection well above the bottom keeps the hints at the bottom")
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
        require(!chrome.size.isHidden && !chrome.hints.isHidden && !chrome.actionBar.isHidden, "the full-screen state shows the size badge, hints, and action bar")
        overlay.topInset = 0
        overlay.refresh()
        require(guides2.bands.path!.boundingBox.maxY == overlay.view.bounds.height, "without an inset the top ruler sits at the top edge")
        overlay.dismiss()
        for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }
        try await verifyRecording(image: image, frame: frame, overlay: overlay, require: require)

        print("Extras UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }
}

extension DebugRun {
    /// `--verify-toast-trash`: the toast's Trash button. Kept out of `--verify-extras-ui` because each run moves three test files into the
    /// real Trash.
    static func verifyToastTrash(image: CGImage) async throws {
        var passed: [String] = []
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Toast trash verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
        }
        let capture = try await Output.png(image.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 400))!)
        let saveFolder = FileManager.default.temporaryDirectory.appending(path: "snug-toast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        // Trash moves the saved file to the Trash and clears the pasteboard only if it still holds this capture; the toast closes. A recording's
        // toast opens in QuickTime Player and its pasteboard holds the file URL.
        let trashDefaults = UserDefaults(suiteName: "snug-toast-\(UUID().uuidString)")!
        Pref.register(in: trashDefaults)
        func trashing(_ name: String, holding: (NSPasteboard, URL) -> Void) throws -> (toast: Toast, pasteboard: NSPasteboard) {
            let file = saveFolder.appending(path: name)
            try capture.write(to: file)
            let trashBoard = NSPasteboard(name: NSPasteboard.Name("snug-toast-trash-\(UUID().uuidString)"))
            holding(trashBoard, file)
            let trashing = Toast(png: capture, message: "Copied, saved", detail: name, file: file, color: nil, defaults: trashDefaults, pasteboard: trashBoard)
            require(trashing.saveButton.isHidden && !trashing.trashButton.isHidden, "a saved toast shows Trash and not Save")
            trashing.trashButton.performClick(nil)
            require(!FileManager.default.fileExists(atPath: file.path) && trashing.png == nil, "Trash removes the saved file and closes the toast: \(name)")
            return (trashing, trashBoard)
        }
        let ownBoard = try trashing("snug-trash-own.png") { board, _ in board.setData(capture, forType: .png) }
        require(ownBoard.pasteboard.data(forType: .png) == nil, "Trash clears a pasteboard that still holds the capture")
        let otherBoard = try trashing("snug-trash-other.png") { board, _ in board.setString("something else", forType: .string) }
        require(otherBoard.pasteboard.string(forType: .string) == "something else", "Trash leaves a pasteboard that holds something else")
        let movieBoard = try trashing("snug-trash-recording.mov") { board, file in board.writeObjects([file as NSURL]) }
        require(movieBoard.pasteboard.readObjects(forClasses: [NSURL.self])?.isEmpty == true, "Trash clears a pasteboard that holds the recording's file URL")
        require(movieBoard.toast.openInPreview.toolTip == "Open in QuickTime Player", "a recording's toast opens in QuickTime Player")

        print("Toast trash verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }
}
