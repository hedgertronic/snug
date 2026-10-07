import AppKit
import ServiceManagement
import SwiftUI

/// The hot key's display string and menu key equivalent, derived from the stored key code and modifiers.
enum Shortcut {
    /// US-layout key names for the keys the recorder accepts: letters, digits, punctuation, and Space.
    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "Space", 50: "`"
    ]

    static func label(code: Int, modifiers: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "\u{2303}" : "") + (flags.contains(.option) ? "\u{2325}" : "")
            + (flags.contains(.shift) ? "\u{21E7}" : "") + (flags.contains(.command) ? "\u{2318}" : "") + keyNames[code]!
    }

    static func label(from defaults: UserDefaults) -> String {
        label(code: defaults.integer(forKey: Pref.hotKeyCode), modifiers: defaults.integer(forKey: Pref.hotKeyModifiers))
    }
}

/// Exactly four controls: shortcut, after capture, save folder, open at login.
struct SettingsView: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @AppStorage(Pref.afterCapture) private var afterCapture = "copy"
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
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
            guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { NSSound.beep(); return }
            guard Shortcut.keyNames[Int(event.keyCode)] != nil else { NSSound.beep(); return }
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Pref.hotKeyCode)
            defaults.set(Int(modifiers.rawValue), forKey: Pref.hotKeyModifiers)
            window?.makeFirstResponder(nil)
        }
    }
}
