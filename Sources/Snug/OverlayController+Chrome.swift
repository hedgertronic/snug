import AppKit
import ScreenshotCore

/// Positions and fills the on-screen chrome: the top bar, the chip row above the object and the action strip below it, the keys
/// line, the candidate list, and the keys sheet.
extension OverlayController {
    /// Whether a window click captures the shadow: the remembered preference, inverted while Option is down.
    func windowShadow(option: Bool) -> Bool { defaults.bool(forKey: Pref.shadow) != option }

    /// A click on a button presses its key, so it does what the key does in the current state.
    func wireChrome() {
        for button in chrome.buttons + [cornerChip] {
            button.onClick = { [unowned self, unowned button] in _ = handleKey(KeyCap.event(for: button.key!)) }
        }
        cornerChip.surface = true
        chrome.ratioMenu.onClose = { [unowned self] in refresh() }
    }

    /// Lights the caps of a key just pressed, for 150 ms.
    func flash(_ event: NSEvent) {
        chrome.pressed = KeyCap.pressed(by: event)
        chrome.pressTask?.cancel()
        chrome.pressTask = Task {
            try await Task.sleep(for: .milliseconds(150))
            chrome.pressed = []
            lightCaps()
        }
        lightCaps()
    }

    /// Whether `point` (view points) is on the top bar, or between the hovered element and its chips or strip: there the
    /// hover holds, so their buttons can be reached.
    func holdsHover(at point: CGPoint) -> Bool {
        guard selection == nil, let hover = view.overlays.hover else { return false }
        let box = view.viewRect(hover)
        // Each attached item and the bridge across the gap between it and the box, as wide as both.
        let attached = [chrome.hover, chrome.snap, chrome.radius, chrome.strip].filter { !$0.isHidden }.flatMap { item in
            let left = max(box.minX, item.frame.minX), right = min(box.maxX, item.frame.maxX)
            let span = item.frame.union(box)
            return [item.frame] + (right > left ? [CGRect(x: left, y: span.minY, width: right - left, height: span.height)] : [])
        }
        return !box.contains(point) && attached.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
            || !chrome.topBar.isHidden && chrome.topBar.frame.contains(point)
    }

    /// The glyphs of the modifiers held now; a cap made of exactly these is lit.
    private var heldGlyphs: Set<Character> {
        Set([(optionHeld, "\u{2325}"), (commandHeld, "\u{2318}"), (shiftHeld, "\u{21E7}")].compactMap { $0.0 ? Character($0.1) : nil })
    }

    /// Every cap is pressed while its key flashes or while exactly its modifiers are held; every button redraws in the current tint.
    private func lightCaps() {
        let held = heldGlyphs
        func light(_ view: NSView) {
            if let cap = view as? KeyCap { cap.pressed = chrome.pressed.contains(cap.text) || !held.isEmpty && Set(cap.text) == held }
            (view as? BarButton)?.apply()
            view.subviews.forEach(light)
        }
        (chrome.all + [cornerChip] + chrome.buttons).forEach(light)
    }

    /// The keys line: each hint is a label and its key caps, shown in that order.
    private var hints: [(keys: [String], label: String)] {
        if !chrome.ratioMenu.isHidden { return [(["\u{2191}\u{2193}"], "pick"), (["\u{21A9}"], "choose"), (["esc"], "close")] }
        if cutout != nil { return [(["K", "esc"], "back")] }
        if scrollArea != nil { return [([], "Scroll the app under the outline")] }
        if let armed = armedRecording {
            if let remaining = armed.remaining { return [([], "Recording in \(remaining)"), (["esc"], "cancel")] }
            return [(["\u{21A9}"], "start"), (["esc"], "cancel")]
        }
        return switch mode {
        case .text: [(["Drag"], "select text"), (["\u{21A9}"], "copy"), (["\u{21E7}", "\u{21A9}"], "rows"), (["Tab"], "links, codes"), (["\u{2325}", "\u{21A9}"], "translate"), (["F"], "all text"), (["C"], "color"), (["?"], "all keys")]
        case .capture where selection != nil:
            [(["\u{2190}\u{2192}"], "move"), (["\u{2325}"], "grow"), (["\u{2325}\u{2318}"], "shrink"), (["\u{2318}"], "next edge"), (["+", "-"], "all sides")]
        case .capture: [(["E"], "edit"), (["\u{2191}", "\u{2193}"], "bigger / smaller"), (["F"], "full screen"), (["W"], "window"), (["?"], "all keys")]
        }
    }

