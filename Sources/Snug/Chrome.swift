import AppKit
import ScreenshotCore

extension NSTextField {
    convenience init(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false, color: NSColor = .labelColor) {
        self.init(labelWithString: text)
        font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        textColor = color
        sizeToFit()
    }
}

/// A rounded strip of views, sized to fit: hints, badges, the hover title. Click-through unless `isClickThrough` is off.
@MainActor
final class Pill: NSView {
    var isClickThrough = true
    private var key: String?
    private let insets: NSEdgeInsets
    private let spacing: CGFloat
    private let vertical: Bool

    init(fill: NSColor, radius: CGFloat, insets: NSEdgeInsets, spacing: CGFloat, vertical: Bool = false) {
        self.insets = insets
        self.spacing = spacing
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = fill.cgColor
        layer!.cornerRadius = radius
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { isClickThrough ? nil : super.hitTest(point) }

    /// Shows the pill; the views (already sized) are rebuilt only when `key` changes.
    func show(_ key: String, _ views: () -> [NSView]) {
        isHidden = false
        guard key != self.key else { return }
        self.key = key
        subviews.forEach { $0.removeFromSuperview() }
        let items = views()
        let gaps = spacing * CGFloat(items.count - 1)
        let inner = vertical
            ? CGSize(width: items.map(\.frame.width).max()!, height: items.reduce(gaps) { $0 + $1.frame.height })
            : CGSize(width: items.reduce(gaps) { $0 + $1.frame.width }, height: items.map(\.frame.height).max()!)
        frame.size = CGSize(width: inner.width + insets.left + insets.right, height: inner.height + insets.top + insets.bottom)
        var offset = vertical ? frame.height - insets.top : insets.left
        for item in items {
            if vertical {
                offset -= item.frame.height
                item.frame.origin = CGPoint(x: insets.left + (inner.width - item.frame.width) / 2, y: offset)
                offset -= spacing
            } else {
                item.frame.origin = CGPoint(x: offset, y: insets.bottom + (inner.height - item.frame.height) / 2)
                offset += item.frame.width + spacing
            }
            addSubview(item)
        }
    }

    static func dark(_ alpha: CGFloat, radius: CGFloat, insets: NSEdgeInsets, spacing: CGFloat = 8, vertical: Bool = false) -> Pill {
        Pill(fill: NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: alpha), radius: radius, insets: insets, spacing: spacing, vertical: vertical)
    }
}

/// A 7 pt status dot.
@MainActor
final class Dot: NSView {
    init(_ color: NSColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 7, height: 7))
        wantsLayer = true
        layer!.backgroundColor = color.cgColor
        layer!.cornerRadius = 3.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
}

/// A small key glyph: mono text in a hairline rounded box.
@MainActor
final class KeyCap: NSView {
    private let label: NSTextField
    var color: NSColor {
        didSet {
            label.textColor = color
            layer!.backgroundColor = color.withAlphaComponent(0.15).cgColor
            layer!.borderColor = color.withAlphaComponent(0.35).cgColor
        }
    }

