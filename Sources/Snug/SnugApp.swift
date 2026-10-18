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
    /// The screen recording from its request on: its start, which may still be running. The capture shortcut, the menu's Stop
    /// Recording, and the system's screen-recording indicator in the menu bar stop it; the status item keeps its icon.
    private var recording: Task<ScreenRecording, any Error>? {
        didSet { statusItem.map { Self.showRecording(recording != nil, in: $0.menu!) } }
    }
    private var iconObservation: NSKeyValueObservation?

    static func main() {
        if CommandLine.arguments.contains("--mcp") { MCPServer.run() }
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
        if let index = arguments.firstIndex(of: "--render-menubar-icons") {
            Task {
                try! await DebugRun.renderMenuBarIcons(into: URL(fileURLWithPath: arguments[index + 1]))
                exit(EXIT_SUCCESS)
            }
            return
        }
        if arguments.contains("--warm-vision") {
            Task { try! await DebugRun.warmVisionAndExit() }
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
        let imageRuns = ["--verify-area-ui", "--verify-extras-ui", "--verify-toast-trash", "--verify-text-ui", "--measure", "--render-states",
                         "--loupe-frames", "--memory-steps", "--verify-agent-ui"]
        if let image, imageRuns.contains(where: arguments.contains) {
            let frame = imageFrame(for: image)
            Task {
                do {
                    if let index = arguments.firstIndex(of: "--memory-steps") {
                        try await DebugRun.memorySteps(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--render-states") {
                        try await DebugRun.renderStates(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--loupe-frames") {
                        try await DebugRun.loupeFrames(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--verify-agent-ui") {
                        try await DebugRun.verifyAgent(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--measure") {
                        try await DebugRun.measure(image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--verify-text-ui") {
                        try await DebugRun.verifyText(image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--verify-toast-trash") {
                        try await DebugRun.verifyToastTrash(image: image)
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
        ScreenRecording.requested = { [unowned self] in startRecording(displayID: $0, area: $1, showsCursor: $2, capturesAudio: $3) }
        hotKey = HotKey(id: 1) { [unowned self] in capture() }
        registerHotKey()
        _ = OverlayController.warmVisionInChild(defaults: .standard)
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
            if current[0] < 0 {
                hotKey!.unregister()
            } else {
                try hotKey!.register(keyCode: UInt32(current[0]), modifiers: NSEvent.ModifierFlags(rawValue: UInt(current[1])))
            }
            registeredShortcut = current
            captureItem?.setShortcut(from: defaults)
        } catch {
            NSApp.presentError(error)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        iconObservation = Self.observeMenuBarIcon(on: item.button!, defaults: .standard)
        let menu = Self.makeMenu(defaults: .standard)
        captureItem = menu.items[0]
        item.menu = menu
        statusItem = item
    }

    /// Keeps `button` showing the icon variant in `SnugMenuBarIcon`, redrawn as soon as the default changes, including from `defaults write`
    /// in another process.
    static func observeMenuBarIcon(on button: NSButton, defaults: UserDefaults) -> NSKeyValueObservation {
        defaults.observe(\.SnugMenuBarIcon, options: [.initial]) { defaults, _ in
            let variant = defaults.string(forKey: Pref.menuBarIcon)!
            Task { @MainActor in button.image = menuBarIcon(variant) }
        }
    }

    /// The menu bar logo as a template image, drawn in an 18 pt space into a 1x and a 2x bitmap so each display scale gets pixels placed for it.
    /// "a": the app tile, solid, with five arch dots and the band cut out. The dots sit on whole points, 2 x 2 squares at 1x and circles at 2x,
    /// and the band's curve is a 1 px step at 1x.
    /// "d": no tile. A solid band with rounded bottom corners under a dashed arch that stands open on the band's curved top. At 2x the dashes
    /// are round-capped and mirror around one centered on top; at 1x they are 2 px blocks with 2 px gaps that stop short of the band.
    static func menuBarIcon(_ variant: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in [1, 2] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18 * scale, pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 18, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            switch variant {
            case "a":
                NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current!.compositingOperation = .clear
                for center in [CGPoint(x: 5, y: 9), CGPoint(x: 5, y: 13), CGPoint(x: 9, y: 14), CGPoint(x: 13, y: 13), CGPoint(x: 13, y: 9)] {
                    let dot = CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)
                    if scale == 1 { dot.fill() } else { NSBezierPath(ovalIn: dot).fill() }
                }
                if scale == 1 {
                    // The band's curve as a 1 px step.
                    CGRect(x: 1, y: 5, width: 3, height: 1).fill()
                    CGRect(x: 4, y: 6, width: 10, height: 1).fill()
                    CGRect(x: 14, y: 5, width: 3, height: 1).fill()
                } else {
                    // Low enough that the bottom dots keep a pixel of tile between them and the cut.
                    let band = NSBezierPath()
                    band.move(to: CGPoint(x: 0, y: 5))
                    band.curve(to: CGPoint(x: 18, y: 5), controlPoint1: CGPoint(x: 5.4, y: 7.25), controlPoint2: CGPoint(x: 12.6, y: 7.25))
                    band.lineWidth = 1.5
                    band.stroke()
                }
            case "d":
                let band = NSBezierPath()
                band.move(to: CGPoint(x: 1, y: 5.5))
                band.line(to: CGPoint(x: 1, y: 5))
                band.appendArc(withCenter: CGPoint(x: 5, y: 5), radius: 4, startAngle: 180, endAngle: 270)
                band.line(to: CGPoint(x: 13, y: 1))
                band.appendArc(withCenter: CGPoint(x: 13, y: 5), radius: 4, startAngle: 270, endAngle: 360)
                band.line(to: CGPoint(x: 17, y: 5.5))
                band.curve(to: CGPoint(x: 1, y: 5.5), controlPoint1: CGPoint(x: 12, y: 7.5), controlPoint2: CGPoint(x: 6, y: 7.5))
                band.fill()
                if scale == 1 {
                    // A solid middle for the band's top row, which the curve only partly covers, and no stubs.
                    CGRect(x: 4, y: 6, width: 10, height: 1).fill()
                    for x: CGFloat in [3, 13] { CGRect(x: x, y: 9, width: 2, height: 2).fill() }
                    for x: CGFloat in [4, 8, 12] { CGRect(x: x, y: x == 8 ? 15 : 13, width: 2, height: 2).fill() }
                } else {
                    // Each half runs from the top center down a leg into the band: 2.25 pt of top, a 3 pt radius corner, then the leg.
                    // Visible dashes (caps included) are 3 pt with 1.25 pt gaps: half of the top one, one on the corner, one on the leg,
                    // then a stub that rises out of the band.
                    for side: CGFloat in [-1, 1] {
                        let half = NSBezierPath()
                        half.move(to: CGPoint(x: 9, y: 16.25))
                        half.line(to: CGPoint(x: 9 + 2.25 * side, y: 16.25))
                        half.appendArc(withCenter: CGPoint(x: 9 + 2.25 * side, y: 13.25), radius: 3, startAngle: 90, endAngle: side < 0 ? 180 : 0, clockwise: side > 0)
                        half.line(to: CGPoint(x: 9 + 5.25 * side, y: 4))
                        half.lineWidth = 1.5
                        half.lineCapStyle = .round
                        half.setLineDash([0.75, 2.75, 1.5, 2.75, 1.5, 2.75, 10, 1], count: 8, phase: 0)
                        half.stroke()
                    }
                }
            default:
                preconditionFailure("SnugMenuBarIcon is a or d: \(variant)")
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "About Snug", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// While recording, the menu's top item is Stop Recording, still showing the capture shortcut, in place of Capture and Capture Text.
    static func showRecording(_ recording: Bool, in menu: NSMenu) {
        menu.items[0].title = recording ? "Stop Recording" : "Capture"
        menu.items[1].isHidden = recording
    }

    /// Capture, or Stop Recording while recording.
    @objc private func captureFromMenu() {
        if recording != nil { return stopRecording(via: "menu item") }
        capture()
    }

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
        if recording != nil { return stopRecording(via: "shortcut") }
        guard !overlay.window.isVisible else { return }
        guard CGPreflightScreenCaptureAccess() else { return showFirstRun() }
        let (screen, id) = screenUnderPointer()
        let clock = ContinuousClock()
        let pressed = clock.now
        captureTask?.cancel()
        captureTask = Task {
            do {
                let capturing = signposter.beginInterval("capture")
                let image = try await DisplayCapture.image(of: id)
                signposter.endInterval("capture", capturing)
                let captured = clock.now
                try Task.checkCancellation()
                overlay.present(image: image, frame: screen.frame, displayID: id)
                let presented = clock.now
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
                openLog.notice("open: capture \(pressed.duration(to: captured), privacy: .public), present \(captured.duration(to: presented), privacy: .public), windows \(presented.duration(to: clock.now), privacy: .public)")
                if overlay.image === image { overlay.setWindows(windows.map(\.rect), names: windows.map(\.name), ids: windows.map(\.id), frozen: windows.map(\.frozen), pointer: NSEvent.mouseLocation) }
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    // MARK: Recording

    /// Starts the recording and keeps it at once, so the capture hotkey stops it even while the stream is starting.
    private func startRecording(displayID: CGDirectDisplayID, area: CGRect, showsCursor: Bool, capturesAudio: Bool) {
        let file = Output.defaultFile(defaults: .standard).deletingPathExtension().appendingPathExtension("mov")
        let start = Task {
            try await ScreenRecording.start(displayID: displayID, area: area, file: file, showsCursor: showsCursor, capturesAudio: capturesAudio, showsPanels: true, defaults: .standard,
                                            onFailure: { [self] error in
                                                endRecording()
                                                showRecordingFailure(error)
                                            },
                                            onStop: { [self] in stopRecording(via: "stream stop") })
        }
        recording = start
        Task {
            do {
                _ = try await start.value
            } catch {
                // After a stop during startup, `stopRecording` reports the failed start.
                guard recording == start else { return }
                endRecording()
                showRecordingFailure(error)
            }
        }
    }

    /// Forgets the recording and returns its start, if one was running.
    @discardableResult
    private func endRecording() -> Task<ScreenRecording, any Error>? {
        defer { recording = nil }
        return recording
    }

    /// A toast for a recording that failed: "Recording failed" and the error's description. Alerts may never show for an accessory app.
    private func showRecordingFailure(_ error: any Error) {
        let failure = error as NSError
        recordingLog.error("recording failed, error \(failure.domain, privacy: .public) \(failure.code): \(failure.localizedDescription, privacy: .public)")
        Toast.show(message: "Recording failed", detail: failure.localizedDescription, color: .systemRed)
    }

    /// Stops the recording once it has started, then copies the saved file's URL and shows the toast with its first frame. `via` names
    /// the route, for the log: "shortcut", "menu item" or "stream stop".
    private func stopRecording(via: String) {
        recordingLog.notice("stop requested via \(via, privacy: .public), recording \(self.recording != nil)")
        guard let start = endRecording() else { return }
        Task {
            do {
                let session = try await start.value
                let file = try await session.stop()
                _ = try await ScreenRecording.deliver(file, pasteboard: .general, defaults: .standard)
            } catch {
                showRecordingFailure(error)
            }
        }
    }

    // MARK: Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsTabs.makeWindow()
        }
        // `activate` is only a request that macOS may decline or grant later; ordered front regardless, the window comes up over the
        // active app's windows either way and becomes key once Snug is active.
        NSApp.activate()
        settingsWindow!.makeKeyAndOrderFront(nil)
        settingsWindow!.orderFrontRegardless()
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

extension UserDefaults {
    /// `Pref.menuBarIcon` for key-value observing, which needs a property named like the defaults key.
    @objc dynamic var SnugMenuBarIcon: String? { string(forKey: Pref.menuBarIcon) }
}

extension NSMenuItem {
    /// Shows the recorded hot key as this item's right-aligned key equivalent.
    func setShortcut(from defaults: UserDefaults) {
        let code = defaults.integer(forKey: Pref.hotKeyCode)
        if code < 0 {
            keyEquivalent = ""
            return
        }
        if let function = Shortcut.functionKeys[code] {
            keyEquivalent = String(Character(UnicodeScalar(function.character)!))
        } else {
            let name = Shortcut.keyNames[code]!
            keyEquivalent = name == "Space" ? " " : name.lowercased()
        }
        keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Pref.hotKeyModifiers)))
    }
}
