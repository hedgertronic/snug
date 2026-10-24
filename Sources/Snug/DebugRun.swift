import AppKit
import ImageIO
import ScreenCaptureKit
import ScreenshotCore

/// Headless checks driven by `--image PATH`: `--verify-area-ui` and `--measure`.
@MainActor
enum DebugRun {
    static func privateSetup(_ overlay: OverlayController, timeout: Duration = .seconds(120)) -> URL {
        overlay.isHeadless = true
        overlay.animates = false
        overlay.chooseSaveURL = { _ in preconditionFailure("a debug run shows no Save As panel") }
        overlay.openURL = { preconditionFailure("a debug run opens nothing: \($0)") }
        Toast.isSuppressed = true
        Toast.chooseSaveURL = { _ in preconditionFailure("a debug run shows no Save As panel") }
        // A debug run never takes the keyboard or activation from the app in front: either ends it at once.
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                FileHandle.standardError.write(Data("Debug run took focus: \(note.name.rawValue) \(note.object.map { "\($0)" } ?? "")\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            FileHandle.standardError.write(Data("Debug run timed out after \(timeout)\n".utf8))
            exit(EXIT_FAILURE)
        }
        // Parallel debug runs share nothing: a fixed suite or pasteboard name lets one run's settings and clipboard leak into another's.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "snug-verify-\(UUID().uuidString)")
        let folder = scratch.appending(path: "saves")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: scratch.appending(path: "prefs").path)!
        Pref.register(in: defaults)
        defaults.set(folder.path, forKey: Pref.saveFolder)
        defaults.set(scratch.appending(path: "agent").path, forKey: Pref.agentFolder)
        overlay.defaults = defaults
        overlay.pasteboard = NSPasteboard.withUniqueName()
        return folder
    }

    /// Ends a headless check: Snug is not active, no window is key, and the overlay never registered its Esc hot key.
    static func requireBackground(_ overlay: OverlayController?) {
        precondition(!NSApp.isActive && !NSApp.windows.contains(where: \.isKeyWindow) && overlay?.escape == nil,
                     "the debug run stayed in the background: active \(NSApp.isActive), key \(NSApp.windows.filter(\.isKeyWindow)), Esc hot key \(overlay?.escape != nil)")
    }

    static func pngSize(_ data: Data?) -> CGSize? {
        guard let data else { return nil }
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return CGSize(width: properties[kCGImagePropertyPixelWidth] as! Int, height: properties[kCGImagePropertyPixelHeight] as! Int)
    }

    // MARK: --verify-area-ui

