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
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 20) {
                GridRow {
                    label("Shortcut")
                    ShortcutRecorder(label: shortcut)
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
            title = UserDefaults.standard.string(forKey: Pref.hotKeyLabel)!
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard event.keyCode != 53 else { window?.makeFirstResponder(nil); return }
            guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { NSSound.beep(); return }
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("\u{2303}") }
            if modifiers.contains(.option) { parts.append("\u{2325}") }
            if modifiers.contains(.shift) { parts.append("\u{21E7}") }
            if modifiers.contains(.command) { parts.append("\u{2318}") }
            parts.append(event.keyCode == 49 ? "Space" : event.charactersIgnoringModifiers!.uppercased())
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Pref.hotKeyCode)
            defaults.set(Int(modifiers.rawValue), forKey: Pref.hotKeyModifiers)
            defaults.set(parts.joined(), forKey: Pref.hotKeyLabel)
            window?.makeFirstResponder(nil)
        }
    }
}
