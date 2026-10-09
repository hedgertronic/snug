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

/// Shortcut, after capture, save folder, Accessibility status, open at login.
struct SettingsView: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @AppStorage(Pref.afterCapture) private var afterCapture = "copy"
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
    @AppStorage(Pref.roundCorners) private var roundCorners = true
    @AppStorage(Pref.highlightColor) private var highlightColor = ""
    @AppStorage(Pref.highlightFill) private var highlightFill = 0.0
    @AppStorage(Pref.highlightFade) private var highlightFade = 0.42
    @AppStorage(Pref.highlightGlow) private var highlightGlow = true
    @AppStorage(Pref.toastPreview) private var toastPreview = true
    @AppStorage(Pref.toastPosition) private var toastPosition = "bottomCenter"
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 20) {
                GridRow {
                    label("Shortcut")
                    ShortcutRecorder(label: Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers))
                        .frame(width: 130, height: 28)
                }
                GridRow {
                    label("After capture")
                    Picker("After capture", selection: $afterCapture) {
                        Text("Copy").tag("copy")
                        Text("Copy and save").tag("copyAndSave")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("Save to")
                    Button(URL(fileURLWithPath: saveFolder).lastPathComponent) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: saveFolder)
                        if panel.runModal() == .OK { saveFolder = panel.url!.path }
                    }
                }
                GridRow {
                    label("Corners")
                    Toggle("Round corners automatically", isOn: $roundCorners)
                }
                GridRow {
                    label("Accessibility")
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if AXIsProcessTrusted() {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow, to highlight parts of apps") { Accessibility.requestTrust() }
                        }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
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
                GridRow {
                    label("Highlight")
                    HStack(spacing: 10) {
                        ColorPicker("Highlight color", selection: Binding(
                            get: { Color(nsColor: Highlight.color(hex: highlightColor)) },
                            set: {
                                let picked = NSColor($0).usingColorSpace(.sRGB)!
                                highlightColor = ColorFormat.hex.string(for: SRGBColor(red: picked.redComponent, green: picked.greenComponent, blue: picked.blueComponent))
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Button("System accent") { highlightColor = "" }.disabled(highlightColor.isEmpty)
                    }
                }
                GridRow {
                    label("Fill")
                    HStack {
                        Slider(value: $highlightFill, in: 0...0.3).frame(width: 180)
                        Text("\(Int((highlightFill * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label("Background fade")
                    HStack {
                        Slider(value: $highlightFade, in: 0...0.6).frame(width: 180)
                        Text("\(Int((highlightFade * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Glow", isOn: $highlightGlow)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HighlightPreview(color: Color(nsColor: Highlight.color(hex: highlightColor)), fill: highlightFill, fade: highlightFade, glow: highlightGlow)
                        .frame(width: 220, height: 90)
                }
                GridRow {
                    label("Toast")
                    Toggle("Preview after capture", isOn: $toastPreview)
                }
                GridRow {
                    label("Toast position")
                    Picker("Toast position", selection: $toastPosition) {
                        Text("Bottom center").tag("bottomCenter")
                        Text("Bottom right").tag("bottomRight")
                        Text("Top right").tag("topRight")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            Divider()
            Text("Everything else lives in the capture overlay. Press ? there.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .frame(width: 540)
        .fixedSize()
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .trailing)
    }
}

/// The highlight on a sample rectangle: the dim, the optional fill and glow, the hairline, and the ring.
struct HighlightPreview: View {
    let color: Color
    let fill: Double
    let fade: Double
    let glow: Bool

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
                if glow { layer.addFilter(.shadow(color: color.opacity(0.45), radius: 9)) }
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
