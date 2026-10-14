import AppKit
import Carbon.HIToolbox
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
        let returnKey: UInt16 = 36, up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
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
        overlay.chrome.modeButtons[.capture]!.onClick()
        require(overlay.mode == .capture, "clicking a top bar mode switches mode")
        require(overlay.chrome.modeButtons.count == 2 && !texts(in: overlay.chrome.topBar).contains("Element"), "the top bar has two modes, Capture and Text")
        overlay.dismiss()

        // Opening draws at once: no layer under the view animates implicitly, so the frozen image replaces the black window in one frame.
        func animations(_ layer: CALayer) -> [String] { (layer.animationKeys() ?? []).map { "\(type(of: layer)) \($0)" } + (layer.sublayers ?? []).flatMap(animations) }
        open()
        require(animations(overlay.view.layer!).isEmpty, "opening animates no layer: \(animations(overlay.view.layer!))")

        // B toggles the keys line and remembers it; the top bar stays.
        let keysLine = overlay.chrome.hints
        require(!keysLine.isHidden && !overlay.chrome.topBar.isHidden, "the keys line and top bar start visible")
        key(11, "b")
        require(keysLine.isHidden && !overlay.chrome.topBar.isHidden && !defaults.bool(forKey: Pref.modeBar), "B hides the keys line and remembers it")
        key(11, "b")
        require(!keysLine.isHidden && defaults.bool(forKey: Pref.modeBar), "B shows it again")

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
        // With Rulers on, the top bar sits below the top ruler's band and nothing clamps into the left ruler's.
        let topRuler = CGRect(x: 0, y: view.bounds.height - overlay.topInset - Guides.rulerThickness, width: view.bounds.width, height: Guides.rulerThickness)
        let leftRuler = CGRect(x: 0, y: 0, width: Guides.rulerThickness, height: view.bounds.height)
        let edgeChrome = [overlay.chrome.topBar, overlay.chrome.hints, overlay.chrome.strip, overlay.chrome.hover, overlay.chrome.snapTag].filter { !$0.isHidden }
        require(edgeChrome.allSatisfy { !$0.frame.intersects(topRuler) && !$0.frame.intersects(leftRuler) } && overlay.chrome.topBar.frame.maxY == topRuler.minY - 8,
                "with Rulers on, the top bar sits 8 pt under the top ruler and no chrome covers a ruler: \(edgeChrome.map(\.frame)) \(topRuler)")
        let controls = overlay.chrome.topBar.groups + [overlay.chrome.hints, overlay.chrome.strip].filter { !$0.isHidden }
        let labelPills = [overlay.chrome.hover, overlay.chrome.size, overlay.chrome.reading].filter { !$0.isHidden }
        require(controls.allSatisfy { $0.frame.height == Chrome.controlHeight } && labelPills.allSatisfy { $0.frame.height == Chrome.labelHeight },
                "controls are \(Chrome.controlHeight) pt and labels \(Chrome.labelHeight) pt tall: \(controls.map(\.frame.height)) \(labelPills.map(\.frame.height))")
        let before = guides.loupe.position
        mouse(.mouseMoved, CGPoint(x: text.x - 300, y: text.y - 200))
        require(guides.loupe.position != before, "the loupe follows the pointer")
        mouse(.mouseMoved, text)
        // The readout under the loupe is a chip: swatch, hex value, pixel coordinates, then copy with a C key cap that flashes on C (here through the flash
        // hook alone, since a real C copies and closes the overlay).
        let readout = guides.readout, readoutCap = readout.subviews.compactMap { $0 as? KeyCap }.filter { $0.text == "C" }
        let loupeBox = guides.loupe.frame
        require(!readout.isHidden && readoutCap.count == 1 && texts(in: readout).count == 4 && texts(in: readout)[0].hasPrefix("#")
                    && texts(in: readout)[1].range(of: #"^x \d+  y \d+$"#, options: .regularExpression) != nil && texts(in: readout)[2] == "copy"
                    && readout.frame.height == Chrome.labelHeight && readout.frame.minY >= loupeBox.minY && readout.frame.maxY <= loupeBox.minY + Chrome.labelHeight && abs(readout.frame.midX - loupeBox.midX) <= 1
                    && overlay.view.bounds.contains(readout.frame),
                "the loupe's readout is a chip under the disc with the value, copy, and a C cap: \(texts(in: readout)) \(readout.frame) \(loupeBox)")
        overlay.flash(KeyCap.event(for: "C"))
        require(readoutCap[0].pressed, "C flashes the readout's C cap")
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
        // The loupe's outline, the crosshair, and the loupe's center cell follow the highlight color pref, not the system accent.
        defaults.set("#E5484D", forKey: Pref.highlightColor)
        overlay.view.highlight = Highlight(defaults: defaults)
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        let edgeContext = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guides.edges.render(in: edgeContext)
        let edgeBytes = NSBitmapImageRep(cgImage: edgeContext.makeImage()!)
        let solid = (0..<size).flatMap { y in (0..<size).map { (x: $0, y: y) } }.map { edgeBytes.colorAt(x: $0.x, y: $0.y)! }.filter { $0.alphaComponent > 0.5 }
        require(!solid.isEmpty && solid.allSatisfy { close(bytes($0), [229, 72, 77], 2) }, "the loupe's selection outline is drawn in the highlight color: \(solid.first.map(bytes) ?? [])")
        for (name, color) in [("crosshair", guides.crosshair.strokeColor), ("loupe center cell", guides.centerAccent.strokeColor)] {
            let shown = NSColor(cgColor: color!)!.usingColorSpace(.sRGB)!
            require(close(bytes(shown), [229, 72, 77], 2), "the \(name) is drawn in the highlight color")
        }
        let modeFill = overlay.chrome.modeButtons[.capture]!.layer!.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        require(modeFill.map { close(bytes($0), [229, 72, 77], 2) } == true, "a new highlight color restyles the buttons: the current mode fills with it")
        defaults.removeObject(forKey: Pref.highlightColor)
        overlay.view.highlight = Highlight(defaults: defaults)
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
        for y in stride(from: barChrome.hints.frame.maxY + 4, through: barChrome.hints.frame.maxY + 140, by: 12) {
            mouse(.mouseMoved, CGPoint(x: barChrome.hints.frame.midX * overlay.scale, y: (viewBounds.height - y) * overlay.scale))
            let covered = [barChrome.topBar, barChrome.hints, barChrome.strip].filter { !$0.isHidden && guides.loupe.frame.intersects($0.frame) }
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

        // U opens the Colors menu under the strip's Colors button: the selection's average (what C copied), a separator, then its main
        // colors, each with a 1-6 cap. The digit or a click copies that value with the C toast and closes the overlay; Esc closes the menu.
        open()
        drag(average)
        let colors = overlay.chrome.colorMenu, format = ColorFormat(rawValue: defaults.string(forKey: Pref.colorFormat)!)!
        let palette = ColorFormat.palette(of: image, in: average).map(format.string)
        func openColors(_ action: () -> Void) async throws {
            colors.isHidden = true
            action()
            for _ in 0..<1000 where colors.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await openColors { overlay.chrome.colors.onClick() }
        require(texts(in: overlay.chrome.strip).contains("Colors") && !colors.isHidden && overlay.window.firstResponder === colors,
                "clicking the strip's Colors button opens the menu: \(texts(in: overlay.chrome.strip))")
        let button = overlay.view.convert(overlay.chrome.colors.bounds, from: overlay.chrome.colors)
        require(colors.panel.frame.minX == min(max(button.minX, 8), overlay.view.bounds.width - colors.panel.frame.width - 8) && colors.panel.frame.maxY <= button.minY,
                "the menu sits under the Colors button, left edges aligned: \(colors.panel.frame) \(button)")
        let averageText = format.string(for: ColorFormat.average(of: image, in: average))
        require(colors.items.map(\.title) == [averageText, ""] + palette && colors.items.map(\.cap) == ["1", nil, "2", "3", "4", "5", "6"] && palette.count == 5
                    && colors.items.filter { $0.swatch != nil }.count == 6,
                "the menu lists the average, a separator, and five main colors, each with a swatch and a cap: \(colors.items.map(\.title)) \(colors.items.map(\.cap))")
        require(averageText == pasteboard.string(forType: .string), "the first row is the color C copies: \(averageText)")
        require(texts(in: overlay.chrome.hints) == ["pick", "\u{2191}", "\u{2193}", "copy", "\u{21A9}", "1-6", "close", "esc"], "the keys line names the menu's keys: \(texts(in: overlay.chrome.hints))")
        key(53, "\u{1B}")
        require(colors.isHidden && overlay.window.isVisible && overlay.selection?.rect == average, "Esc closes the Colors menu and keeps the selection")
        try await openColors { key(32, "u") }
        require(!colors.isHidden, "U opens the menu")
        key(32, "u")
        require(colors.isHidden && overlay.window.isVisible, "U again closes it")
        try await openColors { key(32, "u") }
        pasteboard.clearContents()
        key(20, "3")
        require(!overlay.window.isVisible && pasteboard.string(forType: .string) == palette[1], "the 3 key copies the second main color \(palette[1]): \(pasteboard.string(forType: .string) ?? "nothing")")
        open()
        drag(average)
        try await openColors { key(32, "u") }
        pasteboard.clearContents()
        key(18, "1")
        require(!overlay.window.isVisible && pasteboard.string(forType: .string) == averageText, "the 1 key copies the average \(averageText)")
        open()
        drag(average)
        try await openColors { key(32, "u") }
        let colorRow = colors.rows[colors.items.firstIndex { $0.cap == "2" }!]
        let rowPoint = colorRow.convert(CGPoint(x: colorRow.bounds.midX, y: colorRow.bounds.midY), to: overlay.view)
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: rowPoint.x * overlay.scale, y: (overlay.view.bounds.height - rowPoint.y) * overlay.scale))
        mouse(.leftMouseUp, CGPoint(x: rowPoint.x * overlay.scale, y: (overlay.view.bounds.height - rowPoint.y) * overlay.scale))
        require(!overlay.window.isVisible && pasteboard.string(forType: .string) == palette[0], "a click on a row copies its value \(palette[0])")
        overlay.dismiss()

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
                    && helpActions["K"] == "Subject preview" && helpActions["Subject: Tab"] == "Next subject (Shift: back)" && helpActions["V"] == "Arm recording, hover or selection"
                    && helpActions["Armed: Return / V"] == "Start recording" && helpActions["Armed: H"] == "Cursor on / off" && helpActions["Armed: I"] == "Count-in off, 3 s, 5 s"
                    && helpActions["Capture hotkey"] == "Stop recording" && helpActions["G"] == "Scrolling capture, hover or selection" && helpActions["Subject: S"] == "Crop to subject"
                    && helpActions["Cmd-arrow"] == "Edge out, one side" && helpActions["Cmd-Shift-arrow"] == "Edge in, one side"
                    && helpActions["+ / -"] == "All sides 1 px (Option: 10)" && helpActions["Shift-Return"] == "Copy the text"
                    && helpActions["Tab"] == "Walk out (Shift: in)"
                    && !helpRows.contains { $0.action.contains("Aspect ratio lock") },
                "the sheet lists the ratio menu and lock, W, the subject keys, G and V on a hover, the recording keys, Cmd-arrow, + and -, Shift-Return on a hover, Tab without other fits, and no P cycle")
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
        require(Array(texts(in: overlay.chrome.hover).dropFirst()) == ["\(Int(hovered.width)) x \(Int(hovered.height))"] && texts(in: overlay.chrome.strip).prefix(4) == ["Edit", "E", "Copy", "\u{21A9}"],
                "the hover chip shows the name and the size, and the strip below starts with Edit, then Copy: \(texts(in: overlay.chrome.hover))")
        let hoverBox = overlay.view.viewRect(hovered)
        require(overlay.chrome.hover.frame.minX == max(hoverBox.minX, 8) && (overlay.chrome.hover.frame.minY == hoverBox.maxY + 8 || hoverBox.contains(overlay.chrome.hover.frame)),
                "the hover chip is attached to the hovered element's top-left edge: \(overlay.chrome.hover.frame) \(hoverBox)")
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

        // A sidebar: rows of 32 pt stacked edge to edge, as Finder's. The hover chip sits over the row above the hovered one, and only
        // the strip below the element holds the hover: the pointer moving up a row picks the row it is over.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        let rowHeight = 32 * overlay.scale
        let sidebar = (0..<5).map { Candidate(id: "ax-row-\($0)", label: "Row", bounds: CGRect(x: aim.x - 80 * overlay.scale, y: aim.y - 80 * overlay.scale + CGFloat($0) * rowHeight,
                                                                                            width: 160 * overlay.scale, height: rowHeight), score: AccessibilityBounds.baseScore, kind: .element) }
        overlay.merge(sidebar)
        mouse(.mouseMoved, CGPoint(x: sidebar[3].bounds.midX, y: sidebar[3].bounds.midY))
        require(overlay.view.overlays.hover == sidebar[3].bounds, "the lower sidebar row is hovered")
        var travel = CGPoint(x: sidebar[3].bounds.midX, y: sidebar[3].bounds.midY)
        while travel.y > sidebar[2].bounds.midY {
            travel.y -= overlay.scale
            mouse(.mouseMoved, travel)
        }
        require(overlay.view.overlays.hover == sidebar[2].bounds, "moving up a row hovers the row above, not the chip's row: \(String(describing: overlay.view.overlays.hover)) at \(travel)")

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
        // Right and Left cycle through peers in reading order and wrap: Right all the way around returns to the start, and Left undoes a Right.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, aim)
        let start = overlay.view.overlays.hover
        var seen: [CGRect?] = []
        for _ in 0..<overlay.session!.candidates.count + 1 {
            key(right, "")
            seen.append(overlay.view.overlays.hover)
        }
        require(start != nil && seen.dropLast().contains { $0 != start } && seen.contains { $0 == start }, "Right walks the peers and wraps back to the first: \(String(describing: start)) \(seen)")
        key(right, "")
        let ahead = overlay.view.overlays.hover
        key(left, "")
        require(overlay.view.overlays.hover == seen.last! && ahead != seen.last!, "Left steps back one peer: \(String(describing: ahead)) \(String(describing: overlay.view.overlays.hover))")
        overlay.dismiss()

        // Dim = not part of the target: with nothing targeted (just opened, or the pointer on a blank stretch of page with no window) the
        // whole screen dims evenly; a hovered element cuts it out; the full display walked out to and Text mode dim nothing.
        open()
        let dimBox = { overlay.view.dimLayer.path?.boundingBox ?? .null }
        let openedDim = (overlay.view.overlays.dimsAll, dimBox())
        await overlay.detectionTask?.value
        mouse(.mouseMoved, CGPoint(x: 2450, y: 1500))
        require(dimBox() == .null, "before the windows arrive, a hover leaves the screen undimmed: \(dimBox())")
        overlay.setWindows([], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 2450, y: 1500))
        let blankDim = (overlay.view.overlays.hover, dimBox())
        require(openedDim.0 == false && openedDim.1 == .null && blankDim.0 == nil && blankDim.1 == overlay.view.bounds,
                "the first frame has no dim, and once nothing is targeted the dim covers the whole screen: on open \(openedDim), on a blank stretch \(blankDim)")
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, aim)
        require(overlay.view.overlays.hover != nil && !overlay.view.overlays.dimsAll && overlay.view.dimLayer.fillRule == .evenOdd && dimBox() == overlay.view.bounds,
                "a hovered element cuts an even-odd hole in the dim")
        for _ in 0..<20 where overlay.session!.selected!.kind != .display { key(up, "") }
        let fullChips = [overlay.chrome.hover, overlay.chrome.snapTag, overlay.chrome.strip]
        require(overlay.view.overlays.hover == extent && overlay.view.dimLayer.path?.isEmpty != false && texts(in: overlay.chrome.hover).first == "Full screen"
                    && fullChips.allSatisfy { !$0.isHidden && overlay.view.bounds.contains($0.frame) && !$0.frame.intersects(overlay.chrome.topBar.frame) },
                "the full display walked out to dims nothing, and its chips and strip sit on screen clear of the top bar: \(fullChips.map(\.frame))")
        key(17, "t")
        require(overlay.mode == .text && overlay.view.dimLayer.path?.isEmpty != false, "Text mode dims nothing")
        key(0, "a")
        overlay.dismiss()

        // Left and Right step to the next or previous peer, wrapping at the ends. On the page the First name and Last name fields are
        // accessibility elements, as live; pixel geometry sees their row as one region, their parent. Right from Last name wraps to
        // First name: the cart panel lies to the right but has another parent.
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        let firstName = Candidate(id: "ax-first-name", label: "Text Field", bounds: CGRect(x: 346, y: 454, width: 590, height: 72), score: AccessibilityBounds.baseScore, kind: .element)
        let lastName = Candidate(id: "ax-last-name", label: "Text Field", bounds: CGRect(x: 968, y: 454, width: 592, height: 72), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.merge([firstName, lastName])
        mouse(.mouseMoved, CGPoint(x: 640, y: 489))
        var beside = [overlay.view.overlays.hover]
        for code: UInt16 in [124, 123, 124, 124] {
            key(code, "")
            beside.append(overlay.view.overlays.hover)
        }
        require(beside == [firstName.bounds, lastName.bounds, firstName.bounds, lastName.bounds, firstName.bounds],
                "Right steps from First name to Last name, Left back, and Right on Last name wraps to First name: \(beside)")
        mouse(.mouseMoved, CGPoint(x: 660, y: 489))
        require(overlay.view.overlays.hover == firstName.bounds && !overlay.session!.isLocked, "moving the pointer lets go of the picked element")
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
        let top = chrome.topBar
        /// The key caps under `view` whose glyph is `text`.
        func keyCaps(_ text: String, in view: NSView) -> [KeyCap] {
            ((view as? KeyCap).map { cap in cap.text == text ? [cap] : [] } ?? []) + view.subviews.flatMap { keyCaps(text, in: $0) }
        }
        func viewPixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * overlay.scale, y: (overlay.view.bounds.height - point.y) * overlay.scale) }
        func centerOf(_ view: NSView) -> CGPoint { view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: overlay.view) }
        /// Visible chrome drawn at less than full opacity, other than a disabled button.
        func faded(_ view: NSView) -> [String] {
            guard !view.isHidden else { return [] }
            return (view.alphaValue < 1 && (view as? BarButton)?.isEnabled != false ? ["\(type(of: view)) \(texts(in: view))"] : []) + view.subviews.flatMap(faded)
        }
        require(texts(in: top) == ["Capture", "A", "Text", "T", "Loupe", "L", "Rulers", "R", "Crosshair", "X", "Rounded", "O", "Frame", "M"]
                    && top.groups.count == 3 && zip(top.groups, top.groups.dropFirst()).allSatisfy { abs($1.frame.minX - $0.frame.maxX - 8) < 0.01 },
                "the top bar is three pills 8 pt apart, the modes, view, and style, with key caps: \(texts(in: top))")
        require(top.frame.maxY == overlay.view.bounds.height - overlay.topInset - 8 && abs(top.frame.midX - overlay.view.bounds.midX) <= 0.5 && chrome.hints.frame.minY == 32,
                "the top bar sits centered under the top edge and the keys line at the bottom: \(top.frame) \(chrome.hints.frame)")
        let barButtons = [chrome.modeButtons[.capture]!, chrome.modeButtons[.text]!] + (chrome.viewToggles + chrome.styleToggles).map(\.1)
        func clipped() -> [String] {
            barButtons.filter { $0.title.cell!.cellSize.width > $0.title.frame.width || $0.title.frame.maxX > $0.frame.width }.map { $0.title.stringValue }
        }
        let frameButton = chrome.styleToggles[1].1
        for framed in [false, true] {
            for mode in [OverlayController.Mode.capture, .text] {
                defaults.set(framed, forKey: Pref.frame)
                chrome.modeButtons[mode]!.onClick()
                overlay.refresh()
                require(clipped().isEmpty && abs(frameButton.cap!.frame.minX - frameButton.title.frame.maxX - 7) < 0.01 && abs(frameButton.bounds.maxX - frameButton.cap!.frame.maxX - 7) < 0.01,
                        "no bar title clips and the Frame button hugs its cap with Frame \(framed) and \(mode) selected: \(clipped()) \(frameButton.frame)")
                require(chrome.modeButtons[mode]!.primary && top.groups.count == (mode == .text ? 2 : 3), "the current mode is primary, and Text hides the style pill")
            }
        }
        defaults.set(false, forKey: Pref.frame)
        chrome.modeButtons[.capture]!.onClick()
        overlay.refresh()
        require(barButtons.allSatisfy { $0.cap!.frame.minX >= $0.title.frame.maxX }, "every bar button shows its key cap after its title")
        // Toggles are plain or lit (a tint wash), never faded.
        let rounded = chrome.styleToggles[0].1
        defaults.set(false, forKey: Pref.roundCorners)
        overlay.refresh()
        require(!rounded.lit && rounded.layer!.backgroundColor == nil && rounded.alphaValue == 1, "with Rounded off its button is plain")
        rounded.onClick()
        require(defaults.bool(forKey: Pref.roundCorners) && rounded.lit && rounded.layer!.backgroundColor != nil, "the Rounded button turns rounded corners on and lights")
        rounded.onClick()
        require(!defaults.bool(forKey: Pref.roundCorners), "the Rounded button turns rounded corners off")
        defaults.set(true, forKey: Pref.roundCorners)
        require(!defaults.bool(forKey: Pref.frame) && !frameButton.lit, "Frame defaults to off and its button is plain")
        key(46, "m")
        require(defaults.bool(forKey: Pref.frame) && frameButton.lit, "M turns Frame on and the Frame button lights")
        frameButton.onClick()
        require(!defaults.bool(forKey: Pref.frame) && !frameButton.lit, "the Frame button turns Frame off")
        key(2, "d")
        require(!defaults.bool(forKey: Pref.frame) && !frameButton.lit && chrome.styleToggles.count == 2, "D does nothing and there is no Shadow button")
        let window = CGRect(x: 300, y: 300, width: 400, height: 200)
        overlay.setWindows([window], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        defaults.set(false, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        let windowBox = overlay.view.viewRect(window)
        require(texts(in: chrome.hover) == ["Browser", "400 x 200"] && chrome.snap.isHidden,
                "hovering a window shows the chip row: its title and size (a frozen run crops windows, so no shadow), and no Snap chip: \(texts(in: chrome.hover))")
        require(chrome.hover.frame.minX == windowBox.minX && chrome.hover.frame.minY == windowBox.maxY + 8, "the chip row sits on the hovered box's top-left edge: \(chrome.hover.frame) \(windowBox)")
        // The Snap tag: label tier, lit with Snap on, 16 pt below and right of the pointer, plain with Snap off, and clicks pass through it.
        let tag = chrome.snapTag, pointerView = CGPoint(x: overlay.pointer.x / overlay.scale, y: overlay.view.bounds.height - overlay.pointer.y / overlay.scale)
        require(!tag.isHidden && texts(in: tag) == ["Snap", "S"] && tag.lit && tag.frame.height == Chrome.labelHeight
                    && tag.frame.minX == pointerView.x + 16 && tag.frame.maxY == pointerView.y - 16,
                "hover shows the Snap tag, lit, label height, 16 pt below and right of the pointer: \(tag.frame) \(pointerView)")
        require(overlay.view.hitTest(centerOf(tag)) !== tag, "clicks pass through the Snap tag")
        key(1, "s")
        require(!tag.lit && !defaults.bool(forKey: Pref.snap), "S turns the tag plain")
        key(1, "s")
        require(tag.lit, "S turns the tag lit again")
        mouse(.mouseMoved, CGPoint(x: extent.width - 2, y: extent.height - 2))
        require(overlay.view.bounds.contains(tag.frame), "at the screen corner the Snap tag is clamped into the view: \(tag.frame)")
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        let captureStrip = ["Copy", "\u{21A9}", "Save", "\u{2318}S", "Text", "\u{21E7}\u{21A9}", "Scroll", "G", "Record", "V", "Subject", "K"]
        let offline = captureStrip.filter { !["Scroll", "G", "Record", "V"].contains($0) }
        require(texts(in: chrome.strip) == ["Edit", "E"] + offline && chrome.strip.groups.count == 3 && chrome.copy.primary && !chrome.edit.primary && !chrome.edit.lit
                    && chrome.edit.superview === chrome.strip.groups[0] && chrome.strip.frame.maxY == windowBox.minY - 8 && chrome.strip.frame.minX == windowBox.minX,
                "the action strip hangs under the hovered box: Edit in its own pill, then Copy, Save, Text, then Subject (no live display, so no Scroll or Record): \(texts(in: chrome.strip)) \(chrome.strip.frame) \(windowBox)")
        require(chrome.all.flatMap(faded).isEmpty, "nothing else in the chrome is faded: \(chrome.all.flatMap(faded))")
        // The Edit button does what E does: it opens the hovered window as a selection and leaves the strip, and Esc goes back to the hover.
        chrome.edit.onClick()
        require(overlay.selection?.rect == window && !texts(in: chrome.strip).contains("Edit"), "clicking Edit opens the hovered window as a selection, with no Edit in the strip: \(String(describing: overlay.selection?.rect))")
        key(53, "")
        require(overlay.selection == nil && texts(in: chrome.strip).first == "Edit", "Esc goes back to the hover and its Edit button: \(texts(in: chrome.strip))")
        // The hover holds while the pointer crosses from the element to its strip, so a click reaches Copy; the loupe and crosshair still
        // follow the pointer.
        defaults.set(true, forKey: Pref.loupe)
        defaults.set(true, forKey: Pref.crosshair)
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(!readout.isHidden && tag.frame.maxY == readout.frame.minY - 6 && abs(tag.frame.midX - readout.frame.midX) <= 1,
                "with the loupe showing, the Snap tag sits under its readout: \(tag.frame) \(readout.frame)")
        mouse(.mouseMoved, viewPixel(CGPoint(x: centerOf(chrome.copy).x, y: windowBox.minY - 4)))
        let heldLoupe = overlay.view.guides.loupe.position, heldCrosshair = overlay.view.guides.crosshair.path
        mouse(.mouseMoved, viewPixel(centerOf(chrome.copy)))
        require(overlay.view.overlays.hover == window && overlay.view.hitTest(centerOf(chrome.copy)) === chrome.copy,
                "the hover holds on the way to the strip and a click reaches Copy: \(String(describing: overlay.view.overlays.hover))")
        require(overlay.view.guides.loupe.position != heldLoupe && overlay.view.guides.crosshair.path != heldCrosshair,
                "while the hover holds, the loupe and crosshair follow the pointer")
        defaults.set(false, forKey: Pref.loupe)
        defaults.set(false, forKey: Pref.crosshair)
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        // Frame adds its padding to the hover size, from the output code: 24 pt all round.
        defaults.set(true, forKey: Pref.frame)
        overlay.refresh()
        let framePad = Int(2 * OutputFrame.points * overlay.scale)
        require(texts(in: chrome.hover)[1] == "400 x 200  + frame \(framePad) x \(framePad)", "Frame on adds its padding to the hover size: \(texts(in: chrome.hover))")
        defaults.set(false, forKey: Pref.frame)
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(chrome.hover.isHidden && chrome.strip.isHidden && !tag.isHidden, "the chip row and strip go away off the window, and the Snap tag stays with the pointer")
        require(texts(in: chrome.hints) == ["bigger / smaller", "\u{2191}", "\u{2193}", "next", "\u{2190}", "\u{2192}", "full screen", "F", "window", "W", "all keys", "?"],
                "the hover keys line has no click capture and names W window after F full screen: \(texts(in: chrome.hints))")
        mouse(.leftMouseDown, rough.origin)
        mouse(.leftMouseDragged, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        require(!chrome.size.isHidden && chrome.snap.isHidden && tag.isHidden && chrome.strip.isHidden && texts(in: chrome.size).last!.hasSuffix("Exact"), "a drag shows the size chip, Exact before a preview, and no Snap chip, tag or strip: \(texts(in: chrome.size))")
        for _ in 0..<9000 where overlay.snapPreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        let fit = overlay.snapPreview!
        require(texts(in: chrome.size) == ["\(Int(fit.width)) x \(Int(fit.height))  Snapped"], "a snap preview shows its size and Snapped: \(texts(in: chrome.size))")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.snap) == ["Snapped", "S"] && chrome.snap.lit, "after release on a fit: Snapped, lit")
        require(!top.isHidden && texts(in: chrome.strip) == offline + ["Colors", "U"] && texts(in: chrome.hints)
                    == ["move", "\u{2190}\u{2192}", "grow", "\u{2325}", "shrink", "\u{2325}\u{2318}", "edge out", "\u{2318}", "edge in", "\u{2318}\u{21E7}", "all sides", "+", "-", "undo", "\u{2318}Z"],
                "a selection keeps the top bar, has the strip without Edit, and the arrow layers on the keys line: \(texts(in: chrome.hints))")
        require(chrome.hints.frame.height < 40 && chrome.hints.frame.width <= overlay.view.bounds.width - 16, "the keys line is one line and fits: \(chrome.hints.frame) in \(overlay.view.bounds.width)")
        // The chip row: size and Snap from the selection's left edge, the ratio and radius ending at its right edge (after Snap when they
        // would meet). The ratio chip's readout with P opens the ratio menu, the lock with Shift-P toggles the lock, with no fills of their own.
        let lockedBefore = overlay.ratioLocked, rectBefore = overlay.selection!.rect
        let roughBox = overlay.view.viewRect(overlay.selection!.rect)
        let row = [chrome.size, chrome.snap, chrome.ratio, chrome.radius]
        require(row.allSatisfy { !$0.isHidden && $0.frame.minY == chrome.size.frame.minY } && chrome.size.frame.minX == roughBox.minX && chrome.size.frame.minY == roughBox.maxY + 8
                    && zip(row, row.dropFirst()).allSatisfy { $1.frame.minX >= $0.frame.maxX + 5.99 } && chrome.radius.frame.maxX >= roughBox.maxX - 0.5,
                "the chip row sits on the selection's top edge: \(row.map(\.frame)) \(roughBox)")
        require(texts(in: chrome.ratio) == [overlay.ratioReadout, "P", "|", "lock", "\u{21E7}P"] && chrome.lock.lit == lockedBefore
                    && chrome.ratioButton.layer!.backgroundColor == nil && chrome.lock.layer!.backgroundColor == nil,
                "the ratio chip shows the readout with P, then lock with Shift-P, with no fill of their own: \(texts(in: chrome.ratio))")
        require(texts(in: chrome.radius).count == 3 && texts(in: chrome.radius)[0].hasPrefix("r ") && texts(in: chrome.radius).suffix(2) == ["[", "]"],
                "the radius chip shows the live radius and its keys: \(texts(in: chrome.radius))")
        for button in [chrome.ratioButton, chrome.lock] {
            require(overlay.view.hitTest(centerOf(button)) === button, "a click on the ratio chip's \(texts(in: button)) reaches it")
        }
        chrome.lock.onClick()
        require(overlay.ratioLocked != lockedBefore && overlay.selection!.rect == rectBefore && chrome.lock.lit != lockedBefore && chrome.lock.layer!.backgroundColor == nil,
                "clicking the lock toggles the lock, keeps the selection, and lights the lock with no fill of its own")
        chrome.lock.onClick()
        require(overlay.ratioLocked == lockedBefore && overlay.selection!.rect == rectBefore, "clicking the lock again puts it back")
        // The ratio menu: a panel under the ratio segment, left edges aligned, taking the keys and the pointer while open.
        let menu = chrome.ratioMenu, beforeMenu = overlay.selection!
        func rowCenter(_ title: String) -> CGPoint {
            let row = menu.rows[menu.items.firstIndex { $0.title == title }!]
            return row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: overlay.view)
        }
        chrome.ratioButton.onClick()
        let segment = chrome.ratio.convert(chrome.ratioButton.frame, to: overlay.view)
        require(!menu.isHidden && overlay.window.firstResponder === menu && menu.panel.frame.minX == segment.minX && menu.panel.frame.maxY <= segment.minY,
                "clicking the readout opens the ratio panel under the ratio segment, left edges aligned: \(menu.panel.frame) \(segment)")
        require(texts(in: chrome.hints) == ["pick", "\u{2191}", "\u{2193}", "choose", "\u{21A9}", "close", "esc"], "the keys line names the menu's keys: \(texts(in: chrome.hints))")
        require(menu.items.map(\.title) == ["Free", "Original", "1:1", "4:3", "3:2", "16:10", "16:9", "21:9", "", "Portrait"] && menu.items.filter(\.on).map(\.title) == (overlay.ratioLocked ? [] : ["Free"]),
                "the panel lists the presets and checks Free while unlocked: \(menu.items.map(\.title))")
        key(53, "\u{1B}")
        require(menu.isHidden && overlay.window.isVisible && overlay.selection?.rect == rectBefore && overlay.window.firstResponder === overlay.view && texts(in: chrome.hints).first == "move",
                "Esc closes the panel and leaves the selection, the overlay, and the selection's keys line")
        key(35, "p")
        key(down, "")
        let downCaps = chrome.hints.subviews.flatMap(\.subviews).compactMap { $0 as? KeyCap }.filter(\.pressed).map(\.text)
        require(chrome.pressed == ["\u{2193}"] && downCaps == ["\u{2193}"], "Down in the ratio menu flashes the keys line's Down cap: \(chrome.pressed) \(downCaps)")
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
        require(overlay.selection?.rect == rectBefore && texts(in: chrome.snap) == ["Snapped", "S"], "the snapped selection is back for the next checks")
        chrome.snap.onClick()
        require(!defaults.bool(forKey: Pref.snap) && texts(in: chrome.snap) == ["Exact", "S"] && !chrome.snap.lit, "clicking the Snap chip turns snap off: Exact, plain")
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap) && chrome.snap.lit, "S turns snap back on and the Snap chip follows")
        func flags(_ modifiers: NSEvent.ModifierFlags) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        }
        // The edge keys: the side arrows and the legend show while the pointer rests inside the selection or a modifier is held; the
        // legend and the lit cap on the keys line follow the modifiers.
        let insideSelection = CGPoint(x: overlay.selection!.rect.midX, y: overlay.selection!.rect.midY)
        let sides = chrome.sideHints
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "with the pointer outside the selection no edge keys show")
        mouse(.mouseMoved, insideSelection)
        require(sides.map { texts(in: $0) } == [["\u{2190}"], ["\u{2192}"], ["\u{2191}"], ["\u{2193}"]] && sides.allSatisfy { !$0.isHidden } && texts(in: chrome.legend) == ["move"],
                "with the pointer inside the selection the side arrows show and the legend reads move: \(sides.map(\.isHidden)) \(texts(in: chrome.legend))")
        key(124, "")
        require(keyCaps("\u{2192}", in: sides[1]).allSatisfy(\.pressed) && keyCaps("\u{2190}", in: sides[0]).allSatisfy { !$0.pressed }, "the Right arrow cap flashes when Right is pressed")
        key(123, "")
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "moving the pointer out of the selection hides the edge keys")
        let selected = overlay.view.viewRect(overlay.selection!.rect)
        require(keyCaps("\u{2325}", in: chrome.hints).allSatisfy { !$0.pressed }, "without Option the Option cap is idle")
        flags(.option)
        require(keyCaps("\u{2325}", in: chrome.hints).count == 1 && keyCaps("\u{2325}", in: chrome.hints).allSatisfy(\.pressed) && keyCaps("\u{2325}\u{2318}", in: chrome.hints).allSatisfy { !$0.pressed }
                    && texts(in: chrome.legend) == ["\u{2325} grow"],
                "holding Option lights the Option cap and the legend reads grow: \(texts(in: chrome.legend))")
        require(sides.allSatisfy { !$0.isHidden } && sides[0].frame.maxX <= selected.minX && sides[1].frame.minX >= selected.maxX && sides[2].frame.minY >= selected.maxY
                    && abs(sides[0].frame.midY - selected.midY) < 1 && abs(sides[2].frame.midX - selected.midX) < 1 && !sides[3].frame.intersects(chrome.strip.frame),
                "holding Option puts an arrow cap outside each side's midpoint, clear of the strip: \(sides.map(\.frame)) \(selected)")
        flags([.option, .command])
        require(keyCaps("\u{2325}\u{2318}", in: chrome.hints).allSatisfy(\.pressed) && keyCaps("\u{2325}", in: chrome.hints).allSatisfy { !$0.pressed }
                    && texts(in: chrome.legend) == ["\u{2325}\u{2318} shrink"] && sides.allSatisfy { !$0.isHidden },
                "holding Option-Command lights the Option-Command cap, the legend reads shrink, and the side arrows stay: \(texts(in: chrome.legend))")
        flags(.command)
        require(keyCaps("\u{2318}", in: chrome.hints).allSatisfy(\.pressed) && texts(in: chrome.legend) == ["\u{2318} edge out  \u{2318}\u{21E7} edge in"] && sides.allSatisfy { !$0.isHidden },
                "holding Command: the legend reads both edge directions: \(texts(in: chrome.legend))")
        flags([.command, .shift])
        require(keyCaps("\u{2318}\u{21E7}", in: chrome.hints).allSatisfy(\.pressed) && keyCaps("\u{2318}\u{21E7}", in: chrome.hints).count == 1
                    && texts(in: chrome.legend) == ["\u{2318} edge out  \u{2318}\u{21E7} edge in"],
                "holding Command-Shift lights the edge-in cap: \(texts(in: chrome.legend))")
        flags(.shift)
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "Shift alone with the pointer outside shows no edge keys")
        flags([])
        let snapped = overlay.selection!
        key(48, "\t")
        require(overlay.selection?.rect == snapped.rect, "Tab on a released selection does nothing")
        overlay.editedRadii[snapped.rect] = CornerRadii(12 * overlay.scale)
        mouse(.mouseMoved, overlay.cornerRadii(of: snapped.rect).dot(of: .topLeft, in: snapped.rect, minimumInset: 8 * overlay.scale))
        let cornerKeys = chrome.cornerKeys, cornerChip = overlay.cornerChip
        require(!cornerChip.isHidden && texts(in: cornerKeys) == ["radius", "[", "]", "one corner", "\u{2325}"]
                && cornerKeys.frame.maxY <= cornerChip.frame.minY && abs(cornerKeys.frame.maxX - cornerChip.frame.maxX) < 0.5,
                "hovering a corner dot shows radius [ ] and Option for one corner under the All corners chip: \(texts(in: cornerKeys)) \(cornerKeys.frame) \(cornerChip.frame)")
        flags(.option)
        require(keyCaps("\u{2325}", in: cornerKeys).allSatisfy(\.pressed) && !keyCaps("\u{2325}", in: cornerKeys).isEmpty, "holding Option lights the in-place Option cap by the corner")
        flags([])
        mouse(.mouseMoved, CGPoint(x: snapped.rect.midX, y: snapped.rect.midY))
        require(cornerKeys.isHidden, "leaving the corner dot hides its keys")
        let released = overlay.view.viewRect(overlay.selection!.rect)
        require(chrome.strip.frame.maxY == released.minY - 8 && chrome.strip.frame.minX == min(max(released.minX, 8), overlay.view.bounds.width - chrome.strip.frame.width - 8),
                "the strip hangs under the selection: \(chrome.strip.frame) \(released)")
        require(chrome.size.frame.minY == released.maxY + 8, "the size chip sits above the selection")
        frameButton.onClick()
        require(overlay.framed && frameButton.lit, "clicking the top bar's Frame turns Frame on and lights it")
        key(46, "m")
        require(!overlay.framed && !frameButton.lit, "M turns Frame off on a released selection")
        key(53, "")
        require(overlay.window.isVisible && overlay.selection == nil && chrome.ratio.isHidden, "the first Esc drops the selection back to hover")
        key(53, "")
        require(chrome.strip.isHidden && chrome.size.isHidden && chrome.snap.isHidden && chrome.ratio.isHidden, "a second Esc takes the strip and chips away")

        // The strip's Text button runs Shift-Return, queued here behind a warm-up that never ends so no text recognition runs. The chips
        // and strip anchor to the selection's edges: a new radius moves none of them.
        open()
        let large = CGRect(x: 600, y: 300, width: 1000, height: 600)
        overlay.selection = AreaSelection(extent: extent, exact: large)
        overlay.editedRadii[large] = CornerRadii(40 * overlay.scale)
        overlay.refresh()
        require(texts(in: chrome.radius) == ["r 40", "[", "]"], "the radius chip reads the selection's radius: \(texts(in: chrome.radius))")
        let anchored = [chrome.size, chrome.snap, chrome.strip].map(\.frame.origin) + [CGPoint(x: chrome.radius.frame.maxX, y: chrome.radius.frame.minY)]
        overlay.editedRadii[large] = CornerRadii(120 * overlay.scale)
        overlay.refresh()
        require(texts(in: chrome.radius).first == "r 120"
                    && [chrome.size, chrome.snap, chrome.strip].map(\.frame.origin) + [CGPoint(x: chrome.radius.frame.maxX, y: chrome.radius.frame.minY)] == anchored,
                "a new radius moves no chip and not the strip: \(anchored)")
        overlay.editedRadii[large] = CornerRadii(40 * overlay.scale)
        overlay.refresh()
        OverlayController.visionWarmUp = Task { try? await Task.sleep(for: .seconds(3600)) }
        mouse(.leftMouseDown, viewPixel(centerOf(chrome.text)))
        mouse(.leftMouseUp, viewPixel(centerOf(chrome.text)))
        require(overlay.text.queued?.notice.hasPrefix("Shift-Return") == true, "clicking the strip's Text runs Shift-Return: \(String(describing: overlay.text.queued?.notice))")
        overlay.text.queued = nil
        OverlayController.visionWarmUp!.cancel()
        await OverlayController.visionWarmUp!.value
        await overlay.textTask?.value
        OverlayController.visionWarmUp = nil
        overlay.text.notice = nil

        // A hovered element's radius: `]` adds the radius chip to the hover's chip row, uncovered.
        overlay.dismiss()
        open()
        overlay.setWindows([window], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.radii[window] = 0
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(chrome.radius.isHidden, "a hover with its measured radius shows no radius chip")
        key(30, "]")
        let hoverChips = [chrome.hover, chrome.snapTag, chrome.radius]
        let covering = overlay.view.subviews.filter { view in !view.isHidden && !hoverChips.contains(view) && hoverChips.contains { $0.frame.intersects(view.frame) } && view !== overlay.view.liveText }
        require(texts(in: chrome.radius) == ["r 1", "[", "]"] && chrome.radius.frame.minY == chrome.hover.frame.minY && covering.isEmpty,
                "] on a hovered element shows its radius in the chip row, uncovered: \(texts(in: chrome.radius)) covered by \(covering.map { "\(type(of: $0)) \($0.frame)" })")

        // Released chrome never overlaps or leaves the screen: a large and a small selection, one at each screen edge, and the full
        // screen with a 38 pt inset, each with the pointer inside so the edge keys show.
        overlay.dismiss()
        open()
        let edgeCases = [("large", large), ("small", CGRect(x: 600, y: 300, width: 120, height: 80)), ("left", CGRect(x: 0, y: 600, width: 500, height: 300)),
                         ("right", CGRect(x: extent.width - 500, y: 600, width: 500, height: 300)), ("top", CGRect(x: 900, y: 0, width: 700, height: 300)),
                         ("bottom", CGRect(x: 900, y: extent.height - 300, width: 700, height: 300)), ("full", extent)]
        for (name, rect) in edgeCases {
            overlay.topInset = name == "full" ? 38 : 0
            overlay.selection = AreaSelection(extent: extent, exact: rect)
            overlay.refresh()
            mouse(.mouseMoved, CGPoint(x: 40, y: 40))
            mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
            let pieces: [(String, NSView)] = [("hints", chrome.hints), ("top bar", chrome.topBar), ("strip", chrome.strip), ("size", chrome.size), ("snap", chrome.snap),
                                               ("ratio", chrome.ratio), ("radius", chrome.radius), ("legend", chrome.legend)]
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
        require(!chrome.ratio.isHidden && chrome.record.isEnabled && chrome.sideHints.allSatisfy { !$0.isHidden }, "before arming, the editing chrome shows and Record is enabled")
        key(9, "v")
        require(overlay.armedRecording != nil && chrome.ratio.isHidden && chrome.radius.isHidden && chrome.snap.isHidden && chrome.legend.isHidden && chrome.sideHints.allSatisfy(\.isHidden)
                    && texts(in: chrome.strip).contains("Start"),
                "armed to record, the ratio, radius, and Snap chips and the edge keys hide, and the strip holds the armed controls")
        key(53, "\u{1B}")
        require(overlay.armedRecording == nil && texts(in: chrome.strip) == captureStrip.filter { $0 != "Scroll" && $0 != "G" } + ["Colors", "U"] && !chrome.ratio.isHidden, "Esc disarms and brings the editing chrome back: \(texts(in: chrome.strip))")
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
        overlay.editedRadii[page] = CornerRadii(24 * overlay.scale)
        key(5, "g")
        require(overlay.scrollArea == page && overlay.selection == nil && overlay.view.image == nil && overlay.window.ignoresMouseEvents && chrome.topBar.isHidden,
                "G starts scrolling capture: the frozen image goes away, the top bar hides, and the pointer reaches the app below")
        for _ in 0..<3000 where overlay.scrollHeight < 900 { try await Task.sleep(for: .milliseconds(10)) }
        let pageBox = overlay.view.viewRect(page)
        require(overlay.scrollHeight == 900 && texts(in: chrome.strip) == ["Scrolling 900 px", "Cancel", "esc", "Done", "\u{21A9}"] && chrome.done.primary
                    && chrome.strip.frame.maxY == pageBox.minY - 8 && texts(in: chrome.hints) == ["Scroll the app under the outline"],
                "frames stitch as the area scrolls, and the strip under the area counts the height: \(overlay.scrollHeight) \(texts(in: chrome.strip)) \(texts(in: chrome.hints))")
        offsets = [200]
        for _ in 0..<3000 where overlay.scrollHeight > 800 { try await Task.sleep(for: .milliseconds(10)) }
        require(overlay.scrollHeight == 800 && texts(in: chrome.strip).first == "Scrolling 800 px",
                "scrolling back up trims the end to the bottom of the view, and the count follows: \(overlay.scrollHeight) \(texts(in: chrome.strip))")
        offsets = [300]
        for _ in 0..<3000 where overlay.scrollHeight < 900 { try await Task.sleep(for: .milliseconds(10)) }
        require(overlay.scrollHeight == 900, "scrolling down again adds the end back: \(overlay.scrollHeight)")
        key(5, "g")
        require(overlay.scrollArea == page, "other keys do nothing while scrolling")
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        let stitched = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(!overlay.window.isVisible && stitched.pixelsWide == 1000 && stitched.pixelsHigh == 900 && overlay.window.isOpaque,
                "Return copies the stitched image and closes: \(stitched.pixelsWide) x \(stitched.pixelsHigh)")
        let corners = [(0, 0), (999, 0), (0, 899), (999, 899)].map { stitched.colorAt(x: $0.0, y: $0.1)!.alphaComponent }
        require(corners.allSatisfy { $0 == 0 } && stitched.colorAt(x: 500, y: 0)!.alphaComponent == 1 && stitched.colorAt(x: 500, y: 899)!.alphaComponent == 1,
                "the stitched image takes the area's corner radii: corner alphas \(corners)")
        // G on a hovered element starts scrolling capture of it, as E then G does.
        offsets = [0]
        open()
        let browser = CGRect(x: 100, y: 100, width: 1500, height: 1200)
        overlay.setWindows([browser], names: ["Browser"], pointer: CGPoint(x: frame.minX + 800 / overlay.scale, y: frame.maxY - 700 / overlay.scale))
        let hoveredArea = overlay.hoverRect
        require(hoveredArea != nil && overlay.selection == nil, "a window is hovered with no selection")
        key(5, "g")
        require(overlay.scrollArea == hoveredArea && overlay.selection == nil && overlay.window.ignoresMouseEvents, "G while hovering starts scrolling capture of the hovered rectangle: \(String(describing: overlay.scrollArea))")
        key(53, "")
        offsets = [0]
        open()
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.selection = AreaSelection(extent: extent, exact: page)
        overlay.refresh()
        chrome.scroll.onClick()
        require(overlay.scrollArea == page, "the strip's Scroll starts scrolling capture as G does")
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

        // The top bar and the keys line move to the other edge when a drag or selection reaches them there and not there, and come
        // back; the pointer and the hover never move them, so their buttons stay within reach.
        open()
        overlay.detectionTask?.cancel()
        let halfHeight = overlay.view.bounds.height / 2
        let keysLine2 = chrome.hints
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.midY))
        require(top.frame.minY > halfHeight && keysLine2.frame.maxY < halfHeight && !chrome.barAtBottom && !chrome.hintsAtTop, "the top bar sits at the top and the keys line at the bottom")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(keysLine2.frame.maxY < halfHeight && !chrome.hintsAtTop, "the pointer near the keys line leaves it there")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: 20))
        require(top.frame.minY > halfHeight && !chrome.barAtBottom, "the pointer near the top bar leaves it there")
        overlay.setWindows([CGRect(x: 600, y: extent.height - 420, width: 1200, height: 410)], names: ["Low window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 700, y: extent.height - 400))
        require(!chrome.hover.isHidden && !chrome.hintsAtTop, "a hovered window that reaches the keys line leaves it there")
        let low = CGRect(x: 800, y: extent.height - 300, width: 600, height: 290)
        mouse(.leftMouseDown, low.origin)
        mouse(.leftMouseDragged, CGPoint(x: low.maxX, y: low.maxY))
        require(chrome.hintsAtTop && keysLine2.frame.maxY == top.frame.minY - 8, "a drag that reaches the keys line moves it to the top, under the top bar: \(keysLine2.frame) \(top.frame)")
        mouse(.leftMouseUp, CGPoint(x: low.maxX, y: low.maxY))
        let lowBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.strip.isHidden && chrome.strip.frame.minY == lowBox.maxY + 8 && keysLine2.frame.minY > halfHeight,
                "a released selection at the bottom puts the strip above it and the keys line at the top: \(chrome.strip.frame) \(lowBox)")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(chrome.hintsAtTop, "the pointer at the bottom does not pull the keys line back down")
        key(53, "")
        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 800, y: 0, width: 600, height: 290))
        overlay.refresh()
        require(chrome.barAtBottom && top.frame.maxY < halfHeight && top.frame.minY == keysLine2.frame.maxY + 8,
                "a selection at the top moves the top bar to the bottom, above the keys line: \(top.frame) \(keysLine2.frame)")
        key(53, "")
        open()
        drag(rough)
        require(!chrome.strip.isHidden && keysLine2.frame.maxY < halfHeight && top.frame.minY > halfHeight, "a selection mid-screen keeps both bars home")
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
        require(!chrome.size.isHidden && !chrome.hints.isHidden && !chrome.strip.isHidden && !chrome.topBar.isHidden, "the full-screen state shows the size chip, keys line, strip, and top bar")
        overlay.topInset = 0
        overlay.refresh()
        require(guides2.bands.path!.boundingBox.maxY == overlay.view.bounds.height, "without an inset the top ruler sits at the top edge")
        overlay.dismiss()
        for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }
        try await verifyRecording(image: image, frame: frame, overlay: overlay, require: require)

        // Hot keys: each handler takes only presses of its own ID (the capture shortcut and the overlay's Esc share the app's target).
        // The presses are Carbon events sent to the app, so nothing is registered system-wide.
        var fired: [UInt32] = []
        let hotKeys = [HotKey(id: 7) { fired.append(7) }, HotKey(id: 8) { fired.append(8) }]
        for id: UInt32 in [7, 8, 7] {
            var event: EventRef?
            CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
            var hotKeyID = EventHotKeyID(signature: OSType(0x534E5547), id: id)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
        }
        require(fired == [7, 8, 7] && hotKeys.count == 2, "each hot key acts on its own presses only: \(fired)")

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
