#if DEBUG
import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--verify-rename-live`: real toasts on screen take typed keys in Rename's field (Return renames, Esc cancels, losing the keyboard
    /// renames) and give the keyboard back without Snug ever becoming the active app; then, when Apple Intelligence is available, one
    /// save is renamed by the real on-device model and its toast follows. Unlike the headless runs, this one lets a toast take keys, so
    /// toasts show on screen for a few seconds. It writes only under a temporary folder and uses its own pasteboard and defaults.
    static func verifyRenameLive(image: CGImage) async throws {
        var passed = 0
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Rename live verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed += 1
            FileHandle.standardError.write(Data("  ok: \(message)\n".utf8))
        }
        Sound.isMuted = true
        let temporary = FileManager.default.temporaryDirectory
        let defaults = UserDefaults(suiteName: temporary.appending(path: "snug-rename-live-\(UUID().uuidString)").path)!
        Pref.register(in: defaults)
        defaults.set(-1, forKey: Pref.toastLifetime)
        let folder = temporary.appending(path: "snug-rename-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(folder.path, forKey: Pref.saveFolder)
        let board = NSPasteboard(name: NSPasteboard.Name("snug-rename-live-\(UUID().uuidString)"))
        let png = try await Output.png(image.cropping(to: CGRect(x: 0, y: 0, width: min(image.width, 1200), height: min(image.height, 700)))!)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }

        let front = NSWorkspace.shared.frontmostApplication
        require(!NSApp.isActive && front != nil && front?.processIdentifier != getpid(),
                "Snug starts in the background, behind \(front?.localizedName ?? "nothing")")
        /// The app the keyboard goes to, as Accessibility reports it; nil without Accessibility.
        func focusedPID() -> pid_t? {
            guard AXIsProcessTrusted() else { return nil }
            var app: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success, let app else { return nil }
            var pid: pid_t = 0
            AXUIElementGetPid(app as! AXUIElement, &pid)
            return pid
        }
        func stillBehind(_ toast: Toast, _ when: String) {
            require(!toast.isKeyWindow && NSApp.keyWindow == nil && !NSApp.isActive && NSWorkspace.shared.frontmostApplication == front,
                    "\(when), the toast gives up the keyboard and Snug stays in the background")
            if let pid = focusedPID() {
                require(pid == front!.processIdentifier, "\(when), \(front!.localizedName ?? "the app in front") has the keyboard again (focused pid \(pid))")
            } else {
                print("rename-live          skipped the focused-app check: this process has no Accessibility permission")
            }
        }
        func key(_ toast: Toast, _ characters: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                toast.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: toast.windowNumber, context: nil, characters: characters,
                                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            }
        }
        func type(_ toast: Toast, _ text: String) { for character in text { key(toast, String(character), code: 0) } }
        func saved(_ name: String) throws -> URL {
            let file = folder.appending(path: name).appendingPathExtension("png")
            try png.write(to: file)
            return file
        }
        func show(_ file: URL) -> Toast {
            Toast.show(png: png, message: "Saved to \(folder.lastPathComponent)", detail: "1200 x 700", file: file, defaults: defaults, pasteboard: board)
            return Toast.shown.last!
        }
        func openRename(_ toast: Toast) async throws {
            toast.renameButton.performClick(nil)
            try await Task.sleep(for: .milliseconds(150))
            let name = toast.file!.deletingPathExtension().lastPathComponent
            // A key nonactivating panel reports its app active while another app stays frontmost, with its menu bar.
            require(toast.nameField != nil && toast.isKeyWindow && NSWorkspace.shared.frontmostApplication == front,
                    "Rename gives the toast the keyboard while \(front?.localizedName ?? "the app in front") stays frontmost: field \(toast.nameField != nil) key \(toast.isKeyWindow) "
                        + "active \(NSApp.isActive) front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none") keyWindow \(String(describing: NSApp.keyWindow))")
            require(toast.nameField?.currentEditor()?.selectedRange == NSRange(location: 0, length: name.utf16.count), "the whole name starts selected: \(String(describing: toast.nameField?.currentEditor()?.selectedRange)) of \(name.utf16.count), "
                        + "editor \(toast.nameField?.currentEditor() != nil), first responder \(String(describing: toast.firstResponder))")
        }

        let first = try saved("Snug 2026-11-14 at 18.03.12")
        let returning = show(first)
        try await openRename(returning)
        type(returning, "Flight to Lisbon")
        key(returning, "\r", code: 36)
        try await Task.sleep(for: .milliseconds(150))
        let renamed = folder.appending(path: "Flight to Lisbon.png")
        require(returning.nameField == nil && returning.file == renamed && exists(renamed) && !exists(first),
                "typed keys replace the selected name and Return renames the file")
        stillBehind(returning, "after Return")
        returning.dismiss()

        let second = try saved("Escape test")
        let escaping = show(second)
        try await openRename(escaping)
        type(escaping, "Nope")
        key(escaping, "\u{1B}", code: 53)
        try await Task.sleep(for: .milliseconds(150))
        require(escaping.nameField == nil && escaping.file == second && exists(second) && !exists(folder.appending(path: "Nope.png")),
                "Esc closes the field and renames nothing")
        stillBehind(escaping, "after Esc")

        try await openRename(escaping)
        type(escaping, "Clicked away")
        // A click in another app takes the keyboard from the toast; resignKey is what AppKit calls then.
        escaping.resignKey()
        try await Task.sleep(for: .milliseconds(150))
        require(escaping.nameField == nil && escaping.file == folder.appending(path: "Clicked away.png") && exists(escaping.file!),
                "losing the keyboard renames to what was typed, as Finder does")
        stillBehind(escaping, "after a click away")
        escaping.dismiss()

        if let reason = CaptureNamer.unavailableReason {
            print("rename-live          skipped the on-device model: \(reason)")
        } else {
            defaults.set(true, forKey: Pref.aiNames)
            defaults.set(CaptureName.contextPattern, forKey: Pref.fileNamePattern)
            await Output.publish(png: png, detail: "1200 x 700", copy: false, save: true, context: CaptureContext(app: "Safari", title: nil),
                                 pasteboard: board, defaults: defaults)
            let shown = Toast.shown.last!
            let original = shown.file!
            let started = ContinuousClock.now
            let moved = await CaptureNamer.lastRename?.value
            require(moved != nil && moved != original && moved!.lastPathComponent.hasPrefix("Safari - ") && exists(moved!) && !exists(original) && shown.file == moved,
                    "the on-device model renames a real save in \(Int(started.duration(to: .now).milliseconds)) ms and its toast follows: "
                        + "\(original.lastPathComponent) -> \(moved?.lastPathComponent ?? "nothing")")
            shown.dismiss()
        }
        print("rename-live          \(passed) checks passed")
        exit(EXIT_SUCCESS)
    }
}
#endif
