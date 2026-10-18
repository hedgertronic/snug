import AppKit
import ScreenshotCore

/// The Capture hover's candidate list: numbered rows, the current one filled with the tint.
@MainActor
final class CandidateList: NSVisualEffectView {
    static let width: CGFloat = 240
    private static let rowHeight: CGFloat = 30
    private static let parentRowHeight: CGFloat = 20
    private var key = ""
    private static let parentRows = 3

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 12
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}

    /// Rows for the first five shortlist candidates (`current` is the selected candidate's id), then the selection's nearest parents.
    /// A button for the Accessibility prompt appears above the footer when `onAllowAccessibility` is set.
    func update(_ candidates: [Candidate], parents: [Candidate], current: String?, onAllowAccessibility: (() -> Void)?) {
        let rows = Array(candidates.prefix(5))
        let parentRows = Array(parents.prefix(Self.parentRows))
        let key = (rows + parentRows).map(\.id).joined(separator: ",") + "|" + (current ?? "") + (onAllowAccessibility == nil ? "" : "|ax")
        guard key != self.key else { return }
        self.key = key
        subviews.forEach { $0.removeFromSuperview() }
        let footer = NSTextField("1-5 or Up / Down, click captures", size: 11, color: .secondaryLabelColor)
        footer.sizeToFit()
        var bottom: CGFloat = 10
        let allow = onAllowAccessibility.map { action in
            let button = ActionButton(title: "Allow Accessibility for app elements", action: action)
            button.font = .systemFont(ofSize: 11)
            button.bezelStyle = .inline
            button.sizeToFit()
            return button
        }
        let parentsHeight = parentRows.isEmpty ? 0 : CGFloat(parentRows.count + 1) * Self.parentRowHeight
        let height = CGFloat(rows.count) * Self.rowHeight + parentsHeight + 16 + footer.frame.height + 12 + (allow.map { $0.frame.height + 4 } ?? 0)
        frame.size = CGSize(width: Self.width, height: height)
        footer.frame.origin = CGPoint(x: 14, y: bottom)
        addSubview(footer)
        bottom += footer.frame.height + 2
        if let allow {
            allow.frame.origin = CGPoint(x: 10, y: bottom)
            addSubview(allow)
            bottom += allow.frame.height + 2
        }
        if !parentRows.isEmpty {
            let heading = NSTextField("Parents", size: 11, weight: .semibold, color: .secondaryLabelColor)
            heading.sizeToFit()
            heading.frame.origin = CGPoint(x: 14, y: bottom + CGFloat(parentRows.count) * Self.parentRowHeight + (Self.parentRowHeight - heading.frame.height) / 2)
            addSubview(heading)
            for (index, parent) in parentRows.enumerated() {
                let y = bottom + CGFloat(parentRows.count - 1 - index) * Self.parentRowHeight
                let name = NSTextField(Self.name(of: parent), size: 12, color: .labelColor)
                name.sizeToFit()
                name.frame.origin = CGPoint(x: 36, y: y + (Self.parentRowHeight - name.frame.height) / 2)
                let size = NSTextField("\(Int(parent.bounds.width)) x \(Int(parent.bounds.height))", size: 11, mono: true, color: .secondaryLabelColor)
                size.sizeToFit()
                size.frame.origin = CGPoint(x: Self.width - 14 - size.frame.width, y: y + (Self.parentRowHeight - size.frame.height) / 2)
                addSubview(name)
                addSubview(size)
            }
        }
        for (index, candidate) in rows.enumerated() {
            let selected = candidate.id == current
            let row = NSView(frame: CGRect(x: 6, y: height - 8 - CGFloat(index + 1) * Self.rowHeight, width: Self.width - 12, height: Self.rowHeight))
            row.wantsLayer = true
            row.layer!.cornerRadius = 8
            row.layer!.backgroundColor = selected ? Chrome.tint.cgColor : nil
            let text: NSColor = selected ? Chrome.onTint : .labelColor
            let cap = KeyCap(String(index + 1))
            cap.onTint = selected
            cap.frame.origin = CGPoint(x: 8, y: (Self.rowHeight - cap.frame.height) / 2)
            let name = NSTextField(Self.name(of: candidate), size: 13, weight: selected ? .semibold : .regular, color: text)
            name.sizeToFit()
            name.frame.origin = CGPoint(x: 36, y: (Self.rowHeight - name.frame.height) / 2)
            let size = NSTextField("\(Int(candidate.bounds.width)) x \(Int(candidate.bounds.height))", size: 11, mono: true, color: selected ? Chrome.onTint.withAlphaComponent(0.85) : .secondaryLabelColor)
            size.sizeToFit()
            size.frame.origin = CGPoint(x: row.frame.width - 8 - size.frame.width, y: (Self.rowHeight - size.frame.height) / 2)
            for view in [cap, name, size] { row.addSubview(view) }
            addSubview(row)
        }
    }

    /// Accessibility candidates are named by their role description; the rest by kind.
    private static func name(of candidate: Candidate) -> String {
        candidate.id.hasPrefix("ax-") ? candidate.label.capitalized : candidate.kind.rawValue.capitalized
    }
}

