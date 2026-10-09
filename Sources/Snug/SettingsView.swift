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
    static let width: CGFloat = 500
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
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            controller.addTabViewItem(item)
        }
        return controller
    }
}

/// The app icon and name once, then shortcut, after capture, save folder, open at login, and the permissions.
private struct GeneralPane: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @AppStorage(Pref.afterCapture) private var afterCapture = "copy"
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snug").font(.system(size: 28, weight: .heavy, design: .rounded))
                        Text("Press \(Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)) to capture. Press ? in the overlay for every key.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(label: Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)).frame(width: 130, height: 28)
                }
                Picker("After capture", selection: $afterCapture) {
                    Text("Copy").tag("copy")
                    Text("Copy and save").tag("copyAndSave")
                }
                .pickerStyle(.segmented)
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
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSApp.presentError(error)
                            opensAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            // macOS sends no notification when a permission changes, so the rows re-read both every second.
            Section("Permissions") {
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
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsTabs.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permission(_ name: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: allow)
            }
        } label: {
            Text(name)
            Text(detail)
        }
    }
}

/// The highlight (live preview, color swatches, fill, fade, glow) and the toast.
private struct AppearancePane: View {
    @AppStorage(Pref.highlightColor) private var highlightColor = ""
    @AppStorage(Pref.highlightFill) private var highlightFill = 0.0
    @AppStorage(Pref.highlightFade) private var highlightFade = 0.42
    @AppStorage(Pref.highlightGlow) private var highlightGlow = 0.5
    @AppStorage(Pref.toastPreview) private var toastPreview = true
    @AppStorage(Pref.toastPosition) private var toastPosition = "bottomCenter"

    private var customSelected: Bool { !Highlight.presets.contains { $0.hex == highlightColor } }

    var body: some View {
        Form {
            Section("Highlight") {
                HighlightPreview(color: Color(nsColor: Highlight.color(hex: highlightColor)), fill: highlightFill, fade: highlightFade, glow: highlightGlow)
                    .frame(height: 104)
                    .listRowInsets(EdgeInsets())
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Highlight.presets, id: \.hex) { preset in
                            swatch(Color(nsColor: Highlight.color(hex: preset.hex)), selected: highlightColor == preset.hex)
                                .onTapGesture { highlightColor = preset.hex }
                                .help(preset.name)
                        }
                        swatch(customSelected ? Color(nsColor: Highlight.color(hex: highlightColor)) : nil, selected: customSelected)
                            .overlay {
                                ColorPicker("Custom...", selection: Binding(
                                    get: { Color(nsColor: Highlight.color(hex: highlightColor)) },
                                    set: {
                                        let picked = NSColor($0).usingColorSpace(.sRGB)!
                                        highlightColor = ColorFormat.hex.string(for: SRGBColor(red: picked.redComponent, green: picked.greenComponent, blue: picked.blueComponent))
                                    }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                .opacity(0.02)
                            }
                            .help("Custom...")
                    }
                }
                slider("Fill", value: $highlightFill, range: 0...0.3)
                slider("Background fade", value: $highlightFade, range: 0...0.6)
                slider("Glow", value: $highlightGlow, range: 0...1)
            }
            Section("After capture") {
                Toggle(isOn: $toastPreview) {
                    Text("Show a preview")
                    Text("Thumbnail above the toast. Drag it out to drop the image.")
                }
                Picker("Toast position", selection: $toastPosition) {
                    Text("Bottom center").tag("bottomCenter")
                    Text("Bottom right").tag("bottomRight")
                    Text("Top right").tag("topRight")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: SettingsTabs.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A 20 pt circle; a nil color draws the "Custom..." rainbow. The selected one gets an outer ring.
    private func swatch(_ color: Color?, selected: Bool) -> some View {
        Circle()
            .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)))
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
            .padding(2)
            .overlay(Circle().stroke(Color.primary.opacity(0.7), lineWidth: 1.5).opacity(selected ? 1 : 0))
            .contentShape(Circle())
    }

    /// A slider with its value as a percentage.
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 180)
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// A read-only guide to the overlay keys, built from the same table as the ? sheet.
private struct KeysPane: View {
    var body: some View {
        Form {
            ForEach(HelpSheet.columns, id: \.title) { column in
                Section(column.title) {
                    ForEach(column.rows, id: \.action) { row in
                        LabeledContent(row.action) { Text(row.keys).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsTabs.width, height: 520)
    }
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

/// Click, then press a shortcut with at least one of Control, Option, or Command.
private struct ShortcutRecorder: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) { button.title = label }

    final class RecorderButton: NSButton {
        override var acceptsFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func beginRecording() {
            window?.makeFirstResponder(self)
            title = "Type shortcut"
        }

        override func resignFirstResponder() -> Bool {
            title = Shortcut.label(from: .standard)
            return super.resignFirstResponder()
        }

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
