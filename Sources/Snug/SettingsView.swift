import AppKit
import ServiceManagement
import SwiftUI

/// Exactly four controls: shortcut, after capture, save folder, open at login.
struct SettingsView: View {
    @AppStorage(Pref.hotKeyLabel) private var shortcut = ""
    @AppStorage(Pref.afterCapture) private var afterCapture = "copy"
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent("Shortcut") {
                ShortcutRecorder(label: shortcut)
                    .frame(width: 150, height: 24)
            }
            Picker("After capture", selection: $afterCapture) {
                Text("Copy").tag("copy")
                Text("Copy and save").tag("copyAndSave")
            }
            LabeledContent("Save folder") {
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
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
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
            title = UserDefaults.standard.string(forKey: Pref.hotKeyLabel)!
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard event.keyCode != 53 else { window?.makeFirstResponder(nil); return }
            guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { NSSound.beep(); return }
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Ctrl") }
            if modifiers.contains(.option) { parts.append("Option") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Cmd") }
            parts.append(event.keyCode == 49 ? "Space" : event.charactersIgnoringModifiers!.uppercased())
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Pref.hotKeyCode)
            defaults.set(Int(modifiers.rawValue), forKey: Pref.hotKeyModifiers)
            defaults.set(parts.joined(separator: "-"), forKey: Pref.hotKeyLabel)
            window?.makeFirstResponder(nil)
        }
    }
}
