import AppKit
import AVFoundation
import ScreenCaptureKit
import ScreenshotCore

extension DebugRun {
    /// Part of `--verify-extras-ui`: V and the Record button arm recording of the selection or hovered element; the armed keys start,
    /// switch the cursor and audio and cancel; the count-in delays the request and the overlay is closed when it fires; `stop`'s wait for the
    /// file times out; and a finished movie in the save folder is delivered (URL copied, first frame read). Two live 1 s recordings, one
    /// without and one with system audio, run only when this process has Screen Recording; without it, ScreenCaptureKit is never touched,
    /// since asking could put the permission prompt on screen.
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
        var audios: [Bool] = []
        var overlayShown: [Bool] = []
        var times: [ContinuousClock.Instant] = []
        var displays: Set<CGDirectDisplayID> = []
        ScreenRecording.requested = { id, area, cursor, audio in
            displays.insert(id)
            requests.append(area)
            cursors.append(cursor)
            audios.append(audio)
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
        require(strip() == ["Cursor", "H", "Audio", "J", "Count-in", "I", "Cancel", "esc", "Start", "\u{21A9}"] && overlay.chrome.cursor.lit && !overlay.chrome.audio.lit
                    && !overlay.chrome.countIn.lit && overlay.chrome.start.primary && overlay.chrome.hints.isHidden,
                "the armed strip: Cursor lit, Audio and Count-in plain, Start primary; no keys line, since the strip shows Start and Cancel: \(strip()) \(hints())")
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
        require(!overlay.window.isVisible && requests == [expected] && cursors == [true] && audios == [false] && overlayShown == [false] && armed!.outline.superlayer == nil,
                "Return with no count-in closes the overlay, then records the even-pixel area with the cursor and no audio: \(requests) \(overlayShown) \(audios)")

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
        // J switches system audio, lit when on, and saves it; the next request carries it.
        key(38, "j")
        require(strip().contains("Audio") && overlay.chrome.audio.lit && defaults.bool(forKey: Pref.recordAudio), "J turns Audio lit and saves it: \(strip())")
        overlay.chrome.audio.onClick()
        require(!overlay.chrome.audio.lit && !defaults.bool(forKey: Pref.recordAudio), "clicking Audio turns it plain and saves it")
        key(38, "j")
        key(36, "\r")
        require(cursors.last == false && audios.last == true, "H hides the cursor and J records audio in the recording: \(cursors) \(audios)")
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(!overlay.chrome.cursor.lit && overlay.chrome.audio.lit, "the cursor and audio choices stick for the next recording: \(strip())")
        key(4, "h")
        key(38, "j")
        key(53, "\u{1B}")
        overlay.dismiss()
        require(defaults.bool(forKey: Pref.recordCursor) && !defaults.bool(forKey: Pref.recordAudio), "H again shows the cursor and J again turns audio off")

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

        // Armed, the loupe, crosshair and rulers are hidden and C does nothing; Esc brings the guides back.
        for key in [Pref.loupe, Pref.rulers, Pref.crosshair] { defaults.set(true, forKey: key) }
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        let guides = overlay.view.guides
        func guidesHidden() -> [Bool] { [guides.loupe.isHidden || guides.loupe.opacity == 0, guides.rulers.isHidden || guides.rulers.opacity == 0, guides.crosshair.isHidden] }
        require(guidesHidden() == [false, false, false], "the guides show before arming: \(guidesHidden())")
        key(9, "v")
        overlay.pasteboard.clearContents()
        let countIn = defaults.integer(forKey: Pref.recordCountIn)
        key(8, "c")
        require(overlay.window.isVisible && overlay.armedRecording != nil && requests.count == count && defaults.integer(forKey: Pref.recordCountIn) == countIn
                && overlay.pasteboard.string(forType: .string) == nil, "C while armed does nothing: \(overlay.pasteboard.string(forType: .string) ?? "nothing")")
        require(guidesHidden() == [true, true, true] && guides.readout.isHidden, "armed hides the loupe, rulers, crosshair and readout: \(guidesHidden())")
        key(53, "\u{1B}")
        require(overlay.armedRecording == nil && guidesHidden() == [false, false, false] && !guides.readout.isHidden, "Esc brings the guides back: \(guidesHidden())")
        overlay.dismiss()

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
        require(hints() == ["Recording in 3"], "counting in, the keys line leaves out Cancel, which the strip shows: \(hints())")
        try await Task.sleep(for: .milliseconds(1500))
        key(53, "\u{1B}")
        try await Task.sleep(for: .milliseconds(2600))
        require(overlay.window.isVisible && overlay.armedRecording?.remaining == nil && overlay.armedRecording?.count.isHidden == true
                && requests.count == count + 1, "Esc during the count-in stops it, still armed, and nothing is recorded")
        overlay.dismiss()
        require(displays == [display], "every recording is requested on the overlay's display")
        ScreenRecording.requested = { _, _, _, _ in }

        // While recording: a red outline just outside the area, and the stop reminder below it reading the capture shortcut; both are
        // windows Snug's captures leave out, which Settings is not.
        let recordArea = CGRect(x: 300, y: 300, width: 400, height: 200)
        let outline = ScreenRecording.makeOutline(around: recordArea, on: display)
        let reminder = ScreenRecording.makeReminder(around: recordArea, on: display, defaults: defaults)
        let settings = SettingsTabs.makeWindow()
        require(outline.contentView!.layer!.borderColor == NSColor.systemRed.cgColor, "the recording outline is red, like the armed outline")
        require(texts(in: reminder.contentView!) == ["0:00", "stop", "\u{2303}\u{21E7}Space"], "the reminder reads the time, stop, then the shortcut: \(texts(in: reminder.contentView!))")
        let reminderPills = reminder.contentView!.subviews.compactMap { $0 as? Pill }
        let reminderCaps = reminderPills.last.map { $0.subviews[0].subviews.compactMap { $0 as? KeyCap } } ?? []
        require(reminderPills.count == 2 && reminderPills[1].frame.minX - reminderPills[0].frame.maxX == 8 && reminderCaps.map(\.text) == ["\u{2303}\u{21E7}Space"] && reminder.hasShadow,
                "the reminder is two chrome pills 8 pt apart, the time and then stop with the shortcut's key cap; the panel draws the shadow")
        require(reminderPills.map(\.frame.height) == [32, 32], "the time and stop pills are both the 32 pt control height: \(reminderPills.map(\.frame.height))")
        require([0, 7, 59, 60, 750].map(ScreenRecording.elapsed) == ["0:00", "0:07", "0:59", "1:00", "12:30"], "the time reads m:ss")
        require(reminder.frame.maxY == outline.frame.minY - ScreenRecording.reminderGap && abs(reminder.frame.midX - outline.frame.midX) <= 0.5,
                "the reminder is centered under the outline, \(ScreenRecording.reminderGap) pt away: \(reminder.frame) \(outline.frame)")
        // The dim covers the display at the highlight fade with the area cut out, and lets clicks through.
        let dim = ScreenRecording.makeDim(around: recordArea, on: display, defaults: defaults)
        let dimPath = (dim.contentView!.layer!.sublayers![0] as! CAShapeLayer).path!
        let displayHeight = CGDisplayBounds(display).height
        require(dim.frame.size == CGDisplayBounds(display).size && dim.ignoresMouseEvents && dimPath.contains(CGPoint(x: 10, y: 10), using: .evenOdd)
                    && !dimPath.contains(CGPoint(x: recordArea.midX, y: displayHeight - recordArea.midY), using: .evenOdd),
                "the dim panel covers the display, cuts the area out, and is click-through: \(dim.frame)")
        // NSPanel documents true as its default, but the .nonactivatingPanel style bit makes it false at init, so none of these hide when
        // the overlay's dismiss hands activation back to the previous app.
        require([dim, outline, reminder].allSatisfy { !$0.hidesOnDeactivate }, "the recording panels stay on screen when Snug deactivates")
        let excluded = DisplayCapture.excludedWindowIDs()
        let panelIDs = [dim, outline, reminder].map { CGWindowID($0.windowNumber) }
        require(panelIDs.allSatisfy { $0 > 0 && excluded.contains($0) } && !excluded.contains(CGWindowID(settings.windowNumber)),
                "the dim, outline and reminder \(panelIDs) are left out of recordings and Settings \(settings.windowNumber) is not: \(excluded.sorted())")
        defaults.set(-1, forKey: Pref.hotKeyCode)
        let unset = ScreenRecording.makeReminder(around: recordArea, on: display, defaults: defaults)
        require(texts(in: unset.contentView!) == ["0:00", "Stop from the menu bar"], "with no shortcut the reminder points to the menu bar: \(texts(in: unset.contentView!))")
        defaults.set(49, forKey: Pref.hotKeyCode)
        // Placement in a 1512 x 945 pt visible frame under a 37 pt menu bar, for a 120 x 36 pt reminder.
        let visible = CGRect(x: 0, y: 37, width: 1512, height: 945)
        let size = CGSize(width: 120, height: 36)
        let near = CGRect(x: 600, y: 700, width: 300, height: 260)
        let placements = [recordArea, near, CGRect(x: 1450, y: 300, width: 60, height: 100), CGRect(x: 0, y: 37, width: 1512, height: 945),
                          CGRect(x: 0, y: 60, width: 1512, height: 880)].map { ScreenRecording.reminderFrame(size: size, around: $0, within: visible) }
        require(placements[0] == CGRect(x: 440, y: 511, width: 120, height: 36) && placements[1] == CGRect(x: 690, y: 653, width: 120, height: 36)
                && placements[2] == CGRect(x: 1392, y: 411, width: 120, height: 36) && placements[3] == CGRect(x: 696, y: 922, width: 120, height: 36)
                && placements[4] == CGRect(x: 696, y: 922, width: 120, height: 36),
                "the reminder goes below, above when the area reaches the bottom, inside the screen sideways, and inside the area, bottom center 24 pt up, when neither fits: \(placements)")
        require(placements.allSatisfy { visible.contains($0) }
                && zip([recordArea, near], placements).allSatisfy { !$0.0.insetBy(dx: -3, dy: -3).intersects($0.1) }, "the reminder stays on screen and off a partial area's outline")
        // A full-screen area: the reminder panel sits inside it, bottom center, 24 pt above the visible frame's bottom, and the outline stays on the display.
        let displayBounds = CGRect(origin: .zero, size: CGDisplayBounds(display).size)
        let fullOutline = ScreenRecording.makeOutline(around: displayBounds, on: display)
        let fullReminder = ScreenRecording.makeReminder(around: displayBounds, on: display, defaults: defaults)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == display }!
        require(fullOutline.frame == screen.frame && fullReminder.frame.minY == screen.visibleFrame.minY + ScreenRecording.fullScreenInset
                && abs(fullReminder.frame.midX - screen.frame.midX) <= 0.5 && screen.visibleFrame.contains(fullReminder.frame),
                "a full-screen recording's outline is inset to the display and its reminder sits bottom center inside: \(fullOutline.frame) \(fullReminder.frame) \(screen.visibleFrame)")

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
        let recording = try await ScreenRecording.start(displayID: display, area: area, file: live, showsCursor: true, capturesAudio: false, showsPanels: false, defaults: defaults)
        try await Task.sleep(for: .seconds(1))
        try await recording.stop()
        let recorded = try await movie(live)
        let silentTracks = try await AVURLAsset(url: live).loadTracks(withMediaType: .audio)
        require(silentTracks.isEmpty, "a recording made with audio off has no audio track: \(silentTracks.count)")
        let pixelScale = CGFloat(CGDisplayCopyDisplayMode(display)!.pixelWidth) / CGDisplayBounds(display).width
        require(recorded.size == CGSize(width: area.width * pixelScale, height: area.height * pixelScale) && abs(recorded.seconds - 1) < 0.3,
                "a live 1 s recording of 200 x 100 pt is \(area.width * pixelScale) x \(area.height * pixelScale) px and about 1 s: \(recorded)")

