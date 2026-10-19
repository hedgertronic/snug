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
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
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
        // With Rulers on, nothing covers a ruler's band, and the settings bar stays 8 pt above the bottom edge.
        let topRuler = CGRect(x: 0, y: view.bounds.height - overlay.topInset - Guides.rulerThickness, width: view.bounds.width, height: Guides.rulerThickness)
        let leftRuler = CGRect(x: 0, y: 0, width: Guides.rulerThickness, height: view.bounds.height)
        let edgeChrome = [overlay.chrome.topBar, overlay.chrome.strip, overlay.chrome.hover, overlay.chrome.coordinates, overlay.chrome.snapTag].filter { !$0.isHidden }
        require(edgeChrome.allSatisfy { !$0.frame.intersects(topRuler) && !$0.frame.intersects(leftRuler) } && overlay.chrome.topBar.frame.minY == 8,
                "with Rulers on, the settings bar stays at the bottom and no chrome covers a ruler: \(edgeChrome.map(\.frame)) \(topRuler)")
        let controls = overlay.chrome.topBar.groups + [overlay.chrome.strip].filter { !$0.isHidden }
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
        require(!readout.isHidden && readoutCap.count == 1 && texts(in: readout).count == 3 && texts(in: readout)[0].hasPrefix("#") && texts(in: readout)[1] == "copy"
                    && readout.frame.height == Chrome.labelHeight && readout.frame.minY >= loupeBox.minY && readout.frame.maxY <= loupeBox.minY + Chrome.labelHeight && abs(readout.frame.midX - loupeBox.midX) <= 1
                    && overlay.view.bounds.contains(readout.frame),
                "the loupe's readout is a chip under the disc with the value, copy, and a C cap: \(texts(in: readout)) \(readout.frame) \(loupeBox)")
        // The pointer's pixel is a chip in the Snap tag's cluster, `[x 123  y 456] [Snap S]`: centered under the readout, clicks pass through,
        // and it follows the pointer with no animation.
        let coordinates = overlay.chrome.coordinates, snapTag = overlay.chrome.snapTag
        func passesClicks(_ chip: NSView) -> Bool {
            let hit = overlay.view.hitTest(chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: overlay.view))
            return !(hit?.isDescendant(of: chip) ?? false)
        }
        func clusterMessage() -> String { "\(texts(in: coordinates)) \(coordinates.frame) \(snapTag.frame) \(readout.frame)" }
        require(!coordinates.isHidden && texts(in: coordinates) == ["x 2061  y 1024"] && coordinates.frame.height == Chrome.labelHeight
                    && snapTag.frame.minX == coordinates.frame.maxX + Guides.clusterGap && snapTag.frame.minY == coordinates.frame.minY
                    && coordinates.frame.minY == readout.frame.minY - Guides.clusterGap - Chrome.labelHeight
                    && abs(coordinates.frame.union(snapTag.frame).midX - readout.frame.midX) <= 1 && passesClicks(coordinates),
                "the pointer cluster sits centered under the loupe's readout: \(clusterMessage())")
        mouse(.mouseMoved, CGPoint(x: text.x + 3, y: text.y + 2))
        require(texts(in: coordinates) == ["x 2064  y 1026"] && coordinates.layer!.animationKeys() == nil, "the coordinates follow the pointer, with no animation: \(clusterMessage())")
        mouse(.mouseMoved, text)
        overlay.flash(KeyCap.event(for: "C"))
        require(readoutCap[0].pressed, "C flashes the readout's C cap")
        // The swatch's ring is the chrome's swatch edge in both looks, so a white pixel reads in light mode.
        let swatchView = readout.subviews.first { $0.frame.size == CGSize(width: 12, height: 12) }!
        let readoutLook = readout.appearance
        for (name, edge) in [(NSAppearance.Name.aqua, NSColor.black.withAlphaComponent(0.3)), (.darkAqua, NSColor.white.withAlphaComponent(0.5))] {
            readout.appearance = NSAppearance(named: name)
            mouse(.mouseMoved, CGPoint(x: text.x + 1, y: text.y))
            mouse(.mouseMoved, text)
            let ring = NSColor(cgColor: swatchView.layer!.borderColor!)!.usingColorSpace(.sRGB)!, want = edge.usingColorSpace(.sRGB)!
            require(abs(ring.redComponent - want.redComponent) < 0.01 && abs(ring.alphaComponent - want.alphaComponent) < 0.01,
                    "\(name.rawValue): the loupe swatch's ring is the swatch edge: \(ring) \(want)")
        }
        readout.appearance = readoutLook
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
        // The pointer cluster hangs under the readout, so a chip there moves the loupe, and at the bottom edge the loupe keeps the cluster's
        // depth above it.
        let middlePoint = CGPoint(x: 600, y: 400)
        let freeOrigin = Guides.loupeOrigin(point: middlePoint, bounds: viewBounds, topInset: 0, scale: overlay.scale, avoiding: [])
        let clusterZone = CGRect(x: freeOrigin.x, y: freeOrigin.y - Guides.clusterDepth + 4, width: 40, height: 10)
        let movedOrigin = Guides.loupeOrigin(point: middlePoint, bounds: viewBounds, topInset: 0, scale: overlay.scale, avoiding: [clusterZone])
        require(freeOrigin.x == middlePoint.x + 10 && movedOrigin != freeOrigin,
                "a chip in the space under the readout, where the cluster hangs, moves the loupe: \(freeOrigin) \(movedOrigin) \(clusterZone)")
        require(Guides.loupeOrigin(point: CGPoint(x: 600, y: 20), bounds: viewBounds, topInset: 0, scale: overlay.scale, avoiding: []).y >= Guides.clusterDepth,
                "at the bottom edge the loupe keeps room under its readout for the cluster")

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
        for y in stride(from: barChrome.topBar.frame.maxY + 4, through: barChrome.topBar.frame.maxY + 140, by: 12) {
            mouse(.mouseMoved, CGPoint(x: barChrome.topBar.frame.midX * overlay.scale, y: (viewBounds.height - y) * overlay.scale))
            let covered = [barChrome.topBar, barChrome.strip].filter { !$0.isHidden && guides.loupe.frame.intersects($0.frame) }
            require(covered.isEmpty, "the loupe with the pointer at y \(y) covers no bar: \(guides.loupe.frame) \(covered.map(\.frame))")
        }
        // Nor over a chip: with a selection's chips showing (size, Snap, ratio, radius, and the "move" legend), a sweep of the pointer left of
        // the selection, where a free placement always exists, never puts the loupe or its readout over a visible chip.
        overlay.dismiss()
        open()
        drag(CGRect(x: 1200, y: 900, width: 500, height: 300))
        let chipRow = [barChrome.hover, barChrome.size, barChrome.snap, barChrome.ratio, barChrome.radius, barChrome.status, barChrome.reading, barChrome.legend, barChrome.colorMenu, barChrome.ratioMenu]
        require(chipRow.filter { !$0.isHidden }.count >= 3, "the selection shows its chip row: \(chipRow.filter { !$0.isHidden }.map(\.frame))")
        var swept = 0
        for y in stride(from: 500, through: 1100, by: 50) {
            for x in stride(from: 600, through: 1100, by: 100) {
                mouse(.mouseMoved, CGPoint(x: x, y: y))
                let covered = chipRow.filter { !$0.isHidden && ($0.frame.intersects(guides.loupe.frame) || $0.frame.intersects(guides.readout.frame)) }
                require(covered.isEmpty, "the loupe with the pointer at \(x), \(y) covers no chip: \(guides.loupe.frame) \(guides.readout.frame) \(covered.map { "\(chipRow.firstIndex(of: $0)!) \(texts(in: $0)) \($0.frame)" }) view \(overlay.view.bounds)")
                swept += 1
            }
        }
        require(swept > 50, "swept \(swept) pointer positions")
        // A flip near the screen's right edge (where the readout and cluster no longer fit on the right) slides: the model position follows the pointer at once, and an additive animation carries the
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
        place(CGPoint(x: viewBounds.width - Guides.readoutOverhang - 8, y: 300))
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
        require(guides.loupe.frame.minY == Guides.clusterDepth + 4 && slides().isEmpty, "a loupe pinned above the bottom edge, with room for its pointer cluster, follows the pointer without sliding: \(guides.loupe.frame) \(slides().count)")
        guides.slidesPlacement = false
        guides.loupe.removeAllAnimations()
        // Turning the loupe off (L, or V arming) hides its readout at once. The animated outro keeps the loupe layer visible for 0.18 s, and an
        // update during it, like a pointer move, must not show the readout again: it would stay frozen once the layer hides.
        require(!guides.readout.isHidden, "the readout shows with the loupe")
        guides.setShown(guides.loupe, false, from: Guides.loupeHiddenTransform, animated: true)
        require(!guides.loupe.isHidden && guides.readout.isHidden, "an animated hide starts the outro and hides the readout")
        place(CGPoint(x: 500, y: 300))
        place(CGPoint(x: 520, y: 310))
        require(!guides.loupe.isHidden && guides.readout.isHidden, "updates during the loupe's outro leave the readout hidden")
        guides.setShown(guides.loupe, true, from: Guides.loupeHiddenTransform, animated: false)
        guides.loupe.removeAllAnimations()
        require(!guides.readout.isHidden, "showing the loupe again shows the readout")
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
        require(overlay.chrome.colors.window != nil && !colors.isHidden && overlay.window.firstResponder === colors,
                "clicking the strip's Colors button opens the menu: \(texts(in: overlay.chrome.strip))")
        let button = overlay.view.convert(overlay.chrome.colors.bounds, from: overlay.chrome.colors)
        require(colors.panel.frame.minX == min(max(button.minX, 8), overlay.view.bounds.width - colors.panel.frame.width - 8) && colors.panel.frame.maxY <= button.minY,
                "the menu sits under the Colors button, left edges aligned: \(colors.panel.frame) \(button)")
        let averageText = format.string(for: ColorFormat.average(of: image, in: average))
        require(colors.items.map(\.title) == [averageText, ""] + palette && colors.items.map(\.cap) == ["1", nil, "2", "3", "4", "5", "6"] && palette.count == 5
                    && colors.items.filter { $0.swatch != nil }.count == 6,
                "the menu lists the average, a separator, and five main colors, each with a swatch and a cap: \(colors.items.map(\.title)) \(colors.items.map(\.cap))")
        require(averageText == pasteboard.string(forType: .string), "the first row is the color C copies: \(averageText)")
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

        // The ratio menu numbers its nine rows 1-9 (the separator has no cap). Each digit picks its row and closes the menu as a click does,
        // as one undo step; Cmd-Z restores the selection and the lock.
        open()
        let box = CGRect(x: 1000, y: 500, width: 300, height: 200)
        drag(box)
        let ratioMenu = overlay.chrome.ratioMenu
        key(35, "p")
        require(ratioMenu.items.map(\.cap) == ["1", "2", "3", "4", "5", "6", "7", "8", nil, "9"],
                "the ratio menu numbers its rows 1-9 and skips the separator: \(ratioMenu.items.map(\.cap))")
        key(53, "\u{1B}")
        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (number, code) in digitCodes.enumerated() {
            let index = ratioMenu.items.firstIndex { $0.cap == "\(number + 1)" }!
            key(35, "p")
            ratioMenu.pick(index)
            let byClick = (overlay.selection!.rect, overlay.ratioLocked, overlay.ratioReadout)
            key(6, "z", .command)
            require(overlay.selection!.rect == box && !overlay.ratioLocked, "undo restores the box after the click on row \(number + 1)")
            key(35, "p")
            key(code, "\(number + 1)")
            require(ratioMenu.isHidden && overlay.window.isVisible && overlay.window.firstResponder === overlay.view
                        && overlay.selection!.rect == byClick.0 && overlay.ratioLocked == byClick.1 && overlay.ratioReadout == byClick.2,
                    "the \(number + 1) key picks \(ratioMenu.items[index].title) as a click does and closes the menu: \(overlay.selection!.rect) vs \(byClick.0)")
            key(6, "z", .command)
            require(overlay.selection!.rect == box && !overlay.ratioLocked, "undo restores the selection and the lock after the \(number + 1) key")
        }
        overlay.dismiss()

        // ? shows and hides the keys sheet; Esc closes it without closing the overlay.
        open()
        let help = overlay.chrome.help
        key(44, "?", .shift)
        let sheet = texts(in: help)
        func caps(in view: NSView) -> [KeyCap] { ((view as? KeyCap).map { [$0] } ?? []) + view.subviews.flatMap(caps) }
        let chords = caps(in: help).map(\.text).filter { $0.count > 1 && $0.contains { "\u{2325}\u{2318}\u{21E7}\u{2303}".contains($0) } }
        require(!help.isHidden && sheet.contains("Keys") && sheet.contains("Save As") && sheet.contains("Text:") && sheet.contains("Modes, view, recording") && chords.isEmpty
                    && caps(in: help).map(\.text).contains("\u{21E7}"),
                "? shows the keys sheet with every column, one cap per key: \(sheet.count) texts, chords in one cap \(chords)")
        let helpRows = HelpSheet.columns.flatMap(\.rows)
        require(["[ ]", "\u{21E7} [ ]", "=", "\u{2325} drag", "V", "K"].allSatisfy(helpRows.map(\.keys).contains)
                    && helpRows.contains { $0.keys == "arrows" && $0.action.contains("1 px") && $0.action.contains("10 px") },
                "the sheet lists the corner radius keys, V, K, and arrows in pixels")
        let helpActions = Dictionary(helpRows.map { ($0.keys, $0.action) }, uniquingKeysWith: { $1 })
        require(helpActions["P"] == "Ratio menu" && helpActions["\u{21E7} P"] == "Lock the ratio" && helpActions["W"] == "Capture the window"
                    && helpActions["K"] == "Subject preview" && helpActions["Subject: tab"] == "Next subject (Shift: back)" && helpActions["V"] == "Arm recording, hover or selection"
                    && helpActions["Armed: \u{21A9} / V"] == "Start recording" && helpActions["Armed: H"] == "Cursor on / off" && helpActions["Armed: I"] == "Count-in off, 3 s, 5 s"
                    && helpActions["hotkey"] == "Stop recording" && helpActions["G"] == "Scrolling capture, hover or selection" && helpActions["Subject: S"] == "Crop to subject"
                    && helpActions["\u{2303} \u{2325} arrow"] == "Edge out, one side" && helpActions["\u{2303} \u{2325} \u{2318} arrow"] == "Edge in, one side"
                    && helpActions["+ / -"] == "All sides 1 px (Option: 10)" && helpActions["\u{21E7} \u{21A9}"] == "Copy the text" && helpActions["\u{2318} \u{21A9}"] == "Copy for an agent"
                    && helpActions["\u{2325} \u{21A9}"] == "Translate" && helpActions["\u{21E7} \u{2318} S"] == "Save As"
                    && helpActions["tab"] == "Walk out (Shift: in)" && helpActions["[ ]"] == "Corner radius (Tab: one corner)"
                    && !helpRows.contains { $0.action.contains("Aspect ratio lock") },
                "the sheet lists the ratio menu and lock, W, the subject keys, G and V on a hover, the recording keys, Control-Option-arrow edges, + and -, Shift-Return on a hover, Tab without other fits, and no P cycle")
        require(sheet.contains("Esc or ? closes this.") || sheet.contains { $0.hasSuffix("Esc or ? closes this.") }, "the sheet says how to close it")
        let panel = help.panel.frame
        require(panel.width == 900 && help.bounds.insetBy(dx: 1, dy: 1).contains(panel), "the sheet panel is 900 pt wide and inside the screen \(panel)")
        let keyGroups = help.panel.subviews.compactMap { $0 as? Pill }, labels = help.panel.subviews.compactMap { $0 as? NSTextField }
        let crowded = keyGroups.flatMap { keys in labels.filter { $0.frame.minY < keys.frame.maxY && $0.frame.maxY > keys.frame.minY && $0.frame.minX < keys.frame.minX && $0.frame.maxX > keys.frame.minX - 8 }.map(\.stringValue) }
        require(keyGroups.count == helpRows.count && crowded.isEmpty, "no help label comes within 8 pt of its key caps: \(crowded)")
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

        // Left and Right draw no outline and no cap: a hovered row has no hint, and a Left step still picks the row before it, wrapping.
        let peerRows = (0..<4).map { Candidate(id: "row-\($0)", label: "Row", bounds: CGRect(x: 620, y: 420 + CGFloat($0) * 64, width: 560, height: 64), score: AccessibilityBounds.baseScore, kind: .element) }
        open()
        overlay.detectionTask?.cancel()
        overlay.session = SelectionSession(candidates: peerRows, extent: extent, anchor: CGPoint(x: peerRows[1].bounds.midX, y: peerRows[1].bounds.midY))
        mouse(.mouseMoved, CGPoint(x: peerRows[1].bounds.midX, y: peerRows[1].bounds.midY))
        let o = overlay.view.overlays
        require(o.hover == peerRows[1].bounds && o.upHint == nil && o.downHint == nil && overlay.view.levelHintLayer.path!.isEmpty && overlay.chrome.upHint.isHidden && overlay.chrome.downHint.isHidden,
                "a hovered row among peers has no outline and no cap: \(String(describing: o.upHint)) \(String(describing: o.downHint))")
        key(123, "")
        require(overlay.view.overlays.hover == peerRows[0].bounds && overlay.view.levelHintLayer.path!.isEmpty, "Left still picks the row before it, with no outline")
        key(123, "")
        require(overlay.view.overlays.hover == peerRows[3].bounds, "Left from the first row wraps to the last")
        overlay.dismiss()

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
        let sidebar = (0..<5).map { Candidate(id: "ax-row-\($0)", label: "Row", bounds: CGRect(x: flat.x - 80 * overlay.scale, y: flat.y - 80 * overlay.scale + CGFloat($0) * rowHeight,
                                                                                            width: 160 * overlay.scale, height: rowHeight), score: AccessibilityBounds.baseScore, kind: .element) }
        let outline = Candidate(id: "ax-outline", label: "Outline", bounds: CGRect(x: sidebar[0].bounds.minX, y: sidebar[0].bounds.minY, width: 160 * overlay.scale, height: 5 * rowHeight)
            .insetBy(dx: -8 * overlay.scale, dy: -8 * overlay.scale), score: AccessibilityBounds.baseScore, kind: .element)
        // Only the rows and their outline are candidates: no pixel geometry or flat fills join the hover.
        overlay.detected = []
        await overlay.fillsTask?.value
        overlay.fills = nil
        overlay.buildSession()
        overlay.merge([outline] + sidebar)
        mouse(.mouseMoved, CGPoint(x: sidebar[3].bounds.midX, y: sidebar[3].bounds.midY))
        require(overlay.view.overlays.hover == sidebar[3].bounds, "the lower sidebar row is hovered")
        var travel = CGPoint(x: sidebar[3].bounds.midX, y: sidebar[3].bounds.midY)
        while travel.y > sidebar[2].bounds.midY {
            travel.y -= overlay.scale
            mouse(.mouseMoved, travel)
        }
        require(overlay.view.overlays.hover == sidebar[2].bounds, "moving up a row hovers the row above, not the chip's row: \(String(describing: overlay.view.overlays.hover)) at \(travel)")
        key(right, "")
        require(overlay.view.overlays.hover == sidebar[3].bounds, "Right steps to the next row, which the walk holds: \(String(describing: overlay.view.overlays.hover))")
        for _ in 0..<4 { key(left, "") }
        require(overlay.view.overlays.hover == sidebar[4].bounds, "Left wraps from the first row to the last: \(String(describing: overlay.view.overlays.hover))")

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
        let fullChips = [overlay.chrome.hover, overlay.chrome.coordinates, overlay.chrome.snapTag, overlay.chrome.strip]
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
        require(texts(in: top) == ["Capture", "A", "Text", "T", "Loupe", "L", "Rulers", "R", "Crosshair", "X", "Rounded", "O", "Frame", "M", "?"]
                    && top.groups.count == 4 && top.groups[3].subviews == [chrome.keys] && zip(top.groups, top.groups.dropFirst()).allSatisfy { abs($1.frame.minX - $0.frame.maxX - 8) < 0.01 },
                "the settings bar is four pills 8 pt apart, the modes, view, style, and the ? button, with key caps: \(texts(in: top))")
        require(top.frame.minY == 8 && abs(top.frame.midX - overlay.view.bounds.midX) <= 0.5 && !chrome.barAtTop,
                "the settings bar sits centered 8 pt above the bottom edge: \(top.frame)")
        // The ? button opens the keys sheet, as ? does; ? closes it.
        require(chrome.help.isHidden && chrome.keys.accessibilityLabel() == "All keys", "the keys sheet starts closed and the ? button is labeled All keys")
        mouse(.leftMouseDown, viewPixel(centerOf(chrome.keys)))
        mouse(.leftMouseUp, viewPixel(centerOf(chrome.keys)))
        require(!chrome.help.isHidden && overlay.window.isVisible, "a click on the ? button opens the keys sheet")
        key(44, "?", .shift)
        require(chrome.help.isHidden, "? closes the keys sheet")
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
                require(clipped().isEmpty && abs(frameButton.caps[0].frame.minX - frameButton.title.frame.maxX - 7) < 0.01 && abs(frameButton.bounds.maxX - frameButton.caps.last!.frame.maxX - 7) < 0.01,
                        "no bar title clips and the Frame button hugs its cap with Frame \(framed) and \(mode) selected: \(clipped()) \(frameButton.frame)")
                require(chrome.modeButtons[mode]!.primary && chrome.modeButtons.values.filter(\.primary).count == 1 && !chrome.modeButtons.values.contains(where: \.lit) && top.groups.count == (mode == .text ? 3 : 4),
                        "the current mode draws as Copy does (primary), the other plain, and Text hides the style pill")
            }
        }
        defaults.set(false, forKey: Pref.frame)
        chrome.modeButtons[.capture]!.onClick()
        overlay.refresh()
        require(barButtons.allSatisfy { $0.caps.count == 1 && $0.caps[0].frame.minX >= $0.title.frame.maxX }, "every bar button shows its key cap after its title")
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
        // The pointer cluster: the coordinates, then the Snap tag, both label tier, 16 pt below and right of the pointer. The tag is lit with
        // Snap on and plain with it off, and clicks pass through both.
        let tag = chrome.snapTag, pointerView = CGPoint(x: overlay.pointer.x / overlay.scale, y: overlay.view.bounds.height - overlay.pointer.y / overlay.scale)
        require(!tag.isHidden && texts(in: tag) == ["Snap", "S"] && tag.lit && tag.frame.height == Chrome.labelHeight
                    && !coordinates.isHidden && texts(in: coordinates).count == 1 && coordinates.frame.height == Chrome.labelHeight
                    && coordinates.frame.minX == pointerView.x + 16 && coordinates.frame.maxY == pointerView.y - 16
                    && tag.frame.minX == coordinates.frame.maxX + Guides.clusterGap && tag.frame.minY == coordinates.frame.minY,
                "hover shows the coordinates and the lit Snap tag, label height, 16 pt below and right of the pointer: \(coordinates.frame) \(tag.frame) \(pointerView)")
        require(overlay.view.hitTest(centerOf(tag)) !== tag && overlay.view.hitTest(centerOf(coordinates)) !== coordinates.subviews.first, "clicks pass through the Snap tag and the coordinates")
        key(1, "s")
        require(!tag.lit && !defaults.bool(forKey: Pref.snap), "S turns the tag plain")
        key(1, "s")
        require(tag.lit, "S turns the tag lit again")
        mouse(.mouseMoved, CGPoint(x: extent.width - 2, y: extent.height - 2))
        require(overlay.view.bounds.contains(tag.frame.union(coordinates.frame)), "at the screen corner the pointer cluster is clamped into the view: \(coordinates.frame) \(tag.frame)")
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        // The tools are a symbol and their key cap, named for accessibility; at rest Copy and Save show only their own keys.
        let captureStrip = ["Copy", "\u{21A9}", "Save", "\u{2318}", "S", "G", "V", "K"]
        let offline = captureStrip.filter { !["G", "V"].contains($0) }
        require(texts(in: chrome.strip) == ["Edit", "E"] + offline + ["U"] && chrome.strip.groups.count == 3 && chrome.copy.primary && !chrome.edit.primary && !chrome.edit.lit
                    && chrome.edit.superview === chrome.strip.groups[0] && chrome.strip.frame.maxY == windowBox.minY - 8 && chrome.strip.frame.minX == windowBox.minX,
                "the action strip hangs under the hovered box: Edit in its own pill, then Copy and Save, then Subject and Colors (no live display, so no Scroll or Record): \(texts(in: chrome.strip)) \(chrome.strip.frame) \(windowBox)")
        require([chrome.scroll, chrome.record, chrome.cutout, chrome.colors].map { $0.accessibilityLabel() ?? "" } == ["Scroll", "Record", "Subject", "Colors"]
                    && [chrome.cutout, chrome.colors].allSatisfy { $0.symbol != nil && $0.title.isHidden && $0.caps.count == 1 },
                "the tools are a symbol and a key cap, with their names as accessibility labels")
        require(chrome.copy.caps.map(\.text) == ["\u{21A9}"] && chrome.save.caps.map(\.text) == ["\u{2318}", "S"] && chrome.copy.key == "\u{21A9}" && chrome.save.key == "\u{2318}S",
                "at rest Copy shows only Return and Save only Command S")
        require(chrome.all.flatMap(faded).isEmpty, "nothing else in the chrome is faded: \(chrome.all.flatMap(faded))")
        // Held modifiers fold the alternates into Copy and Save, light their caps, and dim what has no modified meaning; the strip's left
        // edge stays put while the labels change. Releasing restores the strip.
        func flags(_ modifiers: NSEvent.ModifierFlags) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        }
        let restStrip = texts(in: chrome.strip), restLeft = chrome.strip.frame.minX
        let others = [chrome.edit, chrome.cutout, chrome.colors]
        for (held, copy, save, saveKeys) in [(NSEvent.ModifierFlags.command, "Agent", "Save", ["\u{2318}", "S"]), (.shift, "Text", "Save As", ["\u{21E7}", "\u{2318}", "S"]),
                                             (.option, "Translate", "Save", ["\u{2318}", "S"])] {
            flags(held)
            let glyph = held == .command ? "\u{2318}" : held == .shift ? "\u{21E7}" : "\u{2325}"
            require(texts(in: chrome.copy) == [copy, glyph, "\u{21A9}"] && chrome.copy.key == glyph + "\u{21A9}" && chrome.copy.isEnabled
                        && texts(in: chrome.save) == [save] + saveKeys && chrome.save.isEnabled == (held != .option)
                        && others.allSatisfy { !$0.isEnabled && $0.alphaValue < 0.5 } && chrome.strip.frame.minX == restLeft,
                    "holding \(glyph): Copy reads \(copy), Save reads \(save)\(held == .option ? " dimmed" : ""), Edit and the tools dim, and the left edge stays: \(texts(in: chrome.strip)) \(chrome.strip.frame.minX)")
            require(keyCaps(glyph, in: chrome.strip).allSatisfy(\.pressed) && !keyCaps(glyph, in: chrome.strip).isEmpty && keyCaps("\u{21A9}", in: chrome.copy).allSatisfy { !$0.pressed }
,
                    "holding \(glyph) lights its caps in the strip, and only those")
            require(overlay.view.hitTest(centerOf(chrome.edit)) !== chrome.edit && overlay.view.hitTest(centerOf(chrome.colors)) !== chrome.colors,
                    "holding \(glyph), the dimmed Edit and tools take no clicks")
        }
        flags([.command, .shift])
        require(texts(in: chrome.copy) == ["Copy", "\u{21A9}"] && !chrome.copy.isEnabled && chrome.copy.alphaValue < 0.5 && overlay.view.hitTest(centerOf(chrome.copy)) !== chrome.copy
                    && texts(in: chrome.save) == ["Save As", "\u{21E7}", "\u{2318}", "S"] && chrome.save.isEnabled,
                "Command-Shift dims Copy, which then does nothing, and Save reads Save As: \(texts(in: chrome.strip))")
        flags([])
        require(texts(in: chrome.strip) == restStrip && chrome.strip.frame.minX == restLeft && chrome.strip.subviews.flatMap { keyCaps("\u{2318}", in: $0) }.allSatisfy { !$0.pressed }
                    && ([chrome.copy, chrome.save] + others).allSatisfy(\.isEnabled),
                "releasing the modifiers restores the strip: \(texts(in: chrome.strip))")
        // With motion (a live overlay without Reduce Motion), Command cross-fades Copy's label and caps and animates its width, 140 ms,
        // while its frame reads the final value at once; headless, nothing animates.
        let restCopy = chrome.copy.frame
        overlay.isHeadless = false
        flags(.command)
        overlay.isHeadless = true
        let copyLayer = chrome.copy.layer!, animating = copyLayer.animationKeys() ?? []
        require(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? animating.isEmpty : animating.contains("transition") && copyLayer.animation(forKey: "transition")?.duration == 0.14
                        && copyLayer.animation(forKey: "bounds")?.duration == 0.14,
                "with motion, Command cross-fades Copy and animates its width (Reduce Motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)): \(animating)")
        // Command dims Edit and the tools in the same 140 ms, its alpha already at the dimmed value.
        let editLayer = chrome.edit.layer!, dimming = editLayer.animationKeys() ?? []
        require(chrome.edit.alphaValue < 0.5 && (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? dimming.isEmpty : dimming.allSatisfy { editLayer.animation(forKey: $0)!.duration == 0.14 } && !dimming.isEmpty),
                "with motion, Command dims Edit over 140 ms: \(dimming)")
        require(texts(in: chrome.copy) == ["Agent", "\u{2318}", "\u{21A9}"] && chrome.copy.frame.width == BarButton("Agent", key: "\u{2318}\u{21A9}").frame.width
                    && chrome.copy.frame.width > restCopy.width && chrome.strip.frame.minX == restLeft,
                "while it animates, Copy's frame already reads Agent's width: \(texts(in: chrome.copy)) \(chrome.copy.frame) \(restCopy) \(chrome.strip.frame.minX) \(restLeft)")
        func stopAnimations(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(stopAnimations)
        }
        stopAnimations(chrome.strip.layer!)
        flags([])
        require(chrome.strip.subviews.allSatisfy { $0.layer!.animationKeys() == nil } && copyLayer.animationKeys() == nil, "headless, releasing Command animates nothing")
        // Hovering a tool shows its name in a chip under it after a short delay; the chip takes neither the hover nor clicks.
        mouse(.mouseMoved, viewPixel(centerOf(chrome.colors)))
        require(chrome.toolTip.isHidden, "the tool's name waits for the delay")
        for _ in 0..<300 where chrome.toolTip.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        let colorsCenter = centerOf(chrome.colors)
        require(texts(in: chrome.toolTip) == ["Colors"] && chrome.toolTip.frame.maxY <= chrome.strip.frame.minY && abs(chrome.toolTip.frame.midX - colorsCenter.x) <= 1
                    && overlay.view.hitTest(CGPoint(x: chrome.toolTip.frame.midX, y: chrome.toolTip.frame.midY)) !== chrome.toolTip,
                "the Colors name shows in a chip centered under its button, and passes clicks through: \(texts(in: chrome.toolTip)) \(chrome.toolTip.frame)")
        flags(.command)
        require(chrome.toolTip.isHidden, "a held modifier dims the tool and hides its name")
        flags([])
        // With motion the name's chip fades out when the pointer leaves the tool, and is hidden at once.
        chrome.toolTip.layer!.removeAllAnimations()
        overlay.isHeadless = false
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        overlay.isHeadless = true
        let tipFade = chrome.toolTip.layer!.animationKeys() ?? []
        require(chrome.toolTip.isHidden && (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? tipFade.isEmpty : chrome.toolTip.layer!.animation(forKey: "transition")?.duration == 0.14),
                "moving off the tool hides its name at once, with a 140 ms fade under motion: \(tipFade)")
        mouse(.mouseMoved, viewPixel(centerOf(chrome.colors)))
        for _ in 0..<300 where chrome.toolTip.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        mouse(.leftMouseDown, viewPixel(centerOf(chrome.colors)))
        mouse(.leftMouseUp, viewPixel(centerOf(chrome.colors)))
        for _ in 0..<1000 where chrome.colorMenu.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        require(!chrome.colorMenu.isHidden && chrome.toolTip.isHidden, "clicking Colors opens its menu and hides the tool's name")
        key(53, "\u{1B}")
        // With the pointer on the strip, Shift relabels Save under it and keeps the hover, so the Save As click lands.
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        mouse(.mouseMoved, viewPixel(CGPoint(x: centerOf(chrome.copy).x, y: windowBox.minY - 4)))
        mouse(.mouseMoved, viewPixel(centerOf(chrome.copy)))
        mouse(.mouseMoved, viewPixel(centerOf(chrome.save)))
        require(overlay.view.overlays.hover == window, "the hover holds along the strip to Save")
        flags(.shift)
        require(overlay.view.overlays.hover == window && texts(in: chrome.save).first == "Save As" && overlay.view.hitTest(centerOf(chrome.save)) === chrome.save,
                "Shift with the pointer on Save keeps the hover and the strip, and Save reads Save As under the pointer: \(String(describing: overlay.view.overlays.hover)) \(texts(in: chrome.save))")
        flags([])
        // In hover, Option-Return and an Option-click on Copy (reading Translate) both translate, queued behind a warm-up that never ends.
        OverlayController.visionWarmUp = Task { try? await Task.sleep(for: .seconds(3600)) }
        let hoverTranslates: [(String, () -> Void)] = [("Option-Return", { key(36, "\r", .option) }), ("an Option-click on Copy", {
            mouse(.mouseMoved, viewPixel(centerOf(chrome.copy)), .option)
            flags(.option)
            mouse(.leftMouseDown, viewPixel(centerOf(chrome.copy)), .option)
            mouse(.leftMouseUp, viewPixel(centerOf(chrome.copy)), .option)
            flags([])
        })]
        for (name, act) in hoverTranslates {
            act()
            require(overlay.text.queued?.notice.hasPrefix("Option-Return") == true && overlay.selection == nil && overlay.window.isVisible,
                    "\(name) on the hovered window runs Option-Return (translate): \(String(describing: overlay.text.queued?.notice))")
            overlay.text.queued = nil
            overlay.text.notice = nil
        }
        OverlayController.visionWarmUp!.cancel()
        await OverlayController.visionWarmUp!.value
        OverlayController.visionWarmUp = nil
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        // The Edit button does what E does: it opens the hovered window as a selection and stays in the strip, lit; clicking it again, E,
        // and Esc go back to the hover, and Cmd-Z brings the selection back.
        chrome.edit.onClick()
        require(overlay.selection?.rect == window && texts(in: chrome.strip).prefix(2) == ["Edit", "E"] && chrome.edit.lit,
                "clicking Edit opens the hovered window as a selection, with a lit Edit in the strip: \(String(describing: overlay.selection?.rect))")
        for (name, leave) in [("clicking Edit", { chrome.edit.onClick() }), ("E", { key(14, "e") }), ("Esc", { key(53, "") })] as [(String, () -> Void)] {
            leave()
            require(overlay.selection == nil && texts(in: chrome.strip).first == "Edit" && !chrome.edit.lit, "\(name) in edit goes back to the hover and a plain Edit button: \(texts(in: chrome.strip))")
            key(6, "z", .command)
            require(overlay.selection?.rect == window && chrome.edit.lit, "Cmd-Z after \(name) brings the selection back: \(String(describing: overlay.selection?.rect))")
        }
        key(53, "")
        key(14, "e")
        require(overlay.selection?.rect == window, "E in the hover edits the hovered window again")
        key(53, "")
        // U in the hover opens the Colors menu for the hovered element's rectangle, under the hover strip's Colors button; the menu holds
        // the hover while the pointer moves away under it, and Esc closes it and keeps the hover.
        let hoverFormat = ColorFormat(rawValue: defaults.string(forKey: Pref.colorFormat)!)!
        let hoverColors = ([ColorFormat.average(of: image, in: window)] + ColorFormat.palette(of: image, in: window)).map(hoverFormat.string)
        key(32, "u")
        for _ in 0..<1000 where chrome.colorMenu.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        let colorsButton = overlay.view.convert(chrome.colors.bounds, from: chrome.colors)
        require(!chrome.colorMenu.isHidden && overlay.selection == nil && chrome.colorMenu.items.map(\.title).filter { !$0.isEmpty } == hoverColors
                    && chrome.colorMenu.panel.frame.minX == min(max(colorsButton.minX, 8), overlay.view.bounds.width - chrome.colorMenu.panel.frame.width - 8) && chrome.colorMenu.panel.frame.maxY <= colorsButton.minY,
                "U in the hover opens the Colors menu for the hovered window under the strip's Colors button: \(chrome.colorMenu.items.map(\.title)) \(hoverColors)")
        let stripBefore = chrome.strip.frame
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(!chrome.colorMenu.isHidden && overlay.view.overlays.hover == window && chrome.strip.frame == stripBefore,
                "the pointer moving away under the open menu leaves the hover and its strip where they are: \(String(describing: overlay.view.overlays.hover)) \(chrome.strip.frame)")
        key(53, "\u{1B}")
        require(chrome.colorMenu.isHidden && overlay.window.isVisible && overlay.selection == nil, "Esc closes the hover's Colors menu and keeps the overlay")
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        // The hover holds while the pointer crosses from the element to its strip, so a click reaches Copy; the loupe and crosshair still
        // follow the pointer.
        defaults.set(true, forKey: Pref.loupe)
        defaults.set(true, forKey: Pref.crosshair)
        mouse(.mouseMoved, CGPoint(x: 400, y: 400))
        require(!readout.isHidden && tag.frame.maxY == readout.frame.minY - Guides.clusterGap && abs(tag.frame.union(coordinates.frame).midX - readout.frame.midX) <= 1,
                "with the loupe showing, the pointer cluster sits under its readout: \(coordinates.frame) \(tag.frame) \(readout.frame)")
        mouse(.mouseMoved, viewPixel(CGPoint(x: centerOf(chrome.copy).x, y: windowBox.minY - 4)))
        let heldLoupe = overlay.view.guides.loupe.position, heldCrosshair = overlay.view.guides.crosshair.path
        mouse(.mouseMoved, viewPixel(CGPoint(x: centerOf(chrome.copy).x + 3, y: centerOf(chrome.copy).y)))
        require(overlay.view.overlays.hover == window && overlay.view.hitTest(CGPoint(x: centerOf(chrome.copy).x + 3, y: centerOf(chrome.copy).y)) === chrome.copy,
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
        mouse(.leftMouseDown, rough.origin)
        mouse(.leftMouseDragged, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseDragged, CGPoint(x: rough.maxX, y: rough.maxY))
        require(!chrome.size.isHidden && chrome.snap.isHidden && tag.isHidden && chrome.strip.isHidden && texts(in: chrome.size).last!.hasSuffix("Exact"), "a drag shows the size chip, Exact before a preview, and no Snap chip, tag or strip: \(texts(in: chrome.size))")
        for _ in 0..<9000 where overlay.snapPreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        let fit = overlay.snapPreview!
        require(texts(in: chrome.size) == ["\(Int(fit.width)) x \(Int(fit.height))  Snapped"], "a snap preview shows its size and Snapped: \(texts(in: chrome.size))")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        require(texts(in: chrome.snap) == ["Snapped", "S"] && chrome.snap.lit, "after release on a fit: Snapped, lit")
        require(!top.isHidden && texts(in: chrome.strip) == ["Edit", "E"] + offline + ["U"] && chrome.edit.lit,
                "a selection keeps the settings bar and has the strip with a lit Edit: \(texts(in: chrome.strip))")
        // The chip row: size and Snap from the selection's left edge, the ratio and radius ending at its right edge (after Snap when they
        // would meet). The ratio chip's readout with P opens the ratio menu, the lock with Shift-P toggles the lock, with no fills of their own.
        let lockedBefore = overlay.ratioLocked, rectBefore = overlay.selection!.rect
        let roughBox = overlay.view.viewRect(overlay.selection!.rect)
        let row = [chrome.size, chrome.snap, chrome.ratio, chrome.radius]
        require(row.allSatisfy { !$0.isHidden && $0.frame.minY == chrome.size.frame.minY } && chrome.size.frame.minX == roughBox.minX && chrome.size.frame.minY == roughBox.maxY + 8
                    && zip(row, row.dropFirst()).allSatisfy { $1.frame.minX >= $0.frame.maxX + 5.99 } && chrome.radius.frame.maxX >= roughBox.maxX - 0.5,
                "the chip row sits on the selection's top edge: \(row.map(\.frame)) \(roughBox)")
        require(texts(in: chrome.ratio) == [overlay.ratioReadout, "P", "|", "lock", "\u{21E7}", "P"] && chrome.lock.lit == lockedBefore
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
        require(menu.items.map(\.title) == ["Free", "Original", "1:1", "4:3", "3:2", "16:10", "16:9", "21:9", "", "Portrait"] && menu.items.filter(\.on).map(\.title) == (overlay.ratioLocked ? [] : ["Free"]),
                "the panel lists the presets and checks Free while unlocked: \(menu.items.map(\.title))")
        key(53, "\u{1B}")
        require(menu.isHidden && overlay.window.isVisible && overlay.selection?.rect == rectBefore && overlay.window.firstResponder === overlay.view,
                "Esc closes the panel and leaves the selection and the overlay")
        key(35, "p")
        key(down, "")
        require(chrome.pressed == ["\u{2193}"], "Down in the ratio menu flashes the Down caps: \(chrome.pressed)")
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
        // The edge keys: the side arrows and the legend show while the pointer rests inside the selection or Option is held; the
        // legend reads one action for the modifiers held, and the lit caps on the strip and legend follow them.
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
        require(keyCaps("\u{2325}", in: chrome.strip).allSatisfy { !$0.pressed }, "without Option the Option cap is idle")
        flags(.option)
        // One cap per key: a held modifier lights its cap wherever it shows, alone or in a chord, and no other cap.
        func lit(_ glyphs: Set<String>, _ view: NSView) -> Bool {
            ["\u{2303}", "\u{2325}", "\u{2318}", "\u{21E7}"].allSatisfy { glyph in keyCaps(glyph, in: view).allSatisfy { $0.pressed == glyphs.contains(glyph) } }
        }
        require(keyCaps("\u{2325}", in: chrome.copy).count == 1 && lit(["\u{2325}"], chrome.strip) && lit(["\u{2325}"], chrome.legend)
                    && texts(in: chrome.legend) == ["grow", "\u{2325}"],
                "holding Option lights the Option caps on the strip (Translate) and the legend, which reads grow with its cap: \(texts(in: chrome.legend))")
        // The arrow caps are a D-pad around the legend: the group centered in the selection when it fits, else wholly outside it (this
        // one is 35 pt tall, so the group is taller than it), clear of the chips.
        func dpad(_ what: String) {
            let legend = chrome.legend.frame, group = sides.map(\.frame).reduce(legend) { $0.union($1) }
            let fits = group.width <= selected.width && group.height <= selected.height
            require(sides.allSatisfy { !$0.isHidden } && (fits ? abs(group.midX - selected.midX) <= 1 && abs(group.midY - selected.midY) <= 1 : !group.intersects(selected))
                        && ![chrome.strip, chrome.size, chrome.snap, chrome.ratio, chrome.radius].contains { !$0.isHidden && $0.frame.intersects(group) },
                    "\(what): the arrow caps and the legend are one group, centered in the selection when it fits, clear of the chips: \(group) \(selected)")
            require(sides[2].frame.minY == legend.maxY + 6 && sides[3].frame.maxY == legend.minY - 6 && sides[0].frame.maxX == legend.minX - 6 && sides[1].frame.minX == legend.maxX + 6
                        && abs(sides[2].frame.midX - legend.midX) <= 1 && abs(sides[3].frame.midX - legend.midX) <= 1 && abs(sides[0].frame.midY - legend.midY) <= 1 && abs(sides[1].frame.midY - legend.midY) <= 1
                        && !sides.contains { $0.frame.intersects(legend) },
                    "\(what): up above the legend, down below, left and right beside it: \(sides.map(\.frame)) \(legend)")
        }
        dpad("holding Option")
        flags([.option, .shift])
        require(lit(["\u{2325}", "\u{21E7}"], chrome.legend) && texts(in: chrome.legend) == ["grow 10 px", "\u{2325}", "\u{21E7}"], "holding Option-Shift the legend reads grow 10 px with both caps: \(texts(in: chrome.legend))")
        dpad("holding Option-Shift")
        flags([.option, .shift, .command])
        require(lit(["\u{2325}", "\u{21E7}", "\u{2318}"], chrome.legend) && texts(in: chrome.legend) == ["shrink 10 px", "\u{2325}", "\u{21E7}", "\u{2318}"], "holding Option-Shift-Command the legend reads shrink 10 px: \(texts(in: chrome.legend))")
        dpad("holding Option-Shift-Command")
        flags(.option)
        flags([.option, .command])
        require(lit(["\u{2325}", "\u{2318}"], chrome.strip) && lit(["\u{2325}", "\u{2318}"], chrome.legend)
                    && texts(in: chrome.legend) == ["shrink", "\u{2325}", "\u{2318}"] && sides.allSatisfy { !$0.isHidden },
                "holding Option-Command lights every Option and Command cap, the legend reads shrink, and the side arrows stay: \(texts(in: chrome.legend))")
        flags([.control, .option])
        require(lit(["\u{2303}", "\u{2325}"], chrome.legend) && texts(in: chrome.legend) == ["edge out", "\u{2303}", "\u{2325}"] && sides.allSatisfy { !$0.isHidden },
                "holding Control-Option the legend reads edge out with both caps lit: \(texts(in: chrome.legend))")
        dpad("holding Control-Option")
        flags([.control, .option, .shift])
        require(texts(in: chrome.legend) == ["edge out", "\u{2303}", "\u{2325}"], "Shift changes nothing with Control: \(texts(in: chrome.legend))")
        flags([.control, .option, .command])
        require(lit(["\u{2303}", "\u{2325}", "\u{2318}"], chrome.legend) && texts(in: chrome.legend) == ["edge in", "\u{2303}", "\u{2325}", "\u{2318}"],
                "holding Control-Option-Command the legend reads edge in: \(texts(in: chrome.legend))")
        dpad("holding Control-Option-Command")
        flags([.control, .option, .command, .shift])
        require(texts(in: chrome.legend) == ["edge in", "\u{2303}", "\u{2325}", "\u{2318}"], "Shift changes nothing with Control-Option-Command: \(texts(in: chrome.legend))")
        flags(.command)
        require(lit(["\u{2318}"], chrome.strip) && sides.allSatisfy(\.isHidden) && chrome.legend.isHidden,
                "holding Command alone lights the strip's Command caps and shows no edge keys, since Command-arrow is unbound")
        flags(.control)
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "Control alone with the pointer outside shows no edge keys")
        mouse(.mouseMoved, insideSelection, .control)
        require(overlay.controlHeld && texts(in: chrome.legend) == ["move"] && sides.allSatisfy { !$0.isHidden },
                "Control alone with the pointer inside shows nothing new: the legend reads move")
        flags(.command)
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "Command with the pointer inside hides the edge keys")
        flags([])
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        flags(.shift)
        require(sides.allSatisfy(\.isHidden) && chrome.legend.isHidden, "Shift alone with the pointer outside shows no edge keys")
        flags([])
        let snapped = overlay.selection!
        overlay.editedRadii[snapped.rect] = CornerRadii(12 * overlay.scale)
        // Tab cycles a focused corner: top-left, top-right, bottom-right, bottom-left, and around, never back to all corners; Shift-Tab
        // goes back, and from all corners picks bottom-left. The focused corner lights its dot, the chip names it with its radius, and
        // [ ] change only it. Only Esc returns to all corners. Undo covers the edit.
        let radius = 12 * overlay.scale
        let focusedKeys = ["radius", "[", "]", "next corner", "tab", "all corners", "esc"], allKeys = ["radius", "[", "]", "one corner", "tab"]
        var focus: [Handle?] = []
        for _ in 0..<5 { key(48, "\t"); focus.append(overlay.focusedCorner) }
        require(focus == [.topLeft, .topRight, .bottomRight, .bottomLeft, .topLeft] && overlay.selection?.rect == snapped.rect, "Tab cycles the corners TL, TR, BR, BL, TL: \(focus)")
        focus = []
        for _ in 0..<4 { key(48, "\t", .shift); focus.append(overlay.focusedCorner) }
        require(focus == [.bottomLeft, .bottomRight, .topRight, .topLeft], "Shift-Tab cycles back BL, BR, TR, TL: \(focus)")
        key(53, "\u{1B}")
        key(48, "\t", .shift)
        require(overlay.focusedCorner == .bottomLeft, "Shift-Tab from all corners picks bottom-left: \(String(describing: overlay.focusedCorner))")
        key(53, "\u{1B}")
        key(48, "\t")
        require(overlay.view.overlays.focusedCorner == .topLeft && texts(in: overlay.cornerChip) == ["Top left  r 12", "="] && texts(in: chrome.cornerKeys) == focusedKeys,
                "a focused corner lights its dot, the chip names it with its radius, and the keys follow: \(texts(in: overlay.cornerChip)) \(texts(in: chrome.cornerKeys))")
        key(93, "]")
        key(48, "\t")
        key(33, "[")
        let stepped = overlay.cornerRadii(of: snapped.rect)
        require(stepped.topLeft == radius + overlay.scale && stepped.topRight == radius - overlay.scale && stepped.bottomLeft == radius && stepped.bottomRight == radius,
                "] on the top-left and [ on the top-right change only those corners: \(stepped)")
        key(53, "\u{1B}")
        require(overlay.focusedCorner == nil && overlay.selection?.rect == snapped.rect && overlay.cornerChip.isHidden && overlay.view.overlays.focusedCorner == nil, "Esc returns from a focused corner to all four and keeps the selection")
        key(33, "[")
        require(overlay.cornerRadii(of: snapped.rect) == CornerRadii(topLeft: radius, topRight: radius - 2 * overlay.scale, bottomLeft: radius - overlay.scale, bottomRight: radius - overlay.scale),
                "with no corner focused, [ changes all four: \(overlay.cornerRadii(of: snapped.rect))")
        overlay.undoEdit(redo: false)
        // The two [ presses within 0.5 s are one undo step, so undo returns to the state after the ].
        require(overlay.cornerRadii(of: snapped.rect) == CornerRadii(topLeft: radius + overlay.scale, topRight: radius, bottomLeft: radius, bottomRight: radius),
                "undo covers the corner edits like any radius edit: \(overlay.cornerRadii(of: snapped.rect))")
        overlay.editedRadii[snapped.rect] = CornerRadii(radius)
        mouse(.mouseMoved, overlay.cornerRadii(of: snapped.rect).dot(of: .topLeft, in: snapped.rect, minimumInset: 8 * overlay.scale))
        let cornerKeys = chrome.cornerKeys, cornerChip = overlay.cornerChip
        require(!cornerChip.isHidden && texts(in: cornerChip) == ["All corners  r 12", "="] && texts(in: cornerKeys) == allKeys
                && cornerKeys.frame.maxY <= cornerChip.frame.minY && abs(cornerKeys.frame.maxX - cornerChip.frame.maxX) < 0.5,
                "hovering a corner dot shows the same group: All corners with the radius, then radius [ ] and tab for one corner: \(texts(in: cornerChip)) \(texts(in: cornerKeys)) \(cornerKeys.frame) \(cornerChip.frame)")
        // Tab with the pointer on a dot: the focused corner leads the group, so the chip names the corner [ ] change, and a move on the
        // same dot keeps it.
        let bottomRightDot = overlay.cornerRadii(of: snapped.rect).dot(of: .bottomRight, in: snapped.rect, minimumInset: 8 * overlay.scale)
        mouse(.mouseMoved, bottomRightDot)
        key(48, "\t")
        mouse(.mouseMoved, CGPoint(x: bottomRightDot.x + 1, y: bottomRightDot.y))
        let snappedBox = overlay.view.viewRect(snapped.rect)
        require(overlay.focusedCorner == .topLeft && overlay.hoveredCorner == .bottomRight && texts(in: cornerChip) == ["Top left  r 12", "="] && texts(in: cornerKeys) == focusedKeys
                    && cornerChip.frame.midX < snappedBox.midX && cornerChip.frame.midY > snappedBox.midY,
                "Tab on the bottom-right dot focuses top-left, and the group shows at top-left: \(String(describing: overlay.focusedCorner)) \(texts(in: cornerChip)) \(cornerChip.frame) \(snappedBox)")
        key(53, "\u{1B}")
        require(overlay.focusedCorner == nil && texts(in: cornerChip) == ["All corners  r 12", "="] && texts(in: cornerKeys) == allKeys && cornerChip.frame.midX > snappedBox.midX,
                "Esc returns to all corners, and the hovered bottom-right dot's group shows again: \(texts(in: cornerChip)) \(cornerChip.frame)")
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

        // The strip's Copy with Shift held (Text) runs Shift-Return and with Option held (Translate) Option-Return, queued here behind a warm-up that never ends so no text recognition runs. The chips
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
        for (held, label, chord) in [(NSEvent.ModifierFlags.shift, "Text", "Shift-Return"), (.option, "Translate", "Option-Return")] {
            flags(held)
            mouse(.leftMouseDown, viewPixel(centerOf(chrome.copy)), held)
            mouse(.leftMouseUp, viewPixel(centerOf(chrome.copy)), held)
            flags([])
            require(overlay.text.queued?.notice.hasPrefix(chord) == true, "clicking the strip's Copy while it reads \(label) runs \(chord): \(String(describing: overlay.text.queued?.notice))")
            overlay.text.queued = nil
            overlay.text.notice = nil
        }
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
        // With motion the radius chip fades in; it is shown at once.
        overlay.isHeadless = false
        key(30, "]")
        overlay.isHeadless = true
        let radiusFade = chrome.radius.layer!.animationKeys() ?? []
        require(!chrome.radius.isHidden && (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? radiusFade.isEmpty : radiusFade.contains("transition")),
                "with motion, the radius chip fades in and is shown at once: \(radiusFade)")
        let hoverChips = [chrome.hover, chrome.snapTag, chrome.radius]
        let covering = overlay.view.subviews.filter { view in !view.isHidden && !hoverChips.contains(view) && hoverChips.contains { $0.frame.intersects(view.frame) } && view !== overlay.view.liveText && view !== overlay.view.guides.host }
        require(texts(in: chrome.radius) == ["r 1", "[", "]"] && chrome.radius.frame.minY == chrome.hover.frame.minY && covering.isEmpty,
                "] on a hovered element shows its radius in the chip row, uncovered: \(texts(in: chrome.radius)) covered by \(covering.map { "\(type(of: $0)) \($0.frame)" })")

        // With motion, a key's jump to another hover candidate animates the outline, its dim and the chrome on it with one 100 ms
        // animation, while every frame reads its final value at once; the pointer's hover change and key repeat animate nothing.
        overlay.dismiss()
        open()
        let jumpInner = Candidate(id: "jump-inner", label: "Card", bounds: CGRect(x: 1250, y: 420, width: 500, height: 300), score: AccessibilityBounds.baseScore, kind: .element)
        let jumpOuter = Candidate(id: "jump-outer", label: "Panel", bounds: jumpInner.bounds.insetBy(dx: -160, dy: -120), score: AccessibilityBounds.baseScore, kind: .element)
        let jumpChild = Candidate(id: "jump-child", label: "Button", bounds: jumpInner.bounds.insetBy(dx: 90, dy: 70), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.detectionTask?.cancel()
        let jumpAim = CGPoint(x: jumpInner.bounds.midX, y: jumpInner.bounds.midY)
        overlay.session = SelectionSession(candidates: [jumpChild, jumpInner, jumpOuter], extent: extent, anchor: jumpAim)
        mouse(.mouseMoved, jumpAim)
        let jumpLayers = [overlay.view.hoverLayer, overlay.view.dimLayer, overlay.view.levelHintLayer, chrome.strip.layer!, chrome.hover.layer!]
        func jumpAnimations() -> [[Double]] { jumpLayers.map { layer in (layer.animationKeys() ?? []).map { layer.animation(forKey: $0)!.duration } } }
        func settleJump() { jumpLayers.forEach { $0.removeAllAnimations() } }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hoverBefore = overlay.view.overlays.hover
        settleJump()
        overlay.isHeadless = false
        key(126, "")
        overlay.isHeadless = true
        let jumped = jumpAnimations(), hoverAfter = overlay.view.overlays.hover, stripAfter = chrome.strip.frame, chipAfter = chrome.hover.frame
        require(hoverAfter != hoverBefore && hoverAfter != nil, "Up moves the hover to another candidate: \(String(describing: hoverBefore)) to \(String(describing: hoverAfter))")
        let outlinePath = overlay.view.hoverLayer.animation(forKey: "path")
        require(reduced ? jumped.allSatisfy(\.isEmpty)
                    : outlinePath?.duration == 0.1 && jumped[0].allSatisfy { $0 == 0.1 } && jumped[3...].allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == 0.1 } },
                "with motion, an Up jump animates the outline, the strip and the hover chip over 100 ms (Reduce Motion \(reduced)): \(jumped)")
        require(reduced || overlay.view.dimLayer.animation(forKey: "path")?.duration == 0.1 && overlay.view.dimLayer.animation(forKey: "dim") == nil,
                "the dim's cutout moves with the outline instead of cross-fading: \(jumped[1])")
        settleJump()
        key(125, "")
        key(126, "")
        require(overlay.view.overlays.hover == hoverAfter && chrome.strip.frame == stripAfter && chrome.hover.frame == chipAfter && jumpAnimations().allSatisfy(\.isEmpty),
                "the animated jump's frames equal an instant placement, and headless nothing animates: \(chrome.strip.frame) \(stripAfter)")
        // The pointer's hover change moves outline and strip at once, and so does a repeated key.
        settleJump()
        overlay.isHeadless = false
        mouse(.mouseMoved, CGPoint(x: jumpAim.x + 100, y: jumpAim.y))
        overlay.isHeadless = true
        require(overlay.view.overlays.hover != hoverAfter, "the pointer returns the hover to the element under it")
        require(jumpAnimations().enumerated().allSatisfy { $0.offset == 1 || $0.element.isEmpty }, "with motion, a pointer hover change moves the outline, strip and chip at once: \(jumpAnimations())")
        settleJump()
        overlay.isHeadless = false
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 126)!)
        }
        overlay.isHeadless = true
        require(overlay.view.overlays.hover == hoverAfter && jumpAnimations().allSatisfy(\.isEmpty), "with motion, a repeated Up moves the hover at once: \(jumpAnimations())")
        overlay.dismiss()

        // Chrome never overlaps or leaves the screen, and the loupe, which is on throughout, draws above all of it: a large and a small
        // selection, one at each screen edge (the bottom one moves the bar to the top), and the full screen with a 38 pt inset, each with
        // the pointer inside so the edge keys show, then on the top-left and bottom-right corner dots, then with the top-left corner focused.
        overlay.dismiss()
        open()
        defaults.set(true, forKey: Pref.loupe)
        func chromeClear(_ state: String) {
            let pieces: [(String, NSView)] = [("bar", chrome.topBar), ("strip", chrome.strip), ("hover", chrome.hover), ("size", chrome.size), ("snap", chrome.snap),
                                               ("ratio", chrome.ratio), ("radius", chrome.radius), ("status", chrome.status), ("legend", chrome.legend),
                                               ("corner chip", overlay.cornerChip), ("corner keys", chrome.cornerKeys), ("up cap", chrome.upHint), ("down cap", chrome.downHint),
                                               ("cluster", chrome.coordinates), ("snap tag", chrome.snapTag), ("tool tip", chrome.toolTip), ("list", chrome.list),
                                               ("reading", chrome.reading), ("minimap", chrome.minimap), ("readout", guides2.readout)]
                + chrome.sideHints.enumerated().map { ("side \($0.offset)", $0.element) }
            let shown = pieces.filter { !$0.1.isHidden }
            let overlaps = shown.indices.flatMap { i in shown.indices.filter { $0 > i && shown[i].1.frame.intersects(shown[$0].1.frame) }.map { "\(shown[i].0) x \(shown[$0].0)" } }
            let screen = CGRect(x: 0, y: 0, width: overlay.view.bounds.width, height: overlay.view.bounds.height - overlay.topInset)
            let outside = shown.filter { !screen.contains($0.1.frame) }.map { "\($0.0) \($0.1.frame) in \(screen)" }
            let host = overlay.view.guides.host
            require(overlaps.isEmpty && outside.isEmpty, "\(state): the chrome does not overlap or leave the screen: overlaps \(overlaps), outside \(outside) \(shown.map { "\($0.0) \($0.1.frame)" }) loupe \(guides2.loupe.frame)")
            require(!guides2.loupe.isHidden && guides2.loupe.superlayer === host.layer && guides2.readout.superview === host && overlay.view.subviews.last === host,
                    "\(state): the loupe and its readout draw above all the chrome: \(overlay.view.subviews.last.map { "\(type(of: $0))" } ?? "none") on top")
        }
        let edgeCases = [("large", large), ("small", CGRect(x: 600, y: 300, width: 120, height: 80)), ("left", CGRect(x: 0, y: 600, width: 500, height: 300)),
                         ("right", CGRect(x: extent.width - 500, y: 600, width: 500, height: 300)), ("top", CGRect(x: 900, y: 0, width: 700, height: 300)),
                         ("bottom", CGRect(x: 900, y: extent.height - 300, width: 700, height: 300)),
                         ("small bottom", CGRect(x: 600, y: extent.height - 160, width: 120, height: 80)), ("full", extent),
                         ("top left", CGRect(x: 0, y: 0, width: 500, height: 300)), ("bottom right", CGRect(x: extent.width - 500, y: extent.height - 300, width: 500, height: 300))]
        for (name, rect) in edgeCases {
            overlay.topInset = name == "full" ? 38 : 0
            overlay.selection = AreaSelection(extent: extent, exact: rect)
            overlay.refresh()
            mouse(.mouseMoved, CGPoint(x: 40, y: 40))
            mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
            chromeClear("the \(name) selection")
            require(!chrome.ratio.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden } && chrome.barAtTop == name.hasSuffix("bottom"),
                    "the \(name) selection shows the ratio chip and the edge keys, with the bar \(name.hasSuffix("bottom") ? "at the top" : "at the bottom"): ratio \(chrome.ratio.isHidden) sides \(chrome.sideHints.map(\.isHidden)) bar \(chrome.barAtTop)")
            // The arrow keys and legend stay by the selection and its chrome: within a chip row's height of them.
            let dpad = chrome.sideHints.map(\.frame).reduce(chrome.legend.frame) { $0.union($1) }
            let attached = [chrome.strip, chrome.size, chrome.ratio].map(\.frame).reduce(overlay.view.viewRect(rect)) { $0.union($1) }
            require(dpad.insetBy(dx: -40, dy: -40).intersects(attached), "the \(name) selection's arrow keys stay by it: \(dpad) by \(attached)")
            if name == "large" {
                let group = chrome.sideHints.map(\.frame).reduce(chrome.legend.frame) { $0.union($1) }
                require(overlay.view.viewRect(rect).contains(group), "in the large selection the arrow caps and the legend sit inside it: \(group)")
                // With motion, an arrow nudge moves the strip with its outline at once: nothing in the strip animates its position.
                let stripTop = chrome.strip.frame.maxY
                overlay.isHeadless = false
                key(125, "")
                overlay.isHeadless = true
                func moving(_ view: NSView) -> [String] { (view.layer!.animationKeys() ?? []) + view.subviews.flatMap(moving) }
                require(moving(chrome.strip).isEmpty && chrome.strip.frame.maxY == stripTop - 1 / overlay.scale,
                        "with motion, an arrow nudge moves the strip with the outline and animates nothing: \(moving(chrome.strip)) \(chrome.strip.frame.maxY) from \(stripTop)")
                key(126, "")
            }
            for corner in [Handle.topLeft, .bottomRight] {
                mouse(.mouseMoved, overlay.cornerRadii(of: rect).dot(of: corner, in: rect, minimumInset: 8 * overlay.scale))
                require(overlay.hoveredCorner == corner, "the \(name) selection's \(corner) dot is hovered")
                chromeClear("the \(name) selection's hovered \(corner) corner")
            }
            mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
            key(48, "\t")
            require(overlay.focusedCorner == .topLeft, "Tab focuses the \(name) selection's top-left corner")
            chromeClear("the \(name) selection's focused corner")
            key(53, "\u{1B}")
            // Must-show: each of the four corners focused shows its chip and keys, whatever else is placed.
            for corner in [Handle.topLeft, .topRight, .bottomRight, .bottomLeft] {
                overlay.focusedCorner = corner
                overlay.refresh()
                require(!overlay.cornerChip.isHidden && texts(in: chrome.cornerKeys) == ["radius", "[", "]", "next corner", "tab", "all corners", "esc"],
                        "the \(name) selection's focused \(corner) corner shows its chip and keys: \(overlay.cornerChip.isHidden) \(texts(in: chrome.cornerKeys)); box \(overlay.view.viewRect(rect)) \(([("bar", chrome.topBar), ("strip", chrome.strip), ("size", chrome.size), ("snap", chrome.snap), ("ratio", chrome.ratio), ("radius", chrome.radius), ("chip", overlay.cornerChip), ("keys", chrome.cornerKeys)] as [(String, NSView)]).map { "\($0.0) \($0.1.isHidden ? "hidden" : "\($0.1.frame)")" })")
                chromeClear("the \(name) selection's focused \(corner) corner, set directly")
            }
            overlay.focusedCorner = nil
            // Must-show: a notice and the reading chip show beside whatever else is placed.
            overlay.text.notice = "A notice the user must read"
            overlay.text.reading = rect
            overlay.refresh()
            require(!chrome.status.isHidden && !chrome.reading.isHidden, "the \(name) selection shows a notice and the reading chip: \(chrome.status.isHidden) \(chrome.reading.isHidden)")
            chromeClear("the \(name) selection with a notice and the reading chip")
            overlay.text.notice = nil
            overlay.text.reading = nil
            overlay.refresh()
            // At the right edge the strip is clamped with room for its widest labels, so they keep its left edge and stay on screen.
            guard name == "right" else { continue }
            let left = chrome.strip.frame.minX
            for held in [NSEvent.ModifierFlags.option, .shift, .command] {
                flags(held)
                require(chrome.strip.frame.minX == left && chrome.strip.frame.maxX <= overlay.view.bounds.width - 8,
                        "at the right edge, holding \(held.rawValue) keeps the strip's left edge and keeps it on screen: \(chrome.strip.frame)")
            }
            flags([])
        }
        // With Rulers on, a focused corner's chip and keys still show and stay clear of the left ruler's band, for a selection at the left edge.
        defaults.set(true, forKey: Pref.rulers)
        for (name, rect) in [("left", CGRect(x: 0, y: 600, width: 500, height: 300)), ("top left", CGRect(x: 0, y: 0, width: 500, height: 300))] {
            overlay.selection = AreaSelection(extent: extent, exact: rect)
            for corner in [Handle.topLeft, .bottomLeft] {
                overlay.focusedCorner = corner
                overlay.refresh()
                require(!overlay.cornerChip.isHidden && !chrome.cornerKeys.isHidden && min(overlay.cornerChip.frame.minX, chrome.cornerKeys.frame.minX) >= Guides.rulerThickness,
                        "with Rulers on, the \(name) selection's focused \(corner) chip and keys show clear of the left ruler: \(overlay.cornerChip.frame) \(chrome.cornerKeys.frame)")
            }
        }
        overlay.focusedCorner = nil
        defaults.set(false, forKey: Pref.rulers)

        // Must-show: in a 60 x 40 pt selection in the middle of the screen the legend and its arrow caps show under every modifier
        // state that binds the arrows, as one group on the same side of the selection each time.
        let tight = CGRect(x: extent.midX, y: extent.midY, width: 60 * overlay.scale, height: 40 * overlay.scale)
        overlay.selection = AreaSelection(extent: extent, exact: tight)
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        mouse(.mouseMoved, CGPoint(x: tight.midX, y: tight.midY))
        let tightBox = overlay.view.viewRect(tight)
        /// The legend group's side of `box` and the group's anchor on that side, which stay the same when its labels change width.
        func legendSpot(_ box: CGRect) -> String {
            let group = chrome.sideHints.map(\.frame).reduce(chrome.legend.frame) { $0.union($1) }
            let side = box.contains(group) ? "inside" : group.minY >= box.maxY ? "above" : group.maxY <= box.minY ? "below" : group.minX >= box.maxX ? "right" : "left"
            let anchor = switch side { case "above", "below": group.midX; case "right": group.minX; case "left": group.maxX; default: group.midX }
            return "\(side) \(anchor.rounded())"
        }
        var tightSides: [String: String] = [:]
        for (label, held) in [("no modifier", NSEvent.ModifierFlags([])), ("Shift", .shift), ("Option", .option), ("Option-Shift", [.option, .shift]),
                              ("Option-Command", [.option, .command]), ("Control-Option", [.control, .option]), ("Control-Option-Command", [.control, .option, .command])] {
            flags(held)
            require(!chrome.legend.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden }, "the 60 x 40 pt selection shows the legend and arrow caps under \(label)")
            chromeClear("the 60 x 40 pt selection under \(label)")
            tightSides[label] = legendSpot(tightBox)
        }
        flags([])
        require(Set(tightSides.values).count == 1, "the 60 x 40 pt selection's legend group keeps one position under every modifier state: \(tightSides)")
        // Must-show: right after a drag of a 60 x 40 pt area is released, with the pointer on its far corner and no modifier, the legend
        // shows in the same spot as under Option.
        overlay.dismiss()
        open()
        defaults.set(true, forKey: Pref.loupe)
        drag(CGRect(x: 1200, y: 700, width: 60 * overlay.scale, height: 40 * overlay.scale))
        let releasedBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.legend.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden },
                "right after releasing a 60 x 40 pt drag, the legend shows with no modifier: pointer \(overlay.pointer) selection \(overlay.selection!.rect)")
        let afterDrag = legendSpot(releasedBox)
        flags(.option)
        let underOption = legendSpot(releasedBox)
        flags([])
        require(afterDrag == underOption, "after the release the legend sits where it does under Option: \(afterDrag) \(underOption)")

        // The same at the screen's edges and corners: a 60 x 40 pt selection shows its legend and arrow caps under every modifier state.
        for (x, y) in [0, 600, extent.width - 60 * overlay.scale].flatMap({ x in [0, 700, extent.height - 40 * overlay.scale].map { (x, $0) } }) {
            let small = CGRect(x: x, y: y, width: 60 * overlay.scale, height: 40 * overlay.scale)
            overlay.selection = AreaSelection(extent: extent, exact: small)
            overlay.refresh()
            mouse(.mouseMoved, CGPoint(x: 40, y: 700))
            mouse(.mouseMoved, CGPoint(x: small.midX, y: small.midY))
            for (label, held) in [("no modifier", NSEvent.ModifierFlags([])), ("Option", .option), ("Option-Command", [.option, .command]),
                                  ("Control-Option-Command", [.control, .option, .command])] {
                flags(held)
                require(!chrome.legend.isHidden && chrome.sideHints.allSatisfy { !$0.isHidden }, "a 60 x 40 pt selection at (\(Int(x)), \(Int(y))) shows the legend and arrow caps under \(label)")
                chromeClear("a 60 x 40 pt selection at (\(Int(x)), \(Int(y))) under \(label)")
            }
            flags([])
        }
        overlay.topInset = 0
        defaults.set(false, forKey: Pref.loupe)

        // Hovering the menu bar, with the settings bar at the bottom: the hover chip, the strip, and the bar keep clear of each other; a
        // menu bar item too short to hold the chip row stacks it under the strip, with and without a camera-housing inset.
        let menuBar = 24 * overlay.scale
        let menuItem = CGRect(x: extent.midX - 60 * overlay.scale, y: 0, width: 120 * overlay.scale, height: menuBar)
        for (name, inset) in [("flat", CGFloat(0)), ("notched", CGFloat(38))] {
            for (what, hovered) in [("a menu bar item", menuItem), ("the whole menu bar", CGRect(x: 0, y: 0, width: extent.width, height: menuBar))] {
                overlay.dismiss()
                open()
                // Opening reads the screen's inset; the simulated one is set after.
                overlay.topInset = inset
                await overlay.detectionTask?.value
                overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
                overlay.merge([Candidate(id: "ax-menu-bar", label: "Menu bar", bounds: hovered, score: AccessibilityBounds.baseScore, kind: .element)])
                mouse(.mouseMoved, CGPoint(x: hovered.midX, y: 8))
                let pieces: [(String, NSView)] = [("hover chip", chrome.hover), ("strip", chrome.strip), ("bar", chrome.topBar)].filter { !$0.1.isHidden }
                let clashes = pieces.indices.flatMap { i in pieces.indices.filter { $0 > i && pieces[i].1.frame.intersects(pieces[$0].1.frame) }.map { "\(pieces[i].0) x \(pieces[$0].0)" } }
                let box = overlay.view.viewRect(hovered)
                require(pieces.map(\.0) == ["hover chip", "strip", "bar"] && clashes.isEmpty && !chrome.barAtTop && chrome.strip.frame.maxY == min(box.minY, overlay.view.bounds.height - inset) - 8
                            && chrome.hover.frame.maxY == chrome.strip.frame.minY - 6,
                        "hovering \(what) (\(name) screen) hangs the strip under it and stacks the hover chip under the strip, clear of the bar: \(clashes) \(pieces.map { "\($0.0) \($0.1.frame)" })")
                overlay.dismiss()
            }
        }
        overlay.topInset = 0

        // The cursor is the arrow over a button of the top bar and the strip and over a row of an open menu, and the capture cursor on the
        // gaps between them and on the labels that pass the pointer through.
        overlay.dismiss()
        open()
        await overlay.detectionTask?.value
        overlay.setWindows([screenWindow], names: ["Form"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, flat)
        require(overlay.view.cursor === NSCursor.crosshair && !chrome.strip.isHidden && !chrome.hover.isHidden, "a hover shows the capture cursor: \(overlay.view.cursor)")
        defaults.set(true, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: flat.x + 1, y: flat.y))
        chromeClear("a hover")
        // Must-show: with the pointer over the strip, the bar, a tool and near the screen's edges, the pointer cluster hangs under the
        // loupe's readout and both keep clear of the chrome, tool tip included.
        for (name, point) in [("the strip", viewPixel(centerOf(chrome.strip))), ("the bar", viewPixel(centerOf(chrome.topBar))),
                              ("the strip's left end", viewPixel(CGPoint(x: chrome.strip.frame.minX + 2, y: chrome.strip.frame.midY))),
                              ("the bottom edge", CGPoint(x: flat.x, y: extent.height - 2)), ("the right edge", CGPoint(x: extent.width - 2, y: flat.y))] {
            mouse(.mouseMoved, flat)
            mouse(.mouseMoved, point)
            require(!chrome.coordinates.isHidden && !guides2.readout.isHidden && chrome.coordinates.frame.maxY <= guides2.readout.frame.minY && (abs(chrome.snapTag.frame.union(chrome.coordinates.frame).midX - guides2.readout.frame.midX) <= 1.5 || chrome.snapTag.frame.maxX == overlay.view.bounds.width - 8),
                    "with the pointer on \(name), the cluster hangs under the readout: \(chrome.coordinates.frame) \(guides2.readout.frame)")
            chromeClear("a hover with the pointer on \(name)")
        }
        mouse(.mouseMoved, flat)
        mouse(.mouseMoved, viewPixel(centerOf(chrome.colors)))
        try await Task.sleep(for: .milliseconds(700))
        require(!chrome.toolTip.isHidden && chrome.toolTip.frame.maxY <= chrome.strip.frame.minY, "the Colors tool tip shows under the strip: \(chrome.toolTip.frame) \(chrome.strip.frame)")
        chromeClear("a hover with the Colors tool tip")
        mouse(.mouseMoved, flat)
        defaults.set(false, forKey: Pref.loupe)
        mouse(.mouseMoved, flat)
        let overButtons = [("Copy", chrome.copy), ("Edit", chrome.edit), ("Capture", chrome.modeButtons[.capture]!), ("Frame", chrome.styleToggles[1].1)]
        for (name, button) in overButtons {
            mouse(.mouseMoved, viewPixel(centerOf(button)))
            require(overlay.view.cursor === NSCursor.arrow, "the cursor is the arrow over the \(name) button: \(overlay.view.cursor)")
        }
        let barGap = CGPoint(x: (top.groups[0].frame.maxX + top.groups[1].frame.minX) / 2 + top.frame.minX, y: top.frame.midY)
        mouse(.mouseMoved, viewPixel(barGap))
        require(overlay.view.cursor === NSCursor.crosshair, "the cursor is the capture cursor on the gap between top bar pills: \(overlay.view.cursor)")
        mouse(.mouseMoved, flat)
        mouse(.mouseMoved, viewPixel(centerOf(chrome.hover)))
        require(overlay.view.cursor === NSCursor.crosshair, "the hover chip passes the pointer through, so the cursor does not change over it: \(overlay.view.cursor)")
        mouse(.mouseMoved, flat)
        drag(rough)
        key(35, "p")
        require(!chrome.ratioMenu.isHidden, "P opens the ratio menu")
        let menuRow = chrome.ratioMenu.panel.convert(CGPoint(x: chrome.ratioMenu.rows[0].frame.midX, y: chrome.ratioMenu.rows[0].frame.midY), to: overlay.view)
        mouse(.mouseMoved, viewPixel(menuRow))
        require(overlay.view.cursor === NSCursor.arrow, "the cursor is the arrow over a menu row: \(overlay.view.cursor)")
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        require(overlay.view.cursor !== NSCursor.arrow, "the cursor leaves the arrow off the menu's rows: \(overlay.view.cursor)")
        key(53, "\u{1B}")
        overlay.dismiss()

        // A lit Edit button draws exactly as a lit toggle (Loupe) does, and the current mode exactly as Copy, in the light and the dark look.
        for look in ["light", "dark"] {
            defaults.set(look, forKey: Pref.overlayAppearance)
            open()
            drag(rough)
            overlay.refresh()
            defaults.set(true, forKey: Pref.loupe)
            overlay.refresh()
            let mode = chrome.modeButtons[.capture]!, edit = chrome.edit, loupe = chrome.viewToggles[0].1
            func drawn(_ button: BarButton) -> [String] {
                [button.layer!.backgroundColor, button.layer!.borderColor].map { "\(NSColor(cgColor: $0!)!.usingColorSpace(.sRGB)!)" } + ["\(button.layer!.borderWidth)", "\(button.title.textColor!.usingColorSpace(.sRGB)!)", "\(button.title.font!.fontName) \(button.title.font!.pointSize)"]
            }
            require(loupe.lit && edit.lit && drawn(loupe) == drawn(edit), "a lit Edit draws as a lit toggle in the \(look) look: \(drawn(loupe)) \(drawn(edit))")
            require(mode.primary && drawn(mode) == drawn(chrome.copy), "the current mode draws as Copy in the \(look) look: \(drawn(mode)) \(drawn(chrome.copy))")
            defaults.set(false, forKey: Pref.loupe)
            overlay.dismiss()
        }
        defaults.removeObject(forKey: Pref.overlayAppearance)

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
        require(overlay.armedRecording == nil && texts(in: chrome.strip) == ["Edit", "E"] + captureStrip.filter { $0 != "G" } + ["U"] && !chrome.ratio.isHidden, "Esc disarms and brings the editing chrome back: \(texts(in: chrome.strip))")
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
                    && chrome.strip.frame.maxY == pageBox.minY - 8 && texts(in: chrome.status) == ["Scroll the app under the outline"]
                    && chrome.status.frame.origin == CGPoint(x: pageBox.minX, y: pageBox.maxY + 8),
                "frames stitch as the area scrolls, the strip under the area counts the height, and a status chip over its left edge says what to do: \(overlay.scrollHeight) \(texts(in: chrome.strip)) \(texts(in: chrome.status)) \(chrome.status.frame)")
        // The minimap: the stitched image so far, beside the area on its right, centered on it and shorter than it, 80 pt wide at most, with
        // the markerLayer over the bottom 600 of the 900 px, which is what the area shows now. It lives in the overlay window, which every
        // capture leaves out.
        let minimap = chrome.minimap, thumb = chrome.minimapThumb, markerLayer = thumb.layer!.sublayers!.first!
        require(!minimap.isHidden && minimap.frame.minX == pageBox.maxX + 8 && abs(minimap.frame.midY - pageBox.midY) <= 1 && minimap.frame.height <= pageBox.height - 8
                    && minimap.frame.width <= 80 && thumb.superview === minimap && minimap.superview === overlay.view
                    && abs(thumb.frame.height - thumb.frame.width * 900 / 1000) <= 1.5 * thumb.frame.width / 1000 + 1
                    && abs(markerLayer.frame.height / thumb.frame.height - 600.0 / 900) < 0.01 && markerLayer.frame.minY == 0,
                "the minimap sits right of the area with the markerLayer over the bottom two thirds: \(minimap.frame) \(thumb.frame) \(markerLayer.frame) \(pageBox)")
        require(minimap.window === overlay.window && overlay.window is CaptureExcluded && DisplayCapture.excludedWindowIDs().contains(CGWindowID(overlay.window.windowNumber)),
                "the minimap is in the overlay window, which captures leave out: \(overlay.window.windowNumber) \(DisplayCapture.excludedWindowIDs().sorted())")
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
        // No minimap pixel reaches the stitched image, wherever the minimap sat: it equals the fixture rows the area showed, on a 7 px lattice.
        let fixtureRows = NSBitmapImageRep(cgImage: image.cropping(to: CGRect(x: page.minX, y: page.minY, width: 1000, height: 900))!)
        func srgb(_ color: NSColor) -> [CGFloat] { let c = color.usingColorSpace(.sRGB)!; return [c.redComponent, c.greenComponent, c.blueComponent] }
        let differing = stride(from: 40, to: 900 - 40, by: 7).flatMap { y in stride(from: 40, to: 1000 - 40, by: 7).map { (x: $0, y: y) } }
            .filter { zip(srgb(stitched.colorAt(x: $0.x, y: $0.y)!), srgb(fixtureRows.colorAt(x: $0.x, y: $0.y)!)).contains { abs($0 - $1) > 0.01 } }
        require(differing.isEmpty, "the stitched image has no minimap pixels: \(differing.count) lattice points differ from the fixture, first \(differing.prefix(3))")
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

        // The minimap's spots, with a stitched image and no session: beside the area on its right, else its left, else inside its right edge,
        // and hidden when none is free (a 300 pt wide screen, the area as tall as the screen, the strip inside its bottom).
        let tall = ScrollStitcher(first: image.cropping(to: CGRect(x: 0, y: 0, width: 100, height: extent.height))!)
        func minimapSpot(_ area: CGRect) async -> CGRect? {
            overlay.scrollArea = area
            overlay.scrollThumbnail = await tall.thumbnail(fitting: CGSize(width: 72 * overlay.scale, height: area.height - 16 * overlay.scale))
            overlay.scrollHeight = Int(area.height)
            overlay.refresh()
            return minimap.isHidden ? nil : minimap.frame
        }
        open()
        let scale0 = overlay.scale
        let midArea = CGRect(x: 600, y: 300, width: 800, height: 600), atEdge = CGRect(x: extent.width - 30 * scale0 - 800, y: 300, width: 800, height: 600)
        let boxOfArea = overlay.view.viewRect
        let rightSpot = await minimapSpot(midArea), leftSpot = await minimapSpot(atEdge), insideSpot = await minimapSpot(CGRect(x: 12 * scale0, y: 300, width: extent.width - 24 * scale0, height: 600))
        require(rightSpot?.minX == boxOfArea(midArea).maxX + 8 && leftSpot?.maxX == boxOfArea(atEdge).minX - 8 && insideSpot.map { $0.maxX == extent.width / scale0 - 12 - 8 } == true,
                "the minimap takes the right of the area, the left when the right has no room, and the inside of its right edge when neither does: \(String(describing: rightSpot)) \(String(describing: leftSpot)) \(String(describing: insideSpot))")
        overlay.view.setFrameSize(CGSize(width: 300, height: overlay.view.bounds.height))
        let bottomArea = CGRect(x: 10 * scale0, y: 0, width: 280 * scale0, height: extent.height)
        require(await minimapSpot(bottomArea) == nil && minimap.isHidden,
                "with no spot free the minimap hides: \(minimap.frame) strip \(chrome.strip.frame)")
        overlay.view.setFrameSize(CGSize(width: width0, height: overlay.view.bounds.height))
        overlay.dismiss()

        // On a narrow screen the settings bar keeps only its ? button.
        open()
        overlay.view.setFrameSize(CGSize(width: 520, height: overlay.view.bounds.height))
        overlay.refresh()
        require(!chrome.topBar.isHidden && texts(in: chrome.topBar) == ["?"] && chrome.topBar.frame.width <= 520 - 16, "a 520 pt screen keeps only the bar's ? button: \(texts(in: chrome.topBar))")
        overlay.view.setFrameSize(CGSize(width: width0, height: overlay.view.bounds.height))
        overlay.dismiss()

        // The settings bar moves to the top when a drag or selection is within 24 pt of it at the bottom and not at the top, and comes
        // back; the pointer and the hover never move it, so its buttons stay within reach.
        open()
        overlay.detectionTask?.cancel()
        let halfHeight = overlay.view.bounds.height / 2, topLine = overlay.view.bounds.height - overlay.topInset - 8
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.midY))
        require(top.frame.minY == 8 && !chrome.barAtTop, "the settings bar sits at the bottom")
        overlay.bottomInset = 70
        overlay.refresh()
        require(top.frame.minY == 78 && !chrome.barAtTop, "a Dock at the bottom puts the settings bar 8 pt above it: \(top.frame)")
        overlay.bottomInset = 0
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(top.frame.minY == 8 && !chrome.barAtTop, "the pointer near the bar leaves it there")
        overlay.setWindows([CGRect(x: 600, y: extent.height - 420, width: 1200, height: 410)], names: ["Low window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 700, y: extent.height - 400))
        require(!chrome.hover.isHidden && !chrome.barAtTop, "a hovered window that reaches the bar leaves it there")
        let low = CGRect(x: 800, y: extent.height - 300, width: 600, height: 290)
        mouse(.leftMouseDown, low.origin)
        mouse(.leftMouseDragged, CGPoint(x: low.maxX, y: low.maxY))
        require(chrome.barAtTop && top.frame.maxY == topLine, "a drag that reaches the bar moves it under the top edge: \(top.frame)")
        mouse(.leftMouseUp, CGPoint(x: low.maxX, y: low.maxY))
        let lowBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.strip.isHidden && chrome.strip.frame.minY == lowBox.maxY + 8 && top.frame.minY > halfHeight,
                "a released selection at the bottom puts the strip above it and the bar at the top: \(chrome.strip.frame) \(lowBox)")
        mouse(.mouseMoved, CGPoint(x: extent.midX, y: extent.height - 20))
        require(chrome.barAtTop, "the pointer at the bottom does not pull the bar back down")
        key(53, "")
        // Within 24 pt of the bar a selection moves it; 30 pt away it does not.
        open()
        let barTop = top.frame.maxY
        for (gap, moves) in [(CGFloat(20), true), (30, false)] {
            let bottom = (overlay.view.bounds.height - barTop - gap) * overlay.scale
            overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: extent.midX - 300, y: bottom - 400, width: 600, height: 400))
            overlay.refresh()
            require(chrome.barAtTop == moves, "a selection \(gap) pt above the bar \(moves ? "moves" : "leaves") it: \(top.frame)")
        }
        key(53, "")
        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 800, y: 0, width: 600, height: 290))
        overlay.refresh()
        require(!chrome.barAtTop && top.frame.minY == 8, "a selection at the top leaves the bar at the bottom: \(top.frame)")
        // A box beside the bar that ends below its upper edge (a Dock item) gets its strip standing on that edge and its chips above it.
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 80, y: extent.height - 38 * overlay.scale, width: 200, height: 28 * overlay.scale))
        overlay.refresh()
        let dockBox = overlay.view.viewRect(overlay.selection!.rect)
        require(!chrome.barAtTop && dockBox.maxY < top.frame.maxY && chrome.strip.frame.minY == top.frame.maxY + 8 && chrome.size.frame.minY == chrome.strip.frame.maxY + 8
                    && !chrome.strip.frame.intersects(top.frame),
                "a selection below the bar's upper edge stands its strip on that edge and its chips on the strip: \(chrome.strip.frame) \(chrome.size.frame) \(top.frame) \(dockBox)")
        key(53, "")
        open()
        drag(rough)
        require(!chrome.strip.isHidden && top.frame.minY == 8, "a selection mid-screen keeps the bar home")
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
        require(!chrome.size.isHidden && !chrome.strip.isHidden && !chrome.topBar.isHidden, "the full-screen state shows the size chip, strip, and settings bar")
        overlay.topInset = 0
        overlay.refresh()
        require(guides2.bands.path!.boundingBox.maxY == overlay.view.bounds.height, "without an inset the top ruler sits at the top edge")
        overlay.dismiss()
        for key in [Pref.rulers, Pref.loupe] { defaults.set(false, forKey: key) }
        try await verifyAgentHandoff(image: image, frame: frame, overlay: overlay, require: require)
        try await verifyRecording(image: image, frame: frame, overlay: overlay, require: require)

        // Chrome keeps its distance from the object's outline: 8 pt off it outside, and 8 pt in from it when the screen leaves no room outside.
        open()
        overlay.detectionTask?.cancel()
        /// The distance from `item` to the outline `box`: to the nearest side from inside it, else the larger axis gap (negative when they overlap).
        func outlineGap(_ item: NSView, _ box: CGRect) -> CGFloat {
            let f = item.frame
            if box.contains(f) { return min(f.minX - box.minX, box.maxX - f.maxX, f.minY - box.minY, box.maxY - f.maxY) }
            return max(f.minX - box.maxX, box.minX - f.maxX, f.minY - box.maxY, box.minY - f.maxY)
        }
        let outlineCases = [("middle", CGRect(x: 600, y: 300, width: 1000, height: 600)), ("small", CGRect(x: 600, y: 300, width: 120, height: 80)),
                         ("left edge", CGRect(x: 0, y: 600, width: 500, height: 300)), ("right edge", CGRect(x: extent.width - 500, y: 600, width: 500, height: 300)),
                         ("top edge", CGRect(x: 900, y: 0, width: 700, height: 300)), ("bottom edge", CGRect(x: 900, y: extent.height - 300, width: 700, height: 300)),
                         ("edge to edge", CGRect(x: 0, y: 300, width: extent.width, height: 600)), ("full screen", extent)]
        for hovering in [false, true] {
            for (name, rect) in outlineCases {
                if hovering {
                    overlay.selection = nil
                    overlay.setWindows([rect], names: ["Edge"], pointer: CGPoint(x: frame.minX + rect.midX / overlay.scale, y: frame.maxY - rect.midY / overlay.scale))
                    mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
                } else {
                    overlay.selection = AreaSelection(extent: extent, exact: rect)
                    overlay.refresh()
                }
                let box = overlay.view.viewRect(rect)
                let shown: [(String, NSView)] = [("size", chrome.size), ("snap", chrome.snap), ("ratio", chrome.ratio), ("radius", chrome.radius), ("hover", chrome.hover), ("strip", chrome.strip)].filter { !$0.1.isHidden }
                let gaps = shown.map { ($0.0, outlineGap($0.1, box)) }
                require(!shown.isEmpty && gaps.allSatisfy { $0.1 >= 8 - 0.01 }, "a \(hovering ? "hovered" : "selected") \(name) object's chrome keeps 8 pt from its outline: \(gaps)")
            }
        }
        overlay.dismiss()

        // The dashed Frame preview is the padded card of an area or element; on a selection that matches a live window the output is the
        // window's real shadow, so no card is drawn. A frozen window or an imported image crops, so it keeps the card.
        let framedWindow = CGRect(x: 600, y: 300, width: 1000, height: 600)
        defaults.set(true, forKey: Pref.frame)
        for (name, display, frozen, card) in [("a live window", CGMainDisplayID() as CGDirectDisplayID?, false, false), ("a frozen window", CGMainDisplayID(), true, true), ("a window of an imported image", nil, false, true)] {
            overlay.present(image: image, frame: frame, displayID: display)
            overlay.detectionTask?.cancel()
            overlay.setWindows([framedWindow], names: ["Window"], ids: [1], frozen: [frozen], pointer: CGPoint(x: frame.minX, y: frame.maxY))
            overlay.selection = AreaSelection(extent: extent, exact: framedWindow)
            overlay.refresh()
            require((overlay.view.overlays.styleFrame != nil) == card, "with Frame on, the preview on \(name) draws the card: \(card)")
            overlay.selection = AreaSelection(extent: extent, exact: framedWindow.insetBy(dx: 40, dy: 40))
            overlay.refresh()
            require(overlay.view.overlays.styleFrame == OutputFrame.rect(around: framedWindow.insetBy(dx: 40, dy: 40), scale: overlay.scale, framed: true), "an area inside \(name) keeps the card preview")
            overlay.dismiss()
        }
        defaults.set(false, forKey: Pref.frame)

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
