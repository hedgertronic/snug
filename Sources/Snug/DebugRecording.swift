import AppKit
import AVFoundation
import ScreenCaptureKit
import ScreenshotCore

extension DebugRun {
    /// Part of `--verify-extras-ui`: V and the Record button arm recording of the selection or hovered element; the armed keys start,
    /// switch the cursor and cancel; the count-in delays the request and the overlay is closed when it fires; `stop`'s wait for the
    /// file times out; and a finished movie in the save folder is delivered (URL copied, first frame read). A live 1 s recording runs
    /// only when this process has Screen Recording; without it, ScreenCaptureKit is never touched, since asking could put the
    /// permission prompt on screen.
    static func verifyRecording(image: CGImage, frame: CGRect, overlay: OverlayController, require: (Bool, String) -> Void) async throws {
        func key(_ code: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        let display = CGMainDisplayID()
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let defaults = overlay.defaults
        // Each request: its area, whether the cursor shows, whether the overlay was still visible, and when it came.
        var requests: [CGRect] = []
        var cursors: [Bool] = []
        var overlayShown: [Bool] = []
        var times: [ContinuousClock.Instant] = []
        var displays: Set<CGDirectDisplayID> = []
        ScreenRecording.requested = { id, area, cursor in
            displays.insert(id)
            requests.append(area)
            cursors.append(cursor)
            overlayShown.append(overlay.window.isVisible)
            times.append(.now)
        }
        func open(displayID: CGDirectDisplayID? = display) {
            overlay.present(image: image, frame: frame, displayID: displayID)
            overlay.detectionTask?.cancel()
        }
        func select(_ rect: CGRect) {
            overlay.selection = AreaSelection(extent: extent, exact: rect)
            overlay.refresh()
        }
        let scale = overlay.scale
        let hints = { texts(in: overlay.chrome.hints) }
        let strip = { texts(in: overlay.chrome.strip) }

        require(defaults.integer(forKey: Pref.recordCountIn) == 3 && defaults.bool(forKey: Pref.recordCursor),
                "recording defaults: a 3 s count-in and the cursor shown")
        defaults.set(0, forKey: Pref.recordCountIn)

        // V arms: the selection stays with a red outline and the armed strip; Return records its whole even pixels in display points.
        open()
        select(CGRect(x: 401, y: 201, width: 999, height: 601))
        key(9, "v")
        let armed = overlay.armedRecording
        require(overlay.window.isVisible && requests.isEmpty && armed != nil && overlay.selection != nil,
                "V on a released selection arms recording and keeps the overlay and selection: \(requests)")
        require(armed!.outline.superlayer != nil && armed!.outline.path != nil && armed!.outline.strokeColor == NSColor.systemRed.cgColor
                && !overlay.view.overlays.showsHandles && overlay.chrome.topBar.isHidden,
                "armed: a red outline on the selection, no handles or top bar")
        require(strip() == ["Cursor", "H", "Count-in", "I", "Cancel", "esc", "Start", "\u{21A9}"] && overlay.chrome.cursor.lit && !overlay.chrome.countIn.lit
                    && overlay.chrome.start.primary && hints() == ["start", "\u{21A9}", "cancel", "esc"],
                "the armed strip: Cursor lit, Count-in plain, Start primary; the keys line: \(strip()) \(hints())")
        // Armed near the right edge, the size chip stays over the selection's left edge.
        select(CGRect(x: extent.width - 600, y: 400, width: 560, height: 500))
        let badgeOffset = overlay.chrome.size.frame.minX - overlay.view.viewRect(overlay.selection!.rect).minX
        require(abs(badgeOffset) <= 1, "armed, the size badge sits over the selection's left edge: \(badgeOffset)")
        select(CGRect(x: 401, y: 201, width: 999, height: 601))
        // Armed, pointer moves change nothing: no open hand over the selection, no corner chip.
        let cursor = overlay.view.cursor
        func move(_ pixel: CGPoint) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: pixel.x / scale, y: overlay.view.bounds.height - pixel.y / scale),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        move(CGPoint(x: 900, y: 500))
        move(CGPoint(x: 1400, y: 500))
        require(overlay.view.cursor === cursor && overlay.hoveredCorner == nil, "pointer moves while armed leave the cursor alone: \(String(describing: overlay.view.cursor))")
        key(36, "\r")
        let expected = CGRect(x: 401 / scale, y: 201 / scale, width: 998 / scale, height: 600 / scale)
        require(!overlay.window.isVisible && requests == [expected] && cursors == [true] && overlayShown == [false] && armed!.outline.superlayer == nil,
                "Return with no count-in closes the overlay, then records the even-pixel area with the cursor: \(requests) \(overlayShown)")

        // The Record button arms; V starts.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        overlay.chrome.record.onClick()
        require(overlay.window.isVisible && requests.count == 1 && overlay.armedRecording != nil, "clicking Record arms recording")
        key(9, "v")
        require(!overlay.window.isVisible && requests.last == CGRect(x: 600 / scale, y: 300 / scale, width: 400 / scale, height: 200 / scale),
                "V while armed records the selection")

        // Esc disarms back to the released selection; H switches the cursor for one recording.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        key(53, "\u{1B}")
        require(overlay.window.isVisible && overlay.armedRecording == nil && overlay.selection != nil && strip().contains("Copy")
                && requests.count == 2, "Esc while armed disarms and keeps the selection")
        key(9, "v")
        key(4, "h")
        require(strip().contains("Cursor") && !overlay.chrome.cursor.lit && !defaults.bool(forKey: Pref.recordCursor), "H turns Cursor plain and saves it: \(strip())")
        // I cycles the count-in Off, 3 s, 5 s and saves it.
        var counts: [Int] = []
        for _ in 0..<3 {
            key(34, "i")
            counts.append(defaults.integer(forKey: Pref.recordCountIn))
            require(strip().contains(counts.last! > 0 ? "\(counts.last!)-second count" : "Count-in") && overlay.chrome.countIn.lit == (counts.last! > 0),
                    "the strip shows the count-in set, lit when on: \(strip())")
        }
        require(counts == [3, 5, 0], "I cycles the count-in 3 s, 5 s, off: \(counts)")
        key(36, "\r")
        require(cursors.last == false, "H hides the cursor in the recording: \(cursors)")
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(!overlay.chrome.cursor.lit, "the cursor choice sticks for the next recording: \(strip())")
        key(4, "h")
        key(53, "\u{1B}")
        overlay.dismiss()
        require(defaults.bool(forKey: Pref.recordCursor), "H again shows the cursor")

        // A hovered window becomes the armed selection; V again starts.
        open()
        let window = CGRect(x: 500, y: 400, width: 1200, height: 800)
        overlay.setWindows([window], names: ["Window"], pointer: CGPoint(x: frame.minX + 1100 / scale, y: frame.maxY - 800 / scale))
        let hovered = overlay.hoverRect
        require(hovered != nil, "a window is hovered")
        key(9, "v")
        require(overlay.window.isVisible && overlay.armedRecording != nil && overlay.selection?.rect == hovered, "V on a hovered element arms it as the selection")
        // One outline: the stroked shapes around the armed area are the red one alone.
        let box = overlay.view.viewRect(hovered!)
        let outlines = overlay.view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }.filter {
            $0.strokeColor != nil && $0.path.map { $0.boundingBox.insetBy(dx: -4, dy: -4).contains(box.insetBy(dx: 4, dy: 4)) && box.insetBy(dx: -4, dy: -4).contains($0.boundingBox) } == true
        }
        require(outlines.count == 1 && outlines[0] === overlay.armedRecording!.outline, "armed from hover, one outline: \(outlines.map { $0.strokeColor! })")
        key(9, "v")
        require(!overlay.window.isVisible && requests.last == CGRect(x: hovered!.minX / scale, y: hovered!.minY / scale, width: hovered!.width / scale, height: hovered!.height / scale),
                "V twice on a hovered element records it: \(String(describing: requests.last)) \(hovered!)")

