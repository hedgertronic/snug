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
        if arguments.contains("--probe-screen-text") {
            Task {
                await DebugRun.probeScreenText()
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
                         "--loupe-frames", "--memory-steps", "--verify-agent-ui", "--render-toasts", "--verify-screen-text-ui"]
        if let image, imageRuns.contains(where: arguments.contains) {
            let frame = imageFrame(for: image)
            Task {
                do {
                    if let index = arguments.firstIndex(of: "--memory-steps") {
                        try await DebugRun.memorySteps(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--render-states") {
                        try await DebugRun.renderStates(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--render-toasts") {
                        try await DebugRun.renderToasts(into: URL(fileURLWithPath: arguments[index + 1]), image: image)
                        exit(EXIT_SUCCESS)
                    } else if let index = arguments.firstIndex(of: "--loupe-frames") {
                        try await DebugRun.loupeFrames(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if let index = arguments.firstIndex(of: "--verify-agent-ui") {
                        try await DebugRun.verifyAgent(into: URL(fileURLWithPath: arguments[index + 1]), image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--measure") {
                        try await DebugRun.measure(image: image, frame: frame, overlay: overlay)
                    } else if arguments.contains("--verify-screen-text-ui") {
                        try await DebugRun.verifyScreenText(image: image, frame: frame, overlay: overlay)
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
        // A mistyped or image-less debug flag would otherwise launch the real app, which takes focus and registers the capture shortcut.
        if let flag = arguments.dropFirst().first(where: { $0.hasPrefix("--") && $0 != "--image" }) {
            FileHandle.standardError.write(Data("Unknown or incomplete debug flag \(flag)\n".utf8))
            exit(EXIT_FAILURE)
        }
        // Settings saved before the bundle ID became com.hedgertronic.snug move over on the first launch under it.
        if let id = Bundle.main.bundleIdentifier, UserDefaults.standard.persistentDomain(forName: id) == nil,
           let old = UserDefaults.standard.persistentDomain(forName: "local.snug") {
            UserDefaults.standard.setPersistentDomain(old, forName: id)
        }
        // One Snug per user: a second copy (another build, or a second launch) quits, so a shortcut press never reaches two overlays.
        // The --mcp bridge never registers as an app, so it is not counted; an unbundled debug binary has no identifier to check.
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            return NSApp.terminate(nil)
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
        // A shortcut macOS refused is remembered too, so later preference writes don't retry it and toast again.
        registeredShortcut = current
        do {
            if current[0] < 0 {
                hotKey!.unregister()
            } else {
                try hotKey!.register(keyCode: UInt32(current[0]), modifiers: NSEvent.ModifierFlags(rawValue: UInt(current[1])))
            }
            captureItem?.setShortcut(from: defaults)
        } catch {
            Toast.show(message: "Shortcut not registered", detail: error.localizedDescription, color: .systemRed)
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
    /// "d" to "h" are candidates drawn at the logo's proportions (the band's top at about half the tile's height) and share the solid tile's
    /// dashed arch, whose round-capped dashes mirror around one centered on top. Their 1x pixels are not hand-aligned yet.
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
                // No tile: the solid band, with rounded bottom corners, at the logo's height, under the solid tile's dashed arch.
                let band = NSBezierPath()
                band.move(to: CGPoint(x: 1, y: 6.85))
                band.line(to: CGPoint(x: 1, y: 5))
                band.appendArc(withCenter: CGPoint(x: 5, y: 5), radius: 4, startAngle: 180, endAngle: 270)
                band.line(to: CGPoint(x: 13, y: 1))
                band.appendArc(withCenter: CGPoint(x: 13, y: 5), radius: 4, startAngle: 270, endAngle: 360)
                band.line(to: CGPoint(x: 17, y: 6.85))
                band.curve(to: CGPoint(x: 1, y: 6.85), controlPoint1: CGPoint(x: 12.6, y: 8.85), controlPoint2: CGPoint(x: 5.4, y: 8.85))
                band.fill()
                for side: CGFloat in [-1, 1] {
                    let half = NSBezierPath()
                    half.move(to: CGPoint(x: 9, y: 14.25))
                    half.line(to: CGPoint(x: 9 + 2 * side, y: 14.25))
                    half.appendArc(withCenter: CGPoint(x: 9 + 2 * side, y: 12), radius: 2.25, startAngle: 90, endAngle: side < 0 ? 180 : 0, clockwise: side > 0)
                    half.line(to: CGPoint(x: 9 + 4.25 * side, y: 10))
                    half.lineWidth = 1.25
                    half.lineCapStyle = .round
                    half.setLineDash([0.25, 1.85, 0.5, 1.85, 0.5, 1.85, 0.5, 10], count: 8, phase: 0)
                    half.stroke()
                }
            case "e":
                // The app tile in outline, its band filled at the logo's height, under the solid tile's dashed arch.
                let tile = NSBezierPath(roundedRect: CGRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 4, yRadius: 4)
                tile.lineWidth = 1.5
                tile.stroke()
                NSGraphicsContext.saveGraphicsState()
                tile.addClip()
                let band = NSBezierPath()
                band.move(to: CGPoint(x: 0, y: 0))
                band.line(to: CGPoint(x: 0, y: 6.85))
                band.curve(to: CGPoint(x: 18, y: 6.85), controlPoint1: CGPoint(x: 5.4, y: 8.85), controlPoint2: CGPoint(x: 12.6, y: 8.85))
                band.line(to: CGPoint(x: 18, y: 0))
                band.fill()
                NSGraphicsContext.restoreGraphicsState()
                for side: CGFloat in [-1, 1] {
                    let half = NSBezierPath()
                    half.move(to: CGPoint(x: 9, y: 14.25))
                    half.line(to: CGPoint(x: 9 + 2 * side, y: 14.25))
                    half.appendArc(withCenter: CGPoint(x: 9 + 2 * side, y: 12), radius: 2.25, startAngle: 90, endAngle: side < 0 ? 180 : 0, clockwise: side > 0)
                    half.line(to: CGPoint(x: 9 + 4.25 * side, y: 10))
                    half.lineWidth = 1.25
                    half.lineCapStyle = .round
                    half.setLineDash([0.25, 1.85, 0.5, 1.85, 0.5, 1.85, 0.5, 10], count: 8, phase: 0)
                    half.stroke()
                }
            case "f":
                // A solid frame open at the top, its sides standing in a band at the logo's height, as if the selection were tucked in under it.
                for side: CGFloat in [-1, 1] {
                    let corner = NSBezierPath()
                    corner.move(to: CGPoint(x: 9 + 6 * side, y: 6))
                    corner.line(to: CGPoint(x: 9 + 6 * side, y: 13.5))
                    corner.appendArc(withCenter: CGPoint(x: 9 + 3.5 * side, y: 13.5), radius: 2.5, startAngle: side < 0 ? 180 : 0, endAngle: 90, clockwise: side < 0)
                    corner.line(to: CGPoint(x: 9 + 1.75 * side, y: 16))
                    corner.lineWidth = 1.5
                    corner.lineCapStyle = .round
                    corner.lineJoinStyle = .round
                    corner.stroke()
                }
                let band = NSBezierPath()
                band.move(to: CGPoint(x: 1, y: 6.85))
                band.line(to: CGPoint(x: 1, y: 5))
                band.appendArc(withCenter: CGPoint(x: 5, y: 5), radius: 4, startAngle: 180, endAngle: 270)
                band.line(to: CGPoint(x: 13, y: 1))
                band.appendArc(withCenter: CGPoint(x: 13, y: 5), radius: 4, startAngle: 270, endAngle: 360)
                band.line(to: CGPoint(x: 17, y: 6.85))
                band.curve(to: CGPoint(x: 1, y: 6.85), controlPoint1: CGPoint(x: 12.6, y: 8.85), controlPoint2: CGPoint(x: 5.4, y: 8.85))
                band.fill()
            case "g":
                // The app tile's silhouette alone: an outline filled below the band's curve, at the logo's height.
                let tile = NSBezierPath(roundedRect: CGRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 4, yRadius: 4)
                tile.lineWidth = 1.5
                tile.stroke()
                NSGraphicsContext.saveGraphicsState()
                tile.addClip()
                let band = NSBezierPath()
                band.move(to: CGPoint(x: 0, y: 0))
                band.line(to: CGPoint(x: 0, y: 6.85))
                band.curve(to: CGPoint(x: 18, y: 6.85), controlPoint1: CGPoint(x: 5.4, y: 8.85), controlPoint2: CGPoint(x: 12.6, y: 8.85))
                band.line(to: CGPoint(x: 18, y: 0))
                band.fill()
                NSGraphicsContext.restoreGraphicsState()
            case "h":
                // The app tile solid, with its dashed selection and the band's curve cut out of it, in the logo's proportions: the band's top
                // at about half the tile's height in the middle and 53% from the top at the sides.
                NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current!.compositingOperation = .clear
                // Each half of the arch runs from the top center down a leg: 2 pt of top, a 2.25 pt radius corner, 2 pt of leg. Dashes
                // mirror around one centered on top, and each leg ends in a gap above the band.
                for side: CGFloat in [-1, 1] {
                    let half = NSBezierPath()
                    half.move(to: CGPoint(x: 9, y: 14.25))
                    half.line(to: CGPoint(x: 9 + 2 * side, y: 14.25))
                    half.appendArc(withCenter: CGPoint(x: 9 + 2 * side, y: 12), radius: 2.25, startAngle: 90, endAngle: side < 0 ? 180 : 0, clockwise: side > 0)
                    half.line(to: CGPoint(x: 9 + 4.25 * side, y: 10))
                    half.lineWidth = 1.25
                    half.lineCapStyle = .round
                    half.setLineDash([0.25, 1.85, 0.5, 1.85, 0.5, 1.85, 0.5, 10], count: 8, phase: 0)
                    half.stroke()
                }
                let cut = NSBezierPath()
                cut.move(to: CGPoint(x: 0, y: 7.6))
                cut.curve(to: CGPoint(x: 18, y: 7.6), controlPoint1: CGPoint(x: 5.4, y: 9.6), controlPoint2: CGPoint(x: 12.6, y: 9.6))
                cut.lineWidth = 1.5
                cut.stroke()
            default:
                preconditionFailure("SnugMenuBarIcon is a, d, e, f, g or h: \(variant)")
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

    /// The standard About panel, its credits a link to Snug's Ko-fi page.
    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(string: "Buy me a bag of sunflower seeds", attributes: [.link: URL(string: "https://ko-fi.com/hedgertronic")!,
                                                                                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
                // Accessibility text is read as the pixels are grabbed, so it matches the frozen image (`OverlayController.setScreenTexts`).
                async let screenText = ScreenTextReader.read(chromium: overlay.chromiumReadable)
                let image = try await DisplayCapture.image(of: id)
                signposter.endInterval("capture", capturing)
                let captured = clock.now
                try Task.checkCancellation()
                overlay.present(image: image, frame: screen.frame, displayID: id)
                let presented = clock.now
                if text { overlay.setMode(.text) }
                let scale = overlay.scale
                let listing = signposter.beginInterval("windows")
                // `listed` is when the list is done off main; the wait from there to `resumed` is the main thread being busy.
                let excluded = DisplayCapture.excludedWindowIDs()
                let (found, listed) = await Task.detached { (await DisplayCapture.windows(on: id, pixelScale: scale, excluding: excluded), clock.now) }.value
                let resumed = clock.now
                var windows = found
                var dock = "none"
                let ms = { (from: ContinuousClock.Instant, to: ContinuousClock.Instant) in Int((from.duration(to: to) / .milliseconds(1)).rounded()) }
                // The Dock's AXList union is the magnified Dock, tens of points past the panel; the panel's rim in the frozen image gives its edges.
                for index in windows.indices where windows[index].name == "Dock" && windows[index].frozen {
                    let union = windows[index].rect
                    Pref.logHoverLine("dock union \(union) scale \(scale) image \(image.width)x\(image.height)")
                    // Live item frames are magnified, so the tiles come from the frozen pixels, off main while the Dock's titles are read;
                    // titles label them when the counts match.
                    let pid = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windows[index].id) as! [[String: Any]])[0][kCGWindowOwnerPID as String] as! Int32
                    let docking = clock.now
                    async let reading = (Accessibility.dockItemTitles(pid: pid), clock.now)
                    let (panel, tiles, tiled) = await Task.detached {
                        let panel = DockTiles.panel(in: image, near: union, scale: scale) ?? union
                        return (panel, DockTiles.tiles(in: image, panel: panel, scale: scale), clock.now)
                    }.value
                    windows[index].rect = panel
                    Pref.logHoverLine("dock panel \(panel)")
                    let (titles, titled) = await reading
                    dock = "tiles \(ms(docking, tiled)) ms, titles \(ms(docking, titled)) ms"
                    Pref.logHoverLine("dock tiles \(tiles.count) titles \(titles)")
                    overlay.dockTiles = tiles.enumerated().map { offset, rect in
                        Candidate(id: "dock-\(offset)", label: titles.count == tiles.count && !titles[offset].isEmpty ? titles[offset] : "Dock Item",
                                  bounds: rect, score: AccessibilityBounds.baseScore, kind: .element)
                    }
                }
                signposter.endInterval("windows", listing)
                openLog.notice("open: capture \(ms(pressed, captured)) ms, present \(ms(captured, presented)) ms, list \(ms(presented, listed)) ms, main \(ms(listed, resumed)) ms, dock \(dock, privacy: .public), windows \(ms(presented, clock.now)) ms")
                if overlay.image === image { overlay.setWindows(windows.map(\.rect), names: windows.map(\.name), ids: windows.map(\.id), frozen: windows.map(\.frozen), pointer: NSEvent.mouseLocation) }
                let read = await screenText
                if overlay.image === image { overlay.setScreenTexts(read) }
            } catch is CancellationError {
            } catch {
                Toast.show(message: "Capture failed", detail: error.localizedDescription, color: .systemRed)
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

    /// Stops the recording once it has started, then plays the stop sound, copies the saved file's URL and shows the toast with its first frame. `via` names
    /// the route, for the log: "shortcut", "menu item" or "stream stop".
    private func stopRecording(via: String) {
        recordingLog.notice("stop requested via \(via, privacy: .public), recording \(self.recording != nil)")
        guard let start = endRecording() else { return }
        Task {
            do {
                let session = try await start.value
                let file = try await session.stop()
                Sound.recordStop.play(defaults: .standard)
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
            keyEquivalent = name == "space" ? " " : name.lowercased()
        }
        keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Pref.hotKeyModifiers)))
    }
}
