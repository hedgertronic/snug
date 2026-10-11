import AppKit
import ScreenCaptureKit
import SwiftUI
import ScreenshotCore

extension DebugRun {
    /// `--render-states DIR`: renders the overlay offscreen to one PNG per state with `cacheDisplay`.
    /// With `--no-vision` it skips the Vision warm-up and every Text and OCR state, so it can run while another process uses Vision.
    static func renderStates(into directory: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        let vision = !CommandLine.arguments.contains("--no-vision")
        if vision { try await warmVision(image) }
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
            // The pointer just above the bottom bar: the loupe flips above it instead of hiding behind the bar.
            overlay.present(image: content, frame: frame, displayID: nil)
            let barTop = overlay.chrome.bottomBar.frame.maxY
            let nearBar = CGRect(x: 900, y: (overlay.view.bounds.height - barTop - 40) * overlay.scale - 200, width: 500, height: 200)
            drag(nearBar, release: false)
            try snapshot("loupe-near-bar-\(name)")
            mouse(.leftMouseUp, CGPoint(x: nearBar.maxX, y: nearBar.maxY))
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
        // The ratio chip's lock, clicked on and off.
        func ratioLock() -> BarButton { overlay.chrome.hints.subviews.flatMap { $0.subviews.compactMap { $0 as? BarButton } }.last! }
        ratioLock().onClick()
        try snapshot("area-released-ratio-locked")
        ratioLock().onClick()
        for (name, modifiers) in [("option", NSEvent.ModifierFlags.option), ("option-command", [.option, .command])] {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            try snapshot("area-released-\(name)")
        }
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
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
        mouse(.leftMouseDown, CGPoint(x: 900, y: 500))
        mouse(.leftMouseDragged, CGPoint(x: 1700, y: 800))
        mouse(.leftMouseUp, CGPoint(x: 1700, y: 800))
        key(35, "P", .shift)
        try snapshot("ratio-lock-released")
        mouse(.leftMouseDown, CGPoint(x: 1700, y: 800))
        mouse(.leftMouseDragged, CGPoint(x: 1900, y: 820))
        try snapshot("ratio-lock-drag")
        mouse(.leftMouseUp, CGPoint(x: 1900, y: 820))
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

        // The same rounded window hovered, then opened as a selection with E, with a user's highlight settings and with the defaults.
        for (name, settings) in [("user", ["#A550A7", 0.053203125, 0.3011132812499999, 0.2482421875] as [Any]), ("default", [])] {
            for (key, value) in zip([Pref.highlightColor, Pref.highlightFill, Pref.highlightFade, Pref.highlightGlow], settings) { defaults.set(value, forKey: key) }
            open()
            overlay.radii[rounded] = 40
            overlay.setWindows([rounded], names: ["Rounded window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
            mouse(.mouseMoved, CGPoint(x: 1600, y: 600))
            try snapshot("hover-vs-selection-\(name)-hover")
            key(14, "e")
            try await waitFor("E to open the hover as a selection") { overlay.selection?.rect == rounded }
            try snapshot("hover-vs-selection-\(name)-selected")
            overlay.dismiss()
            for key in [Pref.highlightColor, Pref.highlightFill, Pref.highlightFade, Pref.highlightGlow] { defaults.removeObject(forKey: key) }
        }

        if vision {
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

            // Text mode while Vision's warm-up child runs (a sleep stands in for it), then Shift-Return queued behind it.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            OverlayController.watchWarmUp(child)
            open()
            key(17, "t")
            try await waitFor("Live Text") { liveText.analysis != nil }
            try snapshot("text-warming")
            key(3, "f")
            key(36, "\r", .shift)
            try snapshot("text-warming-queued")
            overlay.dismiss()
            child.terminate()
            await OverlayController.visionWarmUp?.value

            // The cut-out preview of one icon, then of the second of three subjects, at 1 pt per pixel so the chrome leaves room.
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../notes/cutout/fixtures").standardized
            let spike = ["icon-flat-composite.png", "dock-tile-composite.png", "badge-real.png"].map {
                CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(fixtures.appending(path: $0) as CFURL, nil)!, 0, nil)!
            }
            defaults.set(false, forKey: Pref.snap)
            overlay.present(image: spike[0], frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(spike[0].width), height: CGFloat(spike[0].height)), displayID: nil)
            drag(CGRect(x: 110, y: 60, width: 180, height: 180), release: true)
            key(40, "k")
            await overlay.textTask?.value
            try snapshot("cutout-preview")
            overlay.dismiss()
            let group = subjectsFixture(spike)
            overlay.present(image: group, frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(group.width), height: CGFloat(group.height)), displayID: nil)
            key(3, "f")
            key(40, "k")
            await overlay.textTask?.value
            key(48, "\t")
            key(48, "\t")
            try snapshot("cutout-preview-subject")
            key(8, "c")
            try snapshot("cutout-preview-subject-cropped")
            defaults.removeObject(forKey: Pref.cutoutCrop)
            overlay.dismiss()
            defaults.removeObject(forKey: Pref.snap)
        }

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
        defaults.set(false, forKey: Pref.rulers)
        defaults.set(false, forKey: Pref.loupe)