        // A hovered display (the pointer outside every window) arms the whole display.
        open()
        overlay.setWindows([window], names: ["Window"], pointer: CGPoint(x: frame.minX + 50 / scale, y: frame.maxY - 50 / scale))
        require(overlay.session?.selected?.kind == .display && overlay.hoverRect == nil, "the pointer outside every window hovers the display")
        key(9, "v")
        require(overlay.window.isVisible && overlay.armedRecording != nil && overlay.selection?.rect == overlay.extent, "V on a hovered display arms the full display: \(String(describing: overlay.selection?.rect))")
        overlay.dismiss()

        let count = requests.count
        open()
        key(17, "t")
        key(9, "v")
        require(overlay.window.isVisible && overlay.armedRecording == nil && requests.count == count, "V does nothing in Text mode")
        overlay.dismiss()
        open(displayID: nil)
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(overlay.window.isVisible && overlay.armedRecording == nil, "V does nothing on an opened image, which has no display to record")
        overlay.dismiss()

        // Armed, C copies the selection's color as everywhere: it closes the overlay, records nothing, and leaves the count-in alone.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        overlay.pasteboard.clearContents()
        let countIn = defaults.integer(forKey: Pref.recordCountIn)
        key(8, "c")
        let average = ColorFormat(rawValue: defaults.string(forKey: Pref.colorFormat)!)!.string(for: ColorFormat.average(of: image, in: CGRect(x: 600, y: 300, width: 400, height: 200)))
        require(!overlay.window.isVisible && overlay.armedRecording == nil && requests.count == count && defaults.integer(forKey: Pref.recordCountIn) == countIn
                && overlay.pasteboard.string(forType: .string) == average, "C while armed copies the selection's color \(average) and records nothing: \(overlay.pasteboard.string(forType: .string) ?? "nothing")")

