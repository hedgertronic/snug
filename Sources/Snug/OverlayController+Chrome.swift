import AppKit
import ScreenshotCore

/// Positions and fills the on-screen chrome: bars, hints, badges, hover title, candidate list, and keys sheet.
extension OverlayController {
    private var hints: [String] {
        switch mode {
        case .text: ["\u{21A9}: copy text", "\u{21E7}\u{21A9}: copy as table", "Tab: links", "A: back to area"]
        case .element: ["Click: copy", "Drag: area", "Tab: next candidate", "Up / Down: bigger / smaller", "1-5: pick", "?: keys"]
        case .area where selection != nil: ["Handles: resize", "Arrows: nudge", "Tab: other fits", "\u{238B}: cancel"]
        case .area: [snapEnabled ? "Pause to snap" : "S: snap back on", "\u{21A9}: copy", "\u{2325}: exact", "Click: window", "\u{2325}-click: no shadow", "F: full screen", "?: keys"]
        }
    }

    func refreshChrome() {
        let c = chrome
        let bounds = view.bounds
        let top = bounds.height - topInset
        let overlays = view.overlays
        let released = mode == .area && selection != nil
        for pill in [c.hover, c.size, c.status, c.count, c.table, c.reading] { pill.isHidden = true }
        c.help.frame = bounds
        c.help.layoutPanel()

        func centered(_ item: NSView, y: CGFloat) {
            item.frame.origin = CGPoint(x: ((bounds.width - item.frame.width) / 2).rounded(), y: y)
        }

        c.bottomBar.update(mode: mode, elementEnabled: defaults.bool(forKey: Pref.elementMode), defaults: defaults, style: style)
        c.bottomBar.isHidden = released || !defaults.bool(forKey: Pref.modeBar)
        c.styleBar.style = style
        c.styleBar.isHidden = !released
        let items = hints
        c.hints.show(items.joined(separator: "|")) { items.map { NSTextField($0, size: 12, color: NSColor.white.withAlphaComponent(0.92)) } }
        if released {
            centered(c.hints, y: 32)
            centered(c.styleBar, y: c.hints.frame.maxY + 6)
        } else {
            centered(c.bottomBar, y: 32)
            centered(c.hints, y: c.bottomBar.isHidden ? 32 : c.bottomBar.frame.maxY + 8)
        }
        let floor = c.hints.frame.maxY + 8

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
            if mode == .area {
                if let selection {
                    status = selection.fits.count > 1 && selection.rect != selection.exact
                        ? ("Snapped - Tab: other fits", .controlAccentColor) : ("Exact - Tab: fits", .white)
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

        if mode == .area, selection == nil, let rect = overlays.hover {
            let name = windows.firstIndex(of: rect).flatMap { windowNames.indices.contains($0) ? windowNames[$0] : nil } ?? "Window"
            let size = "\(Int(rect.width)) x \(Int(rect.height))" + (optionHeld ? "" : "  +  shadow")
            c.hover.show("\(name)|\(size)") {
                [NSTextField(name, size: 15, weight: .semibold, color: .white), NSTextField(size, size: 12, mono: true, color: NSColor.white.withAlphaComponent(0.7)),
                 NSTextField("Click to capture this window", size: 12, color: NSColor.white.withAlphaComponent(0.92))]
            }
            centered(c.hover, in: view.viewRect(rect))
        }

        if mode == .text, let rect = text.rect {
            let box = view.viewRect(rect)
            if let result = text.result {
                let rows = TextLayout.rows(result.lines)
                let columns = rows.map(\.count).max() ?? 0
                let label = "\(rows.count) \(rows.count == 1 ? "line" : "lines")" + (columns > 1 ? ", \(columns) columns" : "")
                c.count.show(label) { [NSTextField(label, size: 12, weight: .semibold, color: .white)] }
                var pills = [c.count]
                if columns > 1 {
                    c.table.show("table") { [NSTextField("Looks like a table", size: 12, color: .white)] }
                    pills.append(c.table)
                }
                place(pills, near: box, above: true)
            } else if textTask != nil {
                c.reading.show("reading") { [NSTextField("Reading text...", size: 12, color: .white)] }
                centered(c.reading, in: box)
            }
        }

        c.list.isHidden = !(mode == .element && !listHidden && session != nil)
        if !c.list.isHidden, let session {
            let allow = displayID != nil && !isHeadless && !AXIsProcessTrusted()
            c.list.update(session.shortlist, parents: session.parents, current: session.selected?.id, onAllowAccessibility: allow ? { Accessibility.requestTrust() } : nil)
            let box = selection.map { view.viewRect($0.rect) } ?? CGRect(x: 0, y: top, width: 0, height: 0)
            let width = c.list.frame.width, height = c.list.frame.height
            let x = box.maxX + 12 + width <= bounds.width - 8 ? box.maxX + 12 : (box.minX - 12 - width >= 8 ? box.minX - 12 - width : 12)
            c.list.frame.origin = CGPoint(x: x, y: min(max(box.maxY - height, 8), top - height - 8))
        }
    }
}