    init(_ text: String, color: NSColor = .secondaryLabelColor) {
        label = NSTextField(text, size: 10.5, weight: .medium, mono: true, color: color)
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = 4
        layer!.borderWidth = 1
        layer!.backgroundColor = color.withAlphaComponent(0.15).cgColor
        layer!.borderColor = color.withAlphaComponent(0.35).cgColor
        label.sizeToFit()
        frame.size = CGSize(width: max(18, label.frame.width + 10), height: 18)
        label.frame.origin = CGPoint(x: (frame.width - label.frame.width) / 2, y: (frame.height - label.frame.height) / 2)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A clickable title with a key cap, beside it or under it.
@MainActor
final class BarButton: NSView {
    var onClick: () -> Void = {}
    let title: NSTextField
    let cap: KeyCap

    init(_ title: String, key: String, width: CGFloat? = nil, height: CGFloat = 44, stacked: Bool = false) {
        self.title = NSTextField(title, size: stacked ? 11 : 13)
        cap = KeyCap(key)
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = 9
        self.title.sizeToFit()
        let content = stacked ? max(self.title.frame.width, cap.frame.width) : self.title.frame.width + 6 + cap.frame.width
        frame.size = CGSize(width: width ?? content + 24, height: height)
        if stacked {
            self.title.frame.origin = CGPoint(x: (frame.width - self.title.frame.width) / 2, y: height - self.title.frame.height - 6)
            cap.frame.origin = CGPoint(x: (frame.width - cap.frame.width) / 2, y: 6)
        } else {
            let x = (frame.width - content) / 2
            self.title.frame.origin = CGPoint(x: x, y: (height - self.title.frame.height) / 2)
            cap.frame.origin = CGPoint(x: x + self.title.frame.width + 6, y: (height - cap.frame.height) / 2)
        }
        addSubview(self.title)
        addSubview(cap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }

    /// `fill` nil leaves the button transparent. The text, key cap, and weight follow `text` and `bold`.
    func style(fill: NSColor?, text: NSColor, bold: Bool = false) {
        layer!.backgroundColor = fill?.cgColor
        title.textColor = text
        title.font = .systemFont(ofSize: title.font!.pointSize, weight: bold ? .semibold : .regular)
        cap.color = text.withAlphaComponent(text == .white ? 0.9 : 0.8)
    }
}

/// The floating capsule shared by the bottom bar and the style bar: material, hairline, shadow.
@MainActor
class Capsule: NSView {
    let material = NSVisualEffectView()
    private let stack = NSStackView()

    init(spacing: CGFloat = 4) {
        super.init(frame: .zero)
        wantsLayer = true
        layer!.shadowColor = NSColor.black.cgColor
        layer!.shadowOpacity = 0.35
        layer!.shadowRadius = 15
        layer!.shadowOffset = CGSize(width: 0, height: -10)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer!.cornerRadius = 14
        material.layer!.masksToBounds = true
        material.layer!.borderWidth = 0.5
        material.layer!.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        material.addSubview(stack)
        addSubview(material)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}

    func setItems(_ views: [NSView]) {
        stack.setViews(views, in: .center)
        stack.frame.size = stack.fittingSize
        frame.size = stack.frame.size
        material.frame = bounds
        layer!.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer!.backgroundColor = NSColor.separatorColor.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return line
    }
}

/// The bottom bar: modes, view toggles, and the output style.
@MainActor
final class BottomBar: Capsule {
    var onMode: (OverlayController.Mode) -> Void = { _ in }
    var onToggle: (String) -> Void = { _ in }
    var onStyle: () -> Void = {}
    private(set) var modes: [OverlayController.Mode] = []
    let modeButtons: [OverlayController.Mode: BarButton] = [.area: BarButton("Area", key: "A"), .element: BarButton("Element", key: "E"), .text: BarButton("Text", key: "T")]
    let toggles = [(Pref.loupe, BarButton("Loupe", key: "L", width: 52, stacked: true)),
                   (Pref.rulers, BarButton("Rulers", key: "R", width: 52, stacked: true)),
                   (Pref.snap, BarButton("Snap", key: "S", width: 52, stacked: true))]
    let styleButton = BarButton("Tight", key: "M", width: 68, stacked: true)
    private let divider = Capsule.divider()

    override init(spacing: CGFloat = 4) {
        super.init(spacing: spacing)
        for (mode, button) in modeButtons { button.onClick = { [unowned self] in onMode(mode) } }
        for (key, button) in toggles { button.onClick = { [unowned self] in onToggle(key) } }
        styleButton.onClick = { [unowned self] in onStyle() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Element only appears when `elementEnabled`.
    func update(mode: OverlayController.Mode, elementEnabled: Bool, defaults: UserDefaults, style: OutputStyle) {
        let wanted: [OverlayController.Mode] = elementEnabled ? [.area, .element, .text] : [.area, .text]
        if wanted != modes {
            modes = wanted
            setItems(wanted.map { modeButtons[$0]! } + [divider] + toggles.map(\.1) + [styleButton])
        }
        for (current, button) in modeButtons {
            let selected = current == mode
            button.style(fill: selected ? .controlAccentColor : nil, text: selected ? .white : .labelColor, bold: selected)
        }
        for (key, button) in toggles {
            let on = defaults.bool(forKey: key)
            button.style(fill: on ? NSColor.controlAccentColor.withAlphaComponent(0.15) : nil, text: on ? .controlAccentColor : .secondaryLabelColor)
        }
        styleButton.title.stringValue = style.rawValue.capitalized
        styleButton.style(fill: nil, text: .secondaryLabelColor)
    }

    /// Clicks the button for `mode`, as the pointer would.
    func click(_ mode: OverlayController.Mode) { modeButtons[mode]!.onClick() }
}

/// The bar under a released selection: output style, Save, and Copy.
@MainActor
final class StyleBar: Capsule {
    var onStyle: (OutputStyle) -> Void = { _ in }
    var onSave: () -> Void = {}
    var onCopy: () -> Void = {}
    let segments = OutputStyle.allCases.enumerated().map { BarButton($1.rawValue.capitalized, key: "\u{2318}\($0 + 1)", height: 38) }
    let save = BarButton("Save", key: "\u{2318}S")
    let copy = BarButton("Copy", key: "Return")

    var style = OutputStyle.tight {
        didSet {
            for (candidate, segment) in zip(OutputStyle.allCases, segments) {
                segment.style(fill: candidate == style ? NSColor.labelColor.withAlphaComponent(0.16) : nil, text: .labelColor, bold: candidate == style)
            }
        }
    }

    override init(spacing: CGFloat = 10) {
        super.init(spacing: spacing)
        let track = Pill(fill: NSColor.labelColor.withAlphaComponent(0.08), radius: 12, insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), spacing: 2)
        track.isClickThrough = false
        track.show("track") { segments }
        for (candidate, segment) in zip(OutputStyle.allCases, segments) { segment.onClick = { [unowned self] in onStyle(candidate) } }
        let cycle = Pill(fill: .clear, radius: 0, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4), spacing: 6)
        cycle.show("cycle") { [KeyCap("M"), NSTextField("cycles", size: 12, color: .secondaryLabelColor)] }
        save.style(fill: NSColor.labelColor.withAlphaComponent(0.1), text: .labelColor)
        copy.style(fill: .controlAccentColor, text: .white, bold: true)
        save.onClick = { [unowned self] in onSave() }
        copy.onClick = { [unowned self] in onCopy() }
        setItems([track, cycle, Capsule.divider(), save, copy])
        style = .tight
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// All the overlay's on-screen chrome. `OverlayController.refreshChrome` positions and fills it.
@MainActor
final class Chrome {
    let bottomBar = BottomBar()
    let styleBar = StyleBar()
    let hints = Pill.dark(0.92, radius: 8, insets: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12), spacing: 14)
    let size = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let status = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let hover = Pill.dark(0.86, radius: 12, insets: NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18), spacing: 3, vertical: true)
    let count = Pill(fill: .controlAccentColor, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9), spacing: 8)
    let table = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let reading = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let list = CandidateList()
    let help = HelpSheet()

    var all: [NSView] { [hover, size, status, count, table, reading, hints, list, bottomBar, styleBar, help] }
}
