import AppKit

extension DebugRun {
    /// `--memory-steps DIR [--no-vision]`: walks the overlay through a capture, a copy with its toast, Text mode, accurate OCR rows, a
    /// cutout and ten open/close cycles. After each step settles it prints the footprint and runs `bash DIR/inspect.sh PID LABEL`, which
    /// takes `footprint` and `heap` of this process (run it with `MallocStackLogging=1` for `malloc_history`). `--no-vision` skips
    /// Live Text, OCR and the cutout, and leaves Text mode out of the cycles.
    static func memorySteps(into folder: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay, timeout: .seconds(1800))
        let vision = !CommandLine.arguments.contains("--no-vision")
        let pid = ProcessInfo.processInfo.processIdentifier
        var index = 0

        func record(_ label: String, settle: Duration = .seconds(2)) async throws {
            try await Task.sleep(for: settle)
            index += 1
            let name = String(format: "%02d-%@", index, label)
            print("\(name): footprint \(footprint())")
            let inspect = Process()
            inspect.executableURL = URL(fileURLWithPath: "/bin/bash")
            inspect.arguments = [folder.appending(path: "inspect.sh").path, "\(pid)", name]
            try inspect.run()
            inspect.waitUntilExit()
            precondition(inspect.terminationStatus == 0, "inspect.sh failed for \(name)")
        }
        func windowPoint(_ pixel: CGPoint) -> CGPoint {
            CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: windowPoint(pixel), modifierFlags: [],
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
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<12000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            precondition(condition(), "memory steps: timed out waiting for \(message)")
        }
        /// Opens Capture, lets the hover geometry join, and moves the pointer across the image.
        func openAndHover() async {
            overlay.present(image: image, frame: frame, displayID: nil)
            await overlay.detectionTask?.value
            for step in 0..<20 {
                mouse(.mouseMoved, CGPoint(x: CGFloat(image.width) * (0.1 + 0.04 * CGFloat(step)), y: CGFloat(image.height) * (0.8 - 0.03 * CGFloat(step))))
            }
        }
        func dragRelease(_ rect: CGRect) {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY))
            mouse(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY))
            mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY))
        }
        func enterText() async throws {
            key(17, "t")
            try await waitFor("the Live Text analysis") { overlay.view.liveText.analysis != nil }
        }
        let returnKey: UInt16 = 36, escape: UInt16 = 53
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)

        try await record("launch-idle")
        await openAndHover()
        try await record("capture-hover")
        dragRelease(rough)
        try await waitFor("a released selection") { overlay.selection != nil }
        try await record("selection-released")
        key(returnKey, "\r")
        await overlay.commitTask?.value
        // The toast Output.publish would show, kept invisible and click-through as the headless overlay is.
        var toast: Toast? = Toast(png: overlay.pasteboard.data(forType: .png)!, message: "Copied", detail: "", file: nil, color: nil, defaults: overlay.defaults)
        toast!.alphaValue = 0
        toast!.ignoresMouseEvents = true
        toast!.orderFrontRegardless()
        try await record("copied-toast-shown")
        toast!.dismiss()
        toast = nil
        try await record("toast-closed")
        if vision {
            await openAndHover()
            var start = ContinuousClock.now
            try await enterText()
            print("Live Text analysis: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms")
            try await record("text-mode-live-text")
            key(3, "f")
            start = ContinuousClock.now
            key(returnKey, "\r", .shift)
            try await waitFor("Shift-Return rows") { !overlay.window.isVisible }
            print("Shift-Return accurate OCR: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms")
            try await record("text-rows-accurate-ocr")
            await openAndHover()
            dragRelease(CGRect(x: 300, y: 250, width: 1000, height: 700))
            start = ContinuousClock.now
            key(40, "k")
            await overlay.textTask?.value
            print("cutout: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms, notice \(overlay.text.notice.debugDescription)")
            try await record("cutout")
        }
        overlay.dismiss()
        try await record("overlay-closed", settle: .seconds(5))
        for cycle in 1...10 {
            await openAndHover()
            dragRelease(rough)
            if vision { try await enterText() }
            key(escape)
            precondition(!overlay.window.isVisible, "Esc closes the overlay")
            if [1, 5, 10].contains(cycle) {
                try await record("cycle-\(cycle)", settle: .seconds(5))
            } else {
                try await Task.sleep(for: .seconds(1))
                print("cycle \(cycle): footprint \(footprint())")
            }
        }
        exit(EXIT_SUCCESS)
    }
}
