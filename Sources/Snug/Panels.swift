import AppKit
import ScreenshotCore

/// The Capture hover's candidate list: numbered rows, the current one filled with the accent.
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
            row.layer!.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
            let text: NSColor = selected ? .white : .labelColor
            let cap = KeyCap(String(index + 1), color: selected ? .white : .secondaryLabelColor)
            cap.frame.origin = CGPoint(x: 8, y: (Self.rowHeight - cap.frame.height) / 2)
            let name = NSTextField(Self.name(of: candidate), size: 13, weight: selected ? .semibold : .regular, color: text)
            name.sizeToFit()
            name.frame.origin = CGPoint(x: 36, y: (Self.rowHeight - name.frame.height) / 2)
            let size = NSTextField("\(Int(candidate.bounds.width)) x \(Int(candidate.bounds.height))", size: 11, mono: true, color: selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor)
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
    static let columns: [(title: String, rows: [(keys: String, action: String)])] = [
        ("Capture", [("drag", "Select a region"), ("click", "Element or window"), ("Option-click", "Flip window shadow"), ("Option-drag", "Exact, no snap"),
                     ("F", "Full screen, or all text"), ("Return", "Copy"), ("Shift-Return", "Copy text in the selection"), ("Cmd-S", "Save"),
                     ("G", "Scrolling capture of the selection"),
                     ("C", "Copy color"), ("Esc", "Cancel"), ("Space", "Hold while dragging to move")]),
        ("Adjust and text", [("Tab", "Walk out, other fits"), ("Arrows", "Nudge (Shift: 10 pt)"), ("Up / Down", "Bigger / smaller element"),
                             ("1-5", "Pick from the list (N)"), ("Cmd-1/2/3", "Tight / Margin / Backdrop"), ("M", "Cycle output style"),
                             ("Text: drag", "Select text"), ("Text: Return", "Copy selected text"), ("Text: Shift-Return", "Copy as rows"),
                             ("Text: Tab", "Next link, email, phone, code"), ("Text: Cmd-Return", "Open the picked item"), ("Option-Return", "Translate text"),
                             ("Shift-C", "Cycle color format")]),
        ("Modes and view", [("A", "Capture"), ("T", "Text"), ("S", "Snap on / off"), ("L", "Loupe"), ("R", "Rulers"),
                            ("X", "Crosshair"), ("D", "Window shadow"), ("N", "Candidate list"), ("B", "Bottom bar"), ("?", "This sheet")])
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
                let cap = KeyCap(item.keys)
                cap.frame.origin = CGPoint(x: x + columnWidth - cap.frame.width, y: y + (rowHeight - cap.frame.height) / 2)
                for view in [line, action, cap] { panel.addSubview(view) }
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