    /// What the arrow keys do with the modifiers held now.
    private var arrowLegend: String {
        switch (optionHeld, commandHeld) {
        case (true, true): "\u{2325}\u{2318} shrink"
        case (true, false): "\u{2325} grow"
        case (false, true): shiftHeld ? "\u{2318}\u{21E7} next edge in" : "\u{2318} next edge"
        case (false, false): shiftHeld ? "\u{21E7} move 10 px" : "move"
        }
    }

    /// "r 12", or each corner when they differ: "r 12 / 0 / 0 / 12" (top-left, top-right, bottom-left, bottom-right), in points.
    private func radiusText(_ rect: CGRect) -> String {
        let radii = cornerRadii(of: rect)
        let points = CornerRadii.corners.map { Int((radii[$0] / scale).rounded()) }
        return "r " + (Set(points).count == 1 ? "\(points[0])" : points.map(String.init).joined(separator: " / "))
    }

    func refreshChrome() {
        let c = chrome
        let bounds = view.bounds
        let topEdge = bounds.height - topInset
        let overlays = view.overlays
        let released = mode == .capture && selection != nil
        let editing = released && armedRecording == nil
        Chrome.tint = view.highlight?.color ?? .controlAccentColor
        let look = switch defaults.string(forKey: Pref.overlayAppearance)! {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil as NSAppearance?
        }
        // The keys sheet keeps its own dark material.
        if c.hints.appearance?.name != look?.name {
            for item in c.all + [cornerChip] where item !== c.help { item.appearance = look }
        }
        for item in [c.hover, c.size, c.snap, c.ratio, c.radius, c.legend, c.reading, c.status, c.strip] { item.isHidden = true }
        c.help.frame = bounds
        c.help.layoutPanel()

        // The top bar: the modes (not in cut out), view, and style (not in Text); hidden while scrolling or armed to record, and on a
        // screen too narrow for it.
        if scrollArea != nil || armedRecording != nil {
            c.topBar.isHidden = true
        } else {
            let modes = cutout == nil ? [[c.modeButtons[.capture]!, c.modeButtons[.text]!]] : []
            c.topBar.show(modes + [c.viewToggles.map(\.1)] + (mode == .text ? [] : [c.styleToggles.map(\.1)]))
            c.topBar.isHidden = c.topBar.frame.width > bounds.width - 16
        }
        for (current, button) in c.modeButtons { button.primary = current == mode }
        for (key, button) in c.viewToggles + c.styleToggles { button.lit = defaults.bool(forKey: key) }

        // The keys line, unless B hid it. Hints that do not fit drop from the end, keeping the first and "all keys".
        c.hints.isHidden = !defaults.bool(forKey: Pref.modeBar)
        if !c.hints.isHidden {
            var items = hints
            let kept = items.last?.label == "all keys" ? 1 : 0
            while true {
                c.hints.show(items.map { $0.label + $0.keys.joined() }.joined(separator: "|")) { items.map { Pill.hint($0.keys, $0.label) } }
                guard c.hints.frame.width > bounds.width - 16, items.count > kept + 1 else { break }
                items.remove(at: items.count - 1 - kept)
            }
        }

        // The top bar sits under the menu bar or notch and the keys line at the bottom. Each moves to the other edge when a drag,
        // preview, or selection reaches it there and not there; items on one edge stack inward, the bar nearer the top.
        let objects = [overlays.ghost, overlays.preview, overlays.selection].compactMap { $0 }.map(view.viewRect)
        func zone(_ item: NSView, atTop: Bool) -> CGRect {
            CGRect(x: (bounds.width - item.frame.width) / 2, y: atTop ? topEdge - 8 - item.frame.height : 32, width: item.frame.width, height: item.frame.height).insetBy(dx: -24, dy: -24)
        }
        func moves(_ item: NSView, fromTop: Bool) -> Bool {
            !item.isHidden && objects.contains { $0.intersects(zone(item, atTop: fromTop)) && !$0.intersects(zone(item, atTop: !fromTop)) }
        }
        let barAtBottom = moves(c.topBar, fromTop: true), hintsAtTop = moves(c.hints, fromTop: false)
        let topItems: [NSView] = (barAtBottom ? [] : [c.topBar]) + (hintsAtTop ? [c.hints] : [])
        let bottomItems: [NSView] = (hintsAtTop ? [] : [c.hints]) + (barAtBottom ? [c.topBar] : [])
        var top = topEdge, floor: CGFloat = 32
        var frames: [(NSView, CGRect)] = []
        for item in topItems where !item.isHidden {
            frames.append((item, CGRect(x: ((bounds.width - item.frame.width) / 2).rounded(), y: top - 8 - item.frame.height, width: item.frame.width, height: item.frame.height)))
            top = frames.last!.1.minY
        }
        for item in bottomItems where !item.isHidden {
            frames.append((item, CGRect(x: ((bounds.width - item.frame.width) / 2).rounded(), y: floor, width: item.frame.width, height: item.frame.height)))
            floor = frames.last!.1.maxY + 8
        }
        if bottomItems.allSatisfy(\.isHidden) { floor = 8 }
        let animate = !isHeadless && (barAtBottom != c.barAtBottom || hintsAtTop != c.hintsAtTop)
        c.barAtBottom = barAtBottom
        c.hintsAtTop = hintsAtTop
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                for (item, frame) in frames { item.animator().frame = frame }
            }
        } else {
            for (item, frame) in frames { item.frame = frame }
        }

        /// Attaches the strip below `box` (above when the bottom has no room, else inside), then the chip row above it (above the strip
        /// when that is above, else inside the top): `left` from the box's left edge, `right` ending at its right edge, or after `left`
        /// when they would meet, or a row higher when the screen ends first. Only the box's edges place them.
        func attach(to box: CGRect, strip: Bool, left: [NSView], right: [NSView] = []) {
            var over = box.maxY + 8
            if strip {
                let size = c.strip.frame.size
                let below = box.minY - 8 - size.height
                let y = below >= floor ? below : over + size.height <= top - 8 ? over : max(box.minY + 8, floor)
                c.strip.frame.origin = CGPoint(x: min(max(box.minX, 8), bounds.width - size.width - 8), y: y)
                if y == over { over = c.strip.frame.maxY + 8 }
            }
            guard let height = (left + right).first?.frame.height else { return }
            for chip in left + right { chip.isHidden = false }
            var y = over + height <= top - 8 ? over : min(box.maxY, top) - 8 - height
            var x = min(max(box.minX, 8), bounds.width - 8 - left.reduce(-6) { $0 + $1.frame.width + 6 })
            for chip in left {
                chip.frame.origin = CGPoint(x: x, y: y)
                x += chip.frame.width + 6
            }
            let width = right.reduce(-6) { $0 + $1.frame.width + 6 }
            var start = min(max(box.maxX - width, x), bounds.width - 8 - width)
            if start < x - 0.5 {
                start = min(max(box.maxX - width, 8), bounds.width - 8 - width)
                y += height + 6
            }
            for chip in right {
                chip.frame.origin = CGPoint(x: start, y: y)
                start += chip.frame.width + 6
            }
        }
        func sizeChip(_ rect: CGRect) -> Pill {
            let text = "\(Int(rect.width)) x \(Int(rect.height))"
            c.size.show(text) { [NSTextField(text, size: 12, mono: true, color: .chromeText)] }
            return c.size
        }
        func radiusChip(_ rect: CGRect) -> Pill {
            let text = radiusText(rect)
            c.radius.show(text) { [NSTextField(text, size: 12, mono: true, color: .chromeText), KeyCap("["), KeyCap("]")] }
            return c.radius
        }
        /// The capture strip: Copy, Save, and Text, then Scroll, Record, and Cut out, which are faded when they cannot run on `area`.
        func captureStrip(_ area: CGRect) {
            c.strip.show([[c.copy, c.save, c.text], [c.scroll, c.record, c.cutout]])
            c.scroll.isEnabled = (scrollFrames != nil || displayID != nil) && area != extent && windows.contains { $0.insetBy(dx: -2, dy: -2).contains(area) }
            c.record.isEnabled = displayID != nil
        }

        if let cutout {
            let subjects = cutout.subjects.count > 1 ? [c.subject] : []
            c.subject.setTitle(cutout.label)
            c.crop.lit = cutout.cropped
            c.strip.show([subjects + [c.crop], [c.save, c.copy]])
            attach(to: view.viewRect(cutout.frame), strip: true, left: [sizeChip(cutout.frame)])
        } else if let scrollArea {
            let height = scrollHeight >= ScrollStitcher.maximumHeight ? "\(ScrollStitcher.maximumHeight) px, the limit" : "\(scrollHeight) px"
            c.scrolled.setTitle("Scrolling \(height)")
            c.strip.show([[c.scrolled], [c.cancel, c.done]])
            attach(to: view.viewRect(scrollArea), strip: true, left: [])
        } else if let armed = armedRecording, let rect = selection?.rect {
            let countIn = defaults.integer(forKey: Pref.recordCountIn)
            c.cursor.lit = defaults.bool(forKey: Pref.recordCursor)
            c.countIn.setTitle(countIn > 0 ? "\(countIn)-second count" : "Count-in")
            c.countIn.lit = countIn > 0
            c.strip.show(armed.remaining == nil ? [[c.cursor, c.countIn], [c.cancel, c.start]] : [[c.cancel]])
            attach(to: view.viewRect(rect), strip: true, left: [sizeChip(rect)])
        } else if mode == .capture, let rect = overlays.selection ?? overlays.preview ?? overlays.ghost {
            // A drag or selection: its size and Snap, which reads Snapped or Exact once released; a selection adds the ratio and radius.
            let snapped = selection.map { $0.fits.count > 1 && $0.rect != $0.exact }
            c.snap.setTitle(snapped.map { $0 ? "Snapped" : "Exact" } ?? "Snap")
            c.snap.lit = snapped ?? (snapEnabled && !bypassSnap)
            var right: [NSView] = []
            if editing {
                c.ratioButton.setTitle(ratioReadout)
                c.lock.lit = ratioLocked
                c.ratio.show(ratioReadout) { [c.ratioButton, c.ratioDivider, c.lock] }
                right = [c.ratio, radiusChip(rect)]
                captureStrip(rect)
            }
            attach(to: view.viewRect(rect), strip: editing, left: [sizeChip(rect), c.snap], right: right)
        } else if mode == .capture, let rect = overlays.hover {
            // Hovering: the element's name and size, and Snap; the radius once `[` or `]` changed it.
            let hovered = session!.selected!
            let isWindow = hovered.kind == .window
            let index = isWindow ? Int(hovered.id.dropFirst("window-".count))! : 0
            let name = switch hovered.kind {
            case .window: windowNames.indices.contains(index) ? windowNames[index] : "Window"
            case .display: "Full screen"
            default: hovered.label
            }
            let size = "\(Int(rect.width)) x \(Int(rect.height))" + (isWindow && windowShadow(option: optionHeld) ? "  +  shadow" : "")
            c.hover.show("\(name)|\(size)") {
                [NSTextField(name, size: 12, weight: .semibold, color: .chromeText), NSTextField(size, size: 12, mono: true, color: NSColor.chromeText.withAlphaComponent(0.65))]
            }
            c.snap.setTitle("Snap")
            c.snap.lit = snapEnabled
            captureStrip(rect)
            attach(to: view.viewRect(rect), strip: true, left: [c.hover, c.snap] + (editedRadii[rect] == nil ? [] : [radiusChip(rect)]))
        }

        // While the pointer rests inside a released selection, or a modifier is held, each side's arrow key sits just outside the side's
        // midpoint, pushed further out past the chips or strip in the way, and inside the side when that leaves the screen; the legend
        // in the middle says what the arrows do.
        let resting = draggedRect == nil && selection?.rect.contains(pointer) == true
        let showsEdgeKeys = editing && (optionHeld || commandHeld || resting)
        let obstacles: [NSView] = [c.strip, c.size, c.snap, c.ratio, c.radius].filter { !$0.isHidden }
        for (index, pill) in c.sideHints.enumerated() {
            pill.isHidden = true
            guard showsEdgeKeys, let rect = overlays.selection else { continue }
            let arrow = ["\u{2190}", "\u{2192}", "\u{2191}", "\u{2193}"][index]
            pill.show(arrow) { [KeyCap(arrow)] }
            let box = view.viewRect(rect), size = pill.frame.size, gap: CGFloat = 6
            let midX = (box.midX - size.width / 2).rounded(), midY = (box.midY - size.height / 2).rounded()
            var outside: CGRect
            var inside: CGPoint
            switch index {
            case 0: (outside, inside) = (CGRect(origin: CGPoint(x: box.minX - gap - size.width, y: midY), size: size), CGPoint(x: box.minX + gap, y: midY))
            case 1: (outside, inside) = (CGRect(origin: CGPoint(x: box.maxX + gap, y: midY), size: size), CGPoint(x: box.maxX - gap - size.width, y: midY))
            case 2: (outside, inside) = (CGRect(origin: CGPoint(x: midX, y: box.maxY + gap), size: size), CGPoint(x: midX, y: min(box.maxY, top) - gap - size.height))
            default: (outside, inside) = (CGRect(origin: CGPoint(x: midX, y: box.minY - gap - size.height), size: size), CGPoint(x: midX, y: box.minY + gap))
            }
            for obstacle in obstacles where obstacle.frame.intersects(outside) {
                switch index {
                case 0: outside.origin.x = obstacle.frame.minX - gap - size.width
                case 1: outside.origin.x = obstacle.frame.maxX + gap
                case 2: outside.origin.y = obstacle.frame.maxY + gap
                default: outside.origin.y = obstacle.frame.minY - gap - size.height
                }
            }
            for obstacle in obstacles where obstacle.frame.intersects(CGRect(origin: inside, size: size)) {
                switch index {
                case 0: inside.x = obstacle.frame.maxX + gap
                case 1: inside.x = obstacle.frame.minX - gap - size.width
                case 2: inside.y = obstacle.frame.minY - gap - size.height
                default: inside.y = obstacle.frame.maxY + gap
                }
            }
            pill.frame.origin = CGRect(x: 4, y: 4, width: bounds.width - 8, height: top - 8).contains(outside) ? outside.origin : inside
        }
        if showsEdgeKeys, let rect = overlays.selection {
            let legend = arrowLegend
            c.legend.show(legend) { [NSTextField(legend, size: 11, weight: .semibold, color: .chromeText)] }
            let box = view.viewRect(rect)
            c.legend.frame.origin = CGPoint(x: (box.midX - c.legend.frame.width / 2).rounded(), y: (box.midY - c.legend.frame.height / 2).rounded())
            // Under the top arrow or over the bottom one when they come inside that far.
            if c.sideHints[2].frame.intersects(c.legend.frame) { c.legend.frame.origin.y = c.sideHints[2].frame.minY - 6 - c.legend.frame.height }
            if c.sideHints[3].frame.intersects(c.legend.frame) { c.legend.frame.origin.y = c.sideHints[3].frame.maxY + 6 }
        }

        // The keys of a hovered corner dot stack under its "All corners" chip (over it at the bottom corners), flush with the chip's outer side.
        c.cornerKeys.isHidden = cornerChip.isHidden
        if !cornerChip.isHidden, let corner = hoveredCorner {
            c.cornerKeys.show("corner") { [Pill.hint(["[", "]"], "radius"), Pill.hint(["\u{2325}"], "one corner")] }
            let chip = cornerChip.frame, size = c.cornerKeys.frame.size
            c.cornerKeys.frame.origin = CGPoint(x: min(max(corner.movesLeft ? chip.maxX - size.width : chip.minX, 8), bounds.width - size.width - 8),
                                                y: corner.movesTop ? chip.minY - 4 - size.height : chip.maxY + 4)
        }

        // The key caps of the faint Up and Down outlines sit inside their top-left corners.
        for (cap, rect) in [(c.upHint, overlays.upHint), (c.downHint, overlays.downHint)] {
            cap.isHidden = rect == nil
            if let rect {
                let box = view.viewRect(rect)
                cap.frame.origin = CGPoint(x: box.minX + 4, y: box.maxY - cap.frame.height - 4)
            }
        }

        if let rect = text.reading {
            c.reading.show("reading") { [NSTextField("Reading text...", size: 12, color: .chromeText)] }
            let box = view.viewRect(rect)
            c.reading.frame.origin = CGPoint(x: min(max(box.midX - c.reading.frame.width / 2, 8), bounds.width - c.reading.frame.width - 8),
                                             y: min(max(box.midY - c.reading.frame.height / 2, 8), top - c.reading.frame.height - 8))
        }

        if let notice = text.notice {
            c.status.show(notice) { [NSTextField(notice, size: 12, color: .chromeText)] }
            c.status.frame.origin = CGPoint(x: ((bounds.width - c.status.frame.width) / 2).rounded(), y: floor)
        }

        c.list.isHidden = !(overlays.hover != nil && selection == nil && defaults.bool(forKey: Pref.candidates))
        if !c.list.isHidden, let session {
            let allow = displayID != nil && !isHeadless && !AXIsProcessTrusted()
            c.list.update(session.shortlist, parents: session.parents, current: session.selected?.id, onAllowAccessibility: allow ? { Accessibility.requestTrust() } : nil)
            let box = view.viewRect(overlays.hover!)
            let width = c.list.frame.width, height = c.list.frame.height
            let x = box.maxX + 12 + width <= bounds.width - 8 ? box.maxX + 12 : (box.minX - 12 - width >= 8 ? box.minX - 12 - width : 12)
            c.list.frame.origin = CGPoint(x: x, y: min(max(box.maxY - height, 8), top - height - 8))
        }
        lightCaps()
    }
}
