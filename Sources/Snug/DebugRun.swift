import AppKit
import ImageIO
import ScreenCaptureKit
import ScreenshotCore

/// Headless checks driven by `--image PATH`: `--verify-area-ui` and `--measure`.
@MainActor
enum DebugRun {
    private static func privateSetup(_ overlay: OverlayController) -> URL {
        let defaults = UserDefaults(suiteName: "local.snug.verify")!
        defaults.removePersistentDomain(forName: "local.snug.verify")
        Pref.register(in: defaults)
        let folder = FileManager.default.temporaryDirectory.appending(path: "snug-verify-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(folder.path, forKey: Pref.saveFolder)
        overlay.defaults = defaults
        overlay.pasteboard = NSPasteboard(name: .init("local.snug.verify"))
        return folder
    }

    private static func pngSize(_ data: Data?) -> CGSize? {
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
            for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
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
        func open() { overlay.present(image: image, frame: frame, displayID: nil) }
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
        overlay.dismiss()

        // Pause-to-snap, release takes the preview.
        open()
        pressDrag(rough)
        require(overlay.snapPreview == nil, "no preview before the debounce")
        try await waitFor("drag + pause shows a snap preview") { overlay.snapPreview != nil }
        let preview = overlay.snapPreview!
        require(preview != rough && Detection.overlap(preview, rough) > 0.5, "preview \(preview) refines the drag and stays related to it")
        release(rough)
        require(overlay.selection?.rect == preview, "release takes the preview")

        // Tab cycles to the exact drag and back.
        var reachedExact = false
        for _ in 0..<overlay.selection!.fits.count where !reachedExact {
            key(tab)
            reachedExact = overlay.selection?.rect == rough
        }
        require(reachedExact, "Tab reaches the exact drag")
        key(tab)
        require(overlay.selection?.rect == preview, "Tab wraps back to the snap preview")
        key(tab, "", .shift)
        require(overlay.selection?.rect == rough, "Shift-Tab returns to the exact drag")
        key(tab)

        // Arrow nudges.
        let before = overlay.selection!.rect
        key(right)
        require(overlay.selection?.rect == before.offsetBy(dx: scale, dy: 0), "Right nudges 1 pt")
        key(down, "", .shift)
        require(overlay.selection?.rect == before.offsetBy(dx: scale, dy: 10 * scale), "Shift-Down nudges 10 pt")
        key(left)
        key(up, "", .shift)
        require(overlay.selection?.rect == before, "Left and Shift-Up undo the nudges")

        // Handle resize and move through the view.
        let selection = overlay.selection!.rect
        mouse(.leftMouseDown, CGPoint(x: selection.maxX, y: selection.midY))
        mouse(.leftMouseDragged, CGPoint(x: selection.maxX + 40, y: selection.midY))
        mouse(.leftMouseUp, CGPoint(x: selection.maxX + 40, y: selection.midY))
        require(overlay.selection?.rect == CGRect(x: selection.minX, y: selection.minY, width: selection.width + 40, height: selection.height),
                "dragging the right handle resizes")
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

        // Margin and backdrop sizes.
        for (command, extra, name) in [("2", 32 * scale, "margin"), ("3", 48 * scale, "backdrop")] {
            open()
            pressDrag(rough)
            try await waitFor("preview for \(name)") { overlay.snapPreview != nil }
            release(rough)
            let crop = overlay.selection!.rect
            key(0, command, .command)
            require(overlay.style.rawValue == name && defaults.string(forKey: Pref.style) == name, "Cmd-\(command) sets \(name) and remembers it")
            pasteboard.clearContents()
            key(returnKey, "\r")
            let size = try await copiedSize()
            require(size == CGSize(width: crop.width + extra, height: crop.height + extra),
                    "\(name) PNG is \(extra / scale) pt larger per dimension (\(String(describing: size)))")
        }
        open()
        key(0, "m")
        require(overlay.style == .tight, "M cycles backdrop to tight")
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
        key(escape)
        try await Task.sleep(for: .milliseconds(300))
        require(!overlay.window.isVisible && pasteboard.data(forType: .png) == nil, "Esc closes without writing")
        let afterEsc = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        require(afterEsc.count == 1, "Esc saves nothing")

        // S toggles snap; Option-drag is exact.
        open()
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap) == false, "S turns snap off")
        pressDrag(rough)
        try await Task.sleep(for: .milliseconds(300))
        require(overlay.snapPreview == nil, "no preview with snap off")
        release(rough)
        require(overlay.selection?.rect == rough, "with snap off the release takes the exact drag")
        key(1, "s")
        require(defaults.bool(forKey: Pref.snap), "S turns snap back on")
        mouse(.leftMouseDown, CGPoint(x: 20, y: 20))
        mouse(.leftMouseUp, CGPoint(x: 20, y: 20))
        pressDrag(rough, .option)
        try await Task.sleep(for: .milliseconds(300))
        require(overlay.snapPreview == nil, "Option-drag shows no preview")
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

        // Quick drag + Tab never swaps the crop for something unrelated.
        open()
        pressDrag(rough)
        release(rough)
        require(overlay.selection?.rect == rough && overlay.snapPreview == nil, "a quick drag releases the exact rectangle")
        key(tab)
        try await overlay.snapTask?.value
        require(Detection.overlap(overlay.selection!.rect, rough) > 0.5, "Tab after a quick drag keeps a crop related to the drag: \(overlay.selection!.rect)")
        key(tab)
        key(tab)
        require(overlay.selection!.fits.contains(rough), "the exact drag stays in the cycle")
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
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)
        pasteboard.clearContents()
        mouse(.leftMouseDown, CGPoint(x: 350, y: 350))
        mouse(.leftMouseUp, CGPoint(x: 350, y: 350))
        let windowSize = try await copiedSize()
        require(windowSize == windowRect.size, "click with no selection copies the window under the pointer")

        print("Area UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }

    // MARK: --measure

    static func measure(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        var stages: [(name: String, values: [Double])] = ["open overlay", "first draw", "snap", "encode", "pasteboard", "encode + pasteboard"].map { ($0, []) }
        var snapCount = 0
        for _ in 0..<30 {
            overlay.present(image: image, frame: frame, displayID: nil)
            var run = [overlay.lastOpenMilliseconds, overlay.lastFirstDrawMilliseconds]
            var start = ContinuousClock.now
            snapCount = try await SmartSnap().suggest(in: image, roughBounds: rough).count
            run.append(start.duration(to: .now).milliseconds)
            start = ContinuousClock.now
            let output = try await Output.encode(image, crop: rough, style: .tight, scale: overlay.scale)
            run.append(start.duration(to: .now).milliseconds)
            start = ContinuousClock.now
            overlay.pasteboard.clearContents()
            overlay.pasteboard.setData(output.png, forType: .png)
            run.append(start.duration(to: .now).milliseconds)
            run.append(run[3] + run[4])
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
        print("snap suggestions per run: \(snapCount)")
        if CGPreflightScreenCaptureAccess() {
            let id = CGMainDisplayID()
            let start = ContinuousClock.now
            let captured = try await DisplayCapture.image(of: id)
            let mode = CGDisplayCopyDisplayMode(id)!
            print("capture               \(String(format: "%.2f", start.duration(to: .now).milliseconds)) ms; image.width=\(captured.width) display pixelWidth=\(mode.pixelWidth) match=\(captured.width == mode.pixelWidth)")
        } else {
            print("capture               skipped: this process has no Screen Recording permission")
        }
        exit(EXIT_SUCCESS)
    }
}