/// A push button that runs a closure.
@MainActor
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(run)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The keys sheet: a scrim over the overlay and a centered material panel in three columns.
@MainActor
final class HelpSheet: NSView {
    /// Each row's keys are space-separated: a cap per key, with "/" and a context ending in ":" ("Text:") as plain words.
    static let columns: [(title: String, rows: [(keys: String, action: String)])] = [
        ("Capture", [("drag", "Select a region"), ("click", "Element or window"), ("\u{2325} click", "Flip Frame for this capture"), ("\u{2325} drag", "Exact, no snap"),
                     ("F", "Full screen, or all text"), ("W", "Capture the window"), ("\u{2190} \u{2192}", "Next / previous peer (hover)"), ("\u{21A9}", "Copy"),
                     ("\u{21E7} \u{21A9}", "Copy the text"), ("\u{2318} \u{21A9}", "Copy for an agent"), ("\u{2325} \u{21A9}", "Translate"), ("\u{2318} S", "Save"),
                     ("\u{21E7} \u{2318} S", "Save As"), ("E / \u{21E7} click", "Edit; E again: back"),
                     ("G", "Scrolling capture, hover or selection"), ("K", "Subject preview"), ("Subject: Tab", "Next subject (Shift: back)"), ("Subject: S", "Crop to subject"),
                     ("C", "Copy color"), ("\u{21E7} C", "Cycle color format"), ("esc", "Cancel"), ("Space", "Hold while dragging to move")]),
        ("Adjust and text", [("Tab", "Walk out (Shift: in)"), ("Arrows", "Nudge 1 px (Shift: 10 px)"), ("\u{2325} arrow", "Grow one side 1 px"),
                             ("\u{2325} \u{2318} arrow", "Shrink one side 1 px"), ("\u{2318} arrow", "Edge out, one side"), ("\u{21E7} \u{2318} arrow", "Edge in, one side"),
                             ("+ / -", "All sides 1 px (Option: 10)"), ("\u{2318} Z", "Undo an edit (Shift: redo)"),
                             ("\u{2191} / \u{2193}", "Bigger / smaller element"), ("\u{21E7} click", "Add an element"),
                             ("[ ]", "Corner radius"), ("\u{21E7} [ ]", "Corner radius by 4 pt"), ("=", "Same radius on all corners"), ("\u{2325} drag", "One corner's radius, on a dot"),
                             ("\u{21E7} drag", "Keep the ratio, on a handle"), ("\u{21E7} drag", "Lock to one axis, moving"),
                             ("Text: drag", "Select text"), ("Text: \u{21A9}", "Copy selected text"), ("Text: \u{21E7} \u{21A9}", "Copy as rows"),
                             ("Text: Tab", "Next link, email, phone, code"), ("Text: \u{2318} \u{21A9}", "Open the picked item"), ("Text: \u{2325} \u{21A9}", "Translate text")]),
        ("Modes, view, recording", [("A", "Capture"), ("T", "Text"), ("S", "Snap on / off"), ("L", "Loupe"), ("R", "Rulers"),
                                    ("X", "Crosshair"), ("O", "Rounded corners"), ("M", "Frame: shadow on / off"), ("P", "Ratio menu"),
                                    ("\u{21E7} P", "Lock the ratio"), ("U", "Colors menu: 1-6 copies"), ("N", "Candidate list"), ("1-5", "Pick from the list (N)"), ("?", "This sheet"),
                                    ("V", "Arm recording, hover or selection"), ("Armed: \u{21A9} / V", "Start recording"), ("Armed: H", "Cursor on / off"), ("Armed: I", "Count-in off, 3 s, 5 s"),
                                    ("Armed: J", "System audio on / off"), ("hotkey", "Stop recording"),
                                    ("Menus: \u{2191} / \u{2193}", "Pick in the Ratio or Colors menu"), ("Subject: K / esc", "Back to the selection")])
    ]
    let panel = NSVisualEffectView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        isHidden = true
        panel.material = .hudWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer!.cornerRadius = 18
        let rowHeight: CGFloat = 30, padX: CGFloat = 32, padY: CGFloat = 28, gap: CGFloat = 28
        let tallest = CGFloat(Self.columns.map(\.rows.count).max()!)
        let height = padY * 2 + 36 + 28 + tallest * rowHeight
        panel.frame.size = CGSize(width: 900, height: height)
        let title = NSTextField("Keys", size: 20, weight: .bold)
        title.sizeToFit()
        title.frame.origin = CGPoint(x: padX, y: height - padY - title.frame.height)
        let subtitle = NSTextField("Every toggle stays the way you leave it.  Esc or ? closes this.", size: 12, color: .secondaryLabelColor)
        subtitle.sizeToFit()
        subtitle.frame.origin = CGPoint(x: 900 - padX - subtitle.frame.width, y: title.frame.minY + 3)
        panel.addSubview(title)
        panel.addSubview(subtitle)
        let columnWidth = (900 - padX * 2 - gap * 2) / 3
        for (index, column) in Self.columns.enumerated() {
            let x = padX + CGFloat(index) * (columnWidth + gap)
            let top = title.frame.minY - 20
            let heading = NSTextField(column.title, size: 12, weight: .semibold, color: .secondaryLabelColor)
            heading.sizeToFit()
            heading.frame.origin = CGPoint(x: x, y: top - heading.frame.height)
            panel.addSubview(heading)
            for (row, item) in column.rows.enumerated() {
                let y = top - 28 - CGFloat(row + 1) * rowHeight
                let line = NSView(frame: CGRect(x: x, y: y, width: columnWidth, height: 0.5))
                line.wantsLayer = true
                line.layer!.backgroundColor = NSColor.separatorColor.cgColor
                let action = NSTextField(item.action, size: 13)
                action.sizeToFit()
                action.frame.origin = CGPoint(x: x, y: y + (rowHeight - action.frame.height) / 2)
                let keys = Pill(fill: .clear, radius: 0, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 3)
                keys.show(item.keys) {
                    item.keys.split(separator: " ").map { token -> NSView in
                        token == "/" || token.hasSuffix(":") ? NSTextField(String(token), size: 12, color: .secondaryLabelColor) : KeyCap(String(token))
                    }
                }
                keys.frame.origin = CGPoint(x: x + columnWidth - keys.frame.width, y: y + (rowHeight - keys.frame.height) / 2)
                for view in [line, action, keys] { panel.addSubview(view) }
            }
        }
        addSubview(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}