    static func verifyArea(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        let folder = privateSetup(overlay)
        let pasteboard = overlay.pasteboard
        let defaults = overlay.defaults
        var passed: [String] = []

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Area UI verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<9000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            require(condition(), message)
        }
        func windowPoint(_ pixel: CGPoint) -> CGPoint {
            CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: windowPoint(pixel), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        // This suite is about drags and windows: it stops the background geometry so no late result changes a hover. --verify-extras-ui covers geometry.
        func open() {
            overlay.present(image: image, frame: frame, displayID: nil)
            overlay.detectionTask?.cancel()
        }
        func pressDrag(_ rect: CGRect, _ flags: NSEvent.ModifierFlags = []) {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY), flags)
            mouse(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY), flags)
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), flags)
        }
        func release(_ rect: CGRect) { mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY)) }
        func copiedSize() async throws -> CGSize? {
            await overlay.commitTask?.value
            return pngSize(pasteboard.data(forType: .png))
        }
        let tab: UInt16 = 48, returnKey: UInt16 = 36, escape: UInt16 = 53, space: UInt16 = 49
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        open()
        let scale = overlay.scale
        require(overlay.window.styleMask.contains(.nonactivatingPanel) && OverlayWindow().canBecomeKey && !overlay.window.canBecomeKey && !overlay.window.hidesOnDeactivate,
                "the overlay is a nonactivating panel that can become key, except in a debug run, and stays up when Snug deactivates")
        overlay.dismiss()

        // Pause-to-snap, release takes the preview.
        open()
        require(overlay.view.dimLayer.path!.isEmpty && !overlay.view.overlays.dimsAll, "the first frame of an opened Capture shows no dim")
        pressDrag(rough)
        require(!overlay.view.dimLayer.path!.isEmpty, "dragging dims everything outside the drag")
        require(overlay.snapPreview == nil, "no preview before the debounce")
        try await waitFor("drag + pause shows a snap preview") { overlay.snapPreview != nil }
        let preview = overlay.snapPreview!
        require(preview != rough && Detection.overlap(preview, rough) > 0.5, "preview \(preview) refines the drag and stays related to it")
        release(rough)
        require(overlay.selection?.rect == preview, "release takes the preview")
        // The form field rounds by about 6 px, under the detector's 8 px minimum, so its measured radius is 0; the check is that the measurement lands.
        try await waitFor("the snap's corner radius is measured") { overlay.radii[preview] != nil }
        require(overlay.view.overlays.radii == CornerRadii(overlay.radii[preview]!), "the released snap keeps its measured corner radius \(overlay.view.overlays.radii)")

        // Tab and Shift-Tab do nothing on a released selection.
        key(tab)
        key(tab, "", .shift)
        require(overlay.selection?.rect == preview, "Tab and Shift-Tab leave a released snap alone: \(String(describing: overlay.selection?.rect))")

        // Arrow nudges.
        let before = overlay.selection!.rect
        key(right)
        require(overlay.selection?.rect == before.offsetBy(dx: 1, dy: 0), "Right nudges 1 px")
        require(overlay.view.overlays.radii == .zero, "a nudged selection has square corners")
        key(down, "", .shift)
        require(overlay.selection?.rect == before.offsetBy(dx: 1, dy: 10), "Shift-Down nudges 10 px")
        key(left)
        key(up, "", .shift)
        require(overlay.selection?.rect == before, "Left and Shift-Up undo the nudges")

        // Handle resize and move through the view.
        let selection = overlay.selection!.rect
        mouse(.leftMouseDown, CGPoint(x: selection.maxX, y: selection.midY), .option)
        mouse(.leftMouseDragged, CGPoint(x: selection.maxX + 40, y: selection.midY), .option)
        mouse(.leftMouseUp, CGPoint(x: selection.maxX + 40, y: selection.midY), .option)
        require(overlay.selection?.rect == CGRect(x: selection.minX, y: selection.minY, width: selection.width + 40, height: selection.height),
                "Option-dragging the right handle resizes exactly")
        let resized = overlay.selection!.rect
        mouse(.leftMouseDown, CGPoint(x: resized.midX, y: resized.midY))
        mouse(.leftMouseDragged, CGPoint(x: resized.midX + 20, y: resized.midY + 6))
        mouse(.leftMouseUp, CGPoint(x: resized.midX + 20, y: resized.midY + 6))
        require(overlay.selection?.rect == resized.offsetBy(dx: 20, dy: 6), "dragging inside moves")

        // Tight copy: Return writes the selection's pixel size.
        let tight = overlay.selection!.rect
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(!overlay.window.isVisible, "Return closes the overlay")
        let tightSize = try await copiedSize()
        require(tightSize == tight.size, "Return writes a PNG of \(tight.size)")

        // Frame size, M toggling it, Cmd-1 / Cmd-2 / Cmd-3 gone, and the one-time SnugStyle migration.
        open()
        pressDrag(rough)
        try await waitFor("preview for the frame") { overlay.snapPreview != nil }
        release(rough)
        let crop = overlay.selection!.rect
        key(0, "m")
        require(overlay.framed && defaults.bool(forKey: Pref.frame), "M turns Frame on and remembers it")
        pasteboard.clearContents()
        key(returnKey, "\r")
        let size = try await copiedSize()
        require(size == CGSize(width: crop.width + 48 * scale, height: crop.height + 48 * scale),
                "a framed PNG is 48 pt larger per dimension (\(String(describing: size)))")
        open()
        require(overlay.framed, "Frame stays on for the next overlay")
        key(0, "m")
        require(!overlay.framed && !defaults.bool(forKey: Pref.frame), "M turns Frame off")
        key(0, "m")
        require(overlay.framed, "M turns Frame back on")
        for digit in ["1", "2", "3"] { key(0, digit, .command) }
        require(overlay.framed, "Cmd-1, Cmd-2 and Cmd-3 do nothing now")
        for (stored, framed) in [("backdrop", true), ("tight", false), ("margin", false)] {
            let legacy = UserDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "snug-migrate-\(UUID().uuidString)").path)!
            legacy.set(stored, forKey: "SnugStyle")
            Pref.register(in: legacy)
            require(legacy.bool(forKey: Pref.frame) == framed && legacy.object(forKey: "SnugStyle") == nil,
                    "a stored SnugStyle of \(stored) migrates to Frame \(framed) and the old key is removed")
        }
        defaults.set(false, forKey: Pref.frame)
        overlay.dismiss()

        // Cmd-S saves only, to the save folder.
        open()
        pressDrag(rough)
        try await waitFor("preview before save") { overlay.snapPreview != nil }
        release(rough)
        let saved = overlay.selection!.rect
        pasteboard.clearContents()
        key(1, "s", .command)
        await overlay.commitTask?.value
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let savedData = try files.first.map { try Data(contentsOf: $0) }
        require(files.count == 1 && pngSize(savedData) == saved.size, "Cmd-S saves a PNG of the selection size")
        require(pasteboard.data(forType: .png) == nil, "Cmd-S alone leaves the pasteboard untouched")

        // Esc cancels without writing.
        open()
        pressDrag(rough)
        try await waitFor("preview before Esc") { overlay.snapPreview != nil }
        release(rough)
        pasteboard.clearContents()
        let released = overlay.selection!
        key(escape)
        require(overlay.window.isVisible && overlay.selection == nil && overlay.session != nil, "Esc on a released selection drops it back to hover: \(String(describing: overlay.selection))")
        key(6, "z", .command)
        require(overlay.selection == released, "Cmd-Z brings the dropped selection back: \(String(describing: overlay.selection))")
        key(6, "z", [.command, .shift])
        require(overlay.selection == nil && overlay.window.isVisible, "Cmd-Shift-Z drops it again")
        key(6, "z", .command)
        key(escape)
        key(escape)
        await overlay.commitTask?.value
        require(!overlay.window.isVisible && pasteboard.data(forType: .png) == nil, "a second Esc in hover closes without writing")
        let afterEsc = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        require(afterEsc.count == 1, "Esc saves nothing")

        // S toggles snap; Option-drag is exact.
        open()
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap) == false, "S turns snap off")
        pressDrag(rough)
        require(overlay.snapTask == nil && overlay.snapPreview == nil, "snap off schedules no analysis and shows no preview")
        release(rough)
        require(overlay.selection?.rect == rough, "with snap off the release takes the exact drag")
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap), "S turns snap back on")
        mouse(.leftMouseDown, CGPoint(x: 20, y: 20))
        mouse(.leftMouseUp, CGPoint(x: 20, y: 20))
        pressDrag(rough, .option)
        require(overlay.snapTask == nil && overlay.snapPreview == nil, "Option-drag schedules no analysis and shows no preview")
        release(rough)
        require(overlay.selection?.rect == rough, "Option-drag takes the exact rectangle")

        // Click outside clears; click inside copies.
        mouse(.leftMouseDown, CGPoint(x: 20, y: 20))
        mouse(.leftMouseUp, CGPoint(x: 20, y: 20))
        require(overlay.selection == nil && overlay.window.isVisible, "click outside clears the selection")
        pressDrag(rough, .option)
        release(rough)
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: rough.midX, y: rough.midY))
        mouse(.leftMouseUp, CGPoint(x: rough.midX, y: rough.midY))
        let clickSize = try await copiedSize()
        require(clickSize == rough.size, "click inside the selection copies it")

        // A quick drag releases the exact rectangle, and Tab leaves it alone.
        open()
        pressDrag(rough)
        release(rough)
        require(overlay.selection?.rect == rough && overlay.snapPreview == nil, "a quick drag releases the exact rectangle")
        key(tab)
        require(overlay.selection?.rect == rough,"Tab after a quick drag keeps the exact rectangle: \(overlay.selection!.rect)")
        overlay.dismiss()

        // Space moves the rectangle while dragging.
        open()
        key(1, "s")
        let origin = CGPoint(x: 400, y: 500)
        mouse(.leftMouseDown, origin)
        mouse(.leftMouseDragged, CGPoint(x: 600, y: 600))
        overlay.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: space)!)
        mouse(.leftMouseDragged, CGPoint(x: 640, y: 630))
        overlay.window.sendEvent(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: space)!)
        mouse(.leftMouseDragged, CGPoint(x: 700, y: 630))
        mouse(.leftMouseUp, CGPoint(x: 700, y: 630))
        require(overlay.selection?.rect == CGRect(x: 440, y: 530, width: 260, height: 100), "holding Space moves the rectangle, releasing Space resizes again")

        // F selects the full display.
        key(3, "f")
        require(overlay.selection?.rect == CGRect(x: 0, y: 0, width: image.width, height: image.height), "F selects the full display")

        // Hover outlines a window; click copies its visible rectangle.
        overlay.dismiss()
        open()
        let windowRect = CGRect(x: 300, y: 300, width: 400, height: 200)
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        require(overlay.view.overlays.hover == windowRect && !overlay.view.dimLayer.path!.isEmpty, "hovering a window dims everything outside it")
        defaults.set(false, forKey: Pref.frame)
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: 350, y: 350))
        mouse(.leftMouseUp, CGPoint(x: 350, y: 350))
        let windowSize = try await copiedSize()
        require(windowSize == windowRect.size, "click with no selection copies the window under the pointer")

        // A pointer event that arrives after the overlay closed (Escape, a copy) is ignored, not a crash.
        overlay.mouseMoved(NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint(CGPoint(x: 350, y: 350)), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        require(overlay.session == nil && overlay.view.overlays.hover == nil, "a mouse move after the overlay closed changes nothing")

        // Return with no selection copies what the pointer is over.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(try await copiedSize() == windowRect.size, "Return with no selection copies the hovered window")

        // W takes the window under the pointer even while an element inside it is hovered.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        let inner = CGRect(x: 330, y: 330, width: 60, height: 40)
        overlay.merge([Candidate(id: "ax-test", label: "Button", bounds: inner, score: AccessibilityBounds.baseScore, kind: .element)])
        require(overlay.view.overlays.hover == inner && overlay.session!.selected!.kind != .window, "an element inside the window is hovered")
        pasteboard.clearContents()
        key(13, "w")
        require(try await copiedSize() == windowRect.size && !overlay.window.isVisible, "W copies the window under the pointer, not the hovered element")

        // F with nothing selected copies the whole display at once, as W takes the window.
        open()
        let display = overlay.extent
        pasteboard.clearContents()
        key(3, "f")
        require(try await copiedSize() == display.size && !overlay.window.isVisible, "F with nothing selected copies the full screen")

        // On a selection, W grows it to the window holding its center and copies nothing.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        overlay.selection = AreaSelection(extent: overlay.extent, exact: CGRect(x: windowRect.midX - 20, y: windowRect.midY - 20, width: 40, height: 40))
        pasteboard.clearContents()
        key(13, "w")
        require(overlay.selection?.rect == windowRect && overlay.window.isVisible && pasteboard.data(forType: .png) == nil, "W on a selection grows it to the window")
        overlay.dismiss()

        // A tight crop that reaches the window's bottom edge is transparent outside the window's rounded bottom corners; the top stays square.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        overlay.radii[windowRect] = 20
        let bottomHalf = CGRect(x: windowRect.minX, y: windowRect.midY, width: windowRect.width, height: windowRect.height / 2)
        overlay.selection = AreaSelection(extent: overlay.extent, exact: bottomHalf)
        pasteboard.clearContents()
        overlay.copy()
        await overlay.commitTask?.value
        let clipped = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        let last = clipped.pixelsHigh - 1
        require(clipped.colorAt(x: 0, y: last)!.alphaComponent == 0 && clipped.colorAt(x: clipped.pixelsWide - 1, y: last)!.alphaComponent == 0
            && clipped.colorAt(x: 0, y: 0)!.alphaComponent == 1 && clipped.colorAt(x: clipped.pixelsWide - 1, y: 0)!.alphaComponent == 1,
            "a tight crop sharing a window's bottom corners clears them and keeps the top corners")

        // With automatic rounding off in Settings, the same crop is square and the outline too.
        defaults.set(false, forKey: Pref.roundCorners)
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        overlay.radii[windowRect] = 20
        overlay.selection = AreaSelection(extent: overlay.extent, exact: bottomHalf)
        overlay.refresh()
        require(overlay.view.overlays.radii == .zero, "with rounding off the outline is square")
        pasteboard.clearContents()
        overlay.copy()
        await overlay.commitTask?.value
        let square = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(square.colorAt(x: 0, y: square.pixelsHigh - 1)!.alphaComponent == 1 && square.colorAt(x: square.pixelsWide - 1, y: square.pixelsHigh - 1)!.alphaComponent == 1,
                "with rounding off the copy keeps square corners")
        defaults.set(true, forKey: Pref.roundCorners)

        // The outline draws the same per-corner shape; ] and [ change every corner by 1 pt (Shift: 4 pt) and the copy follows.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        overlay.radii[windowRect] = 20 * scale
        overlay.selection = AreaSelection(extent: overlay.extent, exact: bottomHalf)
        overlay.refresh()
        func corners(_ top: CGFloat, _ bottom: CGFloat) -> CornerRadii {
            CornerRadii(topLeft: top * scale, topRight: top * scale, bottomLeft: bottom * scale, bottomRight: bottom * scale)
        }
        require(overlay.view.overlays.radii == corners(0, 20), "the outline hugs the window's bottom corners and keeps the top square")
        key(30, "]")
        require(overlay.view.overlays.radii == corners(1, 20 + 1), "] grows every corner by 1 pt")
        require(!overlay.chrome.radius.isHidden && texts(in: overlay.chrome.radius) == ["r 1 / 1 / 21 / 21", "[", "]"]
                    && texts(in: overlay.chrome.size) == ["\(Int(bottomHalf.width)) x \(Int(bottomHalf.height))"],
                "the radius chip shows each corner after ], and the size chip keeps the size: \(texts(in: overlay.chrome.radius)) \(texts(in: overlay.chrome.size))")
        mouse(.mouseMoved, CGPoint(x: bottomHalf.midX, y: bottomHalf.midY))
        key(30, "]")
        let siblings = overlay.chrome.radius.superview!.subviews
        let covering = siblings[(siblings.firstIndex(of: overlay.chrome.radius)! + 1)...].filter { !$0.isHidden && $0 !== overlay.view.guides.host && $0.frame.intersects(overlay.chrome.radius.frame) }
        require(!overlay.chrome.radius.isHidden && texts(in: overlay.chrome.radius).first == "r 2 / 2 / 22 / 22" && covering.isEmpty,
                "with the pointer inside, ] shows the radius uncovered: \(texts(in: overlay.chrome.radius)) \(overlay.chrome.radius.frame) covered by \(covering.map { "\(type(of: $0)) \($0.frame) \(texts(in: $0))" })")
        key(33, "[")
        key(30, "}", .shift)
        require(overlay.view.overlays.radii == corners(5, 20 + 5), "Shift-] grows every corner by 4 pt")
        key(33, "[")
        require(overlay.view.overlays.radii == corners(4, 20 + 4), "[ shrinks every corner by 1 pt")
        pasteboard.clearContents()
        overlay.copy()
        await overlay.commitTask?.value
        let edited = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(edited.colorAt(x: 0, y: 0)!.alphaComponent < 0.5 && edited.colorAt(x: edited.pixelsWide - 1, y: 0)!.alphaComponent < 0.5
            && edited.colorAt(x: 0, y: edited.pixelsHigh - 1)!.alphaComponent == 0 && edited.colorAt(x: edited.pixelsWide / 2, y: 0)!.alphaComponent == 1,
            "the copy rounds the top corners with the edited radius and still clears the bottom ones")

        // The pointer pinned against the screen edge highlights the full display; Return takes it.
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 0, y: 350))
        require(overlay.view.overlays.hover == CGRect(x: 0, y: 0, width: image.width, height: image.height), "the pointer at the screen edge highlights the full display")
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        require(overlay.view.overlays.hover == windowRect, "moving in from the edge goes back to the window")
        mouse(.mouseMoved, CGPoint(x: 0, y: 350))
        pasteboard.clearContents()
        key(returnKey, "\r")
        require(try await copiedSize() == CGSize(width: image.width, height: image.height), "Return at the screen edge copies the full display")

        // A click with no window under the pointer selects the full display.
        overlay.dismiss()
        open()
        overlay.setWindows([windowRect], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 900, y: 900))
        mouse(.leftMouseDown, CGPoint(x: 900, y: 900))
        mouse(.leftMouseUp, CGPoint(x: 900, y: 900))
        require(overlay.selection?.rect == CGRect(x: 0, y: 0, width: image.width, height: image.height), "a click with no window under the pointer selects the full display")

        // A higher-layer target (menu, Dock, menu bar) listed in front wins hit-testing and is cropped from the frozen image.
        overlay.dismiss()
        open()
        let menuRect = CGRect(x: 330, y: 280, width: 150, height: 120)
        overlay.setWindows([menuRect, windowRect], ids: [2, 1], frozen: [true, false], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        require(overlay.view.overlays.hover == menuRect, "the frontmost window wins hit-testing where a menu overlaps a window")
        mouse(.mouseMoved, CGPoint(x: 600, y: 350))
        require(overlay.view.overlays.hover == windowRect, "outside the menu the window underneath is hovered")
        mouse(.mouseMoved, CGPoint(x: 350, y: 350))
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: 350, y: 350))
        mouse(.leftMouseUp, CGPoint(x: 350, y: 350))
        require(try await copiedSize() == menuRect.size, "clicking a menu copies its rectangle from the frozen image")
        // Snap: the band floor, display edges, accessibility fits, draggable edges, per-edge resize snapping, cursors.
        func openFixture(_ shown: CGImage) {
            overlay.present(image: shown, frame: CGRect(x: 0, y: 0, width: shown.width, height: shown.height), displayID: nil)
            overlay.detectionTask?.cancel()
        }
        func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
            abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
                && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
        }
        func snapped(_ drag: CGRect, _ message: String) async throws -> CGRect {
            pressDrag(drag)
            try await waitFor("\(message) shows a preview") { overlay.snapPreview != nil }
            let preview = overlay.snapPreview!
            release(drag)
            require(overlay.selection?.rect == preview, "\(message): release takes the preview")
            return preview
        }
        // A frozen target such as the Dock has no opaque window color to fit; its corner radius comes from its outline.
        openFixture(DebugRun.dockFixture)
        let dockPanel = CGRect(x: 100, y: 100, width: 200, height: 500)
        overlay.setWindows([dockPanel], ids: [3], frozen: [true], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
        mouse(.mouseMoved, CGPoint(x: 200, y: 350))
        try await waitFor("the frozen panel's radius is measured") { overlay.radii[dockPanel] != nil }
        require(abs(overlay.radii[dockPanel]! - 30) <= 4, "a frozen Dock-like panel with a gradient takes its outline's radius: \(overlay.radii[dockPanel]!)")
        overlay.dismiss()
        // The left vertical Dock, 4 pt from the screen edge: a gap between icons hovers the panel with its radius, and a click copies the
        // panel with transparent corners.
        openFixture(DebugRun.leftDockFixture)
        let leftDock = CGRect(x: 4, y: 40, width: 69, height: 720)
        overlay.setWindows([leftDock], names: ["Dock"], ids: [3], frozen: [true], pointer: CGPoint(x: frame.minX + 600, y: frame.maxY - 400))
        mouse(.mouseMoved, CGPoint(x: 38, y: 114))
        require(overlay.view.overlays.hover == leftDock, "a gap in the left Dock hovers its panel: \(String(describing: overlay.view.overlays.hover))")
        try await waitFor("the left Dock's radius is measured") { overlay.radii[leftDock] != nil }
        require(abs(overlay.radii[leftDock]! - 23) <= 4 && overlay.view.overlays.hoverRadii == CornerRadii(overlay.radii[leftDock]!),
                "the left Dock's outline takes its radius: \(overlay.radii[leftDock]!), drawn \(overlay.view.overlays.hoverRadii)")
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: 38, y: 114))
        mouse(.leftMouseUp, CGPoint(x: 38, y: 114))
        await overlay.commitTask?.value
        let dockShot = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(CGSize(width: dockShot.pixelsWide, height: dockShot.pixelsHigh) == leftDock.size && dockShot.colorAt(x: 0, y: 0)!.alphaComponent == 0
                && dockShot.colorAt(x: dockShot.pixelsWide - 1, y: dockShot.pixelsHigh - 1)!.alphaComponent == 0 && dockShot.colorAt(x: 34, y: 2)!.alphaComponent == 1,
                "a click on the left Dock copies its panel with rounded corners")
        overlay.dismiss()
        let pillFixture = DebugRun.pillFixture, cardsFixture = DebugRun.cardsFixture
        defaults.set(true, forKey: Pref.snap)
        let extent = CGRect(x: 0, y: 0, width: 1280, height: 800)
        openFixture(pillFixture)
        require(overlay.scale == 1, "the fixtures open at 1x")
        let pill = CGRect(x: 300, y: 200, width: 160, height: 22)
        let pillPreview = try await snapped(pill.insetBy(dx: -7, dy: -7), "a drag 7 px outside a 22 px pill")
        require(near(pillPreview, pill, 2), "the pill snaps from a sloppy drag: \(pillPreview)")
        overlay.dismiss()
        openFixture(pillFixture)
        let full = try await snapped(CGRect(x: 4, y: 3, width: 1272, height: 794), "a corner-to-corner drag")
        require(full == extent, "corner to corner snaps to the full display: \(full)")
        overlay.dismiss()
        openFixture(pillFixture)
        let strip = try await snapped(CGRect(x: 5, y: 34, width: 1270, height: 52), "an edge-to-edge drag")
        require(near(strip, CGRect(x: 0, y: 40, width: 1280, height: 40), 2), "edge to edge snaps to a full-width strip: \(strip)")
        overlay.dismiss()

        let card = CGRect(x: 580, y: 200, width: 260, height: 230)
        let axFrame = card.insetBy(dx: -6, dy: -6)
        openFixture(cardsFixture)
        overlay.snapFrameSource = { _ in [axFrame] }
        let axPreview = try await snapped(card.insetBy(dx: -9, dy: -9), "a drag around an accessibility frame")
        require(axPreview == axFrame, "the accessibility frame ranks ahead of the pixel fit: \(axPreview)")
        require(overlay.selection!.fits.count == 3 && near(overlay.selection!.fits[1], card, 3), "the pixel fit follows it: \(overlay.selection!.fits)")
        overlay.snapFrameSource = nil
        overlay.dismiss()

        // An exact drag whose bottom-right corner sits on a rounded panel's corner takes the panel's arc there; the others stay square.
        openFixture(panelCornerFixture)
        let onPanelCorner = CGRect(x: 600, y: 400, width: 400, height: 200)
        pressDrag(onPanelCorner, .option)
        release(onPanelCorner)
        try await waitFor("the settled selection's corners are measured") { overlay.arcs[onPanelCorner] != nil }
        let panelRadii = overlay.view.overlays.radii
        require(panelRadii.topLeft == 0 && panelRadii.topRight == 0 && panelRadii.bottomLeft == 0 && abs(panelRadii.bottomRight - 20) <= 3,
                "only the corner on the panel's corner takes its 20 px arc: \(panelRadii)")
        overlay.dismiss()

        openFixture(pillFixture)
        let area = CGRect(x: 300, y: 500, width: 400, height: 200)
        pressDrag(area, .option)
        release(area)
        mouse(.mouseMoved, CGPoint(x: area.maxX, y: area.minY + 60))
        require(overlay.view.cursor === OverlayController.resizeCursors[.right], "the pointer on a side shows its resize cursor")
        mouse(.mouseMoved, CGPoint(x: area.maxX, y: area.maxY))
        require(overlay.view.cursor === OverlayController.resizeCursors[.bottomRight], "the pointer on a corner handle shows its resize cursor")
        mouse(.mouseMoved, CGPoint(x: area.midX, y: area.midY + 20))
        require(overlay.view.cursor === NSCursor.openHand, "the pointer inside the selection shows an open hand")
        mouse(.mouseMoved, CGPoint(x: area.minX - 60, y: area.midY))
        require(overlay.view.cursor === NSCursor.crosshair, "the pointer outside the selection shows the crosshair")
        mouse(.leftMouseDown, CGPoint(x: area.maxX, y: area.minY + 60), .option)
        require(overlay.view.cursor === OverlayController.resizeCursors[.right], "dragging a side keeps its resize cursor")
        mouse(.leftMouseDragged, CGPoint(x: area.maxX + 40, y: area.minY + 60), .option)
        mouse(.leftMouseUp, CGPoint(x: area.maxX + 40, y: area.minY + 60), .option)
        require(overlay.selection?.rect == CGRect(x: 300, y: 500, width: 440, height: 200), "dragging along a side, away from its handles, resizes that side")
        mouse(.leftMouseDown, CGPoint(x: 450, y: area.minY), .option)
        mouse(.leftMouseDragged, CGPoint(x: 450, y: area.minY - 30), .option)
        mouse(.leftMouseUp, CGPoint(x: 450, y: area.minY - 30), .option)
        require(overlay.selection?.rect == CGRect(x: 300, y: 470, width: 440, height: 230), "dragging the top side resizes it")
        mouse(.leftMouseDown, CGPoint(x: 500, y: 600), .option)
        require(overlay.view.cursor === NSCursor.closedHand, "moving the selection shows a closed hand")
        mouse(.leftMouseDragged, CGPoint(x: 510, y: 600), .option)
        mouse(.leftMouseUp, CGPoint(x: 510, y: 600), .option)
        require(overlay.view.cursor === NSCursor.openHand, "releasing a move returns to the open hand")
        overlay.dismiss()
        require(overlay.view.cursor === NSCursor.crosshair, "closing the overlay resets the cursor")

        openFixture(cardsFixture)
        let row = CGRect(x: 270, y: 190, width: 880, height: 250)
        pressDrag(row, .option)
        release(row)
        require(overlay.selection?.rect == row, "an exact drag around three cards selects the whole row")
        mouse(.leftMouseDown, CGPoint(x: row.maxX, y: row.midY))
        mouse(.leftMouseDragged, CGPoint(x: 846, y: row.midY))
        require(abs(overlay.selection!.rect.maxX - 840) <= 3 && overlay.view.overlays.snappedEdges.count == 1,
                "dragging the right edge near card two snaps to its right edge: \(overlay.selection!.rect.maxX)")
        mouse(.leftMouseDragged, CGPoint(x: 546, y: row.midY))
        require(abs(overlay.selection!.rect.maxX - 540) <= 3, "then to card one's right edge: \(overlay.selection!.rect.maxX)")
        mouse(.leftMouseDragged, CGPoint(x: 846, y: row.midY), .option)
        require(overlay.selection!.rect.maxX == 846 && overlay.view.overlays.snappedEdges.isEmpty, "Option keeps the dragged edge exact")
        mouse(.leftMouseUp, CGPoint(x: 846, y: row.midY), .option)
        require(overlay.view.overlays.snappedEdges.isEmpty, "the snapped edge is not drawn after release")
        mouse(.leftMouseDown, CGPoint(x: 846, y: row.midY))
        mouse(.leftMouseDragged, CGPoint(x: 866, y: row.midY))
        require(overlay.selection!.rect.maxX == 866 && overlay.view.overlays.snappedEdges.isEmpty, "an edge 14 px away is outside the 6 pt snap band")
        mouse(.leftMouseDragged, CGPoint(x: 874, y: row.midY))
        require(abs(overlay.selection!.rect.maxX - 880) <= 3, "card three's left edge, 6 px away, is inside the snap band")
        mouse(.leftMouseUp, CGPoint(x: 874, y: row.midY))
        mouse(.leftMouseDown, CGPoint(x: 600, y: row.maxY))
        mouse(.leftMouseDragged, CGPoint(x: 600, y: 436))
        require(abs(overlay.selection!.rect.maxY - 430) <= 3, "the bottom side snaps to the cards' bottom edge: \(overlay.selection!.rect.maxY)")
        mouse(.leftMouseUp, CGPoint(x: 600, y: 436))
        overlay.snapFrameSource = { _ in [CGRect(x: 580, y: 200, width: 263, height: 230)] }
        mouse(.leftMouseDown, CGPoint(x: overlay.selection!.rect.maxX, y: 300))
        try await Task.sleep(for: .milliseconds(50))
        mouse(.leftMouseDragged, CGPoint(x: 846, y: 300))
        require(overlay.selection!.rect.maxX == 843, "an accessibility edge 3 px away beats the pixel edge 6 px away: \(overlay.selection!.rect.maxX)")
        mouse(.leftMouseUp, CGPoint(x: 846, y: 300))
        overlay.snapFrameSource = nil
        overlay.dismiss()

        // S acts at once: during a drag, and on a released drag.
        open()
        defaults.set(true, forKey: Pref.snap)
        pressDrag(rough)
        try await waitFor("a preview before S") { overlay.snapPreview != nil }
        let live = overlay.snapPreview!
        key(1, "s")
        require(!defaults.bool(forKey: Pref.snap) && overlay.snapPreview == nil && overlay.view.overlays.preview == nil, "S during a drag clears the preview at once")
        let snap = overlay.chrome.snap
        require(texts(in: overlay.chrome.size).last!.hasSuffix("Exact"), "with snap off the dragging size chip reads Exact: \(texts(in: overlay.chrome.size))")
        key(1, "s")
        try await waitFor("the analysis restarts when S turns snap on mid-drag") { overlay.snapPreview != nil }
        require(overlay.snapPreview == live, "S during a drag starts the analysis for the current drag")
        release(rough)
        require(overlay.selection?.rect == live, "release takes the preview")
        key(1, "s")
        require(overlay.selection?.rect == rough && texts(in: snap) == ["Exact", "S"] && !snap.lit, "S after release switches to the exact drag, and the Snap chip reads Exact, plain")
        key(1, "s")
        require(overlay.selection?.rect == live && texts(in: snap) == ["Snapped", "S"] && snap.lit, "S again switches back to the best fit, and the Snap chip reads Snapped, lit")
        snap.onClick()
        require(!defaults.bool(forKey: Pref.snap) && overlay.selection?.rect == rough, "the Snap button acts the same way")
        snap.onClick()
        require(overlay.selection?.rect == live, "the Snap button switches back to the best fit")
        overlay.dismiss()

        open()
        key(1, "s")
        pressDrag(rough)
        release(rough)
        require(overlay.selection?.rect == rough && overlay.selection!.fits.count == 1, "a quick drag with snap off releases the exact drag with no fits")
        key(1, "s")
        try await overlay.snapTask?.value
        require(overlay.selection?.rect == live, "S on computes the best fit on demand: \(String(describing: overlay.selection?.rect))")
        key(right)
        let nudged = overlay.selection!.rect
        key(1, "s")
        key(1, "s")
        require(overlay.selection?.rect == nudged, "S leaves a nudged selection alone")
        overlay.dismiss()
        defaults.set(true, forKey: Pref.snap)

        passed += try await verifyEditing(image: image, frame: frame, overlay: overlay, folder: folder)

        requireBackground(overlay)
        print("Area UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }

    // MARK: --measure

    /// The process's physical memory footprint, as Activity Monitor's Memory column shows it.
    static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        precondition(result == KERN_SUCCESS)
        return String(format: "%.1f MiB", Double(info.phys_footprint) / 1_048_576)
    }

    /// Each run presents a fresh, already decoded copy of the image in the display's color space, as ScreenCaptureKit returns a capture,
    /// and moves the pointer over it once the hover geometry has joined, with the loupe on. Prints the process's memory footprint before
    /// the first capture and after the last.
    static func measure(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        overlay.defaults.set(true, forKey: Pref.loupe)
        // A 2x horizontal Dock along the bottom (top-left origin): a rimmed panel with 14 icon tiles, and the magnified union of its lists.
        let dockPanel = CGRect(x: CGFloat(image.width) / 2 - 750, y: CGFloat(image.height) - 150, width: 1500, height: 136)
        let dockUnion = dockPanel.insetBy(dx: -74, dy: -6)
        func decodedCopy(dock: Bool = false) -> CGImage {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: NSScreen.main!.colorSpace!.cgColorSpace!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if dock {
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: 1, y: -1)
                context.addPath(CGPath(roundedRect: dockPanel.insetBy(dx: 1, dy: 1), cornerWidth: 30, cornerHeight: 30, transform: nil))
                context.setStrokeColor(gray: 0.55, alpha: 1)
                context.setLineWidth(2)
                context.setFillColor(gray: 0.22, alpha: 1)
                context.drawPath(using: .fillStroke)
                context.setFillColor(gray: 0.9, alpha: 1)
                for offset in stride(from: 30, to: 1450, by: 102) { context.fill(CGRect(x: dockPanel.minX + CGFloat(offset), y: dockPanel.minY + 20, width: 96, height: 96)) }
            }
            return context.makeImage()!
        }
        let launched = footprint()
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        var stages: [(name: String, values: [Double])] = ["open overlay", "first draw", "snap", "encode", "pasteboard", "encode + pasteboard", "snap, full drag", "hover analysis", "hover move, mean", "dock tiles"].map { ($0, []) }
        var moves: [Double] = []
        var snapCount = 0, dockTileCount = 0
        for _ in 0..<30 {
            let image = decodedCopy()
            overlay.present(image: image, frame: frame, displayID: nil)
            var run = [overlay.lastOpenMilliseconds, overlay.lastFirstDrawMilliseconds]
            var start = ContinuousClock.now
            snapCount = try await SmartSnap().suggest(in: image, roughBounds: rough).count
            run.append(start.duration(to: .now).milliseconds)
            start = ContinuousClock.now
            let output = try await Output.encode(image, crop: rough, padding: nil, scale: overlay.scale)
            run.append(start.duration(to: .now).milliseconds)
            start = ContinuousClock.now
            overlay.pasteboard.clearContents()
            overlay.pasteboard.setData(output.png, forType: .png)
            run.append(start.duration(to: .now).milliseconds)
            run.append(run[3] + run[4])
            start = ContinuousClock.now
            _ = try await SmartSnap().suggest(in: image, roughBounds: CGRect(x: 10, y: 10, width: image.width - 20, height: image.height - 20))
            run.append(start.duration(to: .now).milliseconds)
            await overlay.detectionTask?.value
            start = ContinuousClock.now
            overlay.detected = []
            overlay.startHover()
            await overlay.detectionTask?.value
            run.append(start.duration(to: .now).milliseconds)
            // 60 pointer moves on a diagonal across the image, 8 ms apart like a 120 Hz pointer, each timed from the event through
            // committing its layer changes. Back-to-back events would measure the render server's backpressure instead.
            var runMoves: [Double] = []
            for step in 0..<60 {
                try await Task.sleep(for: .milliseconds(8))
                let point = CGPoint(x: frame.width * (0.05 + 0.9 * CGFloat(step) / 59), y: frame.height * (0.95 - 0.9 * CGFloat(step) / 59))
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: overlay.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                start = ContinuousClock.now
                overlay.window.sendEvent(event)
                CATransaction.flush()
                runMoves.append(start.duration(to: .now).milliseconds)
            }
            run.append(runMoves.reduce(0, +) / Double(runMoves.count))
            let docked = decodedCopy(dock: true)
            start = ContinuousClock.now
            let panel = DockTiles.panel(in: docked, near: dockUnion, scale: 2)!
            dockTileCount = DockTiles.tiles(in: docked, panel: panel, scale: 2).count
            run.append(start.duration(to: .now).milliseconds)
            if !stages[0].values.isEmpty { moves += runMoves }
            for index in run.indices { stages[index].values.append(run[index]) }
            overlay.dismiss()
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            values.sorted()[Int((Double(values.count) * fraction).rounded(.up)) - 1]
        }
        print("stage                 cold ms   warm p50   warm p95   (30 runs: run 1 cold, runs 2-30 warm)")
        for stage in stages {
            let warm = Array(stage.values.dropFirst())
            print(stage.name.padding(toLength: 21, withPad: " ", startingAt: 0),
                  String(format: "%8.2f  %9.2f  %9.2f", stage.values[0], percentile(warm, 0.5), percentile(warm, 0.95)))
        }
        print("hover move, per event (runs 2-30, \(moves.count) events): p50 \(String(format: "%.2f", percentile(moves, 0.5))) ms, "
              + "p95 \(String(format: "%.2f", percentile(moves, 0.95))) ms, max \(String(format: "%.2f", moves.max()!)) ms")
        print("snap suggestions per run: \(snapCount), dock tiles: \(dockTileCount)")
        // 200 pointer moves across the hovered page with the chrome up, 8 ms apart: each move from the event through committing its layer
        // changes, and a `refresh` on its own right after it.
        overlay.present(image: decodedCopy(), frame: frame, displayID: nil)
        overlay.setWindows([CGRect(x: 200, y: 200, width: image.width - 400, height: image.height - 400)], names: ["Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        await overlay.detectionTask?.value
        var pointerMoves: [Double] = [], refreshes: [Double] = []
        for step in 0..<200 {
            try await Task.sleep(for: .milliseconds(8))
            let point = CGPoint(x: frame.width * (0.05 + 0.9 * CGFloat(step) / 199), y: frame.height * (0.95 - 0.9 * CGFloat(step) / 199))
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: overlay.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            var start = ContinuousClock.now
            overlay.window.sendEvent(event)
            CATransaction.flush()
            pointerMoves.append(start.duration(to: .now).milliseconds)
            start = ContinuousClock.now
            overlay.refresh()
            CATransaction.flush()
            refreshes.append(start.duration(to: .now).milliseconds)
        }
        overlay.dismiss()
        for (name, values) in [("pointer move", pointerMoves), ("refresh", refreshes)] {
            print("\(name), 200 hover moves: p50 \(String(format: "%.3f", percentile(values, 0.5))) ms, p95 \(String(format: "%.3f", percentile(values, 0.95))) ms, "
                  + "mean \(String(format: "%.3f", values.reduce(0, +) / Double(values.count))) ms")
        }
        print("footprint: before the first capture \(launched), after the last dismiss \(footprint())")
        try await Task.sleep(for: .seconds(1))
        print("footprint: 1 s after the last dismiss \(footprint())")
        if CGPreflightScreenCaptureAccess() {
            let id = CGMainDisplayID()
            let start = ContinuousClock.now
            let captured = try await DisplayCapture.image(of: id)
            let mode = CGDisplayCopyDisplayMode(id)!
            print("capture               \(String(format: "%.2f", start.duration(to: .now).milliseconds)) ms; image.width=\(captured.width) display pixelWidth=\(mode.pixelWidth) match=\(captured.width == mode.pixelWidth)")
        } else {
            print("capture               skipped: this process has no Screen Recording permission")
        }
        requireBackground(overlay)
        exit(EXIT_SUCCESS)
    }
}
