import AppKit
import ServiceManagement
import ScreenshotCore
import SwiftUI

/// The hot key's display string and menu key equivalent, derived from the stored key code and modifiers.
enum Shortcut {
    /// Function keys F1-F12 by key code, with the `NSF1FunctionKey`-based character a menu key equivalent needs.
    static let functionKeys: [Int: (name: String, character: Int)] = [
        122: ("F1", NSF1FunctionKey), 120: ("F2", NSF2FunctionKey), 99: ("F3", NSF3FunctionKey), 118: ("F4", NSF4FunctionKey),
        96: ("F5", NSF5FunctionKey), 97: ("F6", NSF6FunctionKey), 98: ("F7", NSF7FunctionKey), 100: ("F8", NSF8FunctionKey),
        101: ("F9", NSF9FunctionKey), 109: ("F10", NSF10FunctionKey), 103: ("F11", NSF11FunctionKey), 111: ("F12", NSF12FunctionKey)
    ]

    /// US-layout key names for the other keys the recorder accepts: letters, digits, punctuation, and Space.
    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "Space", 50: "`"
    ]

    static func label(code: Int, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "\u{2303}" : "") + (flags.contains(.option) ? "\u{2325}" : "")
            + (flags.contains(.shift) ? "\u{21E7}" : "") + (flags.contains(.command) ? "\u{2318}" : "") + (functionKeys[code]?.name ?? keyNames[code]!)
    }

    static func label(from defaults: UserDefaults) -> String {
        label(code: defaults.integer(forKey: Pref.hotKeyCode), modifiers: defaults.integer(forKey: Pref.hotKeyModifiers))
    }
}

/// The Settings window's toolbar tabs. The window title follows the selected tab.
@MainActor
enum SettingsTabs {
    static let width: CGFloat = 400
    static let panes: [(title: String, symbol: String, view: AnyView)] = [
        ("General", "gearshape", AnyView(GeneralPane())),
        ("Appearance", "paintpalette", AnyView(AppearancePane())),
        ("Keys", "keyboard", AnyView(KeysPane()))
    ]

    static func makeController() -> NSTabViewController {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        for pane in panes {
            let host = NSHostingController(rootView: pane.view)
            host.sizingOptions = .preferredContentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            controller.addTabViewItem(item)
        }
        return controller
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeController())
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }
}

/// A pane's content: 20 pt side insets, 14 pt between blocks.
private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.init(top: 18, leading: 20, bottom: 20, trailing: 20))
            .frame(width: SettingsTabs.width, alignment: .leading)
    }
}

/// A row's label at the leading edge and its control at the trailing edge.
private struct RowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// Rows on a rounded card, separated by hairlines. Each row is at least `rowHeight` tall with 12 pt side insets.
private struct Card<Content: View>: View {
    var rowHeight: CGFloat = 38
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    rows[index].padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    if index < rows.count - 1 { Divider() }
                }
            }
        }
        .labeledContentStyle(RowStyle())
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
    }
}

/// A row title with a smaller secondary line under it.
private func detailed(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
}

/// The app icon and name once, then shortcut, after capture, save folder, open at login, recording, and the permissions.
private struct GeneralPane: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @AppStorage(Pref.afterCapture) private var afterCapture = "copy"
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Pane {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snug").font(.system(size: 28, weight: .heavy, design: .rounded))
                        Text("Press \(Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)) to capture.\nPress ? in the overlay for every key.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Card {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(label: Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)).fixedSize()
                    }
                    LabeledContent("After capture") {
                        Picker("After capture", selection: $afterCapture) {
                            Text("Copy").tag("copy")
                            Text("Copy and save").tag("copyAndSave")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    LabeledContent("Save to") {
                        Button(URL(fileURLWithPath: saveFolder).lastPathComponent) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.directoryURL = URL(fileURLWithPath: saveFolder)
                            if panel.runModal() == .OK { saveFolder = panel.url!.path }
                        }
                    }
                    LabeledContent("Open at login") {
                        Toggle("Open at login", isOn: $opensAtLogin).labelsHidden().toggleStyle(.switch)
                    }
                    .onChange(of: opensAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSApp.presentError(error)
                            opensAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                }
                RecordingSettings()
                caption("Permissions")
                // macOS sends no notification when a permission changes, so the rows re-read both every second.
                Card {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        permission("Screen Recording", detail: "Required", granted: CGPreflightScreenCaptureAccess()) {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        permission("Accessibility", detail: "Recommended, highlights parts of apps", granted: AXIsProcessTrusted()) { Accessibility.requestTrust() }
                    }
                }
            }
            Divider()
            Text("Everything else lives in the capture overlay.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.init(top: 10, leading: 20, bottom: 14, trailing: 20))
                .frame(width: SettingsTabs.width, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permission(_ name: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: allow).buttonStyle(.borderedProminent)
            }
        } label: {
            detailed(name, detail)
        }
        .padding(.vertical, 4)
    }
}