        // The same recording with system audio on: SCRecordingOutput writes an audio track (one, with no microphone).
        let loud = FileManager.default.temporaryDirectory.appending(path: "snug-recording-audio-\(UUID().uuidString).mov")
        let withAudio = try await ScreenRecording.start(displayID: display, area: area, file: loud, showsCursor: true, capturesAudio: true, showsPanels: false, defaults: defaults)
        try await Task.sleep(for: .seconds(1))
        try await withAudio.stop()
        let audioTracks = try await AVURLAsset(url: loud).loadTracks(withMediaType: .audio)
        let audioSeconds = try await audioTracks.first?.load(.timeRange).duration.seconds
        print("recording audio       \(audioTracks.count) audio track(s), \(audioSeconds.map { String(format: "%.2f", $0) } ?? "none") s")
        require(audioTracks.count == 1, "a recording made with audio on has one audio track: \(audioTracks.count)")

        // `start` orders the panels in while still transparent, before it reads the shareable content: ScreenCaptureKit lists them then.
        [dim, outline, reminder].forEach { $0.orderFrontRegardless() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        [dim, outline, reminder].forEach { $0.orderOut(nil) }
        let listed = Set(content.windows.map(\.windowID))
        require(panelIDs.allSatisfy(listed.contains), "the transparent dim, outline and reminder \(panelIDs) are in the shareable content")
        // The stream's filter leaves Snug out by application, so it includes none of Snug's excluded windows, listed or not.
        let streamFilter = DisplayCapture.filter(for: display, in: content, excluding: DisplayCapture.excludedWindowIDs())
        let leftOut = DisplayCapture.excludedWindowIDs().union(panelIDs)
        require(Set(streamFilter.includedWindows.map(\.windowID)).isDisjoint(with: leftOut) && streamFilter.includedApplications.allSatisfy { $0.processID != getpid() },
                "the recording filter includes none of Snug's chrome windows \(leftOut.sorted())")
    }
}
