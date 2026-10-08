import AppKit
import ImageIO
import ScreenshotCore
import SwiftUI

@main
@MainActor
final class SnugApp: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var captureItem: NSMenuItem?
    private var captureTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var firstRunWindow: NSWindow?
    private var registeredShortcut: [Int] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = SnugApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register(in: .standard)
        let arguments = CommandLine.arguments
        let image = arguments.firstIndex(of: "--image").map { index in
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[index + 1]) as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!
        }
        if let image, arguments.contains("--verify-area-ui") || arguments.contains("--verify-extras-ui") || arguments.contains("--verify-text-ui") || arguments.contains("--measure") || arguments.contains("--render-states") {
            let frame = imageFrame(for: image)
            Task {
                do {
                    if let index = arguments.firstIndex(of: "--render-states") {
                        try await DebugRun.renderStates(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--measure") {
                        try await DebugRun.measure(image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--verify-text-ui") {
                        try await DebugRun.verifyText(image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--verify-extras-ui") {
                        try await DebugRun.verifyExtras(image: image, frame: frame, overlay: overlay)
                    } else {
                        try await DebugRun.verifyArea(image: image, frame: frame, overlay: overlay)
                    }
                } catch {
                    FileHandle.standardError.write(Data("Debug run failed: \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        installStatusItem()
        hotKey = HotKey { [unowned self] in capture() }
        registerHotKey()
        Task {
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) { registerHotKey() }
        }
        if let image { overlay.present(image: image, frame: imageFrame(for: image), displayID: nil) }
        // Screen Recording is required, so its absence always shows the window; missing Accessibility shows it once.
        if !CGPreflightScreenCaptureAccess() || (!AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: Pref.accessibilityAsked)) {
            UserDefaults.standard.set(true, forKey: Pref.accessibilityAsked)
            showFirstRun()
        }
    }

    /// A window for a saved image at an integer point-to-pixel scale that fits the main screen.
    private func imageFrame(for image: CGImage) -> CGRect {
        let visible = NSScreen.main!.visibleFrame
        let scale = max(1, ceil(max(CGFloat(image.width) / visible.width, CGFloat(image.height) / visible.height)))
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Shortcut and menu

    private func registerHotKey() {
        let defaults = UserDefaults.standard
        let current = [defaults.integer(forKey: Pref.hotKeyCode), defaults.integer(forKey: Pref.hotKeyModifiers)]
        guard current != registeredShortcut else { return }
        do {
            try hotKey!.register(keyCode: UInt32(defaults.integer(forKey: Pref.hotKeyCode)),
                                 modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Pref.hotKeyModifiers))))
            registeredShortcut = current
            captureItem?.setShortcut(from: defaults)
        } catch {
            NSApp.presentError(error)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button!.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Snug")
        let menu = Self.makeMenu(defaults: .standard)
        captureItem = menu.items[0]
        item.menu = menu
        statusItem = item
    }

    static func makeMenu(defaults: UserDefaults) -> NSMenu {
        let menu = NSMenu()
        let capture = menu.addItem(withTitle: "Capture", action: #selector(captureFromMenu), keyEquivalent: "")
        capture.setShortcut(from: defaults)
        menu.addItem(withTitle: "Copy Text", action: #selector(copyTextFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Repeat Last Area", action: #selector(repeatLastArea), keyEquivalent: "")
        menu.addItem(withTitle: "Open Image...", action: #selector(openImage), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Snap While Dragging", action: #selector(toggleSnap), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func captureFromMenu() { capture() }

    @objc private func toggleSnap() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Pref.snap), forKey: Pref.snap) }

    @objc private func copyTextFromMenu() { capture(text: true) }

    // MARK: Capture

    private func screenUnderPointer() -> (screen: NSScreen, id: CGDirectDisplayID) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }!
        return (screen, CGDirectDisplayID((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value))
    }

    private func capture(text: Bool = false) {
        guard !overlay.window.isVisible else { return }
        guard CGPreflightScreenCaptureAccess() else { return showFirstRun() }
        let (screen, id) = screenUnderPointer()
        captureTask?.cancel()
        captureTask = Task {
            do {
                let capturing = signposter.beginInterval("capture")
                let image = try await DisplayCapture.image(of: id)
                signposter.endInterval("capture", capturing)
                try Task.checkCancellation()
                overlay.present(image: image, frame: screen.frame, displayID: id)
                if text { overlay.setMode(.text) }
                let scale = overlay.scale
                let windows = await DisplayCapture.windows(on: id, pixelScale: scale).map { window in
                    window.name == "Dock" && window.frozen
                        ? (rect: AccessibilityBounds.dockPanel(in: image, around: window.rect, scale: scale), name: window.name, id: window.id, frozen: window.frozen) : window
                }
                if overlay.image === image { overlay.setWindows(windows.map(\.rect), names: windows.map(\.name), ids: windows.map(\.id), frozen: windows.map(\.frozen), pointer: NSEvent.mouseLocation) }
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func repeatLastArea() {
        guard CGPreflightScreenCaptureAccess() else { return showFirstRun() }
        guard let area = UserDefaults.standard.array(forKey: Pref.lastArea) as? [Double] else { return NSSound.beep() }
        let id = CGDirectDisplayID(area[0])
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == id }
        guard let screen else { return NSSound.beep() }
        Task {
            do {
                let image = try await DisplayCapture.image(of: id)
                let scale = CGFloat(image.width) / screen.frame.width
                let crop = CGRect(x: area[1], y: area[2], width: area[3], height: area[4]).applying(CGAffineTransform(scaleX: scale, y: scale))
                let defaults = UserDefaults.standard
                try await Output.deliver(image, crop: crop, style: overlay.style, scale: scale, copy: true,
                                         save: defaults.string(forKey: Pref.afterCapture) == "copyAndSave",
                                         pasteboard: .general, defaults: defaults)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        overlay.present(image: image, frame: imageFrame(for: image), displayID: nil)
    }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Snug Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow!.makeKeyAndOrderFront(nil)
    }

    private func showFirstRun() {
        if firstRunWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: FirstRunView(onLater: { [unowned self] in firstRunWindow?.close() })))
            window.title = "Welcome to Snug"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            firstRunWindow = window
        }
        NSApp.activate()
        firstRunWindow!.center()
        firstRunWindow!.makeKeyAndOrderFront(nil)
    }
}

extension SnugApp: NSMenuItemValidation {
    /// Checks Snap While Dragging when snapping is on; the S key in the overlay changes the same preference.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSnap) { item.state = UserDefaults.standard.bool(forKey: Pref.snap) ? .on : .off }
        return true
    }
}

extension NSMenuItem {
    /// Shows the recorded hot key as this item's right-aligned key equivalent.
    func setShortcut(from defaults: UserDefaults) {
        let code = defaults.integer(forKey: Pref.hotKeyCode)
        if let function = Shortcut.functionKeys[code] {
            keyEquivalent = String(Character(UnicodeScalar(function.character)!))
        } else {
            let name = Shortcut.keyNames[code]!
            keyEquivalent = name == "Space" ? " " : name.lowercased()
        }
        keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Pref.hotKeyModifiers)))
    }
}