/// The Recording group: the count-in before a recording starts and whether recordings show the cursor.
private struct RecordingSettings: View {
    @AppStorage(Pref.recordCountIn) private var countIn = 3
    @AppStorage(Pref.recordCursor) private var showsCursor = true

    var body: some View {
        caption("Recording")
        Card {
            LabeledContent("Count-in") {
                Picker("Count-in", selection: $countIn) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent {
                Toggle("Show cursor", isOn: $showsCursor).labelsHidden().toggleStyle(.switch)
            } label: {
                detailed("Show cursor", "H switches it for one recording")
            }
        }
    }
}

/// The highlight (live preview, color menu, fill, fade, glow) and the toast.
private struct AppearancePane: View {
    @AppStorage(Pref.highlightColor) private var highlightColor = ""
    @AppStorage(Pref.highlightFill) private var highlightFill = 0.0
    @AppStorage(Pref.highlightFade) private var highlightFade = 0.42
    @AppStorage(Pref.highlightGlow) private var highlightGlow = 0.5
    @AppStorage(Pref.toastPreview) private var toastPreview = true
    @AppStorage(Pref.toastPosition) private var toastPosition = "bottomCenter"

    private static let positions: [(tag: String, title: String, alignment: Alignment)] = [
        ("bottomCenter", "Bottom center", .bottom), ("bottomRight", "Bottom right", .bottomTrailing), ("topRight", "Top right", .topTrailing)
    ]