        // A 3 s count-in shows 3, 2, 1 over the selection; the request comes 3 s after Return, with the overlay already closed.
        defaults.set(3, forKey: Pref.recordCountIn)
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(strip().contains("3-second count") && overlay.chrome.countIn.lit, "the armed strip shows the count-in: \(strip())")
        let pressed = ContinuousClock.now
        key(36, "\r")
        var shown: [String] = []
        while requests.count == count, pressed.duration(to: .now) < .seconds(5) {
            if let digit = texts(in: overlay.armedRecording?.count ?? NSView()).first, shown.last != digit { shown.append(digit) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let delay = requests.count > count ? pressed.duration(to: times.last!).milliseconds : .infinity
        require(shown == ["3", "2", "1"] && (2900...3600).contains(delay) && overlayShown.last == false,
                "the count-in shows 3, 2, 1 and records 3 s after Return with the overlay closed: \(shown) \(delay) ms \(overlayShown)")

        // Esc during the count-in stops it and stays armed; nothing is recorded.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        key(36, "\r")
        require(hints().contains("Recording in 3"), "the count-in strip: \(hints())")
        try await Task.sleep(for: .milliseconds(1500))
        key(53, "\u{1B}")
        try await Task.sleep(for: .milliseconds(2600))
        require(overlay.window.isVisible && overlay.armedRecording?.remaining == nil && overlay.armedRecording?.count.isHidden == true
                && requests.count == count + 1, "Esc during the count-in stops it, still armed, and nothing is recorded")
        overlay.dismiss()
        require(displays == [display], "every recording is requested on the overlay's display")
        ScreenRecording.requested = { _, _, _ in }

        // While recording: a red outline just outside the area, and the stop reminder below it reading the capture shortcut; both are
        // windows Snug's captures leave out, which Settings is not.
        let recordArea = CGRect(x: 300, y: 300, width: 400, height: 200)
        let outline = ScreenRecording.makeOutline(around: recordArea, on: display)
        let reminder = ScreenRecording.makeReminder(around: recordArea, on: display, defaults: defaults)!
        let settings = SettingsTabs.makeWindow()
        require(outline.contentView!.layer!.borderColor == NSColor.systemRed.cgColor, "the recording outline is red, like the armed outline")
        require(texts(in: reminder.contentView!) == ["\u{2303}\u{21E7}Space", "to stop"], "the reminder reads the shortcut, then to stop: \(texts(in: reminder.contentView!))")
        require(reminder.frame.maxY == outline.frame.minY - ScreenRecording.reminderGap && abs(reminder.frame.midX - outline.frame.midX) <= 0.5,
                "the reminder is centered under the outline, \(ScreenRecording.reminderGap) pt away: \(reminder.frame) \(outline.frame)")
        let excluded = DisplayCapture.excludedWindowIDs()
        let panelIDs = [outline, reminder].map { CGWindowID($0.windowNumber) }
        require(panelIDs.allSatisfy { $0 > 0 && excluded.contains($0) } && !excluded.contains(CGWindowID(settings.windowNumber)),
                "the outline and reminder \(panelIDs) are left out of recordings and Settings \(settings.windowNumber) is not: \(excluded.sorted())")
        defaults.set(-1, forKey: Pref.hotKeyCode)
        let unset = ScreenRecording.makeReminder(around: recordArea, on: display, defaults: defaults)!
        require(texts(in: unset.contentView!) == ["Stop from the menu bar"], "with no shortcut the reminder points to the menu bar: \(texts(in: unset.contentView!))")
        defaults.set(49, forKey: Pref.hotKeyCode)
        // Placement in a 1512 x 945 pt visible frame under a 37 pt menu bar, for a 120 x 36 pt reminder.
        let visible = CGRect(x: 0, y: 37, width: 1512, height: 945)
        let size = CGSize(width: 120, height: 36)
        let near = CGRect(x: 600, y: 700, width: 300, height: 260)
        let placements = [recordArea, near, CGRect(x: 1450, y: 300, width: 60, height: 100), CGRect(x: 0, y: 37, width: 1512, height: 945),
                          CGRect(x: 0, y: 60, width: 1512, height: 880)].map { ScreenRecording.reminderFrame(size: size, around: $0, within: visible) }
        require(placements[0] == CGRect(x: 440, y: 511, width: 120, height: 36) && placements[1] == CGRect(x: 690, y: 653, width: 120, height: 36)
                && placements[2] == CGRect(x: 1392, y: 411, width: 120, height: 36) && placements[3] == nil && placements[4] == nil,
                "the reminder goes below, above when the area reaches the bottom, inside the screen sideways, and nowhere when neither fits: \(placements)")
        require(placements.compactMap(\.self).allSatisfy { visible.contains($0) }
                && zip([recordArea, near], placements).allSatisfy { !$0.0.insetBy(dx: -3, dy: -3).intersects($0.1!) }, "the reminder never covers the outlined area")

        // Stopping waits at most 5 s for the recording output to finish the file, then fails with an error naming it.
        let (never, unfinished) = AsyncStream<(any Error)?>.makeStream()
        let waitStart = ContinuousClock.now
        var waitError: (any Error)?
        Task {
            do { try await ScreenRecording.waitForEnd(never, file: URL(fileURLWithPath: "/stuck.mov")) } catch { waitError = error }
        }
        try await Task.sleep(for: .seconds(5.5))
        require(waitError.map { "\($0)".contains("stuck.mov") } == true && waitStart.duration(to: .now) < .seconds(6),
                "stop's wait for an unfinished recording fails after 5 s: \(String(describing: waitError))")
        unfinished.finish()
        let (prompt, finishing) = AsyncStream<(any Error)?>.makeStream()
        finishing.yield(nil)
        try await ScreenRecording.waitForEnd(prompt, file: URL(fileURLWithPath: "/done.mov"))

        func movie(_ file: URL) async throws -> (size: CGSize, seconds: Double) {
            let asset = AVURLAsset(url: file)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            return (try await track.load(.naturalSize), try await asset.load(.duration).seconds)
        }

        // Delivery of a 1 s, 640 x 360 movie written into the save folder, as a recording's file would be.
        let file = Output.defaultFile(defaults: overlay.defaults).deletingPathExtension().appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        require(writer.startWriting(), "the test movie starts writing")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: 640, height: 360, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image.cropping(to: CGRect(x: 400 + index * 4, y: 200, width: 640, height: 360))!, in: CGRect(x: 0, y: 0, width: 640, height: 360))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 60))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 60))
        await writer.finishWriting()
        overlay.pasteboard.clearContents()
        let first = try await ScreenRecording.deliver(file, pasteboard: overlay.pasteboard, defaults: overlay.defaults)
        let copied = overlay.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        let written = try await movie(file)
        require(copied == [file] && file.deletingLastPathComponent().path == overlay.defaults.string(forKey: Pref.saveFolder)
                && file.lastPathComponent.hasPrefix("Snug ") && file.pathExtension == "mov",
                "a finished recording in the save folder has its file URL copied: \(String(describing: copied))")
        require(first.width == 640 && first.height == 360 && written.size == CGSize(width: 640, height: 360) && abs(written.seconds - 1) < 0.05,
                "the delivered movie's first frame and track are 640 x 360 and it lasts 1 s: \(first.width) x \(first.height) \(written)")

        guard CGPreflightScreenCaptureAccess() else {
            print("recording             skipped: this process has no Screen Recording permission")
            return
        }
        let live = FileManager.default.temporaryDirectory.appending(path: "snug-recording-\(UUID().uuidString).mov")
        let area = CGRect(x: 0, y: 0, width: 200, height: 100)
        let recording = try await ScreenRecording.start(displayID: display, area: area, file: live, showsCursor: true, showsPanels: false, defaults: defaults)
        try await Task.sleep(for: .seconds(1))
        try await recording.stop()
        let recorded = try await movie(live)
        let pixelScale = CGFloat(CGDisplayCopyDisplayMode(display)!.pixelWidth) / CGDisplayBounds(display).width
        require(recorded.size == CGSize(width: area.width * pixelScale, height: area.height * pixelScale) && abs(recorded.seconds - 1) < 0.3,
                "a live 1 s recording of 200 x 100 pt is \(area.width * pixelScale) x \(area.height * pixelScale) px and about 1 s: \(recorded)")

        // `start` orders the outline and reminder in while still transparent, before it reads the shareable content: ScreenCaptureKit
        // lists them then, so the filter's window-ID exclusion finds them. (A display filter's `includedWindows` is empty, so it can't
        // show the exclusion itself.)
        [outline, reminder].forEach { $0.orderFrontRegardless() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        [outline, reminder].forEach { $0.orderOut(nil) }
        let listed = Set(content.windows.map(\.windowID))
        require(panelIDs.allSatisfy(listed.contains), "the transparent outline and reminder \(panelIDs) are in the shareable content")
    }
}
