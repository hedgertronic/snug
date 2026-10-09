import AppKit
import ScreenshotCore

/// Positions and fills the on-screen chrome: bars, hints, badges, hover title, candidate list, and keys sheet.
extension OverlayController {
    /// Whether a window click captures the shadow: the remembered preference, inverted while Option is down.
    func windowShadow(option: Bool) -> Bool { defaults.bool(forKey: Pref.shadow) != option }

    private var hints: [String] {
        let shadowHint = windowShadow(option: false) ? "Option-click: no shadow" : "Option-click: with shadow"
        if scrollArea != nil {
            let height = scrollHeight >= ScrollStitcher.maximumHeight ? "\(ScrollStitcher.maximumHeight) px, the limit" : "\(scrollHeight) px"
            return ["Scroll to capture more: \(height)", "Return: done", "Esc: cancel"]
        }
        return switch mode {
        case .text: ["Drag: select text", "Return: copy", "Option-Return: translate", "F: all text", "C: color", "A: back to capture", "?: keys"]
        case .capture where selection != nil: ["Handles: resize", "Arrows: nudge", "Shift-Return: copy text", "G: scroll capture", "Tab: other fits", "Esc: cancel"]
        case .capture: [snapEnabled ? "Pause to snap, S: off" : "S: snap back on", "Click: capture", "Up / Down: bigger / smaller", "Option: exact", shadowHint, "F: full screen", "?: keys"]
        }
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

        c.bottomBar.update(mode: mode, defaults: defaults, style: style)
        c.bottomBar.isHidden = released || scrollArea != nil || !defaults.bool(forKey: Pref.modeBar)
        c.styleBar.style = style
        c.styleBar.isHidden = !released
        var items = hints
        let kept = items.last == "?: keys" ? 1 : 0
        while true {
            c.hints.show(items.joined(separator: "|")) { items.map { NSTextField($0, size: 12, color: NSColor.white.withAlphaComponent(0.92)) } }
            guard c.hints.frame.width > bounds.width - 16, items.count > kept + 1 else { break }
            items.remove(at: items.count - 1 - kept)
        }
        // The bars and the hint strip stack inward from the bottom edge, or from just under the menu bar or notch.
        let stack: [NSView] = released ? [c.hints, c.styleBar] : c.bottomBar.isHidden ? [c.hints] : [c.bottomBar, c.hints]
        func layout(atTop: Bool) -> [CGRect] {
            var edge = atTop ? topEdge - 8 : 32
            return stack.map {
                let frame = CGRect(x: ((bounds.width - $0.frame.width) / 2).rounded(), y: atTop ? edge - $0.frame.height : edge, width: $0.frame.width, height: $0.frame.height)
                edge = atTop ? frame.minY - (released ? 6 : 8) : frame.maxY + (released ? 6 : 8)
                return frame
            }
        }
        /// Within 24 pt of the bottom stack: the pointer (not once released, when the style bar must stay clickable), or a drag, preview,
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
        func place(_ pills: [Pill], near box: CGRect, above: Bool) {
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

        if mode != .text, let rect = overlays.selection ?? overlays.preview ?? overlays.ghost {
            let size = "\(Int(rect.width)) x \(Int(rect.height))"
            c.size.show(size) { [NSTextField(size, size: 12, mono: true, color: .white)] }
            var pills = [c.size]
            var status: (text: String, dot: NSColor)?
            if mode == .capture {
                if let selection {
                    status = selection.fits.count > 1 && selection.rect != selection.exact
                        ? ("Snapped - S: exact, Tab: other fits", .controlAccentColor)
                        : (snapEnabled ? ("Exact - Tab: fits", .white) : ("Exact, snap off - S: best fit", .white))
                } else if overlays.ghost != nil {
                    if snapPreview != nil {
                        status = ("Snap ready: release to take it, Tab for others", .controlAccentColor)
                    } else if !snapEnabled || bypassSnap {
                        status = ("Snap off: exact drag", .white)
                    }
                }
            }
            if let status {
                c.status.show(status.text) {
                    let dot = Dot(status.dot)
                    return [dot, NSTextField(status.text, size: 12, color: .white)]
                }
                pills.append(c.status)
            }
            place(pills, near: view.viewRect(rect), above: false)
        }

        if mode == .capture, selection == nil, let rect = overlays.hover {
            let hovered = session!.selected!
            let isWindow = hovered.kind == .window
            let index = isWindow ? Int(hovered.id.dropFirst("window-".count))! : 0
            let name = switch hovered.kind {
            case .window: windowNames.indices.contains(index) ? windowNames[index] : "Window"
            case .display: "Full screen"
            default: hovered.label.capitalized
            }
            let size = "\(Int(rect.width)) x \(Int(rect.height))" + (isWindow && windowShadow(option: optionHeld) ? "  +  shadow" : "")
            c.hover.show("\(name)|\(size)|\(isWindow)") {
                [NSTextField(name, size: 15, weight: .semibold, color: .white), NSTextField(size, size: 12, mono: true, color: NSColor.white.withAlphaComponent(0.7))]
                    + (isWindow ? [NSTextField("Click to capture this window", size: 12, color: NSColor.white.withAlphaComponent(0.92))] : [])
            }
            let box = view.viewRect(rect)
            if box.width >= c.hover.frame.width + 16 && box.height >= c.hover.frame.height + 16 { centered(c.hover, in: box) }
            else { place([c.hover], near: box, above: false) }
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
