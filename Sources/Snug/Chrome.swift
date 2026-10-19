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

extension NSColor {
    /// The chrome's colors in its dark and light looks, resolved by the appearance they are drawn in. The surface is more opaque than
    /// the mocks' 84%, which sat on a background blur this flat fill does not have.
    static let chromeText = look(dark: .white.withAlphaComponent(0.92), light: .black.withAlphaComponent(0.86))
    static let chromeSurface = look(dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 53 / 255, alpha: 0.96),
                                    light: NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 0.92))
    static let chromeHairline = look(dark: .white.withAlphaComponent(0.22), light: .black.withAlphaComponent(0.12))
    /// The ring around a color swatch, so dark colors show on the dark surface and light ones on the light surface.
    static let swatchEdge = look(dark: .white.withAlphaComponent(0.5), light: .black.withAlphaComponent(0.3))
    static let capFill = look(dark: .white.withAlphaComponent(0.16), light: .white)
    static let capEdge = look(dark: .black.withAlphaComponent(0.45), light: .black.withAlphaComponent(0.18))

    static func look(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

extension NSView {
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A row (or column) of views on the chrome surface, sized to fit: chips, hints, the groups of a `Bar`. Click-through, except for the
/// `BarButton`s in it, unless `isClickThrough` is off, when clicks on it go nowhere.
@MainActor
final class Pill: NSView {
    var isClickThrough = true
    private var key: String?
    private let insets: NSEdgeInsets
    private let spacing: CGFloat
    private let vertical: Bool
    /// A horizontal pill's fixed height, with its views centered in it; nil fits the views and the insets.
    private let height: CGFloat?
    /// nil is the chrome surface: its fill, hairline, and shadow in the current look.
    private let fill: NSColor?

    init(fill: NSColor? = nil, radius: CGFloat, insets: NSEdgeInsets, spacing: CGFloat, vertical: Bool = false, height: CGFloat? = nil) {
        self.height = height
        self.insets = insets
        self.spacing = spacing
        self.vertical = vertical
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = radius
        if fill == nil {
            layer!.borderWidth = 0.5
            layer!.shadowColor = NSColor.black.cgColor
            layer!.shadowRadius = 11
            layer!.shadowOffset = CGSize(width: 0, height: -8)
        }
        applyLook()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { isClickThrough ? super.hitTest(point) as? BarButton : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {}
    override func viewDidChangeEffectiveAppearance() { applyLook() }

    private func applyLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer!.backgroundColor = (fill ?? .chromeSurface).cgColor
            guard fill == nil else { return }
            layer!.borderColor = NSColor.chromeHairline.cgColor
            layer!.shadowOpacity = isDark ? 0.42 : 0.2
        }
    }

    /// Shows the pill; the views (already sized) are rebuilt only when `key` changes. A new label at the position of a shown label is
    /// copied into it instead: AppKit keeps about three dependency records for every text field that enters a window, after it is freed.
    func show(_ key: String, _ views: () -> [NSView]) {
        isHidden = false
        guard key != self.key else { return }
        self.key = key
        let shown = subviews
        let items = views().enumerated().map { index, new -> NSView in
            guard index < shown.count, let label = shown[index] as? NSTextField, let fresh = new as? NSTextField else { return new }
            label.stringValue = fresh.stringValue
            label.font = fresh.font
            label.textColor = fresh.textColor
            label.frame.size = fresh.frame.size
            return label
        }
        for view in shown where !items.contains(where: { $0 === view }) { view.removeFromSuperview() }
        let gaps = spacing * CGFloat(items.count - 1)
        let inner = vertical
            ? CGSize(width: items.map(\.frame.width).max()!, height: items.reduce(gaps) { $0 + $1.frame.height })
            : CGSize(width: items.reduce(gaps) { $0 + $1.frame.width }, height: items.map(\.frame.height).max()!)
        frame.size = CGSize(width: inner.width + insets.left + insets.right, height: height ?? inner.height + insets.top + insets.bottom)
        if fill == nil { layer!.shadowPath = CGPath(roundedRect: bounds, cornerWidth: layer!.cornerRadius, cornerHeight: layer!.cornerRadius, transform: nil) }
        var offset = vertical ? frame.height - insets.top : insets.left
        for item in items {
            if vertical {
                offset -= item.frame.height
                item.frame.origin = CGPoint(x: insets.left + (inner.width - item.frame.width) / 2, y: offset)
                offset -= spacing
            } else {
                item.frame.origin = CGPoint(x: offset, y: insets.bottom + (frame.height - insets.top - insets.bottom - item.frame.height) / 2)
                offset += item.frame.width + spacing
            }
            if item.superview !== self { addSubview(item) }
        }
    }

    /// An object chip: one line on the surface, a label tier pill, with or without a key cap in it.
    static func chip() -> Pill { Pill(radius: 8, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8), spacing: 8, height: Chrome.labelHeight) }
}

/// The key cap: one key's glyph on a raised key. Idle it is neutral; `pressed` fills it with the tint (for a moment after its chord,
/// or while its modifier is held), darker with a ring on a tint-filled button; `onTint` is the white key on a tint-filled button.
@MainActor
final class KeyCap: NSView {
    let text: String
    /// The chord the cap is part of ("⌘S" for both its caps): a press of the chord lights it.
    let chord: String
    private let label: NSTextField
    var pressed = false {
        didSet { if pressed != oldValue { apply() } }
    }
    var onTint = false {
        didSet { if onTint != oldValue { apply() } }
    }

    init(_ text: String, chord: String? = nil) {
        self.text = text
        self.chord = chord ?? text
        label = NSTextField(text, size: 11, weight: .semibold)
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = 5
        layer!.shadowColor = NSColor.black.cgColor
        layer!.shadowOffset = CGSize(width: 0, height: -1)
        layer!.shadowRadius = 0
        frame.size = CGSize(width: max(20, label.frame.width + 10), height: 20)
        label.frame.origin = CGPoint(x: (frame.width - label.frame.width) / 2, y: (frame.height - label.frame.height) / 2)
        addSubview(label)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { apply() }

    /// Draws the current state in the current look and tint.
    func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if pressed && onTint {
                let fill = Chrome.tint.blended(withFraction: 0.4, of: .black)!
                label.textColor = Chrome.text(on: fill)
                layer!.backgroundColor = fill.cgColor
                layer!.borderWidth = 1
                layer!.borderColor = Chrome.onTint.withAlphaComponent(0.7).cgColor
                layer!.shadowOpacity = 0
            } else {
                label.textColor = pressed ? Chrome.onTint : onTint ? Chrome.tint : .chromeText
                layer!.backgroundColor = (pressed ? Chrome.tint : onTint ? NSColor.white.withAlphaComponent(0.94) : NSColor.capFill).cgColor
                layer!.borderWidth = 0.5
                layer!.borderColor = (pressed || onTint ? NSColor.clear : NSColor.capEdge).cgColor
                layer!.shadowOpacity = isDark ? 0.55 : 0.22
            }
        }
    }

    /// One cap per key of `chord`: each leading modifier glyph, then the key ("⌘S": ⌘ and S; "⌥⌘": ⌥ and ⌘; "esc" stays whole).
    /// Keys are named one way everywhere: a key printed as a word is its lowercase word ("esc", "tab", "space"); the modifiers,
    /// arrows and Return keep their glyphs; letters are uppercase.
    static func caps(_ chord: String) -> [KeyCap] {
        var key = Substring(chord)
        var texts: [String] = []
        while let glyph = key.first, modifiers.contains(where: { $0.glyph == glyph }) {
            texts.append(String(glyph))
            key.removeFirst()
        }
        return (texts + (key.isEmpty ? [] : [String(key)])).map { KeyCap($0, chord: chord) }
    }

    private static let modifiers: [(flag: NSEvent.ModifierFlags, glyph: Character)] = [(.control, "\u{2303}"), (.option, "\u{2325}"), (.shift, "\u{21E7}"), (.command, "\u{2318}")]

    /// A key-down event for a cap's text, so a click on a button presses its key: modifier glyphs, then a key name or character.
    static func event(for text: String) -> NSEvent {
        var flags = NSEvent.ModifierFlags()
        var key = Substring(text)
        while let glyph = key.first, let modifier = modifiers.first(where: { $0.glyph == glyph }) {
            flags.insert(modifier.flag)
            key.removeFirst()
        }
        let (code, characters): (UInt16, String) = switch key {
        case "\u{21A9}": (36, "\r")
        case "esc": (53, "\u{1B}")
        case "tab": (48, "\t")
        // No real key code: the overlay's keys match characters.
        default: (UInt16.max, flags.contains(.shift) ? String(key) : key.lowercased())
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// The cap texts a key press lights: its modifiers then its key ("⌘S", "⇧↩", "P"), and for an arrow or a symbol key, whose caps
    /// carry no modifiers, the key alone.
    static func pressed(by event: NSEvent) -> Set<String> {
        let named: String? = switch event.keyCode {
        case 36, 76: "\u{21A9}"
        case 53: "esc"
        case 48: "tab"
        case 123: "\u{2190}"
        case 124: "\u{2192}"
        case 125: "\u{2193}"
        case 126: "\u{2191}"
        default: nil
        }
        let key = named ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        let letter = key.count == 1 && key.first!.isLetter
        // Shift is part of a letter's or named key's cap; a symbol's character already shows it ("?", "+").
        let held = modifiers.filter { event.modifierFlags.contains($0.flag) && ($0.glyph != "\u{21E7}" || letter || named != nil) }
        let arrow = (123...126).contains(event.keyCode)
        return Set([String(held.map(\.glyph)) + key] + (arrow || !letter && named == nil ? [key] : []))
    }
}

extension Pill {
    /// A hint: a label then its chords, with no surface of its own. A chord shows one cap per key, 2 pt apart.
    static func hint(_ keys: [String], _ label: String) -> Pill {
        let hint = Pill(fill: .clear, radius: 0, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 6)
        hint.show(label + keys.joined()) {
            (label.isEmpty ? [] : [NSTextField(label, size: 12, weight: .medium, color: .chromeText)]) + keys.map { chord in
                let caps = KeyCap.caps(chord)
                guard caps.count > 1 else { return caps[0] }
                let group = Pill(fill: .clear, radius: 0, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 2)
                group.show(chord) { caps }
                return group
            }
        }
        return hint
    }
}

/// The button: a title then one cap per key of its chord, after an optional SF Symbol. Plain; `lit`, a toggle that is on or the
/// current mode (a tint wash and tint text); `primary`, the state's main action (tint fill, white caps); or disabled (`isEnabled` off:
/// dimmed, no clicks), an action that cannot run on this object or under the modifiers held. `surface` gives it the chip surface, for
/// a button that stands alone. The width fits the title in semibold, so a primary title never clips and the caps follow the text. A
/// nil key has no cap.
@MainActor
final class BarButton: NSView {
    var onClick: () -> Void = {}
    /// The chord a click presses.
    private(set) var key: String?
    let title: NSTextField
    /// The chord's caps.
    private(set) var caps: [KeyCap] = []
    let symbol: NSImageView?
    var lit = false {
        didSet { if lit != oldValue { apply() } }
    }
    var primary = false {
        didSet { if primary != oldValue { apply() } }
    }
    var isEnabled = true {
        didSet { if isEnabled != oldValue { apply() } }
    }
    /// Off for a button inside a chip, which keeps the chip's one fill: lit is then the tint text alone.
    var washes = true {
        didSet { if washes != oldValue { apply() } }
    }
    var surface = false {
        didSet {
            layer!.borderWidth = surface ? 0.5 : 0
            apply()
        }
    }
    /// Off, clicks pass through to what is under it.
    var clicks = true
    private let size: CGFloat

    /// `symbol` is an SF Symbol name and its accessibility description.
    init(_ title: String, key: String?, symbol: (name: String, description: String)? = nil, height: CGFloat = 26, size: CGFloat = 12) {
        self.title = NSTextField(title, size: size, weight: .medium)
        self.symbol = symbol.map { NSImageView(image: NSImage(systemSymbolName: $0.name, accessibilityDescription: $0.description)!) }
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        layer!.cornerRadius = 8
        frame.size.height = height
        self.title.frame.origin.y = (height - self.title.frame.height) / 2
        self.title.isHidden = title.isEmpty
        addSubview(self.title)
        if let image = self.symbol {
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            image.frame.size = image.fittingSize
            image.frame.origin.y = ((height - image.frame.height) / 2).rounded()
            addSubview(image)
        }
        setKeys(key)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !isEnabled || !clicks || !frame.contains(point) ? nil : self }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func viewDidChangeEffectiveAppearance() { apply() }

    /// Shows `text` and resizes the button to it.
    func setTitle(_ text: String) {
        guard text != title.stringValue else { return }
        title.stringValue = text
        title.isHidden = text.isEmpty
        fit()
    }

    /// Shows a cap per key of `key`, the chord a click presses, and resizes the button.
    func setKeys(_ key: String?) {
        guard caps.isEmpty || key != self.key else { return }
        self.key = key
        caps.forEach { $0.removeFromSuperview() }
        caps = key.map(KeyCap.caps) ?? []
        for cap in caps {
            cap.frame.origin.y = (frame.height - cap.frame.height) / 2
            addSubview(cap)
        }
        fit()
        apply()
    }

    private func fit() {
        var x: CGFloat = 7
        if let symbol {
            symbol.frame.origin.x = x
            x += symbol.frame.width + (title.isHidden ? 6 : 5)
        }
        if !title.isHidden {
            let width = NSTextField(title.stringValue, size: size, weight: .semibold).frame.width
            title.frame.origin.x = x
            title.frame.size.width = width
            x += width + 7
        }
        for cap in caps {
            cap.frame.origin.x = x
            x += cap.frame.width + 2
        }
        frame.size.width = caps.isEmpty ? x : x - 2 + 7
        invalidateIntrinsicContentSize()
    }

    /// Draws the current state in the current look and tint.
    func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = isDark
            let wash = dark ? 0.26 : 0.16
            let fill: NSColor? = primary ? Chrome.tint
                : lit && washes ? (surface ? NSColor.chromeSurface.blended(withFraction: wash, of: Chrome.tint) : Chrome.tint.withAlphaComponent(wash))
                : surface ? .chromeSurface : nil
            let text: NSColor = primary ? Chrome.onTint : lit ? Chrome.tint.blended(withFraction: dark ? 0.38 : 0.2, of: dark ? .white : .black)! : .chromeText
            layer!.backgroundColor = fill?.cgColor
            layer!.borderColor = NSColor.chromeHairline.cgColor
            title.textColor = text
            title.font = .systemFont(ofSize: size, weight: primary ? .semibold : .medium)
            symbol?.contentTintColor = text
            for cap in caps { cap.onTint = primary }
            alphaValue = isEnabled ? 1 : 0.32
        }
    }
}

