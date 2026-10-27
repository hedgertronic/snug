import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI
import ScreenshotCore
import UniformTypeIdentifiers

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
        // On the main display, as a live capture is, so Record shows enabled; nothing here captures from it.
        func open() { overlay.present(image: image, frame: frame, displayID: CGMainDisplayID()) }
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
        // The fixture is a dark page; the light states invert it.
        let light = CIContext().createCGImage(CIImage(cgImage: image).applyingFilter("CIColorInvert"), from: CGRect(x: 0, y: 0, width: image.width, height: image.height))!

        /// Text mode, light and dark: the found-text flash on entering, then a box drawn from off text mid-drag, while it is read, and
        /// read with its pills and line count.
        func renderTextBox() async throws {
            for (look, content) in [("dark", image), ("light", light)] {
                defaults.set(look, forKey: Pref.overlayAppearance)
                overlay.present(image: content, frame: frame, displayID: CGMainDisplayID())
                key(17, "t")
                try await waitFor("the found-text flash") { !overlay.view.overlays.flashPills.isEmpty }
                try snapshot("text-flash-\(look)")
                try await waitFor("Live Text") { overlay.view.liveText.analysis != nil }
                try await waitFor("the found-text flash to go off") { overlay.view.overlays.flashPills.isEmpty }
                mouse(.leftMouseDown, CGPoint(x: 1645, y: 384))
                mouse(.leftMouseDragged, CGPoint(x: 1900, y: 700))
                mouse(.leftMouseDragged, CGPoint(x: 2227, y: 941))
                try snapshot("text-box-drag-\(look)")
                mouse(.leftMouseUp, CGPoint(x: 2227, y: 941))
                try snapshot("text-box-reading-\(look)")
                await overlay.textTask?.value
                try snapshot("text-box-\(look)")
                overlay.dismiss()
            }
            defaults.removeObject(forKey: Pref.overlayAppearance)
        }
        if CommandLine.arguments.contains("--text-only") {
            try await renderTextBox()
            exit(EXIT_SUCCESS)
        }

        // Mid-drag with the loupe and rulers on: the selection's edges pass through the loupe's center cell and the rulers flag the span.
        for (name, content) in [("dark", image), ("light", light)] {
            overlay.present(image: content, frame: frame, displayID: nil)
            for key in [Pref.loupe, Pref.rulers] { defaults.set(true, forKey: key) }
            drag(rough, release: false)
            try snapshot("loupe-drag-\(name)")
            mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
            overlay.dismiss()
            // The pointer just above the settings bar: the loupe flips above it instead of hiding behind it.
            overlay.present(image: content, frame: frame, displayID: nil)
            let barTop = overlay.chrome.topBar.frame.maxY
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

        // The settings bar with the current mode drawn as Copy is, in Capture and in Text, light and dark.
        for look in ["light", "dark"] {
            defaults.set(look, forKey: Pref.overlayAppearance)
            for mode in [OverlayController.Mode.capture, .text] {
                open()
                overlay.chrome.modeButtons[mode]!.onClick()
                mouse(.mouseMoved, CGPoint(x: 1200, y: 1000))
                try snapshot("bar-\(mode)-\(look)")
                overlay.dismiss()
            }
        }
        defaults.removeObject(forKey: Pref.overlayAppearance)

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
        mouse(.mouseMoved, CGPoint(x: 1200, y: 1000))
        try snapshot("bar-frame")
        defaults.set(false, forKey: Pref.frame)
        overlay.dismiss()

        open()
        drag(rough, release: false)
        try await waitFor("a snap preview") { overlay.snapPreview != nil }
        try snapshot("area-drag-snap")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        try snapshot("area-released")
        // The ratio chip's lock, clicked on and off.
        func ratioLock() -> BarButton { overlay.chrome.lock }
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
        // Edit-mode chrome on a large selection: the ratio chip and the Live Text button, then the edge keys with the pointer inside,
        // the ratio menu open, and a small selection, one at each screen edge, and the full screen, each with the pointer inside.
        open()
        let editExtent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let editRect = CGRect(x: 600, y: 300, width: 1000, height: 600)
        overlay.selection = AreaSelection(extent: editExtent, exact: editRect)
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: 40, y: 40))
        try snapshot("edit-chrome")
        print("strip width, edit: \(overlay.chrome.strip.frame.width) pt")
        // The strip under each modifier: Agent, Text and Save As, Translate, with the held caps lit.
        for (name, modifiers) in [("cmd", NSEvent.ModifierFlags.command), ("shift", .shift), ("option", .option), ("option-shift", [.option, .shift]), ("option-cmd", [.option, .command])] {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            try snapshot("edit-chrome-\(name)")
            print("strip width, edit with \(name): \(overlay.chrome.strip.frame.width) pt")
        }
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        mouse(.mouseMoved, CGPoint(x: editRect.midX, y: editRect.midY))
        try snapshot("edit-chrome-pointer-inside")
        // The legend with the pointer inside, under each modifier set: one action, or none while Command is held without Option.
        for (name, modifiers) in [("shift", NSEvent.ModifierFlags.shift), ("option", .option), ("option-shift", [.option, .shift]), ("option-cmd", [.option, .command]),
                                  ("option-shift-cmd", [.option, .shift, .command]), ("control-option", [.control, .option]),
                                  ("control-option-cmd", [.control, .option, .command]), ("control", .control), ("cmd", .command)] {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            try snapshot("legend-\(name)")
        }
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        try snapshot("edit-chrome-pointer-inside-shift")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        key(35, "p")
        for _ in 0..<3 { key(125, "") }
        try snapshot("edit-ratio-menu")
        key(53, "\u{1B}")
        key(32, "u")
        try await waitFor("the Colors menu") { !overlay.chrome.colorMenu.isHidden }
        try snapshot("edit-colors-menu")
        key(53, "\u{1B}")
        let edgeRects = [("small", CGRect(x: 600, y: 300, width: 120, height: 80)), ("left", CGRect(x: 0, y: 600, width: 500, height: 300)),
                         ("right", CGRect(x: editExtent.width - 500, y: 600, width: 500, height: 300)), ("top", CGRect(x: 900, y: 0, width: 700, height: 300)),
                         ("bottom", CGRect(x: 900, y: editExtent.height - 300, width: 700, height: 300)),
                         ("small-bottom", CGRect(x: 600, y: editExtent.height - 160, width: 120, height: 80)), ("full", editExtent)]
        for (name, rect) in edgeRects {
            overlay.selection = AreaSelection(extent: editExtent, exact: rect)
            overlay.refresh()
            mouse(.mouseMoved, CGPoint(x: 40, y: 40))
            mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY))
            try snapshot("edit-chrome-\(name)")
            guard name == "small" else { continue }
            // The 60 x 40 pt selection keeps its legend group in one place under a modifier, and a focused corner shows its chip and keys.
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            try snapshot("edit-chrome-small-option")
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            overlay.focusedCorner = .topRight
            overlay.refresh()
            try snapshot("edit-chrome-small-corner-focused")
            overlay.focusedCorner = nil
        }
        overlay.dismiss()

        open()
        overlay.setWindows([CGRect(x: 300, y: 300, width: 1300, height: 1000)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 900, y: 700))
        try snapshot("window-hover")
        defaults.set(true, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: 901, y: 701))
        try snapshot("window-hover-loupe")
        // Shift held in HSL: the readout's value in HSL, then format and the Shift-C caps.
        defaults.set(ColorFormat.hsl.rawValue, forKey: Pref.colorFormat)
        func shift(_ flags: NSEvent.ModifierFlags) {
            overlay.flagsChanged(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        }
        shift(.shift)
        try snapshot("window-hover-loupe-format")
        shift([])
        defaults.set(ColorFormat.hex.rawValue, forKey: Pref.colorFormat)
        defaults.set(false, forKey: Pref.loupe)
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
        mouse(.mouseMoved, CGPoint(x: rounded.midX, y: rounded.midY))
        for (corner, name) in [(Handle.topLeft, "top-left"), (.bottomRight, "bottom-right")] {
            overlay.focusedCorner = corner
            overlay.refresh()
            try snapshot("selection-corner-focused-\(name)")
        }
        // The loupe on the hovered bottom-right corner's chip, on the strip, and on the chip row: it draws above them all.
        overlay.focusedCorner = nil
        defaults.set(true, forKey: Pref.loupe)
        func pixel(at view: NSView) -> CGPoint { CGPoint(x: view.frame.midX * overlay.scale, y: (overlay.view.bounds.height - view.frame.midY) * overlay.scale) }
        for (name, at) in [("corner-chip", { overlay.cornerRadii(of: rounded).dot(of: .bottomRight, in: rounded, minimumInset: 8 * overlay.scale) }),
                           ("strip", { pixel(at: overlay.chrome.strip) }), ("chips", { pixel(at: overlay.chrome.size) })] {
            mouse(.mouseMoved, CGPoint(x: rounded.midX, y: rounded.midY))
            mouse(.mouseMoved, at())
            try snapshot("loupe-over-\(name)")
        }
        defaults.set(false, forKey: Pref.loupe)
        overlay.dismiss()

        // The loupe's readout with the pointer over and next to the bottom chrome (the settings bar and the strip), in hover and in edit.
        defaults.set(true, forKey: Pref.loupe)
        let chrome = overlay.chrome
        for state in ["hover", "edit"] {
            open()
            if state == "hover" {
                overlay.setWindows([CGRect(x: 300, y: 300, width: 1300, height: 1000)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
                mouse(.mouseMoved, CGPoint(x: 900, y: 700))
            } else {
                overlay.selection = AreaSelection(extent: editExtent, exact: editRect)
                overlay.refresh()
            }
            func center(_ view: NSView, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint { CGPoint(x: (view.frame.midX + dx) * overlay.scale, y: (overlay.view.bounds.height - view.frame.midY + dy) * overlay.scale) }
            let spots: [(String, CGPoint)] = [("strip", center(chrome.strip)), ("strip-left", center(chrome.strip, dx: -chrome.strip.frame.width / 2 - 30)),
                                              ("strip-below", center(chrome.strip, dy: chrome.strip.frame.height / 2 + 20)), ("bar", center(chrome.topBar)),
                                              ("bar-left", center(chrome.topBar, dx: -chrome.topBar.frame.width / 2 - 30)), ("bottom-edge", CGPoint(x: 1280, y: editExtent.height - 4))]
            for (name, spot) in spots {
                mouse(.mouseMoved, CGPoint(x: 40, y: 40))
                mouse(.mouseMoved, spot)
                try snapshot("readout-\(state)-\(name)")
            }
            overlay.dismiss()
        }
        defaults.set(false, forKey: Pref.loupe)

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

        // Finder's sidebar (a synthetic 920 x 436 pt Finder window at 2x) with Documents hovered: Up outlines the sidebar, Down the
        // icon, and Left and Right outline nothing. The frames are the live AX tree's (FinderSidebarHoverTests), in window points; the
        // icon's is its glyph's pixel box in the fixture, as the AX tree read has no icon frame.
        let finderURL = DebugRun.sourceFile("Tests/Fixtures/finder-window.png")
        let finder = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(finderURL as CFURL, nil)!, 0, nil)!
        overlay.present(image: finder, frame: CGRect(x: frame.minX, y: frame.minY, width: CGFloat(finder.width) / 2, height: CGFloat(finder.height) / 2), displayID: nil)
        overlay.detectionTask?.cancel()
        func finderPixels(_ rect: CGRect) -> CGRect { CGRect(x: (rect.minX - 341) * 2, y: (rect.minY - 162) * 2, width: rect.width * 2, height: rect.height * 2) }
        let sidebarRows: [(name: String, y: CGFloat)] = [("Recents", 214), ("Shared", 246), ("Applications", 310), ("Desktop", 342), ("Developer", 374), ("Documents", 406),
                                                         ("Downloads", 438), ("iCloud Drive", 502), ("Home", 534), ("Macintosh HD", 566)]
        let finderCells = sidebarRows.map { Candidate(id: "ax-\($0.name)", label: "cell", bounds: finderPixels(CGRect(x: 351, y: $0.y, width: 139, height: 32)), score: AccessibilityBounds.baseScore, kind: .element) }
        let finderSidebar = Candidate(id: "ax-sidebar", label: "scroll area", bounds: finderPixels(CGRect(x: 341, y: 214, width: 159, height: 384)), score: AccessibilityBounds.baseScore, kind: .element)
        let documentsIcon = Candidate(id: "ax-icon", label: "image", bounds: CGRect(x: 44, y: 503, width: 28, height: 35), score: AccessibilityBounds.baseScore, kind: .element)
        overlay.session = SelectionSession(candidates: finderCells + [finderSidebar, documentsIcon], extent: CGRect(x: 0, y: 0, width: finder.width, height: finder.height),
                                           anchor: CGPoint(x: documentsIcon.bounds.midX, y: documentsIcon.bounds.midY))
        mouse(.mouseMoved, CGPoint(x: documentsIcon.bounds.midX, y: documentsIcon.bounds.midY))
        key(126, "")
        let finderHints = overlay.view.overlays
        require(finderHints.hover == finderCells[5].bounds && finderHints.upHint == finderSidebar.bounds && finderHints.downHint == documentsIcon.bounds,
                "Finder render: Documents hovered, Up the sidebar, Down the icon, nothing for Left and Right")
        try snapshot("hint-outlines-finder")
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
            try await waitFor("the found-text flash to go off") { overlay.view.overlays.flashPills.isEmpty }
            let all = liveText.text
            liveText.selectedRanges = [all.range(of: "Product name")!.lowerBound..<all.range(of: "Second product")!.upperBound]
            overlay.refresh()
            try snapshot("text")
            // The Text strip under a one-line selection, with Shift held: Rows.
            liveText.selectedRanges = [all.range(of: "Billing address")!]
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
            try snapshot("text-selected-strip")
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
            overlay.targetLanguage = Locale.Language(identifier: "de")
            overlay.translationStatus = { _, _ in .supported }
            key(36, "\r", .option)
            try await waitFor("the not-installed pill") { overlay.text.notice != nil }
            try snapshot("text-translate-missing")
            overlay.dismiss()

            try await renderTextBox()

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
            let fixtures = DebugRun.sourceFile("Tests/Fixtures/cutout")
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
            key(1, "s")
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
        print("strip width, hover: \(overlay.chrome.strip.frame.width) pt")
        defaults.set(true, forKey: Pref.candidates)
        key(126, "")
        try snapshot("capture-hover-list")
        defaults.set(false, forKey: Pref.candidates)
        overlay.dismiss()

        // On a live display a hovered window is captured with its real shadow when Frame is on: the hover size says "+ frame" with no
        // numbers, and Option flips it.
        open()
        try snapshot("capture-nothing-targeted")
        try await overlay.detectionTask?.value
        let browser = CGRect(x: 100, y: 100, width: 1500, height: 1200)
        overlay.setWindows([browser], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        for _ in 0..<8 where overlay.session?.selected?.kind != .window { key(126, "") }
        func option(_ held: Bool) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        }
        let framed = "1500 x 1200  + frame"
        var sizes = [texts(in: overlay.chrome.hover).last ?? ""]
        try snapshot("capture-hover-window")
        for _ in 0..<4 where overlay.session?.selected?.kind != .display { key(126, "") }
        try snapshot("capture-hover-display")
        for _ in 0..<4 where overlay.session?.selected?.kind != .window { key(125, "") }
        option(true)
        sizes.append(texts(in: overlay.chrome.hover).last ?? "")
        option(false)
        defaults.set(true, forKey: Pref.frame)
        overlay.refresh()
        sizes.append(texts(in: overlay.chrome.hover).last ?? "")
        try snapshot("capture-hover-window-frame")
        option(true)
        sizes.append(texts(in: overlay.chrome.hover).last ?? "")
        option(false)
        defaults.set(false, forKey: Pref.frame)
        require(sizes == ["1500 x 1200", framed, framed, "1500 x 1200"],
                "a live window's hover size adds nothing with Frame off and + frame with it on, and Option flips it: \(sizes)")
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
        for key in [Pref.loupe, Pref.rulers, Pref.crosshair] { defaults.set(true, forKey: key) }
        mouse(.mouseMoved, CGPoint(x: cart.midX, y: cart.midY))
        key(9, "v")
        try snapshot("recording-armed")
        for key in [Pref.loupe, Pref.rulers, Pref.crosshair] { defaults.set(false, forKey: key) }
        key(36, "\r")
        try snapshot("recording-count-in")
        overlay.dismiss()

        // Scrolling capture of an area inside a window, frames cut from the fixture; the live screen would show through.
        open()
        var scrolled: CGFloat = 0
        overlay.scrollFrames = { image.cropping(to: $0.offsetBy(dx: 0, dy: scrolled))! }
        overlay.setWindows([CGRect(x: 100, y: 100, width: 1500, height: 1200)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.selection = AreaSelection(extent: editExtent, exact: editRect)
        key(5, "g")
        try await waitFor("the first frame") { overlay.scrollHeight > 0 }
        for offset in [150, 300, 450] as [CGFloat] {
            scrolled = offset
            try await waitFor("the frame at \(offset)") { overlay.scrollHeight == Int(editRect.height + offset) }
        }
        try snapshot("scrolling")
        overlay.dismiss()
        overlay.scrollFrames = nil

        // The light look: hover, a selection with the pointer inside and the ratio menu open, and armed recording.
        defaults.set("light", forKey: Pref.overlayAppearance)
        open()
        overlay.detectionTask?.cancel()
        overlay.setWindows([CGRect(x: 300, y: 300, width: 1300, height: 1000)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 900, y: 700))
        try snapshot("light-window-hover")
        defaults.set(true, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: 901, y: 701))
        try snapshot("light-window-hover-loupe")
        defaults.set(false, forKey: Pref.loupe)
        overlay.dismiss()
        open()
        overlay.selection = AreaSelection(extent: editExtent, exact: editRect)
        overlay.refresh()
        mouse(.mouseMoved, CGPoint(x: editRect.midX, y: editRect.midY))
        try snapshot("light-edit-chrome-pointer-inside")
        key(35, "p")
        try snapshot("light-edit-ratio-menu")
        key(53, "\u{1B}")
        key(32, "u")
        try await waitFor("the Colors menu") { !overlay.chrome.colorMenu.isHidden }
        try snapshot("light-edit-colors-menu")
        key(53, "\u{1B}")
        for key in [Pref.loupe, Pref.rulers, Pref.crosshair] { defaults.set(true, forKey: key) }
        key(9, "v")
        try snapshot("light-recording-armed")
        for key in [Pref.loupe, Pref.rulers, Pref.crosshair] { defaults.set(false, forKey: key) }
        overlay.dismiss()
        defaults.removeObject(forKey: Pref.overlayAppearance)

        try await renderMenuBarIcons(into: directory)

        try await renderToasts(into: directory, image: image)
        // The recording's stop reminder, in the dark look.
        defaults.set("dark", forKey: Pref.overlayAppearance)
        try renderPanels([ScreenRecording.makeReminder(around: CGRect(x: 300, y: 300, width: 400, height: 200), on: CGMainDisplayID(), defaults: defaults)],
                         on: NSColor(white: 0.5, alpha: 1), to: directory.appending(path: "recording-reminder.png"))
        defaults.removeObject(forKey: Pref.overlayAppearance)

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
        require(menu.items.map(\.title) == ["Capture", "Capture Text", "", "Settings...", "Check for Updates...", "", "Quit Snug"], "menu items: \(menu.items.map(\.title))")
        require(capture.keyEquivalent == " " && capture.keyEquivalentModifierMask == [.control, .shift], "Capture shows the shortcut as a key equivalent")
        require(menu.items[3].keyEquivalent == "," && menu.items[6].keyEquivalent == "q", "Settings and Quit carry their command keys")
        SnugApp.showRecording(true, in: menu)
        require(menu.items.filter { !$0.isHidden }.prefix(2).map(\.title) == ["Stop Recording", ""] && capture.keyEquivalent == " ",
                "while recording, Stop Recording with the shortcut replaces Capture and Capture Text: \(menu.items.filter { !$0.isHidden }.map(\.title))")
        SnugApp.showRecording(false, in: menu)
        require(menu.items.filter { !$0.isHidden }.map(\.title) == ["Capture", "Capture Text", "", "Settings...", "Check for Updates...", "", "Quit Snug"],
                "after the recording the menu is restored")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{21E7}space", "the default shortcut displays as glyphs: \(Shortcut.label(from: defaults))")
        defaults.set(40, forKey: Pref.hotKeyCode)
        defaults.set(Int(NSEvent.ModifierFlags([.control, .option]).rawValue), forKey: Pref.hotKeyModifiers)
        capture.setShortcut(from: defaults)
        require(capture.keyEquivalent == "k" && capture.keyEquivalentModifierMask == [.control, .option], "a recorded letter shortcut updates the key equivalent")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{2325}K", "the recorded shortcut displays from code and modifiers: \(Shortcut.label(from: defaults))")
        let hintFill = overlay.chrome.topBar.groups[0].layer!.backgroundColor.flatMap(NSColor.init(cgColor:))!
        require(hintFill.alphaComponent >= 0.92, "the settings bar is on the chrome surface: \(hintFill.alphaComponent)")
        requireBackground(overlay)
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
            let included = Set(try DisplayCapture.filter(for: CGMainDisplayID(), in: content, excluding: excluded).includedWindows.map(\.windowID))
            precondition(included.contains(settingsID), "the capture filter includes the Settings window \(settingsID)")
            precondition(!included.contains(overlayID), "the capture filter leaves out the overlay window \(overlayID)")
            print("capture filter: settings included, overlay excluded, \(included.count) windows included")
        } else {
            print("capture filter: skipped, this process has no Screen Recording permission")
        }
        requireBackground(overlay)
        exit(EXIT_SUCCESS)
    }

    /// Each Settings tab hosted in an NSHostingView inside a window that is never shown, drawn to a PNG in `directory`.
    static func renderSettings(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs = SettingsTabs.makeController()
        func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] { view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(of: $0, type) } }
        for item in tabs.tabViewItems {
            let host = NSHostingView(rootView: (item.viewController as! NSHostingController<AnyView>).rootView.background(Color(nsColor: .windowBackgroundColor)))
            let offscreen = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: true)
            offscreen.contentView = host
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.width == SettingsTabs.width, "the \(item.label) tab is \(SettingsTabs.width) pt wide: \(host.fittingSize.width)")
            precondition(host.fittingSize.height == SettingsTabs.tallHeight,
                         "the \(item.label) tab is \(SettingsTabs.tallHeight) pt tall: \(host.fittingSize.height)")
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = directory.appending(path: "settings-\(item.label.lowercased()).png")
            try rep.representation(using: .png, properties: [:])!.write(to: file)
            print(file.path, host.fittingSize)
            if item.label == "General" {
                // The pane scrolled to its end, where the Agent section sits.
                let scroll = descendants(of: host, NSScrollView.self).first!
                scroll.documentView!.scroll(CGPoint(x: 0, y: scroll.documentView!.isFlipped ? scroll.documentView!.bounds.maxY : 0))
                host.layoutSubtreeIfNeeded()
                host.cacheDisplay(in: host.bounds, to: rep)
                let scrolled = directory.appending(path: "settings-general-scrolled.png")
                try rep.representation(using: .png, properties: [:])!.write(to: scrolled)
                print(scrolled.path)
            }
            if item.label == "Appearance" {
                // The checks below change these real settings; they are put back as they were.
                let saved = [Pref.frameShadow, Pref.highlightColor, Pref.frameShadowColor].map { ($0, UserDefaults.standard.object(forKey: $0)) }
                // The pane scrolled to its end, where the Frame section sits, with the default shadow and then a custom one.
                for (suffix, shadow) in [("", "default"), ("-custom", "custom")] {
                    UserDefaults.standard.set(shadow, forKey: Pref.frameShadow)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    host.layoutSubtreeIfNeeded()
                    let scroll = descendants(of: host, NSScrollView.self).first!
                    scroll.documentView!.scroll(CGPoint(x: 0, y: scroll.documentView!.isFlipped ? scroll.documentView!.bounds.maxY : 0))
                    host.layoutSubtreeIfNeeded()
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let scrolled = directory.appending(path: "settings-appearance\(suffix)-scrolled.png")
                    try rep.representation(using: .png, properties: [:])!.write(to: scrolled)
                    print(scrolled.path)
                }
                // The highlight's custom circle and the shadow swatch share the color panel: whichever took it last alone writes a picked color,
                // even when the other still hears the change. The panel is never ordered in.
                let defaults = UserDefaults.standard, panel = NSColorPanel.shared
                let swatches = descendants(of: host, NSButton.self).compactMap { $0.target as? ColorSwatch.Coordinator }
                precondition(swatches.count == 2, "the highlight's custom circle and the custom shadow's swatch: \(swatches.count)")
                // View order is SwiftUI's, so each control is told apart by the setting its binding reads.
                defaults.set("#ABCDEF", forKey: Pref.highlightColor)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let highlight = swatches.first { $0.hex.wrappedValue == "#ABCDEF" }!, swatch = swatches.first { $0 !== highlight }!
                for (first, second, firstKey, secondKey) in [(highlight, swatch, Pref.highlightColor, Pref.frameShadowColor),
                                                             (swatch, highlight, Pref.frameShadowColor, Pref.highlightColor)] {
                    defaults.set("#112233", forKey: firstKey)
                    defaults.set("#445566", forKey: secondKey)
                    first.take()
                    second.take()
                    panel.color = NSColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 1)
                    first.colorChanged(panel)
                    second.colorChanged(panel)
                    precondition(defaults.string(forKey: secondKey) == "#3399FF" && defaults.string(forKey: firstKey) == "#112233" && !panel.isVisible,
                                 "a color picked after \(secondKey)'s control took the panel from \(firstKey)'s changes only \(secondKey): "
                                 + "\(String(describing: defaults.string(forKey: firstKey))) \(String(describing: defaults.string(forKey: secondKey)))")
                    print("color panel: \(secondKey) took it from \(firstKey), only \(secondKey) changed")
                }
                for (key, value) in saved { defaults.set(value, forKey: key) }
            }
            guard item.label == "General" else { continue }
            let field = descendants(of: host, ShortcutRecorder.Field.self).first!
            // The first two focus rings are the hedgertronic and Ko-fi links at the top, which are not buttons; then the Reset button and the
            // Save to button, an Allow button for each missing permission, and the Agent section's Clear and Copy.
            let controls = descendants(of: host, NSView.self).filter { "\(type(of: $0))".contains("FocusRingView") }.dropFirst(2)
            print("shortcut field", host.convert(field.frame, from: field.superview), "pop-up and button frames", controls.map { host.convert($0.frame, from: $0.superview) })
            precondition(controls.count >= 2 && controls.allSatisfy { $0.frame.height == field.frame.height }, "the shortcut field is as tall as the pop-ups and buttons: \(controls.map(\.frame)) \(field.frame)")
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
            descendants(of: field, NSButton.self).first!.performClick(nil)
            precondition(field.recording && UserDefaults.standard.integer(forKey: Pref.hotKeyCode) == hotKeyCode, "the clear button starts recording and writes nothing")
            // Command alone and a shortcut macOS has turned on are refused: recording goes on, with the reason in place of the placeholder.
            func press(_ code: Int, _ flags: NSEvent.ModifierFlags) {
                let character = Shortcut.keyNames[code]?.lowercased() ?? ""
                field.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: offscreen.windowNumber, context: nil,
                                                     characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(code))!)
            }
            func shown() -> [String] { descendants(of: field, NSTextField.self).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue) }
            press(13, .command)
            precondition(field.recording && shown() == ["Add \u{2303}, \u{2325} or \u{21E7}"] && UserDefaults.standard.integer(forKey: Pref.hotKeyCode) == hotKeyCode,
                         "Cmd-W is refused as every app's own: \(shown())")
            var symbolic: Unmanaged<CFArray>?
            precondition(CopySymbolicHotKeys(&symbolic) == noErr)
            let system = (symbolic!.takeRetainedValue() as! [[String: Any]]).first {
                $0["kHISymbolicHotKeyEnabled"] as? Bool == true && Shortcut.keyNames[$0["kHISymbolicHotKeyCode"] as? Int ?? -1] != nil
                    && ($0["kHISymbolicHotKeyModifiers"] as? Int ?? 0) & (controlKey | optionKey | cmdKey) != 0
                    && ($0["kHISymbolicHotKeyModifiers"] as? Int ?? 0) & (cmdKey | shiftKey | optionKey | controlKey) != cmdKey
            }!
            let systemCode = system["kHISymbolicHotKeyCode"] as! Int, carbon = system["kHISymbolicHotKeyModifiers"] as! Int
            let pairs: [(Int, NSEvent.ModifierFlags)] = [(cmdKey, .command), (shiftKey, .shift), (optionKey, .option), (controlKey, .control)]
            let systemFlags = NSEvent.ModifierFlags(pairs.filter { carbon & $0.0 != 0 }.map(\.1))
            press(systemCode, systemFlags)
            precondition(field.recording && shown() == ["Used by macOS"] && UserDefaults.standard.integer(forKey: Pref.hotKeyCode) == hotKeyCode,
                         "\(Shortcut.label(code: systemCode, modifiers: Int(systemFlags.rawValue))), a macOS shortcut, is refused: \(shown())")
            print("shortcut field refuses Cmd-W and \(Shortcut.label(code: systemCode, modifiers: Int(systemFlags.rawValue))) (macOS)")
            offscreen.makeFirstResponder(nil)
            precondition(!field.recording && UserDefaults.standard.integer(forKey: Pref.hotKeyCode) == hotKeyCode, "clearing then leaving the field keeps the shortcut")
        }
        precondition(tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Keys"], "Settings tabs: \(tabs.tabViewItems.map(\.label))")
        let window = SettingsTabs.makeWindow()
        let tabController = window.contentViewController as! NSTabViewController
        for (index, item) in tabController.tabViewItems.enumerated() {
            tabController.selectedTabViewItemIndex = index
            precondition(window.title == "Settings", "the Settings window title stays Settings on the \(item.label) tab: \"\(window.title)\"")
        }
    }

    /// Transparent windows' contents drawn where they sit on screen relative to each other, on `backdrop`, at the backing scale.
    /// Window shadows are the window server's, so they are not drawn.
    static func renderPanels(_ windows: [NSWindow], on backdrop: NSColor, to file: URL) throws {
        let area = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }.insetBy(dx: -16, dy: -16)
        let scale = windows[0].backingScaleFactor
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width * scale), pixelsHigh: Int(area.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        sheet.size = area.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        backdrop.setFill()
        CGRect(origin: .zero, size: area.size).fill()
        for window in windows {
            let content = window.contentView!
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: rep)
            rep.draw(in: window.frame.offsetBy(dx: -area.minX, dy: -area.minY), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using: .png, properties: [:])!.write(to: file)
        print(file.path)
    }

    /// `--render-toasts DIR`: the toast in each state, in the light and the dark look, as `toast-<state>-<look>.png` on a backdrop of
    /// that look; the preview states draw the preview panel where it sits by the capsule. Checks the sizes the design fixes: one line
    /// is 40 pt tall, a long warning two lines, the capsule at most 360 pt wide; the preview of a very tall and a very wide capture
    /// at 72 pt on their short side, cropped at the top and in the middle; hovering and the preview moving or resizing nothing. Then a stack
    /// of three toasts as `toast-stack-<look>.png`.
    static func renderToasts(into directory: URL, image: CGImage) async throws {
        Toast.isSuppressed = true
        Sound.isMuted = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        let defaults = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "snug-render-toast-\(UUID().uuidString)").path)!
        Pref.register(in: defaults)
        let screenshot = try await Output.png(image.cropping(to: CGRect(x: 0, y: 0, width: 1280, height: 800))!)
        // A very tall and a very wide capture: the screenshot tiled, the tall one with an orange band across its top 300 px.
        func tiled(_ width: Int, _ height: Int, band: Bool) async throws -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for x in stride(from: 0, to: width, by: 1280) {
                for y in stride(from: 0, to: height, by: 800) { context.draw(image.cropping(to: CGRect(x: 0, y: 0, width: 1280, height: 800))!, in: CGRect(x: x, y: y, width: 1280, height: 800)) }
            }
            if band {
                context.setFillColor(NSColor.systemOrange.cgColor)
                context.fill(CGRect(x: 0, y: height - 300, width: width, height: 300))
            }
            return try await Output.png(context.makeImage()!)
        }
        let tall = try await tiled(1280, 9000, band: true), wide = try await tiled(7200, 800, band: false)
        let movie = URL(fileURLWithPath: "/tmp/Snug 2026-10-22 at 14.03.11.mov")
        let longMovie = URL(fileURLWithPath: "/tmp/Snug 2026-10-22 at 14.03.11 onboarding walkthrough for review 11.mov")
        let swatch = NSColor(srgbRed: 0x3A / 255, green: 0x7B / 255, blue: 0xD5 / 255, alpha: 1)
        let topRight = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "snug-render-toast-\(UUID().uuidString)").path)!
        Pref.register(in: topRight)
        topRight.set("topRight", forKey: Pref.toastPosition)
        let yellow = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "snug-render-toast-\(UUID().uuidString)").path)!
        Pref.register(in: yellow)
        yellow.set("#FFC600", forKey: Pref.highlightColor)
        let longWarning = "Pinned or moving content: the header and sidebar stayed fixed while the page scrolled, so 120 px at 4 seams may repeat. Check the stitch before sharing."
        let states: [(name: String, hover: Bool, peek: Bool, toast: () -> Toast)] = [
            ("image", false, false, { Toast(png: screenshot, message: "Copied", detail: "1280 x 800", file: nil, color: nil, defaults: defaults) }),
            ("hover", true, false, { Toast(png: screenshot, message: "Copied", detail: "1280 x 800", file: nil, color: nil, defaults: defaults) }),
            ("preview", true, true, { Toast(png: screenshot, message: "Copied", detail: "1280 x 800", file: nil, color: nil, defaults: defaults) }),
            ("preview-top-right", true, true, { Toast(png: screenshot, message: "Copied", detail: "1280 x 800", file: nil, color: nil, defaults: topRight) }),
            ("saved-hover", true, false, { Toast(png: screenshot, message: "Saved to Desktop", detail: "1280 x 800",
                                                 file: URL(fileURLWithPath: "/tmp/Snug 2026-10-22 at 14.03.11.png"), color: nil, defaults: defaults) }),
            ("text", false, false, { Toast(png: nil, message: "Copied 3 lines", detail: "", file: nil, color: nil,
                                           text: "\nShip v1.0 settings pane and move the toast lifetime picker under General\nFix toast on second display\nDraft the release notes", defaults: defaults) }),
            ("text-hover", true, false, { Toast(png: nil, message: "Copied 3 lines", detail: "", file: nil, color: nil, text: "Ship v1.0 settings pane\nFix toast", defaults: defaults) }),
            ("text-yellow-highlight", false, false, { Toast(png: nil, message: "Copied", detail: "", file: nil, color: nil, text: "Ship v1.0", defaults: yellow) }),
            ("warning", false, false, { Toast(png: tall, message: "Copied", detail: "Pinned or moving content: 120 px may repeat", file: nil, color: .systemOrange, defaults: defaults) }),
            ("warning-long", false, false, { Toast(png: tall, message: "Copied", detail: longWarning, file: nil, color: .systemOrange, defaults: defaults) }),
            ("warning-long-hover", true, false, { Toast(png: tall, message: "Copied", detail: longWarning, file: nil, color: .systemOrange, defaults: defaults) }),
            ("recording", false, false, { Toast(png: screenshot, message: "Copied, saved to Desktop", detail: movie.lastPathComponent, file: movie, color: nil, defaults: defaults) }),
            ("recording-hover", true, false, { Toast(png: screenshot, message: "Copied, saved to Desktop", detail: movie.lastPathComponent, file: movie, color: nil, defaults: defaults) }),
            ("color", false, false, { Toast(png: nil, message: "Copied", detail: "#3A7BD5", file: nil, color: swatch, text: "#3A7BD5", defaults: defaults) }),
            ("color-hover", true, false, { Toast(png: nil, message: "Copied", detail: "#3A7BD5", file: nil, color: swatch, text: "#3A7BD5", defaults: defaults) }),
            ("failure", false, false, { Toast(png: nil, message: "Capture failed", detail: "The display is not available.", file: nil, color: .systemRed, defaults: defaults) }),
            ("failure-hover", true, false, { Toast(png: nil, message: "Capture failed", detail: "The display is not available.", file: nil, color: .systemRed, defaults: defaults) }),
            ("failure-capture", false, false, { Toast(png: screenshot, message: "Save failed", detail: "You do not have permission to save in Desktop.", file: nil,
                                                      color: .systemRed, defaults: defaults) }),
            ("long-filename", false, false, { Toast(png: screenshot, message: "Copied, saved to Desktop", detail: longMovie.lastPathComponent, file: longMovie, color: nil, defaults: defaults) }),
            ("long-message", false, false, { Toast(png: screenshot, message: "Saved to Design Review Screenshots 2026", detail: "1280 x 800",
                                                   file: URL(fileURLWithPath: "/tmp/Snug 2026-10-22 at 14.03.11.png"), color: nil, defaults: defaults) }),
            ("tall", true, true, { Toast(png: tall, message: "Copied", detail: "1280 x 9000", file: nil, color: nil, defaults: defaults) }),
            ("wide", true, true, { Toast(png: wide, message: "Copied", detail: "7200 x 800", file: nil, color: nil, defaults: defaults) })
        ]
        for state in states {
            for (look, backdrop) in [(NSAppearance.Name.aqua, NSColor(srgbRed: 0.84, green: 0.87, blue: 0.93, alpha: 1)), (.darkAqua, NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1))] {
                // A toast takes the look the app is in when it opens.
                NSApp.appearance = NSAppearance(named: look)
                let toast = state.toast()
                func frames() -> [CGRect] { [toast.frame, toast.card.frame, toast.lead.frame, toast.textBox.frame, toast.actions.frame, toast.message.frame, toast.detail.frame] }
                let rest = frames()
                require(toast.card.frame.width <= 360 && toast.card.frame.height == (toast.detail.maximumNumberOfLines == 2 ? toast.card.frame.height : 40),
                        "\(state.name): one line is 40 pt tall (only a warning or failure wraps), and no capsule is wider than 360 pt: \(toast.card.frame.size)")
                if state.hover {
                    toast.setHovering(true)
                    try await Task.sleep(for: .milliseconds(250))
                }
                if state.peek { toast.setPeeking(true) }
                require(frames() == rest, "\(state.name): hovering and the preview move and resize nothing: \(frames()) \(rest)")
                try renderPanels([toast] + (state.peek ? [toast.preview!] : []), on: backdrop,
                                 to: directory.appending(path: "toast-\(state.name)-\(look == .aqua ? "light" : "dark").png"))
                switch state.name {
                case "warning-long":
                    require(toast.card.frame.height > 40 && toast.card.frame.height <= 48 && toast.detail.frame.height > 20 && toast.card.frame.width == 360,
                            "a long warning takes two lines at the full 360 pt: \(toast.card.frame.size) \(toast.detail.frame)")
                case "text":
                    require(toast.detail.stringValue == "\"Ship v1.0 settings pane and move the toast lifetime picker under General\"" && toast.detail.toolTip == nil
                                && toast.detail.lineBreakMode == .byTruncatingTail && toast.lead is NSImageView,
                            "copied text shows its first non-empty line in quotes, cut at the end, behind the text glyph: \(toast.detail.stringValue)")
                case "text-yellow-highlight":
                    require((toast.lead as! NSImageView).symbolConfiguration == NSImage.SymbolConfiguration(pointSize: 27, weight: .regular)
                                .applying(.init(paletteColors: [.black, Highlight.color(hex: "#FFC600")])),
                            "the text glyph is black on the yellow highlight color")
                case "long-filename":
                    require(toast.detail.lineBreakMode == .byTruncatingMiddle && toast.detail.toolTip == longMovie.lastPathComponent && toast.card.frame.width == 360,
                            "a long file name is cut in the middle with the full name as its tooltip")
                case "recording-hover":
                    require(toast.actions.arrangedSubviews.filter { !$0.isHidden }.map { $0.toolTip! } == ["Copy", "Move to Trash", "Open in \(Toast.appName(toOpen: .quickTimeMovie))", "Show in Finder", "Share"],
                            "a saved recording offers Copy, Trash, Open in its default app, Show in Finder and Share")
                case "saved-hover":
                    require(toast.actions.arrangedSubviews.filter { !$0.isHidden }.map { $0.toolTip! } == ["Copy", "Move to Trash", "Open in \(Toast.appName(toOpen: .png))", "Show in Finder", "Share"],
                            "a saved capture offers Copy, Trash, Open in its default app, Show in Finder and Share")
                case "color-hover":
                    require(toast.actions.arrangedSubviews.filter { !$0.isHidden }.map { $0.toolTip! } == ["Copy"] && toast.lead is NSBox, "a color offers Copy, behind its swatch")
                case "text-hover":
                    require(toast.actions.arrangedSubviews.filter { !$0.isHidden }.map { $0.toolTip! } == ["Copy", "Open in \(Toast.appName(toOpen: .plainText))", "Share"],
                            "copied text offers Copy, Open in the default plain text app and Share")
                case "tall", "wide":
                    let size = toast.preview!.frame.size
                    require(size == (state.name == "tall" ? CGSize(width: 72, height: 160) : CGSize(width: 240, height: 72)), "\(state.name): the preview is \(size)")
                case "preview":
                    require(toast.preview!.frame.minY == toast.frame.maxY && toast.preview!.frame.minY - (toast.frame.minY + toast.card.frame.maxY) == 10,
                            "the preview is 10 pt above the capsule")
                default: break
                }
                if state.name == "tall" {
                    // The band across the tall capture's top is the top of both the thumbnail and the preview.
                    for view in [toast.lead, toast.preview!.contentView!] {
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let top = rep.colorAt(x: rep.pixelsWide / 2, y: 6)!.usingColorSpace(.sRGB)!, bottom = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 6)!.usingColorSpace(.sRGB)!
                        require(top.redComponent - top.blueComponent > 0.4 && bottom.redComponent - bottom.blueComponent < 0.2,
                                "a tall capture is cropped to its top: top \(top), bottom \(bottom)")
                    }
                }
                toast.dismiss()
            }
        }
        // A stack of three, the newest at the bottom, with the middle one's preview, as `toast-stack-<look>.png`.
        for (look, backdrop) in [(NSAppearance.Name.aqua, NSColor(srgbRed: 0.84, green: 0.87, blue: 0.93, alpha: 1)), (.darkAqua, NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1))] {
            NSApp.appearance = NSAppearance(named: look)
            let stacked = [Toast(png: tall, message: "Copied", detail: "1280 x 9000", file: nil, color: nil, defaults: defaults),
                           Toast(png: screenshot, message: "Saved to Desktop", detail: "1280 x 800", file: URL(fileURLWithPath: "/tmp/Snug.png"), color: nil, defaults: defaults),
                           Toast(png: nil, message: "Copied", detail: "#3A7BD5", file: nil, color: swatch, text: "#3A7BD5", defaults: defaults)]
            for toast in stacked { Toast.stack(toast) }
            try renderPanels(stacked + [stacked[1].preview!], on: backdrop, to: directory.appending(path: "toast-stack-\(look == .aqua ? "light" : "dark").png"))
            for toast in stacked { toast.dismiss() }
        }
        NSApp.appearance = nil
    }

    /// `--render-menubar-icons DIR`: every menu bar icon variant drawn from `SnugApp.menuBarIcon` the way the status item draws it (an 18 pt
    /// template image picking its 1x or 2x representation), tinted for a light (#F6F6F6) and a dark (#1E1E1E) menu bar, at true size above
    /// an 8x nearest-neighbor zoom, one row per variant in `menubar-icons.png`. Then checks that the status item's observer switches icons
    /// when another process writes `SnugMenuBarIcon`.
    static func renderMenuBarIcons(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants = ["q", "p", "h", "a"]
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
            for (column, cell) in cells.enumerated() {
                let icon = SnugApp.menuBarIcon(variant, dark: cell.dark)
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
                try small.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(variant)-\(cell.scale)x-\(cell.dark ? "dark" : "light").png"))
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

        // At 1x, variant h's arch dashes and band step are fully clear (top-left pixel and size, rows from the top) and the tile between them solid.
        let solidTile = SnugApp.menuBarIcon("h").representations.first { $0.pixelsWide == 18 } as! NSBitmapImageRep
        let clear = [(5, 3, 2, 1), (8, 3, 2, 1), (11, 3, 2, 1), (4, 5, 1, 2), (13, 5, 1, 2), (1, 10, 3, 1), (4, 9, 10, 1), (14, 10, 3, 1)]
        for (x, y, width, height) in clear {
            for column in x..<x + width {
                for row in y..<y + height { precondition(solidTile.colorAt(x: column, y: row)!.alphaComponent == 0, "1x h: pixel \(column), \(row) is clear") }
            }
        }
        for (column, row) in [(7, 3), (10, 3), (4, 4), (4, 7), (13, 4), (4, 8), (9, 7), (9, 10), (2, 9), (2, 11)] {
            precondition(solidTile.colorAt(x: column, y: row)!.alphaComponent == 1, "1x h: pixel \(column), \(row) is solid")
        }

        let suite = FileManager.default.temporaryDirectory.appending(path: "snug-icon-\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: suite)!
        Pref.register(in: defaults)
        let button = NSButton()
        let observation = SnugApp.observeMenuBarIcon(on: button, defaults: defaults)
        // "q" is the registered default, so it goes last to make every write a real change.
        for variant in variants.reversed() {
            let writer = try Process.run(URL(fileURLWithPath: "/usr/bin/defaults"), arguments: ["write", suite, Pref.menuBarIcon, variant])
            writer.waitUntilExit()
            let expected = SnugApp.menuBarIcon(variant, dark: SnugApp.isDark(button)).tiffRepresentation
            for _ in 0..<500 where button.image?.tiffRepresentation != expected { try await Task.sleep(for: .milliseconds(10)) }
            precondition(button.image?.tiffRepresentation == expected, "`defaults write \(Pref.menuBarIcon) \(variant)` from another process switches the icon")
            print("defaults write \(Pref.menuBarIcon) \(variant): the status item shows variant \(variant)")
        }
        observation.forEach { $0.invalidate() }
    }
}
