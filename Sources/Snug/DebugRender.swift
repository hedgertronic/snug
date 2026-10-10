import AppKit
import ScreenCaptureKit
import SwiftUI
import ScreenshotCore

extension DebugRun {
    /// `--render-states DIR`: renders the overlay offscreen to one PNG per state with `cacheDisplay`.
    static func renderStates(into directory: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        try await warmVision(image)
        _ = privateSetup(overlay)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = overlay.defaults

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<10000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            guard condition() else { throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(message)"]) }
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        func open() { overlay.present(image: image, frame: frame, displayID: nil) }
        func drag(_ rect: CGRect, release: Bool) {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY))
            mouse(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY))
            if release { mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY)) }
        }
        func snapshot(_ name: String) throws {
            let view = overlay.view
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
            print(directory.appending(path: "\(name).png").path)
        }
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        let cart = CGRect(x: 1645, y: 384, width: 582, height: 557)

        // Mid-drag with the loupe and rulers on: the selection's edges pass through the loupe's center cell and the rulers flag the span.
        // The fixture is a dark page; the light state inverts it.
        let light = CIContext().createCGImage(CIImage(cgImage: image).applyingFilter("CIColorInvert"), from: CGRect(x: 0, y: 0, width: image.width, height: image.height))!
        for (name, content) in [("dark", image), ("light", light)] {
            overlay.present(image: content, frame: frame, displayID: nil)
            for key in [Pref.loupe, Pref.rulers] { defaults.set(true, forKey: key) }
            drag(rough, release: false)
            try snapshot("loupe-drag-\(name)")
            mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
            overlay.dismiss()
        }
        for key in [Pref.loupe, Pref.rulers] { defaults.set(false, forKey: key) }

        open()
        mouse(.mouseMoved, CGPoint(x: 1200, y: 1000))
        try snapshot("area-idle")
        overlay.dismiss()

        open()
        mouse(.mouseMoved, CGPoint(x: 1280, y: 1580))
        try snapshot("bar-at-top")
        overlay.dismiss()

        open()
        drag(CGRect(x: 900, y: 1200, width: 800, height: 380), release: true)
        try snapshot("style-bar-at-top")
        overlay.dismiss()

        open()
        defaults.set(true, forKey: Pref.frame)
        defaults.set(false, forKey: Pref.shadow)
        mouse(.mouseMoved, CGPoint(x: 1200, y: 1000))
        try snapshot("bar-frame")
        defaults.set(false, forKey: Pref.frame)
        defaults.set(true, forKey: Pref.shadow)
        overlay.dismiss()

        open()
        drag(rough, release: false)
        try await waitFor("a snap preview") { overlay.snapPreview != nil }
        try snapshot("area-drag-snap")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        try snapshot("area-released")
        key(0, "m")
        try snapshot("area-frame")
        overlay.dismiss()
        defaults.set(false, forKey: Pref.frame)

        open()
        overlay.setWindows([CGRect(x: 300, y: 300, width: 1300, height: 1000)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 900, y: 700))
        try snapshot("window-hover")
        overlay.dismiss()

        open()
        let rounded = CGRect(x: 1100, y: 250, width: 1000, height: 700)
        overlay.setWindows([rounded], names: ["Rounded window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.radii[rounded] = 40
        mouse(.mouseMoved, CGPoint(x: 1600, y: 600))
        try snapshot("window-hover-rounded")
        key(14, "e")
        try await waitFor("E to carry the radii") { overlay.editedRadii[rounded] != nil }
        try snapshot("selection-corner-dots")
        let topLeft = overlay.cornerRadii(of: rounded).dot(of: .topLeft, in: rounded, minimumInset: 8 * overlay.scale)
        mouse(.leftMouseDown, topLeft)
        mouse(.leftMouseDragged, CGPoint(x: topLeft.x + 30, y: topLeft.y + 30))
        mouse(.leftMouseUp, CGPoint(x: topLeft.x + 30, y: topLeft.y + 30))
        let bottomRight = overlay.cornerRadii(of: rounded).dot(of: .bottomRight, in: rounded, minimumInset: 8 * overlay.scale)
        mouse(.leftMouseDown, bottomRight, .option)
        mouse(.leftMouseDragged, CGPoint(x: bottomRight.x - 30, y: bottomRight.y - 30), .option)
        mouse(.leftMouseUp, CGPoint(x: bottomRight.x - 30, y: bottomRight.y - 30), .option)
        try snapshot("selection-corners-unequal")
        mouse(.mouseMoved, overlay.cornerRadii(of: rounded).dot(of: .topLeft, in: rounded, minimumInset: 8 * overlay.scale))
        try snapshot("selection-corner-chip-top-left")
        mouse(.mouseMoved, overlay.cornerRadii(of: rounded).dot(of: .bottomRight, in: rounded, minimumInset: 8 * overlay.scale))
        try snapshot("selection-corner-chip-bottom-right")
        overlay.dismiss()

        open()
        key(35, "p")
        key(35, "p")
        mouse(.leftMouseDown, CGPoint(x: 900, y: 500))
        mouse(.leftMouseDragged, CGPoint(x: 1700, y: 800))
        try snapshot("ratio-lock-drag")
        mouse(.leftMouseUp, CGPoint(x: 1700, y: 800))
        try snapshot("ratio-lock-released")
        overlay.dismiss()

        // Up and Down outlines around a rounded hover.
        open()
        let hintInner = Candidate(id: "hint-inner", label: "Card", bounds: CGRect(x: 1250, y: 420, width: 500, height: 300), score: AccessibilityBounds.baseScore, kind: .element)
        let hintOuter = Candidate(id: "hint-outer", label: "Panel", bounds: hintInner.bounds.insetBy(dx: -160, dy: -120), score: AccessibilityBounds.baseScore, kind: .element)
        let hintChild = Candidate(id: "hint-child", label: "Button", bounds: hintInner.bounds.insetBy(dx: 90, dy: 70), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.detectionTask?.cancel()
        overlay.radii[hintInner.bounds] = 28
        overlay.radii[hintOuter.bounds] = 48
        overlay.radii[hintChild.bounds] = 20
        let hintAim = CGPoint(x: hintInner.bounds.midX, y: hintInner.bounds.midY)
        overlay.session = SelectionSession(candidates: [hintChild, hintInner, hintOuter], extent: CGRect(x: 0, y: 0, width: image.width, height: image.height), anchor: hintAim)
        mouse(.mouseMoved, hintAim)
        key(126, "")
        require(overlay.view.overlays.hover == hintInner.bounds && overlay.view.overlays.upHint == hintOuter.bounds && overlay.view.overlays.downHint == hintChild.bounds, "hint render: hover, up and down are set: \(String(describing: overlay.view.overlays.hover)) \(String(describing: overlay.view.overlays.upHint)) \(String(describing: overlay.view.overlays.downHint)) \(overlay.view.bounds) \(overlay.scale)")
        try snapshot("hint-outlines-rounded")
        overlay.dismiss()

        // Highlight with a fill and no glow, in a picked color.
        defaults.set("#E5484D", forKey: Pref.highlightColor)
        defaults.set(0.15, forKey: Pref.highlightFill)
        defaults.set(0.55, forKey: Pref.highlightFade)
        defaults.set(false, forKey: Pref.highlightGlow)
        open()
        overlay.radii[rounded] = 40
        overlay.setWindows([rounded], names: ["Rounded window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 1600, y: 600))
        try snapshot("highlight-fill-no-glow")
        overlay.dismiss()
        for key in [Pref.highlightColor, Pref.highlightFill, Pref.highlightFade, Pref.highlightGlow] { defaults.removeObject(forKey: key) }

        open()
        key(17, "t")
        try snapshot("text-reading")
        let liveText = overlay.view.liveText
        try await waitFor("Live Text") { liveText.analysis != nil }
        let all = liveText.text
        liveText.selectedRanges = [all.range(of: "Product name")!.lowerBound..<all.range(of: "Second product")!.upperBound]
        try snapshot("text")
        overlay.targetLanguage = Locale.Language(identifier: "de")
        overlay.translationStatus = { _, _ in .supported }
        key(36, "\r", .option)
        try await waitFor("the not-installed pill") { overlay.text.notice != nil }
        try snapshot("text-translate-missing")
        overlay.dismiss()

        open()
        key(17, "t")
        try await waitFor("Live Text") { liveText.analysis != nil }
        key(48, "\t")
        try await waitFor("a picked item") { overlay.text.picked != nil }
        try snapshot("text-item-picked")
        overlay.dismiss()

        overlay.present(image: itemsFixture(width: image.width, height: image.height), frame: frame, displayID: nil)
        key(17, "t")
        try await waitFor("Live Text") { liveText.analysis != nil }
        key(48, "\t", .shift)
        try await waitFor("the QR code picked") { overlay.text.picked != nil }
        try snapshot("text-item-code")
        overlay.dismiss()

        open()
        drag(cart, release: true)
        key(36, "\r", .shift)
        try snapshot("capture-text-reading")
        overlay.dismiss()

        open()
        try await overlay.detectionTask?.value
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        try snapshot("capture-hover")
        defaults.set(true, forKey: Pref.candidates)
        key(126, "")
        try snapshot("capture-hover-list")
        defaults.set(false, forKey: Pref.candidates)
        overlay.dismiss()

        open()
        key(44, "?", .shift)
        try snapshot("help")
        overlay.dismiss()

        open()
        drag(rough, release: true)
        key(37, "l")
        key(15, "r")
        mouse(.mouseMoved, CGPoint(x: 1500, y: 700))
        try snapshot("loupe-rulers")
        overlay.dismiss()

        open()
        overlay.topInset = 38
        defaults.set(true, forKey: Pref.rulers)
        defaults.set(true, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: 1200, y: 90))
        try snapshot("area-idle-notch")
        overlay.dismiss()

        // The menu bar icon on light and dark menu bars: real pixel size (1x, 2x) above, magnified to 144 px below.
        let icon = SnugApp.menuBarIcon()
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSGraphicsContext.current!.imageInterpolation = .none
        for (index, (scale, dark)) in [(1, false), (2, false), (1, true), (2, true)].enumerated() {
            let x = CGFloat(index * 160)
            let pixels = CGFloat(18 * scale)
            let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18 * scale, pixelsHigh: 18 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
            NSColor(white: dark ? 0.12 : 0.93, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: pixels, height: pixels).fill()
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                (dark ? NSColor.white : NSColor.black).set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: dark ? 0.12 : 0.93, alpha: 1).setFill()
            CGRect(x: x, y: 0, width: 160, height: 200).fill()
            let image = NSImage(size: CGSize(width: pixels, height: pixels))
            image.addRepresentation(small)
            image.draw(in: CGRect(x: x + 8, y: 176, width: pixels, height: pixels))
            image.draw(in: CGRect(x: x + 8, y: 8, width: 144, height: 144))
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "menubar-icon.png"))
        print(directory.appending(path: "menubar-icon.png").path)

        /// A toast's content on a mid-gray backdrop, since its panel is transparent.
        func renderToast(_ name: String, _ toast: Toast, hovered: Bool = false) throws {
            if hovered {
                toast.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: toast.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
                toast.dismissal?.cancel()
            }
            let content = toast.contentView!
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: rep)
            let backed = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: backed)
            let whole = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            NSColor(white: 0.5, alpha: 1).setFill()
            whole.fill()
            rep.draw(in: whole)
            NSGraphicsContext.restoreGraphicsState()
            try backed.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
            print(directory.appending(path: "\(name).png").path)
        }
        try renderToast("toast", Toast(png: nil, message: "Copied", detail: "1824 x 768  frame", file: nil, color: nil, defaults: defaults))
        let roundedCapture = CGContext(data: nil, width: 960, height: 520, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        roundedCapture.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 960, height: 520), cornerWidth: 40, cornerHeight: 40, transform: nil))
        roundedCapture.clip()
        roundedCapture.draw(image.cropping(to: CGRect(x: 300, y: 380, width: 960, height: 520))!, in: CGRect(x: 0, y: 0, width: 960, height: 520))
        let roundedPNG = try await Output.png(roundedCapture.makeImage()!)
        try renderToast("toast-preview", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: defaults))
        try renderToast("toast-preview-hover", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: defaults), hovered: true)
        let noPreview = UserDefaults(suiteName: "snug-render-toast-\(UUID().uuidString)")!
        Pref.register(in: noPreview)
        noPreview.set(false, forKey: Pref.toastPreview)
        try renderToast("toast-no-preview", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: noPreview))
        try renderToast("toast-no-preview-hover", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: noPreview), hovered: true)

        func render(_ name: String, _ content: some View) throws {
            let renderer = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
            print(directory.appending(path: "\(name).png").path)
        }
        let firstRun = NSHostingView(rootView: FirstRunView())
        try render("first-run", FirstRunView())
        require(firstRun.fittingSize.width == 500, "the first-run window is 500 pt wide")
        try renderSettings(into: directory)

        let menu = SnugApp.makeMenu(defaults: defaults)
        let capture = menu.items[0]
        require(menu.items.map(\.title) == ["Capture", "Capture Text", "Repeat Last Area", "Open Image...", "", "Settings...", "About Snug", "", "Quit Snug"], "menu items: \(menu.items.map(\.title))")
        require(capture.keyEquivalent == " " && capture.keyEquivalentModifierMask == [.control, .shift], "Capture shows the shortcut as a key equivalent")
        require(menu.items[5].keyEquivalent == "," && menu.items[8].keyEquivalent == "q", "Settings and Quit carry their command keys")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{21E7}Space", "the default shortcut displays as glyphs: \(Shortcut.label(from: defaults))")
        defaults.set(40, forKey: Pref.hotKeyCode)
        defaults.set(Int(NSEvent.ModifierFlags([.control, .option]).rawValue), forKey: Pref.hotKeyModifiers)
        capture.setShortcut(from: defaults)
        require(capture.keyEquivalent == "k" && capture.keyEquivalentModifierMask == [.control, .option], "a recorded letter shortcut updates the key equivalent")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{2325}K", "the recorded shortcut displays from code and modifiers: \(Shortcut.label(from: defaults))")
        let hintFill = overlay.chrome.hints.layer!.backgroundColor.flatMap(NSColor.init(cgColor:))!
        require(hintFill.alphaComponent >= 0.9, "the hint strip is nearly opaque: \(hintFill.alphaComponent)")
        exit(EXIT_SUCCESS)
    }

    /// `--verify-settings-capture`: with the Settings window and the overlay window both ordered in far offscreen, the windows Snug's
    /// captures exclude are the overlay and not Settings, and the window server lists both. With Screen Recording, the display's capture
    /// filter also includes Settings and leaves the overlay out.
    static func verifySettingsCapture(overlay: OverlayController) async throws {
        let settings = SettingsTabs.makeWindow()
        for window in [settings, overlay.window] {
            window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
        }
        try await Task.sleep(for: .milliseconds(500))
        let settingsID = CGWindowID(settings.windowNumber), overlayID = CGWindowID(overlay.window.windowNumber)
        let excluded = DisplayCapture.excludedWindowIDs()
        precondition(excluded.contains(overlayID), "the overlay window \(overlayID) is excluded from captures: \(excluded.sorted())")
        precondition(!excluded.contains(settingsID), "the Settings window \(settingsID) is not excluded from captures: \(excluded.sorted())")
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]).map { CGWindowID($0[kCGWindowNumber as String] as! Int) }
        precondition(onScreen.contains(settingsID) && onScreen.contains(overlayID), "the window server lists both offscreen windows \(settingsID), \(overlayID)")
        print("excluded \(excluded.sorted()): overlay \(overlayID) in, settings \(settingsID) out")
        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let included = Set(DisplayCapture.filter(for: CGMainDisplayID(), in: content, excluding: excluded).includedWindows.map(\.windowID))
            precondition(included.contains(settingsID), "the capture filter includes the Settings window \(settingsID)")
            precondition(!included.contains(overlayID), "the capture filter leaves out the overlay window \(overlayID)")
            print("capture filter: settings included, overlay excluded, \(included.count) windows included")
        } else {
            print("capture filter: skipped, this process has no Screen Recording permission")
        }
        exit(EXIT_SUCCESS)
    }

    /// Each Settings tab hosted in an NSHostingView inside a window that is never shown, drawn to a PNG in `directory`.
    static func renderSettings(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs = SettingsTabs.makeController()
        for item in tabs.tabViewItems {
            let host = NSHostingView(rootView: (item.viewController as! NSHostingController<AnyView>).rootView.background(Color(nsColor: .windowBackgroundColor)))
            let offscreen = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: true)
            offscreen.contentView = host
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.width == SettingsTabs.width, "the \(item.label) tab is \(SettingsTabs.width) pt wide: \(host.fittingSize.width)")
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = directory.appending(path: "settings-\(item.label.lowercased()).png")
            try rep.representation(using: .png, properties: [:])!.write(to: file)
            print(file.path, host.fittingSize)
        }
        precondition(tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Keys"], "Settings tabs: \(tabs.tabViewItems.map(\.label))")
        let window = SettingsTabs.makeWindow()
        let tabController = window.contentViewController as! NSTabViewController
        for (index, item) in tabController.tabViewItems.enumerated() {
            tabController.selectedTabViewItemIndex = index
            precondition(window.title == item.label, "the Settings window title follows the \(item.label) tab: \"\(window.title)\"")
        }
    }
}
