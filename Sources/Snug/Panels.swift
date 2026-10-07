import AppKit
import ScreenshotCore

/// The Element mode candidate list: numbered rows, the current one filled with the accent.
@MainActor
final class CandidateList: NSVisualEffectView {
    static let width: CGFloat = 240
    private static let rowHeight: CGFloat = 30
    private var key = ""

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

    /// Rows for the first five shortlist candidates; `current` is the selected candidate's id.
    func update(_ candidates: [Candidate], current: String?) {
        let rows = Array(candidates.prefix(5))
        let key = rows.map(\.id).joined(separator: ",") + "|" + (current ?? "")
        guard key != self.key else { return }
        self.key = key
        subviews.forEach { $0.removeFromSuperview() }
        let footer = NSTextField("1-5 or Up / Down, \u{21A9} copies", size: 11, color: .secondaryLabelColor)
        footer.sizeToFit()
        let height = CGFloat(rows.count) * Self.rowHeight + 16 + footer.frame.height + 12
        frame.size = CGSize(width: Self.width, height: height)
        footer.frame.origin = CGPoint(x: 14, y: 10)
        addSubview(footer)
        for (index, candidate) in rows.enumerated() {
            let selected = candidate.id == current
            let row = NSView(frame: CGRect(x: 6, y: height - 8 - CGFloat(index + 1) * Self.rowHeight, width: Self.width - 12, height: Self.rowHeight))
            row.wantsLayer = true
            row.layer!.cornerRadius = 8
            row.layer!.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
            let text: NSColor = selected ? .white : .labelColor
            let cap = KeyCap(String(index + 1), color: selected ? .white : .secondaryLabelColor)
            cap.frame.origin = CGPoint(x: 8, y: (Self.rowHeight - cap.frame.height) / 2)
            let name = NSTextField(candidate.kind.rawValue.capitalized, size: 13, weight: selected ? .semibold : .regular, color: text)
            name.sizeToFit()
            name.frame.origin = CGPoint(x: 36, y: (Self.rowHeight - name.frame.height) / 2)
            let size = NSTextField("\(Int(candidate.bounds.width)) x \(Int(candidate.bounds.height))", size: 11, mono: true, color: selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor)
            size.sizeToFit()
            size.frame.origin = CGPoint(x: row.frame.width - 8 - size.frame.width, y: (Self.rowHeight - size.frame.height) / 2)
            for view in [cap, name, size] { row.addSubview(view) }
            addSubview(row)
        }
    }
}

/// The keys sheet: a scrim over the overlay and a centered material panel in three columns.
@MainActor
final class HelpSheet: NSView {
    static let columns: [(title: String, rows: [(keys: String, action: String)])] = [
        ("Capture", [("drag", "Select a region"), ("click", "Copy window under pointer"), ("\u{2325}-drag", "Exact, no snap"),
                     ("F", "Full screen"), ("\u{21A9}", "Copy"), ("\u{2318}S", "Save"), ("C", "Copy color"), ("\u{238B}", "Cancel")]),
        ("Adjust", [("Tab", "Other fits, found items"), ("Arrows", "Nudge (Shift: 10 pt)"), ("Up / Down", "Bigger / smaller element"),
                    ("1-5", "Pick a candidate"), ("\u{2318}1/2/3", "Tight / Margin / Backdrop"), ("M", "Cycle output style"),
                    ("\u{21E7}\u{21A9}", "Copy text as table"), ("\u{2318}\u{21A9}", "Open picked link"), ("\u{21E7}C", "Cycle color format")]),
        ("Modes and view", [("A", "Area"), ("E", "Element"), ("T", "Text"), ("S", "Snap on / off"), ("L", "Loupe"), ("R", "Rulers"),
                            ("X", "Crosshair"), ("N", "Candidate list"), ("B", "Bottom bar"), ("?", "This sheet")])
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
        let subtitle = NSTextField("Every toggle stays the way you leave it.  \u{238B} or ? closes this.", size: 12, color: .secondaryLabelColor)
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