    var body: some View {
        Pane {
            caption("Highlight")
            HighlightPreview(color: Color(nsColor: Highlight.color(hex: highlightColor)), fill: highlightFill, fade: highlightFade, glow: highlightGlow)
                .frame(height: 104)
            Card {
                LabeledContent("Color") { ColorMenu(hex: $highlightColor).fixedSize() }
                slider("Fill", value: $highlightFill, range: 0...0.3)
                slider("Background fade", value: $highlightFade, range: 0...0.6)
                slider("Glow", value: $highlightGlow, range: 0...1)
            }
            caption("After capture")
            Card {
                LabeledContent {
                    Toggle("Show a preview", isOn: $toastPreview).labelsHidden().toggleStyle(.switch)
                } label: {
                    detailed("Show a preview", "Thumbnail above the toast. Drag it out to drop the image.")
                }
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Toast position")
                    HStack(spacing: 8) {
                        ForEach(Self.positions, id: \.tag) { position in
                            let selected = toastPosition == position.tag
                            Button { toastPosition = position.tag } label: {
                                VStack(spacing: 5) {
                                    ZStack(alignment: position.alignment) {
                                        RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(red: 0.72, green: 0.77, blue: 0.82), Color(red: 0.87, green: 0.89, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : Color(white: 0.16, opacity: 0.85)).frame(width: 22, height: 9).padding(5)
                                    }
                                    .frame(height: 46)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                                    Text(position.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Color.accentColor : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A slider with its value as a percentage.
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range).frame(width: 150)
                Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/// The highlight color as a pop-up: the system accent, the eight macOS accents with a color dot each, then "Custom..." for the color panel.
private struct ColorMenu: NSViewRepresentable {
    @Binding var hex: String

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.pick)
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.hex = $hex
        popUp.removeAllItems()
        for preset in Highlight.presets {
            popUp.addItem(withTitle: preset.name)
            popUp.lastItem!.image = Self.dot(Highlight.color(hex: preset.hex))
            popUp.lastItem!.representedObject = preset.hex
        }
        popUp.addItem(withTitle: "Custom...")
        let selected = popUp.indexOfItem(withRepresentedObject: hex)
        if selected >= 0 {
            popUp.selectItem(at: selected)
        } else {
            popUp.lastItem!.image = Self.dot(Highlight.color(hex: hex))
            popUp.selectItem(at: popUp.numberOfItems - 1)
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            circle.stroke()
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var hex: Binding<String>

        init(hex: Binding<String>) { self.hex = hex }

        @objc func pick(_ popUp: NSPopUpButton) {
            if let preset = popUp.selectedItem!.representedObject as? String {
                hex.wrappedValue = preset
                return
            }
            // Until a color is picked, the menu keeps showing the current choice.
            let current = popUp.indexOfItem(withRepresentedObject: hex.wrappedValue)
            if current >= 0 { popUp.selectItem(at: current) }
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            panel.color = Highlight.color(hex: hex.wrappedValue)
            panel.setTarget(self)
            panel.setAction(#selector(colorChanged))
            panel.orderFront(nil)
        }

        @objc func colorChanged(_ panel: NSColorPanel) {
            let picked = panel.color.usingColorSpace(.sRGB)!
            hex.wrappedValue = ColorFormat.hex.string(for: SRGBColor(red: picked.redComponent, green: picked.greenComponent, blue: picked.blueComponent))
        }
    }
}

/// A read-only guide to the overlay keys, built from the same table as the ? sheet: the action, then its key caps.
private struct KeysPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Every overlay key, grouped like the ? sheet. Rebinding is planned.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(HelpSheet.columns, id: \.title) { column in
                    caption(column.title)
                    Card(rowHeight: 30) {
                        ForEach(column.rows, id: \.action) { row in
                            LabeledContent {
                                HStack(spacing: 4) {
                                    ForEach(Self.caps(row.keys), id: \.self) { KeyCapView(text: $0).fixedSize() }
                                }
                            } label: {
                                Text(row.action).font(.system(size: 12.5))
                            }
                        }
                    }
                }
            }
            .padding(.init(top: 10, leading: 20, bottom: 20, trailing: 20))
        }
        .frame(width: SettingsTabs.width, height: 520)
    }

    /// The caps for a row's keys: alternatives split on " / ", modifier words as their symbols.
    private static func caps(_ keys: String) -> [String] {
        keys.components(separatedBy: " / ").map {
            $0.replacingOccurrences(of: "Option-", with: "\u{2325}").replacingOccurrences(of: "Cmd-", with: "\u{2318}").replacingOccurrences(of: "Shift-", with: "\u{21E7}")
        }
    }
}

/// The overlay's key cap in SwiftUI.
private struct KeyCapView: NSViewRepresentable {
    let text: String

    /// `KeyCap` reports its frame as its size, and SwiftUI resizes the frame, so the size it was built with is kept here.
    final class Coordinator { var size = CGSize.zero }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyCap {
        let cap = KeyCap(text)
        context.coordinator.size = cap.frame.size
        return cap
    }

    func updateNSView(_ cap: KeyCap, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView cap: KeyCap, context: Context) -> CGSize? { context.coordinator.size }
}

/// The highlight on a sample rectangle: the dim, the optional fill and glow, the hairline, and the ring.
struct HighlightPreview: View {
    let color: Color
    let fill: Double
    let fade: Double
    let glow: Double

    var body: some View {
        Canvas { context, size in
            let sample = CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 20)
            let shape = Path(roundedRect: sample, cornerRadius: 10)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            for row in 0..<4 {
                context.fill(Path(CGRect(x: 8, y: 10 + CGFloat(row) * 22, width: size.width - 16, height: 8)), with: .color(Color(white: 0.78)))
            }
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addPath(shape)
            context.fill(dim, with: .color(.black.opacity(fade)), style: FillStyle(eoFill: true))
            context.fill(shape, with: .color(color.opacity(fill)))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: color.opacity(min(1, 1.6 * glow)), radius: 4 + 14 * glow))
                layer.stroke(shape, with: .color(color), lineWidth: 1.5)
            }
            context.stroke(Path(roundedRect: sample.insetBy(dx: -2.25, dy: -2.25), cornerRadius: 12.25), with: .color(color.opacity(0.28)), lineWidth: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

/// A key cap that records a shortcut: click, then press one with at least one of Control, Option, or Command. Styled like the overlay's key caps.
private struct ShortcutRecorder: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) { button.show(label, recording: false) }

    final class RecorderButton: NSButton {
        private var recording = false
        override var acceptsFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            isBordered = false
            wantsLayer = true
            layer!.cornerRadius = 5
            layer!.shadowOffset = CGSize(width: 0, height: -1)
            layer!.shadowRadius = 0
            target = self
            action = #selector(beginRecording)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The cap's text, or while `recording` a dashed accent outline with a prompt.
        func show(_ text: String, recording: Bool) {
            self.recording = recording
            attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
            ])
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer!.backgroundColor = recording ? NSColor.clear.cgColor : NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
                layer!.borderColor = (recording ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.45)).cgColor
            }
            layer!.borderWidth = recording ? 1.5 : 0.5
            layer!.shadowColor = NSColor.black.cgColor
            layer!.shadowOpacity = recording ? 0 : 0.55
            invalidateIntrinsicContentSize()
        }

        override var intrinsicContentSize: NSSize { NSSize(width: max(80, attributedTitle.size().width + 24), height: 26) }

        @objc private func beginRecording() {
            window?.makeFirstResponder(self)
            show("Type shortcut", recording: true)
        }

        override func resignFirstResponder() -> Bool {
            show(Shortcut.label(from: .standard), recording: false)
            return super.resignFirstResponder()
        }

        override func viewDidChangeEffectiveAppearance() { show(attributedTitle.string, recording: recording) }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard event.keyCode != 53 else { window?.makeFirstResponder(nil); return }
            let isFunctionKey = Shortcut.functionKeys[Int(event.keyCode)] != nil
            guard isFunctionKey || !modifiers.isDisjoint(with: [.control, .option, .command]) else { NSSound.beep(); return }
            guard isFunctionKey || Shortcut.keyNames[Int(event.keyCode)] != nil else { NSSound.beep(); return }
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Pref.hotKeyCode)
            defaults.set(Int(modifiers.rawValue), forKey: Pref.hotKeyModifiers)
            window?.makeFirstResponder(nil)
        }
    }
}
