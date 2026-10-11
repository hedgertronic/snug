import AppKit
import Carbon.HIToolbox

/// A global shortcut through Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        precondition(status == noErr, "InstallEventHandler failed: \(status)")
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Replaces the registered shortcut. Throws when another app already owns it.
    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) throws {
        unregister()
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        let status = RegisterEventHotKey(keyCode, UInt32(carbon), EventHotKeyID(signature: OSType(0x534E5547), id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
