import AppKit
import ScreenshotCore

/// Positions and fills the on-screen chrome: bars, hints, badges, hover title, candidate list, and keys sheet.
extension OverlayController {
    /// Whether a window click captures the shadow: the remembered preference, inverted while Option is down.
    func windowShadow(option: Bool) -> Bool { defaults.bool(forKey: Pref.shadow) != option }

    /// The glyphs of the modifiers held now; hint key caps made of them fill with the accent.
    private var heldGlyphs: Set<Character> {
        Set([(optionHeld, "\u{2325}"), (commandHeld, "\u{2318}"), (shiftHeld, "\u{21E7}")].compactMap { $0.0 ? Character($0.1) : nil })
    }

    /// The hint row: each hint is a label and its key caps, shown in that order.
    private var hints: [(keys: [String], label: String)] {
        if let cutout {
            return [([], cutout.label)] + (cutout.subjects.count > 1 ? [(["Tab"], "next subject")] : [])
                + [(["\u{21A9}"], "copy"), (["\u{2318}S"], "save"), (["K"], "back")]
        }
        if scrollArea != nil {
            let height = scrollHeight >= ScrollStitcher.maximumHeight ? "\(ScrollStitcher.maximumHeight) px, the limit" : "\(scrollHeight) px"
            return [([], "Scroll to capture more: \(height)"), (["\u{21A9}"], "done"), (["esc"], "cancel")]
        }
        if let armed = armedRecording {
            if let remaining = armed.remaining { return [([], "Recording in \(remaining)"), (["esc"], "cancel")] }
            let countIn = defaults.integer(forKey: Pref.recordCountIn)
            return [(["\u{21A9}"], "start"), (["H"], armed.showsCursor ? "cursor on" : "cursor off"),
                    ([], countIn > 0 ? "count-in \(countIn) s" : "count-in off"), (["esc"], "cancel")]
        }
        return switch mode {
        case .text: [(["Drag"], "select text"), (["\u{21A9}"], "copy"), (["\u{21E7}", "\u{21A9}"], "rows"), (["Tab"], "links, codes"), (["\u{2325}", "\u{21A9}"], "translate"), (["F"], "all text"), (["C"], "color"), (["?"], "all keys")]
        case .capture where selection != nil:
            // The resize hint follows the held modifiers: Option grows, Option-Command shrinks; the side arrows appear in place.
            [optionHeld && commandHeld ? (["\u{2325}", "\u{2318}"], "shrink") : (["\u{2325}"], optionHeld ? "grow" : "resize"),
             (["\u{21E7}"], "keep ratio, axis"), (["esc"], "cancel")]
        case .capture: [(["Click"], "capture"), (["E"], "edit"), (["\u{2191}", "\u{2193}"], "bigger / smaller"), (["F"], "full screen"), (["W"], "window"), (["?"], "all keys")]
        }
    }

    /// Fills the ratio chip: the readout with P, which opens the ratio menu, then the lock with Shift-P, which locks or unlocks the
    /// current ratio. Both take clicks.
    private func fillRatioChip(_ readout: String) {
        let menu = BarButton(readout, key: "P", height: 22, size: 12)
        let lock = BarButton("", key: "\u{21E7}P", symbol: ratioLocked ? ("lock.fill", "Ratio locked") : ("lock.open", "Ratio unlocked"), height: 22, size: 12)
        let text = NSColor.white.withAlphaComponent(0.92)
        menu.style(fill: NSColor.white.withAlphaComponent(0.12), text: text)
        lock.style(fill: ratioLocked ? .controlAccentColor : NSColor.white.withAlphaComponent(0.12), text: text, bold: ratioLocked)
        menu.onClick = { [unowned self] in showRatioMenu() }
        lock.onClick = { [unowned self] in
            toggleRatioLock()
            refresh()
        }
        chrome.ratio.show(readout + (ratioLocked ? "|locked" : "")) { [menu, lock] }
    }