    /// Fills `bounds` with the scrim and centers the panel.
    func layoutPanel() {
        panel.frame.origin = CGPoint(x: ((bounds.width - panel.frame.width) / 2).rounded(), y: ((bounds.height - panel.frame.height) / 2).rounded())
    }
}

/// The ratio chip's menu, and the Colors menu: rows on the chrome surface, over a clear layer that covers the overlay and closes the menu
/// on a click outside it. While open it is the first responder: Up and Down move the highlight, Return picks, Esc or its own key
/// (`toggleKey`) closes, a row's cap key picks it; the pointer highlights the row under it and a click picks. Any other key closes it
/// and goes on to the overlay.
@MainActor
final class RatioMenu: NSView {
    /// A row; an empty title is a separator. `swatch` takes the check column, and `cap` is a key cap at the row's right end that picks it.
    struct Item {
        let title: String
        let on: Bool
        var swatch: NSColor?
        var cap: String?
        let pick: () -> Void
    }

    /// The key that opens the menu, which closes it again.
    var toggleKey = "p"

    var onClose: () -> Void = {}
    /// The pointer moved over the menu: `overRow` is current again.
    var onMove: () -> Void = {}
    /// Whether the pointer is on an item row, which a click picks.
    private(set) var overRow = false
    /// A key the menu handles itself, so its cap can flash.
    var onKey: (NSEvent) -> Void = { _ in }
    private(set) var items: [Item] = []
    private(set) var highlighted: Int?
    let panel = Pill(radius: 11, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 0)
    private(set) var rows: [NSView] = []
    private static let rowHeight: CGFloat = 22, separatorHeight: CGFloat = 9, inset: CGFloat = 4

