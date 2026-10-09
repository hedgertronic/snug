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

/// A key cap: the key's glyph on a raised rounded key. `prominent` is the white key on an accent button (Copy, the current mode).
@MainActor
final class KeyCap: NSView {
    private let label: NSTextField
    var color: NSColor {
        didSet { applyColor() }
    }
    var prominent = false {
        didSet { applyColor() }
    }

    init(_ text: String, color: NSColor = .secondaryLabelColor) {
        label = NSTextField(text, size: 11, weight: .semibold, color: color)
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = 5
        layer!.borderWidth = 0.5
        layer!.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer!.shadowColor = NSColor.black.cgColor
        layer!.shadowOpacity = 0.55
        layer!.shadowOffset = CGSize(width: 0, height: -1)
        layer!.shadowRadius = 0
        label.sizeToFit()
        frame.size = CGSize(width: max(20, label.frame.width + 12), height: 20)
        label.frame.origin = CGPoint(x: (frame.width - label.frame.width) / 2, y: (frame.height - label.frame.height) / 2)
        addSubview(label)
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColor() {
        label.textColor = prominent ? .controlAccentColor : color
        layer!.backgroundColor = prominent ? NSColor.white.withAlphaComponent(0.9).cgColor : color.withAlphaComponent(0.2).cgColor
    }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension Pill {
    /// A hint: key caps then a label, on no fill.
    static func chip(_ keys: [String], _ label: String) -> Pill {
        let chip = Pill(fill: .clear, radius: 0, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 6)
        let color = NSColor.white.withAlphaComponent(0.92)
        chip.show(keys.joined() + label) {
            keys.map { KeyCap($0, color: color) } + (label.isEmpty ? [] : [NSTextField(label, size: 12, weight: .medium, color: color)])
        }
        return chip
    }
}

/// A clickable title with its key cap after it. The width fits the current title in semibold, so a selected title never clips and
/// the key cap follows the text. A nil key has no cap.
@MainActor
final class BarButton: NSView {
    var onClick: () -> Void = {}
    let title: NSTextField
    let cap: KeyCap?
    private let size: CGFloat
    private let padding: CGFloat

    init(_ title: String, key: String?, height: CGFloat = 32, size: CGFloat = 13) {
        self.title = NSTextField(title, size: size, weight: .medium)
        cap = key.map { KeyCap($0) }
        self.size = size
        padding = height > 30 ? 10 : 8
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = height > 30 ? 9 : 8
        frame.size.height = height
        self.title.frame.origin.y = (height - self.title.frame.height) / 2
        addSubview(self.title)
        if let cap {
            cap.frame.origin.y = (height - cap.frame.height) / 2
            addSubview(cap)
        }
        fit()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }

    /// Shows `text` and resizes the button to it.
    func setTitle(_ text: String) {
        title.stringValue = text
        fit()
    }

    private func fit() {
        let width = NSTextField(title.stringValue, size: size, weight: .semibold).frame.width
        title.frame.origin.x = padding
        title.frame.size.width = width
        cap?.frame.origin.x = padding + width + 7
        frame.size.width = padding * 2 + width + (cap.map { 7 + $0.frame.width } ?? 0)
        invalidateIntrinsicContentSize()
    }

    /// `fill` nil leaves the button transparent. The text and weight follow `text` and `bold`; `prominent` puts a white key cap on it.
    func style(fill: NSColor?, text: NSColor, bold: Bool = false, prominent: Bool = false) {
        layer!.backgroundColor = fill?.cgColor
        title.textColor = text
        title.font = .systemFont(ofSize: title.font!.pointSize, weight: bold ? .semibold : .medium)
        cap?.color = text.withAlphaComponent(text == .white ? 0.94 : 0.85)
        cap?.prominent = prominent
    }
}

/// The floating capsule shared by the bottom bar and the action bar: material, hairline, shadow.
@MainActor
class Capsule: NSView {
    let material = NSVisualEffectView()
    private let stack = NSStackView()
    private let radius: CGFloat

    init(spacing: CGFloat = 6, inset: CGFloat = 6, radius: CGFloat = 14) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer!.shadowColor = NSColor.black.cgColor
        layer!.shadowOpacity = 0.45
        layer!.shadowRadius = 15
        layer!.shadowOffset = CGSize(width: 0, height: -10)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer!.cornerRadius = radius
        material.layer!.masksToBounds = true
        material.layer!.borderWidth = 0.5
        material.layer!.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        material.addSubview(stack)
        addSubview(material)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}

    func setItems(_ views: [NSView]) {
        stack.setViews(views, in: .center)
        relayout()
    }

    /// Resizes the capsule to its items, after one of them changed size.
    func relayout() {
        stack.frame.size = stack.fittingSize
        frame.size = stack.frame.size
        material.frame = bounds
        layer!.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func divider(height: CGFloat = 20) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer!.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: height).isActive = true
        return line
    }
}