        // V arms recording only on a display, which arming never captures from.
        overlay.present(image: image, frame: frame, displayID: CGMainDisplayID())
        overlay.detectionTask?.cancel()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: cart)
        overlay.refresh()
        key(9, "v")
        try snapshot("recording-armed")
        key(36, "\r")
        try snapshot("recording-count-in")
        overlay.dismiss()

        try await renderMenuBarIcons(into: directory)

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
        let topRight = UserDefaults(suiteName: "snug-render-toast-\(UUID().uuidString)")!
        Pref.register(in: topRight)
        topRight.set("topRight", forKey: Pref.toastPosition)
        try renderToast("toast-preview-top-right", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: topRight))
        try renderToast("toast-preview-top-right-hover", Toast(png: roundedPNG, message: "Copied", detail: "960 x 520", file: nil, color: nil, defaults: topRight), hovered: true)
        try renderToast("toast-saved-hover", Toast(png: roundedPNG, message: "Copied, saved to Desktop", detail: "Snug 2026-10-10 at 12.00.00.png", file: URL(fileURLWithPath: "/tmp/Snug.png"), color: nil, defaults: defaults), hovered: true)
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
            guard item.label == "General" else { continue }
            func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] { view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(of: $0, type) } }
            let field = descendants(of: host, ShortcutRecorder.Field.self).first!
            let controls = descendants(of: host, NSView.self).filter { "\(type(of: $0))".contains("FocusRingView") }
            print("shortcut field", host.convert(field.frame, from: field.superview), "pop-up and button frames", controls.map { host.convert($0.frame, from: $0.superview) })
            precondition(controls.count == 4 && controls.allSatisfy { $0.frame.height == field.frame.height }, "the shortcut field is as tall as the pop-ups and buttons: \(controls.map(\.frame)) \(field.frame)")
            field.beginRecording()
            precondition(field.recording, "a click starts recording")
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: rep)
            let recordingFile = directory.appending(path: "settings-general-recording.png")
            try rep.representation(using: .png, properties: [:])!.write(to: recordingFile)
            print(recordingFile.path)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: offscreen.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
            let hotKeyCode = UserDefaults.standard.integer(forKey: Pref.hotKeyCode)
            field.keyDown(with: escape)
            precondition(!field.recording && UserDefaults.standard.integer(forKey: Pref.hotKeyCode) == hotKeyCode, "Esc stops recording and keeps the shortcut")
        }
        precondition(tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Keys"], "Settings tabs: \(tabs.tabViewItems.map(\.label))")
        let window = SettingsTabs.makeWindow()
        let tabController = window.contentViewController as! NSTabViewController
        for (index, item) in tabController.tabViewItems.enumerated() {
            tabController.selectedTabViewItemIndex = index
            precondition(window.title == item.label, "the Settings window title follows the \(item.label) tab: \"\(window.title)\"")
        }
    }

    /// `--render-menubar-icons DIR`: every menu bar icon variant drawn from `SnugApp.menuBarIcon` the way the status item draws it (an 18 pt
    /// template image picking its 1x or 2x representation), tinted for a light (#F6F6F6) and a dark (#1E1E1E) menu bar, at true size above
    /// an 8x nearest-neighbor zoom, one row per variant in `menubar-icons.png`. Then checks that the status item's observer switches icons
    /// when another process writes `SnugMenuBarIcon`.
    static func renderMenuBarIcons(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants = ["a", "d"]
        let cells: [(scale: Int, dark: Bool)] = [(1, false), (2, false), (1, true), (2, true)]
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40 + 304 * cells.count, pixelsHigh: 348 * variants.count, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSGraphicsContext.current!.imageInterpolation = .none
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: sheet.pixelsWide, height: sheet.pixelsHigh).fill()
        for (row, variant) in variants.enumerated() {
            let top = CGFloat(sheet.pixelsHigh - 348 * row)
            variant.draw(at: CGPoint(x: 14, y: top - 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
            let icon = SnugApp.menuBarIcon(variant)
            for (column, cell) in cells.enumerated() {
                let pixels = 18 * cell.scale
                let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                small.size = icon.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
                icon.draw(in: CGRect(origin: .zero, size: icon.size))
                (cell.dark ? NSColor.white : NSColor.black).set()
                CGRect(origin: .zero, size: icon.size).fill(using: .sourceIn)
                NSGraphicsContext.restoreGraphicsState()
                let tinted = NSImage(size: CGSize(width: pixels, height: pixels))
                tinted.addRepresentation(small)
                let x = CGFloat(40 + 304 * column)
                NSColor(srgbRed: cell.dark ? 0x1E / 255 : 0xF6 / 255, green: cell.dark ? 0x1E / 255 : 0xF6 / 255, blue: cell.dark ? 0x1E / 255 : 0xF6 / 255, alpha: 1).setFill()
                CGRect(x: x, y: top - 344, width: 300, height: 340).fill()
                tinted.draw(in: CGRect(x: x + 8, y: top - 12 - CGFloat(pixels), width: CGFloat(pixels), height: CGFloat(pixels)))
                tinted.draw(in: CGRect(x: x + 8, y: top - 340, width: CGFloat(pixels * 8), height: CGFloat(pixels * 8)))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let file = directory.appending(path: "menubar-icons.png")
        try sheet.representation(using: .png, properties: [:])!.write(to: file)
        print(file.path)

        // At 1x, variant a's five dots are fully clear 2 x 2 cells (top-left pixel listed, rows from the top) inside a ring of solid tile.
        let small = SnugApp.menuBarIcon("a").representations.first { $0.pixelsWide == 18 } as! NSBitmapImageRep
        for (x, y) in [(4, 8), (4, 4), (8, 3), (12, 4), (12, 8)] {
            for column in x - 1...x + 2 {
                for row in y - 1...y + 2 {
                    let inside = (x...x + 1).contains(column) && (y...y + 1).contains(row)
                    precondition(small.colorAt(x: column, y: row)!.alphaComponent == (inside ? 0 : 1), "1x dot at \(x), \(y): pixel \(column), \(row)")
                }
            }
        }

        let suite = FileManager.default.temporaryDirectory.appending(path: "snug-icon-\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: suite)!
        Pref.register(in: defaults)
        let button = NSButton()
        let observation = SnugApp.observeMenuBarIcon(on: button, defaults: defaults)
        // "a" is the registered default, so "d" goes first to make both writes real changes.
        for variant in variants.reversed() {
            let writer = try Process.run(URL(fileURLWithPath: "/usr/bin/defaults"), arguments: ["write", suite, Pref.menuBarIcon, variant])
            writer.waitUntilExit()
            let expected = SnugApp.menuBarIcon(variant).tiffRepresentation
            for _ in 0..<500 where button.image?.tiffRepresentation != expected { try await Task.sleep(for: .milliseconds(10)) }
            precondition(button.image?.tiffRepresentation == expected, "`defaults write \(Pref.menuBarIcon) \(variant)` from another process switches the icon")
            print("defaults write \(Pref.menuBarIcon) \(variant): the status item shows variant \(variant)")
        }
        observation.invalidate()
    }
}