/// Floating pills side by side, 8 pt apart, each a group of buttons: the top bar and the action strip. Clicks between the pills go
/// to the overlay; clicks on a pill go nowhere unless they land on a button.
@MainActor
final class Bar: NSView {
    private(set) var groups: [Pill] = []
    private var key: String?

    init() {
        super.init(frame: .zero)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Shows the groups, laid out again only when their buttons or titles change. The pills stay while their number does, so in an
    /// animation a button's new width moves the buttons and pills after it.
    func show(_ groups: [[BarButton]]) {
        isHidden = false
        let key = groups.map { $0.map { $0.title.stringValue + $0.caps.map(\.text).joined() }.joined(separator: ",") }.joined(separator: "|")
        guard key != self.key else { return }
        self.key = key
        if self.groups.count != groups.count {
            self.groups.forEach { $0.removeFromSuperview() }
            self.groups = groups.map { _ in
                let pill = Pill(radius: 11, insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), spacing: 2, height: Chrome.controlHeight)
                pill.isClickThrough = false
                return pill
            }
        }
        var x: CGFloat = 0
        for (pill, buttons) in zip(self.groups, groups) {
            pill.show(key) { buttons }
            pill.frame.origin.x = x
            x += pill.frame.width + 8
            if pill.superview !== self { addSubview(pill) }
        }
        frame.size = CGSize(width: x - 8, height: self.groups.map(\.frame.height).max()!)
    }
}

