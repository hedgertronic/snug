import AppKit
import AVFoundation
import ScreenshotCore

extension DebugRun {
    /// Part of `--verify-extras-ui`: V and the Record button hand the right display area to the app, and a finished movie in the save
    /// folder is delivered (URL copied, first frame read). A live 1 s recording runs only when this process has Screen Recording;
    /// without it, ScreenCaptureKit is never touched, since asking could put the permission prompt on screen.
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
        var requests: [CGRect] = []
        var displays: Set<CGDirectDisplayID> = []
        ScreenRecording.requested = { id, area in
            displays.insert(id)
            requests.append(area)
        }
        func open(displayID: CGDirectDisplayID? = display) {
            overlay.present(image: image, frame: frame, displayID: displayID)
            overlay.detectionTask?.cancel()
        }
        let scale = overlay.scale

        // An odd-sized selection records its whole even pixels, in display points.
        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 401, y: 201, width: 999, height: 601))
        overlay.refresh()
        key(9, "v")
        let expected = CGRect(x: 401 / scale, y: 201 / scale, width: 998 / scale, height: 600 / scale)
        require(!overlay.window.isVisible && requests == [expected], "V on a released selection closes the overlay and records its even-pixel area: \(requests)")

        open()
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 600, y: 300, width: 400, height: 200))
        overlay.refresh()
        overlay.chrome.actionBar.record.onClick()
        require(!overlay.window.isVisible && requests.last == CGRect(x: 600 / scale, y: 300 / scale, width: 400 / scale, height: 200 / scale),
                "clicking Record records the selection")

        open()
        let window = CGRect(x: 500, y: 400, width: 1200, height: 800)
        overlay.setWindows([window], names: ["Window"], pointer: CGPoint(x: frame.minX + 1100 / scale, y: frame.maxY - 800 / scale))
        let hovered = overlay.hoverRect
        require(hovered != nil, "a window is hovered")
        key(9, "v")
        require(!overlay.window.isVisible && requests.last == CGRect(x: hovered!.minX / scale, y: hovered!.minY / scale, width: hovered!.width / scale, height: hovered!.height / scale),
                "V on a hovered element records it: \(String(describing: requests.last)) \(hovered!)")

        let count = requests.count
        open()
        key(17, "t")
        key(9, "v")
        require(overlay.window.isVisible && requests.count == count, "V does nothing in Text mode")
        overlay.dismiss()
        open(displayID: nil)
        overlay.selection = AreaSelection(extent: extent, exact: CGRect(x: 600, y: 300, width: 400, height: 200))
        key(9, "v")
        require(overlay.window.isVisible && requests.count == count, "V does nothing on an opened image, which has no display to record")
        overlay.dismiss()
        require(displays == [display], "every recording is requested on the overlay's display")
        ScreenRecording.requested = { _, _ in }

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
        let recording = try await ScreenRecording.start(displayID: display, area: area, file: live, showsOutline: false)
        try await Task.sleep(for: .seconds(1))
        try await recording.stop()
        let recorded = try await movie(live)
        let pixelScale = CGFloat(CGDisplayCopyDisplayMode(display)!.pixelWidth) / CGDisplayBounds(display).width
        require(recorded.size == CGSize(width: area.width * pixelScale, height: area.height * pixelScale) && abs(recorded.seconds - 1) < 0.3,
                "a live 1 s recording of 200 x 100 pt is \(area.width * pixelScale) x \(area.height * pixelScale) px and about 1 s: \(recorded)")
    }
}