    func refreshChrome() {
        let c = chrome
        let bounds = view.bounds
        let topEdge = bounds.height - topInset
        var top = topEdge
        let overlays = view.overlays
        let released = mode == .capture && selection != nil
        for pill in [c.hover, c.size, c.status, c.reading] { pill.isHidden = true }
        c.help.frame = bounds
        c.help.layoutPanel()

        c.bottomBar.update(mode: mode, defaults: defaults)
        c.bottomBar.isHidden = released || scrollArea != nil || cutout != nil || !defaults.bool(forKey: Pref.modeBar)
        c.actionBar.framed = framed
        c.actionBar.snapped = snapEnabled
        c.actionBar.rounded = defaults.bool(forKey: Pref.roundCorners)
        c.actionBar.shadowed = defaults.bool(forKey: Pref.shadow)
        c.actionBar.isHidden = !released
        // Hints that do not fit drop from the end, keeping the first and "all keys".
        var items = hints
        let held = heldGlyphs
        let kept = items.last?.label == "all keys" ? 1 : 0
        while true {
            c.hints.show(items.map { $0.label + $0.keys.joined() }.joined(separator: "|") + String(held.sorted())) {
                items.map { Pill.chip($0.keys, $0.label, held: held) }
            }
            guard c.hints.frame.width > bounds.width - 16, items.count > kept + 1 else { break }
            items.remove(at: items.count - 1 - kept)
        }
        // The bar and the hint row stack inward from the bottom edge, or from just under the menu bar or notch.
        let stack: [NSView] = c.bottomBar.isHidden ? [c.hints] : [c.bottomBar, c.hints]
        func layout(atTop: Bool) -> [CGRect] {
            var edge = atTop ? topEdge - 8 : 32
            return stack.map {
                let frame = CGRect(x: ((bounds.width - $0.frame.width) / 2).rounded(), y: atTop ? edge - $0.frame.height : edge, width: $0.frame.width, height: $0.frame.height)
                edge = atTop ? frame.minY - 8 : frame.maxY + 8
                return frame
            }
        }
        /// Within 24 pt of the bottom stack: the pointer (not once released, when the stack only holds hints), or a drag, preview,
        /// hover, or selection rectangle, unless that rectangle also reaches the top stack.
        let zones = [false, true].map { layout(atTop: $0).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -24) }
        let pointerView = CGPoint(x: pointer.x / scale, y: bounds.height - pointer.y / scale)
        let atTop = (!released && zones[0].contains(pointerView))
            || [overlays.ghost, overlays.preview, overlays.selection, overlays.hover].compactMap { $0 }.map(view.viewRect).contains { $0.intersects(zones[0]) && !$0.intersects(zones[1]) }
        let frames = layout(atTop: atTop)
        let animate = !isHeadless && atTop != c.atTop
        c.atTop = atTop
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                for (item, frame) in zip(stack, frames) { item.animator().frame = frame }
            }
        } else {
            for (item, frame) in zip(stack, frames) { item.frame = frame }
        }
        let floor = atTop ? 8 : frames[stack.firstIndex(of: c.hints)!].maxY + 8
        if atTop { top = frames.map(\.minY).min()! }

        /// Left-aligns `pills` next to `box` with an 8 pt gap: below it (or above, when `above`) if there is room, else the other side, else inside.
        func place(_ pills: [NSView], near box: CGRect, above: Bool) {
            let height = pills[0].frame.height
            let width = pills.reduce(0) { $0 + $1.frame.width } + 6 * CGFloat(pills.count - 1)
            let below = box.minY - 8 - height, over = box.maxY + 8
            let fitsBelow = below >= floor, fitsAbove = over + height <= top - 8
            let options = above ? [(over, fitsAbove), (below, fitsBelow)] : [(below, fitsBelow), (over, fitsAbove)]
            let y = options.first { $0.1 }?.0 ?? top - height - 8
            var x = min(max(box.minX, 8), bounds.width - width - 8)
            for pill in pills {
                pill.frame.origin = CGPoint(x: x, y: y)
                x += pill.frame.width + 6
            }
        }
        func centered(_ pill: Pill, in box: CGRect) {
            pill.frame.origin = CGPoint(x: min(max(box.midX - pill.frame.width / 2, 8), bounds.width - pill.frame.width - 8),
                                        y: min(max(box.midY - pill.frame.height / 2, 8), top - pill.frame.height - 8))
        }

        // A released selection: the action bar attached below it (above when the bottom has no room, else inside), the badges above.
        var anchor: CGRect?
        if released, let rect = overlays.selection {
            let box = view.viewRect(rect)
            let bar = c.actionBar.frame.size
            let below = box.minY - 8 - bar.height, over = box.maxY + 8
            let y = below >= floor ? below : over + bar.height <= top - 8 ? over : max(box.minY + 8, floor)
            c.actionBar.frame.origin = CGPoint(x: min(max(box.minX, 8), bounds.width - bar.width - 8), y: y)
            anchor = y == over || y == below ? box.union(c.actionBar.frame) : box
        }

        if mode != .text, let rect = overlays.selection ?? overlays.preview ?? overlays.ghost ?? (radiusReadout == nil ? nil : overlays.hover) {
            let size = radiusReadout ?? "\(Int(rect.width)) x \(Int(rect.height))"
            c.size.show(size) { [NSTextField(size, size: 12, mono: true, color: .white)] }
            var pills: [NSView] = [c.size]
            var status: (text: String, dot: NSColor)?
            if mode == .capture {
                if let selection {
                    status = selection.fits.count > 1 && selection.rect != selection.exact
                        ? ("Snapped", .controlAccentColor)
                        : (snapEnabled ? ("Exact", .white) : ("Exact, snap off", .white))
                } else if overlays.ghost != nil {
                    if snapPreview != nil {
                        status = ("Snap ready: release to take it, Tab for others", .controlAccentColor)
                    } else if !snapEnabled || bypassSnap {
                        status = ("Snap off: exact drag", .white)
                    }
                }
            }
            if ratioLocked {
                status = (status.map { "\($0.text), Ratio locked" } ?? "Ratio locked", status?.dot ?? .white)
            }
            if let status {
                c.status.show(status.text) {
                    let dot = Dot(status.dot)
                    return [dot, NSTextField(status.text, size: 12, color: .white)]
                }
                pills.append(c.status)
            }
            place(pills, near: anchor ?? view.viewRect(rect), above: released)
        }

        // Editing a released selection (not armed to record): the ratio chip right-aligned above it (above the action bar when that is
        // above, after the badges when they are in the way, inside the top when there is no room), and the Live Text button inside the
        // bottom-right corner, past the corner dot, lifted over any chrome in the way and hidden when the selection cannot hold it.
        let editing = released && armedRecording == nil
        c.ratio.isHidden = !editing
        c.textButton.isHidden = true
        if editing, let rect = overlays.selection {
            let box = view.viewRect(rect)
            fillRatioChip("ratio \(ratioReadout)")
            let chip = c.ratio.frame.size
            let over = (anchor ?? box).maxY + 8
            var origin = CGPoint(x: min(max(box.maxX - chip.width, 8), bounds.width - chip.width - 8),
                                 y: over + chip.height <= top - 8 ? over : min(box.maxY, top) - 8 - chip.height)
            // On the size badge's row, centered on it.
            if !c.size.isHidden, abs(c.size.frame.minY - origin.y) < 1 { origin.y = (c.size.frame.midY - chip.height / 2).rounded() }
            let badges = [c.size, c.status].filter { !$0.isHidden }.reduce(CGRect.null) { $0.union($1.frame) }
            if badges.intersects(CGRect(origin: origin, size: chip)) {
                origin = badges.maxX + 6 + chip.width <= bounds.width - 8 ? CGPoint(x: badges.maxX + 6, y: origin.y) : CGPoint(x: origin.x, y: badges.maxY + 6)
            }
            c.ratio.frame.origin = origin

            let dot = view.viewRect(CGRect(origin: cornerRadii(of: rect).dot(of: .bottomRight, in: rect, minimumInset: 8 * scale), size: .zero)).origin
            let inset = box.maxX - dot.x + 8, button = c.textButton.frame.size
            var frame = CGRect(x: box.maxX - inset - button.width, y: box.minY + inset, width: button.width, height: button.height)
            for obstacle in [c.actionBar, c.hints, c.size, c.status, c.ratio] where !obstacle.isHidden && obstacle.frame.intersects(frame) {
                frame.origin.y = obstacle.frame.maxY + 8
            }
            c.textButton.isHidden = frame.minX < box.minX + inset || frame.maxY > box.maxY - inset
            c.textButton.frame = frame
        }

        // While the pointer rests inside a released selection, or Option is held, each side's arrow key sits just outside the side's
        // midpoint, pushed further out past the action bar or a badge in the way, and inside the side when that leaves the screen, past
        // the ratio chip or Live Text button in the way. The radius keys sit outside the top-right corner.
        let resting = draggedRect == nil && selection?.rect.contains(pointer) == true
        let showsEdgeKeys = editing && (optionHeld || resting)
        for (index, pill) in c.sideHints.enumerated() {
            pill.isHidden = true
            guard showsEdgeKeys, let rect = overlays.selection else { continue }
            let arrow = ["\u{2190}", "\u{2192}", "\u{2191}", "\u{2193}"][index]
            pill.show(arrow) { [KeyCap(arrow, color: .white)] }
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
            for obstacle in [c.actionBar, c.size, c.status, c.ratio] where !obstacle.isHidden && obstacle.frame.intersects(outside) {
                switch index {
                case 0: outside.origin.x = obstacle.frame.minX - gap - size.width
                case 1: outside.origin.x = obstacle.frame.maxX + gap
                case 2: outside.origin.y = obstacle.frame.maxY + gap
                default: outside.origin.y = obstacle.frame.minY - gap - size.height
                }
            }
            for obstacle in [c.ratio, c.textButton] where !obstacle.isHidden && obstacle.frame.intersects(CGRect(origin: inside, size: size)) {
                switch index {
                case 0: inside.x = obstacle.frame.maxX + gap
                case 1: inside.x = obstacle.frame.minX - gap - size.width
                case 2: inside.y = obstacle.frame.minY - gap - size.height
                default: inside.y = obstacle.frame.maxY + gap
                }
            }
            pill.frame.origin = CGRect(x: 4, y: 4, width: bounds.width - 8, height: top - 8).contains(outside) ? outside.origin : inside
        }
        c.radiusHint.isHidden = true
        if showsEdgeKeys, cornerChip.isHidden, let rect = overlays.selection {
            c.radiusHint.show("radius") { [Pill.chip(["[", "]"], "radius")] }
            // On the ratio chip's row when the chip is above the selection, after it.
            let box = view.viewRect(rect), chip = c.ratio.frame, size = c.radiusHint.frame.size
            let origin = chip.minY > box.maxY ? CGPoint(x: max(box.maxX, chip.maxX) + 6, y: chip.midY - size.height / 2) : CGPoint(x: box.maxX + 6, y: box.maxY + 6)
            let frame = CGRect(origin: origin, size: size)
            c.radiusHint.frame = frame
            c.radiusHint.isHidden = !CGRect(x: 4, y: 4, width: bounds.width - 8, height: top - 8).contains(frame)
                || ([c.ratio, c.size, c.status, c.actionBar] + c.sideHints).contains { !$0.isHidden && $0.frame.intersects(frame) }
        }

        // The keys of a hovered corner dot stack under its "All corners" chip (over it at the bottom corners), flush with the chip's outer side.
        c.cornerKeys.isHidden = cornerChip.isHidden
        if !cornerChip.isHidden, let corner = hoveredCorner {
            c.cornerKeys.show("corner" + String(held.sorted())) { [Pill.chip(["[", "]"], "radius"), Pill.chip(["\u{2325}"], "one corner", held: held)] }
            let chip = cornerChip.frame, size = c.cornerKeys.frame.size
            c.cornerKeys.frame.origin = CGPoint(x: min(max(corner.movesLeft ? chip.maxX - size.width : chip.minX, 8), bounds.width - size.width - 8),
                                                y: corner.movesTop ? chip.minY - 4 - size.height : chip.maxY + 4)
        }

        if mode == .capture, selection == nil, let rect = overlays.hover {
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
                let divider = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 16))
                divider.wantsLayer = true
                divider.layer!.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                return [NSTextField(name, size: 13, weight: .semibold, color: .white), NSTextField(size, size: 11, weight: .medium, mono: true, color: NSColor.white.withAlphaComponent(0.65)),
                        divider, Pill.chip(["\u{21A9}"], "copy"), Pill.chip(["\u{2318}S"], "save")]
            }
            place([c.hover], near: view.viewRect(rect), above: false)
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
            c.reading.show("reading") { [NSTextField("Reading text...", size: 12, color: .white)] }
            centered(c.reading, in: view.viewRect(rect))
        }

        if let notice = text.notice {
            c.status.show(notice) { [NSTextField(notice, size: 12, color: .white)] }
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
    }
}