/// All the overlay's on-screen chrome. `OverlayController.refreshChrome` positions and fills it.
@MainActor
final class Chrome {
    /// The two pill heights. Controls (the top bar's groups, the action strip, the recording pills) and labels (the chip row,
    /// the loupe's readout) keep theirs with or without a key cap inside.
    static let controlHeight: CGFloat = 32
    static let labelHeight: CGFloat = 26
    /// The highlight color: the primary button, pressed caps, lit toggles, the highlighted menu row. Set on each refresh.
    static var tint = NSColor.controlAccentColor
    /// The look `SnugOverlayAppearance` picks for the chrome; nil follows the system.
    static func appearance(_ defaults: UserDefaults) -> NSAppearance? {
        switch defaults.string(forKey: Pref.overlayAppearance)! {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// White or black, whichever reads on `tint`.
    static var onTint: NSColor { text(on: tint) }

    /// White or black, whichever reads on `color`.
    static func text(on color: NSColor) -> NSColor {
        let color = color.usingColorSpace(.sRGB)!
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent > 0.7 ? .black : .white
    }

    /// The settings bar at the bottom center: three pills of remembered settings, the modes, view, and style, then the keys sheet's button.
    let topBar = Bar()
    let modeButtons: [OverlayController.Mode: BarButton] = [.capture: BarButton("Capture", key: "A"), .text: BarButton("Text", key: "T")]
    let viewToggles = [(Pref.loupe, BarButton("Loupe", key: "L")), (Pref.rulers, BarButton("Rulers", key: "R")), (Pref.crosshair, BarButton("Crosshair", key: "X"))]
    let styleToggles = [(Pref.roundCorners, BarButton("Rounded", key: "O")), (Pref.frame, BarButton("Frame", key: "M"))]
    /// Opens the keys sheet, as ? does: the permanent route to every shortcut.
    let keys = BarButton("", key: "?")
    /// The action strip below the hovered element, the selection or the selected text, or a session's (scroll, armed recording, cut
    /// out) controls.
    let strip = Bar()
    let edit = BarButton("Edit", key: "E")
    /// Copy and Save fold their alternates under the modifiers (`OverlayController.captureStrip`): Agent, Text, Translate, Save As.
    let copy = BarButton("Copy", key: "\u{21A9}")
    let save = BarButton("Save", key: "\u{2318}S")
    /// The tools: an SF Symbol and the key; the name is their accessibility label and shows in `toolTip`.
    let scroll = BarButton("", key: "G", symbol: ("arrow.down.document", "Scroll"))
    let record = BarButton("", key: "V", symbol: ("record.circle", "Record"))
    let cutout = BarButton("", key: "K", symbol: ("person.crop.rectangle", "Subject"))
    let colors = BarButton("", key: "U", symbol: ("eyedropper", "Colors"))
    /// The name of the tool button under the pointer, under it after a short delay, as a macOS tooltip. Hover and clicks pass through.
    let toolTip = Pill.chip()
    /// The tool button the pointer is on, and whether its delay has passed.
    var tipButton: BarButton?
    var tipDue = false
    var tipTask: Task<Void, any Error>?
    /// How much wider Copy and Save get under the modifiers than now, at most: the strip's left edge is clamped with it, so a label
    /// change never moves the edge.
    var stripSlack: CGFloat = 0
    static let widest: (copy: CGFloat, save: CGFloat, text: CGFloat) = (
        [("Copy", "\u{21A9}"), ("Agent", "\u{2318}\u{21A9}"), ("Text", "\u{21E7}\u{21A9}"), ("Translate", "\u{2325}\u{21A9}")].map { BarButton($0, key: $1).frame.width }.max()!,
        [("Save", "\u{2318}S"), ("Save As", "\u{21E7}\u{2318}S")].map { BarButton($0, key: $1).frame.width }.max()!,
        [("Copy", "\u{21A9}"), ("Rows", "\u{21E7}\u{21A9}"), ("Translate", "\u{2325}\u{21A9}")].map { BarButton($0, key: $1).frame.width }.max()!)
    let scrolled = BarButton("Scrolling", key: nil)
    /// Scrolling: the stitched image so far, beside the area.
    let minimap = Pill(radius: 8, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), spacing: 0)
    let minimapThumb = Minimap()
    let done = BarButton("Done", key: "\u{21A9}")
    let cancel = BarButton("Cancel", key: "esc")
    let cursor = BarButton("Cursor", key: "H")
    let audio = BarButton("Audio", key: "J")
    let countIn = BarButton("Count-in", key: "I")
    let start = BarButton("Start", key: "\u{21A9}")
    let subject = BarButton("Subject", key: "tab")
    let crop = BarButton("Snap to subject", key: "S")
    /// The chip row above the object: the hovered element's name and size, or the size; Snap; then on a selection the ratio and radius.
    let hover = Pill.chip()
    let size = Pill.chip()
    let snap = BarButton("Snap", key: "S")
    /// Hovering: Snap as a label by the pointer or the loupe's readout, lit when Snap is on. Clicks pass through it.
    let snapTag = BarButton("Snap", key: "S", height: Chrome.labelHeight)
    /// Hovering: the pointer pixel's "x 123  y 456", left of the Snap tag. The two are one pointer cluster; clicks pass through.
    let coordinates = Pill.chip()
    /// The ratio readout with P, which opens `ratioMenu`, and the lock with Shift-P, on one surface.
    let ratio = Pill(radius: 8, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), spacing: 0)
    let ratioButton = BarButton("", key: "P")
    let ratioDivider = NSTextField("|", size: 12, color: NSColor.chromeText.withAlphaComponent(0.5))
    let lock = BarButton("lock", key: "\u{21E7}P")
    let ratioMenu = RatioMenu()
    /// U's menu under the Colors button: the selection's average color and its five main colors.
    let colorMenu = RatioMenu()
    /// The live corner radius with its keys.
    let radius = Pill(radius: 8, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 3), spacing: 6, height: Chrome.labelHeight)
    /// Key caps at the top-left corners of the faint outlines of what Up and Down would select.
    let upHint = KeyCap("\u{2191}")
    let downHint = KeyCap("\u{2193}")
    let reading = Pill.chip()
    /// Notices: text recognition getting ready, a translation not installed, no subject found.
    let status = Pill.chip()
    let list = CandidateList()
    let help = HelpSheet()
    /// On a released selection: the arrow keys at each side (left, right, top, bottom), and in the middle what they do with the
    /// modifiers held now.
    let sideHints = (0..<4).map { _ in Pill(radius: 7, insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3), spacing: 0) }
    let legend = Pill.chip()
    /// Beside the "All corners" chip of a hovered corner dot: the radius keys and Option for one corner.
    let cornerKeys = Pill(radius: 8, insets: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 5), spacing: 5, vertical: true)
    /// The outline the strip and chips were last placed against, in view points; nil with none.
    var anchor: CGRect?
    /// The settings bar sits at the top, moved off the bottom edge by a rectangle there.
    var barAtTop = false
    /// The rulers' thickness the chrome last kept clear of, 0 with Rulers off; a change moves the chrome with the rulers' slide.
    var ruler: CGFloat = 0
    /// The cap texts of the key just pressed, lit for 150 ms.
    var pressed: Set<String> = []
    var pressTask: Task<Void, any Error>?

    init() {
        ratio.isClickThrough = false
        colorMenu.toggleKey = "u"
        snap.surface = true
        snap.isHidden = true
        snapTag.surface = true
        snapTag.clicks = false
        snapTag.isHidden = true
        lock.washes = false
        for button in [copy, done, start] { button.primary = true }
        keys.setAccessibilityElement(true)
        keys.setAccessibilityRole(.button)
        keys.setAccessibilityLabel("All keys")
        for tool in [scroll, record, cutout, colors] {
            tool.setAccessibilityElement(true)
            tool.setAccessibilityRole(.button)
            tool.setAccessibilityLabel(tool.symbol!.image!.accessibilityDescription)
        }
    }

    /// Every button, for the click wiring.
    var buttons: [BarButton] {
        Array(modeButtons.values) + (viewToggles + styleToggles).map(\.1) + [keys]
            + [edit, copy, save, scroll, record, cutout, colors, done, cancel, cursor, audio, countIn, start, subject, crop, snap, ratioButton, lock]
    }

    /// Lowest first, in tiers: the hint caps, the chips, the strip and settings bar with their tool tip and menus, then the keys sheet.
    /// The cut-out preview goes under all of them, and the loupe over them.
    var all: [NSView] { [upHint, downHint, hover, size, snap, ratio, radius, status, reading, legend] + sideHints + [cornerKeys, snapTag, coordinates, list, minimap, topBar, strip, toolTip, ratioMenu, colorMenu, help] }
}
