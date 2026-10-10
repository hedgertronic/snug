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
    /// The running screen recording, the status item's menu and icon it replaces, and the loop updating its elapsed time.
    private var recording: (session: ScreenRecording, menu: NSMenu?, icon: NSImage?, ticker: Task<Void, any Error>)?

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
        if let index = arguments.firstIndex(of: "--cutout") {
            Task {
                do {
                    try await DebugRun.cutout(URL(fileURLWithPath: arguments[index + 1]), into: URL(fileURLWithPath: arguments[index + 2]), visionKit: arguments.contains("--visionkit"))
                } catch {
                    FileHandle.standardError.write(Data("Cutout failed: \(error)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--render-settings") {
            try! DebugRun.renderSettings(into: URL(fileURLWithPath: arguments[index + 1]))
            exit(EXIT_SUCCESS)
        }
        if arguments.contains("--verify-settings-capture") {
            Task { try! await DebugRun.verifySettingsCapture(overlay: overlay) }
            return
        }
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
        ScreenRecording.requested = { [unowned self] in startRecording(displayID: $0, area: $1) }
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
        item.button!.image = Self.menuBarIcon()
        let menu = Self.makeMenu(defaults: .standard)
        captureItem = menu.items[0]
        item.menu = menu
        statusItem = item
    }

    /// The logo as a template image: the app tile as a solid rounded square with the dashed arch and the band cut out of it.
    /// Drawn in an 18 pt space with the tile edges and arch strokes on whole points and scaled to whatever rectangle it is asked for,
    /// so it is sharp at 1x and 2x.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 18)
            transform.concat()
            NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.current!.compositingOperation = .clear
            let arch = NSBezierPath()
            arch.move(to: CGPoint(x: 5, y: 9))
            arch.line(to: CGPoint(x: 5, y: 11))
            arch.appendArc(withCenter: CGPoint(x: 8, y: 11), radius: 3, startAngle: 180, endAngle: 90, clockwise: true)
            arch.line(to: CGPoint(x: 10, y: 14))
            arch.appendArc(withCenter: CGPoint(x: 10, y: 11), radius: 3, startAngle: 90, endAngle: 0, clockwise: true)
            arch.line(to: CGPoint(x: 13, y: 9))
            arch.lineWidth = 2
            arch.lineCapStyle = .round
            // Five round dots, one at each end and three between, spaced evenly along the path's 6 + 3 pi pt.
            let spacing = (6 + 3 * CGFloat.pi) / 4
            arch.setLineDash([0.01, spacing - 0.01], count: 2, phase: 0)
            arch.stroke()
            let band = NSBezierPath()
            band.move(to: CGPoint(x: 0, y: 6))
            band.curve(to: CGPoint(x: 18, y: 6), controlPoint1: CGPoint(x: 5.4, y: 8.25), controlPoint2: CGPoint(x: 12.6, y: 8.25))
            band.lineWidth = 1.5
            band.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snug"
        return image
    }

    static func makeMenu(defaults: UserDefaults) -> NSMenu {
        let menu = NSMenu()
        let capture = menu.addItem(withTitle: "Capture", action: #selector(captureFromMenu), keyEquivalent: "")
        capture.setShortcut(from: defaults)
        menu.addItem(withTitle: "Capture Text", action: #selector(copyTextFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Repeat Last Area", action: #selector(repeatLastArea), keyEquivalent: "")
        menu.addItem(withTitle: "Open Image...", action: #selector(openImage), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "About Snug", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func captureFromMenu() { capture() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func copyTextFromMenu() { capture(text: true) }

    // MARK: Capture

    private func screenUnderPointer() -> (screen: NSScreen, id: CGDirectDisplayID) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }!
        return (screen, CGDirectDisplayID((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value))
    }

    private func capture(text: Bool = false) {
        if recording != nil { return stopRecording() }
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
                let listing = signposter.beginInterval("windows")
                var windows = await DisplayCapture.windows(on: id, pixelScale: scale)
                // The Dock's AXList union is the magnified Dock, tens of points past the panel; the panel's rim in the frozen image gives its edges.
                for index in windows.indices where windows[index].name == "Dock" && windows[index].frozen {
                    let union = windows[index].rect
                    Pref.logHoverLine("dock union \(union) scale \(scale) image \(image.width)x\(image.height)")
                    // Live item frames are magnified, so the tiles come from the frozen pixels, off main while the Dock's titles are read;
                    // titles label them when the counts match.
                    let pid = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windows[index].id) as! [[String: Any]])[0][kCGWindowOwnerPID as String] as! Int32
                    async let reading = Accessibility.dockItemTitles(pid: pid)
                    let (panel, tiles) = await Task.detached {
                        let panel = DockTiles.panel(in: image, near: union, scale: scale) ?? union
                        return (panel, DockTiles.tiles(in: image, panel: panel, scale: scale))
                    }.value
                    windows[index].rect = panel
                    Pref.logHoverLine("dock panel \(panel)")
                    let titles = await reading
                    Pref.logHoverLine("dock tiles \(tiles.count) titles \(titles)")
                    overlay.dockTiles = tiles.enumerated().map { offset, rect in
                        Candidate(id: "dock-\(offset)", label: titles.count == tiles.count && !titles[offset].isEmpty ? titles[offset] : "Dock Item",
                                  bounds: rect, score: AccessibilityBounds.baseScore, kind: .element)
                    }
                }
                signposter.endInterval("windows", listing)
                if overlay.image === image { overlay.setWindows(windows.map(\.rect), names: windows.map(\.name), ids: windows.map(\.id), frozen: windows.map(\.frozen), pointer: NSEvent.mouseLocation) }
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    // MARK: Recording

    private func startRecording(displayID: CGDirectDisplayID, area: CGRect) {
        let file = Output.defaultFile(defaults: .standard).deletingPathExtension().appendingPathExtension("mov")
        Task {
            do {
                let session = try await ScreenRecording.start(displayID: displayID, area: area, file: file, showsOutline: true)
                session.onFailure = { [self] error in
                    endRecording()
                    NSApp.presentError(error)
                }
                showRecording(session)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    /// While recording, the status item is a stop button showing a stop glyph and the elapsed time.
    private func showRecording(_ session: ScreenRecording) {
        let item = statusItem!, button = item.button!
        let ticker = Task {
            while true {
                let seconds = Int(session.started.duration(to: .now).components.seconds)
                button.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
                try await Task.sleep(for: .seconds(1))
            }
        }
        recording = (session, item.menu, button.image, ticker)
        item.menu = nil
        item.length = NSStatusItem.variableLength
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = self
        button.action = #selector(stopRecordingFromMenu)
    }

    @objc private func stopRecordingFromMenu() { stopRecording() }

    /// Puts the status item back and returns the recording, if one was running.
    @discardableResult
    private func endRecording() -> ScreenRecording? {
        guard let recording else { return nil }
        self.recording = nil
        recording.ticker.cancel()
        let item = statusItem!, button = item.button!
        button.action = nil
        button.title = ""
        button.image = recording.icon
        item.length = NSStatusItem.squareLength
        item.menu = recording.menu
        return recording.session
    }

    /// Stops the recording, then copies the saved file's URL and shows the toast with its first frame.
    private func stopRecording() {
        guard let session = endRecording() else { return }
        Task {
            do {
                try await session.stop()
                _ = try await ScreenRecording.deliver(session.file, pasteboard: .general, defaults: .standard)
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
                try await Output.deliver(image, crop: crop, framed: overlay.framed, scale: scale, copy: true,
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
            settingsWindow = SettingsTabs.makeWindow()
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