    init() {
        super.init(frame: .zero)
        isHidden = true
        panel.isHidden = false
        panel.isClickThrough = false
        addSubview(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    /// Opens over the whole superview with `items`, the panel under `anchor` (superview points) with left edges aligned, or over it
    /// when there is no room below.
    func open(_ items: [Item], under anchor: CGRect) {
        self.items = items
        highlighted = nil
        frame = superview!.bounds
        rows.forEach { $0.removeFromSuperview() }
        let heights = items.map { $0.title.isEmpty ? Self.separatorHeight : Self.rowHeight }
        // As wide as the longest title: the checkmark column (22) before it, 12 after.
        let titles = items.map { ($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width }
        let capWidth = items.contains { $0.cap != nil } ? KeyCap("1").frame.width + 12 : 0
        let size = CGSize(width: (Self.inset * 2 + 22 + titles.max()! + 12 + capWidth).rounded(.up), height: heights.reduce(Self.inset * 2, +))
        var top = size.height - Self.inset
        rows = zip(items, heights).map { item, height in
            top -= height
            let row = NSView(frame: CGRect(x: Self.inset, y: top, width: size.width - Self.inset * 2, height: height))
            row.wantsLayer = true
            row.layer!.cornerRadius = 6
            if item.title.isEmpty {
                let line = NSView(frame: CGRect(x: 6, y: (height / 2).rounded(), width: row.frame.width - 12, height: 1))
                line.wantsLayer = true
                effectiveAppearance.performAsCurrentDrawingAppearance { line.layer!.backgroundColor = NSColor.chromeHairline.cgColor }
                row.addSubview(line)
            } else {
                let title = NSTextField(item.title, size: 12, weight: .medium, color: .chromeText)
                title.frame.origin = CGPoint(x: 22, y: ((height - title.frame.height) / 2).rounded())
                row.addSubview(title)
                if let color = item.swatch {
                    let swatch = NSView(frame: CGRect(x: 6, y: ((height - 12) / 2).rounded(), width: 12, height: 12))
                    swatch.wantsLayer = true
                    swatch.layer!.cornerRadius = 3
                    swatch.layer!.backgroundColor = color.cgColor
                    swatch.layer!.borderWidth = 1
                    effectiveAppearance.performAsCurrentDrawingAppearance { swatch.layer!.borderColor = NSColor.swatchEdge.cgColor }
                    row.addSubview(swatch)
                }
                if let key = item.cap {
                    let cap = KeyCap(key)
                    cap.frame.origin = CGPoint(x: row.frame.width - cap.frame.width - 6, y: ((height - cap.frame.height) / 2).rounded())
                    row.addSubview(cap)
                }
                if item.on {
                    let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")!)
                    check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    check.contentTintColor = .chromeText
                    check.frame.size = check.fittingSize
                    check.frame.origin = CGPoint(x: 6, y: ((height - check.frame.height) / 2).rounded())
                    row.addSubview(check)
                }
            }
            panel.addSubview(row)
            return row
        }
        let below = anchor.minY - 4 - size.height
        panel.frame = CGRect(x: min(max(anchor.minX, 8), bounds.width - size.width - 8),
                             y: below >= 8 ? below : min(anchor.maxY + 4, bounds.height - size.height - 8), width: size.width, height: size.height)
        panel.layer!.shadowPath = CGPath(roundedRect: panel.bounds, cornerWidth: 11, cornerHeight: 11, transform: nil)
        isHidden = false
        window!.makeFirstResponder(self)
    }

    func close() {
        isHidden = true
        overRow = false
        window!.makeFirstResponder(superview)
        onClose()
    }

    /// Closes the menu, then runs the item at `index`.
    func pick(_ index: Int) {
        close()
        items[index].pick()
    }

    /// Fills the highlighted row with the tint, its title and check in the color that reads on it.
    private func highlight(_ index: Int?) {
        highlighted = index
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (row, item) in rows.enumerated() {
                item.layer!.backgroundColor = row == index ? Chrome.tint.cgColor : nil
                for label in item.subviews.compactMap({ $0 as? NSTextField }) { label.textColor = row == index ? Chrome.onTint : .chromeText }
                for check in item.subviews.compactMap({ $0 as? NSImageView }) { check.contentTintColor = row == index ? Chrome.onTint : .chromeText }
                for cap in item.subviews.compactMap({ $0 as? KeyCap }) { cap.onTint = row == index }
            }
        }
    }

    /// The item row under a point in this view's coordinates, skipping separators.
    private func row(at point: CGPoint) -> Int? {
        let local = panel.convert(point, from: self)
        return rows.indices.first { rows[$0].frame.contains(local) && !items[$0].title.isEmpty }
    }

    override func keyDown(with event: NSEvent) {
        let choices = items.indices.filter { !items[$0].title.isEmpty }
        let character = event.charactersIgnoringModifiers
        if [125, 126, 36, 76, 53].contains(event.keyCode) || character == toggleKey { onKey(event) }
        if let index = items.firstIndex(where: { $0.cap != nil && $0.cap == character }) {
            onKey(event)
            return pick(index)
        }
        switch event.keyCode {
        case 125, 126:
            let position = highlighted.flatMap(choices.firstIndex) ?? (event.keyCode == 125 ? -1 : choices.count)
            highlight(choices[(position + (event.keyCode == 125 ? 1 : -1) + choices.count) % choices.count])
        case 36, 76:
            if let highlighted { pick(highlighted) }
        case 53: close()
        case _ where character == toggleKey: close()
        default:
            close()
            super.keyDown(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        overRow = index != nil
        highlight(index)
        onMove()
    }

    override func mouseDown(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) { pick(index) } else { close() }
    }
}
