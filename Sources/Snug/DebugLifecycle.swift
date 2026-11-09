#if DEBUG
import AppKit
import ScreenshotCore
import Translation

extension DebugRun {
    /// `--verify-lifecycle-ui`: interrupted gestures and delayed results, with no live captures or permission prompts.
    static func verifyLifecycle(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        var passed: [String] = []
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Lifecycle verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
            FileHandle.standardError.write(Data("  ok: \(message)\n".utf8))
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            require(condition(), message)
        }
        func open() {
            overlay.present(image: image, frame: frame, displayID: nil)
            overlay.detectionTask?.cancel()
            overlay.defaults.set(false, forKey: Pref.snap)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) {
            let event = NSEvent.mouseEvent(with: type,
                location: CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: overlay.mouseDown(event)
            case .leftMouseDragged: overlay.mouseDragged(event)
            default: overlay.mouseUp(event)
            }
        }
        let rect = CGRect(x: 350, y: 458, width: 580, height: 64)
        let point = CGPoint(x: rect.midX, y: rect.midY)

        // Mode keys can arrive while the mouse is still down, including between a handle press and its first drag event.
        for gesture in ["draw", "move", "resize", "round"] {
            open()
            if gesture != "draw" { overlay.selection = AreaSelection(extent: overlay.extent, exact: rect) }
            let start: CGPoint = switch gesture {
            case "draw": rect.origin
            case "resize": CGPoint(x: rect.maxX, y: rect.midY)
            case "round": overlay.cornerRadii(of: rect).dot(of: .topLeft, in: rect, minimumInset: 8 * overlay.scale)
            default: point
            }
            mouse(.leftMouseDown, start)
            if gesture == "draw" { mouse(.leftMouseDragged, point) }
            overlay.setMode(.text)
            require(overlay.draggedRect == nil, "\(gesture): changing mode ends the gesture")
            overlay.setMode(.capture)
            mouse(.leftMouseDragged, CGPoint(x: point.x + 10, y: point.y + 10))
            mouse(.leftMouseUp, point)
            require(overlay.selection == nil && overlay.undoStack.isEmpty, "\(gesture): trailing events cannot edit or copy a cleared selection")
            overlay.dismiss()
        }

        open()
        overlay.window.textPress = (.zero, nil)
        overlay.window.screenTextPress = true
        overlay.window.textDragging = true
        overlay.window.buttonPress = true
        overlay.dismiss()
        require(overlay.window.textPress == nil && !overlay.window.screenTextPress && !overlay.window.textDragging && !overlay.window.buttonPress,
                "dismiss clears every text mouse route before another capture")

        // Suspend the AX side of a snap until after the user has turned Snap off.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: rect)
        var frames: CheckedContinuation<[CGRect], Never>?
        overlay.snapFrameSource = { _ in await withCheckedContinuation { frames = $0 } }
        overlay.toggleSnap()
        let snap = overlay.snapTask
        try await waitFor("snap lookup is suspended") { frames != nil }
        overlay.toggleSnap()
        frames!.resume(returning: [rect.insetBy(dx: 2, dy: 2)])
        _ = try? await snap?.value
        require(!overlay.snapEnabled && overlay.selection?.rect == rect && overlay.selection?.fits == [rect],
                "turning Snap off prevents an in-flight fit from replacing the exact selection")
        overlay.snapFrameSource = nil
        overlay.dismiss()

        // Canceling a task that awaits an unstructured warm-up does not cancel that warm-up's value.
        open()
        var warmed: CheckedContinuation<Void, Never>?
        let warmUp = Task<Void, Never> { await withCheckedContinuation { warmed = $0 } }
        OverlayController.visionWarmUp = warmUp
        try await waitFor("warm-up is suspended") { warmed != nil }
        overlay.selection = AreaSelection(extent: overlay.extent, exact: rect)
        overlay.copySelectionText(translating: false)
        let canceled = overlay.textTask
        require(overlay.text.queued != nil, "text copy queues during warm-up")
        overlay.cancelWork()
        var ran = false
        overlay.text.queued = ("New session action", { ran = true })
        warmed!.resume()
        await canceled?.value
        require(!ran && overlay.text.queued != nil, "a canceled warm-up waiter cannot consume another session's action")
        OverlayController.visionWarmUp = nil
        overlay.dismiss()

        open()
        var status: CheckedContinuation<LanguageAvailability.Status, Never>?
        overlay.translationStatus = { _, _ in await withCheckedContinuation { status = $0 } }
        overlay.copyText("Hola, este texto está escrito en español.", message: "Copied", translating: true)
        let translation = overlay.textTask
        try await waitFor("translation awaits language availability") { status != nil }
        overlay.cancelWork()
        overlay.text.notice = "Current session notice"
        status!.resume(returning: .unsupported)
        await translation?.value
        require(overlay.text.notice == "Current session notice", "a canceled translation cannot publish a late availability notice")
        overlay.translationStatus = { await LanguageAvailability().status(from: $0, to: $1) }
        overlay.dismiss()

        // A capture provider may return a frame even after its caller was canceled.
        open()
        overlay.setWindows([overlay.extent], pointer: frame.origin)
        overlay.selection = AreaSelection(extent: overlay.extent, exact: rect)
        var first: CheckedContinuation<CGImage, Never>?
        var next: CheckedContinuation<CGImage, Never>?
        var captures = 0
        overlay.scrollFrames = { _ in
            captures += 1
            return await withCheckedContinuation { if captures == 1 { first = $0 } else { next = $0 } }
        }
        overlay.startScroll()
        let scroll = overlay.scrollTask
        try await waitFor("scrolling awaits its first frame") { first != nil }
        let crop = image.cropping(to: rect)!
        first!.resume(returning: crop)
        try await waitFor("scrolling awaits another frame") { next != nil }
        let stitcher = overlay.stitcher!
        let height = await stitcher.height
        overlay.dismiss()
        next!.resume(returning: crop)
        await scroll?.value
        require(await stitcher.height == height && overlay.stitcher == nil && overlay.scrollArea == nil,
                "a frame returned after dismissal cannot update scrolling state")
        overlay.scrollFrames = nil

        requireBackground(overlay)
        print("Lifecycle UI verification passed (\(passed.count) checks)")
        exit(EXIT_SUCCESS)
    }
}
#endif
