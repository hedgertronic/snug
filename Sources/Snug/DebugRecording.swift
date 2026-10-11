import AppKit
import AVFoundation
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
                && overlay.chrome.actionBar.isHidden && !overlay.view.overlays.showsHandles,
                "armed: a red outline on the selection, no action bar or handles")
        require(hints() == ["start", "\u{21A9}", "cursor on", "H", "count-in off", "cancel", "esc"], "the armed strip: \(hints())")
        key(36, "\r")
        let expected = CGRect(x: 401 / scale, y: 201 / scale, width: 998 / scale, height: 600 / scale)
        require(!overlay.window.isVisible && requests == [expected] && cursors == [true] && overlayShown == [false] && armed!.outline.superlayer == nil,
                "Return with no count-in closes the overlay, then records the even-pixel area with the cursor: \(requests) \(overlayShown)")

        // The Record button arms; V starts.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        overlay.chrome.actionBar.record.onClick()
        require(overlay.window.isVisible && requests.count == 1 && overlay.armedRecording != nil, "clicking Record arms recording")
        key(9, "v")
        require(!overlay.window.isVisible && requests.last == CGRect(x: 600 / scale, y: 300 / scale, width: 400 / scale, height: 200 / scale),
                "V while armed records the selection")

        // Esc disarms back to the released selection; H switches the cursor for one recording.
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        key(53, "\u{1B}")
        require(overlay.window.isVisible && overlay.armedRecording == nil && overlay.selection != nil && !overlay.chrome.actionBar.isHidden
                && requests.count == 2, "Esc while armed disarms and keeps the selection")
        key(9, "v")
        key(4, "h")
        require(hints().contains("cursor off"), "H shows the cursor off: \(hints())")
        key(36, "\r")
        require(cursors.last == false && defaults.bool(forKey: Pref.recordCursor), "H hides the cursor for this recording only: \(cursors)")

        // A hovered window becomes the armed selection; V again starts.
        open()
        let window = CGRect(x: 500, y: 400, width: 1200, height: 800)
        overlay.setWindows([window], names: ["Window"], pointer: CGPoint(x: frame.minX + 1100 / scale, y: frame.maxY - 800 / scale))
        let hovered = overlay.hoverRect
        require(hovered != nil, "a window is hovered")
        key(9, "v")
        require(overlay.window.isVisible && overlay.armedRecording != nil && overlay.selection?.rect == hovered, "V on a hovered element arms it as the selection")
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

        // A 3 s count-in shows 3, 2, 1 over the selection; the request comes 3 s after Return, with the overlay already closed.
        defaults.set(3, forKey: Pref.recordCountIn)
        open()
        select(CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(hints().contains("count-in 3 s"), "the armed strip shows the count-in: \(hints())")
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
        let recording = try await ScreenRecording.start(displayID: display, area: area, file: live, showsCursor: true, showsOutline: false)
        try await Task.sleep(for: .seconds(1))
        try await recording.stop()
        let recorded = try await movie(live)
        let pixelScale = CGFloat(CGDisplayCopyDisplayMode(display)!.pixelWidth) / CGDisplayBounds(display).width
        require(recorded.size == CGSize(width: area.width * pixelScale, height: area.height * pixelScale) && abs(recorded.seconds - 1) < 0.3,
                "a live 1 s recording of 200 x 100 pt is \(area.width * pixelScale) x \(area.height * pixelScale) px and about 1 s: \(recorded)")
    }
}