/// The bottom bar in three titled groups: Mode, View, and Output.
@MainActor
final class BottomBar: Capsule {
    var onMode: (OverlayController.Mode) -> Void = { _ in }
    var onToggle: (String) -> Void = { _ in }
    let modeButtons: [OverlayController.Mode: BarButton] = [.capture: BarButton("Capture", key: "A"), .text: BarButton("Text", key: "T")]
    let toggles = [(Pref.loupe, BarButton("Loupe", key: "L")),
                   (Pref.rulers, BarButton("Rulers", key: "R")),
                   (Pref.snap, BarButton("Snap", key: "S")),
                   (Pref.roundCorners, BarButton("Rounded", key: "O")),
                   (Pref.frame, BarButton("Frame", key: "M"))]
    let shadowButton = BarButton("Shadow", key: "D")
    let groups: [NSStackView]
    let dividers = [Capsule.divider(height: 36), Capsule.divider(height: 36)]

    init() {
        func group(_ title: String, _ buttons: [BarButton]) -> NSStackView {
            let row = NSStackView(views: buttons)
            row.spacing = 6
            let column = NSStackView(views: [NSTextField(title, size: 10, weight: .semibold, color: .secondaryLabelColor), row])
            column.orientation = .vertical
            column.spacing = 5
            return column
        }
        let buttons = toggles.map(\.1)
        groups = [group("Mode", [modeButtons[.capture]!, modeButtons[.text]!]), group("View", Array(buttons[0..<2])),
                  group("Output", [buttons[2], buttons[3], buttons[4], shadowButton])]
        super.init()
        for (mode, button) in modeButtons { button.onClick = { [unowned self] in onMode(mode) } }
        for (key, button) in toggles { button.onClick = { [unowned self] in onToggle(key) } }
        shadowButton.onClick = { [unowned self] in onToggle(Pref.shadow) }
        setItems([groups[0], dividers[0], groups[1], dividers[1], groups[2]])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(mode: OverlayController.Mode, defaults: UserDefaults) {
        for (current, button) in modeButtons {
            let selected = current == mode
            button.style(fill: selected ? .controlAccentColor : nil, text: selected ? .white : .labelColor, bold: selected, prominent: selected)
        }
        for (key, button) in toggles + [(Pref.shadow, shadowButton)] {
            let on = defaults.bool(forKey: key)
            button.style(fill: on ? NSColor.controlAccentColor.withAlphaComponent(0.22) : nil, text: on ? .controlAccentColor : .labelColor)
        }
        relayout()
    }

    /// Clicks the button for `mode`, as the pointer would.
    func click(_ mode: OverlayController.Mode) { modeButtons[mode]!.onClick() }
}

/// The bar attached to a released selection: Frame, Text, Save, and Copy.
@MainActor
final class ActionBar: Capsule {
    var onFrame: () -> Void = {}
    var onText: () -> Void = {}
    var onSave: () -> Void = {}
    var onCopy: () -> Void = {}
    let frameButton = BarButton("Frame", key: "M", height: 28, size: 12)
    let text = BarButton("Text", key: "\u{21E7}\u{21A9}", height: 28, size: 12)
    let save = BarButton("Save", key: "\u{2318}S", height: 28, size: 12)
    let copy = BarButton("Copy", key: "\u{21A9}", height: 28, size: 12)

    var framed = false {
        didSet { frameButton.style(fill: framed ? NSColor.white.withAlphaComponent(0.16) : nil, text: .labelColor, bold: framed) }
    }

    init() {
        super.init(spacing: 4, inset: 4, radius: 11)
        frameButton.onClick = { [unowned self] in onFrame() }
        text.style(fill: nil, text: .labelColor)
        save.style(fill: nil, text: .labelColor)
        copy.style(fill: .controlAccentColor, text: .white, bold: true, prominent: true)
        text.onClick = { [unowned self] in onText() }
        save.onClick = { [unowned self] in onSave() }
        copy.onClick = { [unowned self] in onCopy() }
        setItems([frameButton, Capsule.divider(height: 18), text, save, copy])
        framed = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// All the overlay's on-screen chrome. `OverlayController.refreshChrome` positions and fills it.
@MainActor
final class Chrome {
    let bottomBar = BottomBar()
    let actionBar = ActionBar()
    let hints = Pill.dark(0.9, radius: 11, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14), spacing: 18)
    /// Key caps at the top-left corners of the faint outlines of what Up and Down would select.
    let upHint = KeyCap("\u{2191}", color: .white)
    let downHint = KeyCap("\u{2193}", color: .white)
    let size = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let status = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let hover = Pill.dark(0.9, radius: 9, insets: NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6), spacing: 10)
    let reading = Pill.dark(0.86, radius: 6, insets: NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
    let list = CandidateList()
    let help = HelpSheet()
    /// The bars and hint strip sit under the menu bar or notch instead of at the bottom edge.
    var atTop = false

    var all: [NSView] { [upHint, downHint, hover, size, status, reading, hints, list, bottomBar, actionBar, help] }
}
