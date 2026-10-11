import AppKit
import AVFoundation
import ScreenCaptureKit

extension Pref {
    /// Seconds of the count shown over the area before a recording starts: 0 (off), 3 or 5; C cycles it while armed.
    static let recordCountIn = "SnugRecordCountIn"
    /// Whether recordings show the cursor; H switches it while armed.
    static let recordCursor = "SnugRecordCursor"
}

/// A click-through, borderless panel over everything that recordings leave out of the video: the outline around the area and the stop
/// reminder. It starts transparent.
final class RecordingPanel: NSPanel, CaptureExcluded {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        alphaValue = 0
    }
}

/// A screen recording of one area of a display: H.264 at up to 60 fps, with or without the cursor, and no audio, written to a .mov by
/// `SCRecordingOutput`. The windows Snug's captures exclude (the overlay, the toast, the outline and the stop reminder) are left out of
/// the video by window ID; Settings and Snug's other windows show.
@MainActor
final class ScreenRecording: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// The armed overlay hands the display, its area (display points, top-left origin, whole even pixels) and whether the cursor
    /// shows here once the count-in ends; the app starts the recording. Debug runs replace it.
    static var requested: (CGDirectDisplayID, CGRect, Bool) -> Void = { _, _, _ in }
    /// How long `stop` waits for the recording output to finish the file before it fails.
    nonisolated static let finishTimeout = Duration.seconds(5)
    /// Space between the outline and the stop reminder.
    static let reminderGap: CGFloat = 8

    let file: URL
    /// Called on the main actor if the recording fails before `stop`.
    var onFailure: (any Error) -> Void = { _ in }
    /// Called on the main actor when the stream stops without `stop`, as when the system's screen-recording indicator in the menu bar
    /// stops it; `stop` then waits for the file without stopping the stream again.
    var onStop: () -> Void = {}
    private var stream: SCStream!
    private var output: SCRecordingOutput!
    private let panels: [RecordingPanel]
    /// The recording output's end: nil once the file is finished, or the error that ended it.
    private let ended: AsyncStream<(any Error)?>
    private let end: AsyncStream<(any Error)?>.Continuation
    private var stopping = false
    private var streamStopped = false

    private init(file: URL, filter: SCContentFilter, configuration: SCStreamConfiguration, recordingConfiguration: SCRecordingOutputConfiguration,
                 panels: [RecordingPanel]) throws {
        self.file = file
        self.panels = panels
        (ended, end) = AsyncStream.makeStream()
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
    }

    /// Starts recording `area` of the display into `file`. With `showsPanels`, a thin red outline just outside the area pulses once as
    /// capture starts, and the stop reminder sits outside it.
    static func start(displayID: CGDirectDisplayID, area: CGRect, file: URL, showsCursor: Bool, showsPanels: Bool, defaults: UserDefaults) async throws -> ScreenRecording {
        // Ordered in while transparent, so the window server lists them for the filter that leaves them out.
        let outline = showsPanels ? makeOutline(around: area, on: displayID) : nil
        let reminder = showsPanels ? makeReminder(around: area, on: displayID, defaults: defaults) : nil
        let panels = [outline, reminder].compactMap(\.self)
        panels.forEach { $0.orderFrontRegardless() }
        let recording: ScreenRecording
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let filter = DisplayCapture.filter(for: displayID, in: content, excluding: DisplayCapture.excludedWindowIDs())
            let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = area
            configuration.width = Int((area.width * scale).rounded())
            configuration.height = Int((area.height * scale).rounded())
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.showsCursor = showsCursor
            configuration.capturesAudio = false
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = file
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .h264
            recording = try ScreenRecording(file: file, filter: filter, configuration: configuration, recordingConfiguration: recordingConfiguration, panels: panels)
            try await recording.stream.startCapture()
        } catch {
            // A failed start leaves nothing on screen.
            panels.forEach { $0.orderOut(nil) }
            throw error
        }
        panels.forEach { $0.alphaValue = 1 }
        // The start cue: the outline flashes once.
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0.25, 1]
        pulse.duration = 0.5
        outline?.contentView!.layer!.add(pulse, forKey: "pulse")
        return recording
    }

    /// Ends the recording and waits until the file is written, or fails after `finishTimeout`.
    func stop() async throws {
        stopping = true
        panels.forEach { $0.orderOut(nil) }
        // A failed stop ends the wait with its error; a stop that never returns is caught by the timeout.
        if !streamStopped {
            Task { [stream, end] in
                do { try await stream!.stopCapture() } catch { end.yield(error) }
            }
        }
        try await Self.waitForEnd(ended, file: file)
    }

    /// Waits for the first end in `ended`: returns on nil, throws the error it carries, or throws a write error naming `file` after
    /// `finishTimeout`.
    static func waitForEnd(_ ended: AsyncStream<(any Error)?>, file: URL) async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                // The stream never finishes; the loop ends without an element only when the timeout wins and cancels it.
                for await error in ended {
                    if let error { throw error }
                    return
                }
            }
            group.addTask {
                try await Task.sleep(for: finishTimeout)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path,
                    NSLocalizedDescriptionKey: "The recording didn't finish writing \(file.lastPathComponent) within \(finishTimeout.components.seconds) seconds."])
            }
            try await group.next()
            group.cancelAll()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            streamStopped = true
            if !stopping { onStop() }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in finished(nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in finished(error) }
    }

    private func finished(_ error: (any Error)?) {
        end.yield(error)
        if let error, !stopping {
            panels.forEach { $0.orderOut(nil) }
            onFailure(error)
        }
    }

    /// `rect`, in display points with a top-left origin, in AppKit's global coordinates.
    private static func screenFrame(_ rect: CGRect, on displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        return CGRect(x: bounds.minX + rect.minX, y: CGDisplayBounds(CGMainDisplayID()).height - (bounds.minY + rect.maxY), width: rect.width, height: rect.height)
    }

    /// The outline: a 2 pt red border, the armed outline's color, just outside `area`.
    static func makeOutline(around area: CGRect, on displayID: CGDirectDisplayID) -> RecordingPanel {
        let panel = RecordingPanel(frame: screenFrame(area.insetBy(dx: -3, dy: -3), on: displayID))
        let border = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        border.wantsLayer = true
        border.layer!.borderWidth = 2
        border.layer!.borderColor = NSColor.systemRed.cgColor
        border.layer!.cornerRadius = 4
        panel.contentView = border
        return panel
    }

    /// The stop reminder: the capture shortcut then "to stop" (with no shortcut, "Stop from the menu bar") on a dark pill, placed by
    /// `reminderFrame` within the display's visible frame; nil when it fits neither below nor above the area.
    static func makeReminder(around area: CGRect, on displayID: CGDirectDisplayID, defaults: UserDefaults) -> RecordingPanel? {
        let color = NSColor.white.withAlphaComponent(0.92)
        let pill = Pill.dark(0.9, radius: 11, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14), spacing: 6)
        pill.show("") {
            defaults.integer(forKey: Pref.hotKeyCode) < 0
                ? [NSTextField("Stop from the menu bar", size: 12, weight: .medium, color: color)]
                : [KeyCap(Shortcut.label(from: defaults), color: color), NSTextField("to stop", size: 12, weight: .medium, color: color)]
        }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == displayID }!
        let visible = CGRect(x: screen.visibleFrame.minX - screen.frame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        guard let frame = reminderFrame(size: pill.frame.size, around: area, within: visible) else { return nil }
        let panel = RecordingPanel(frame: screenFrame(frame, on: displayID))
        panel.contentView = pill
        return panel
    }

    /// Where the stop reminder of `size` goes, in display points with a top-left origin: centered under `area`, `reminderGap` outside
    /// the outline, or over it when there is no room below within `visible`, and kept inside `visible` sideways. Nil when neither fits,
    /// as for a full-screen area: the reminder never covers the area.
    static func reminderFrame(size: CGSize, around area: CGRect, within visible: CGRect) -> CGRect? {
        let outside = 3 + reminderGap
        let x = min(max(area.midX - size.width / 2, visible.minX), visible.maxX - size.width).rounded()
        let below = CGRect(x: x, y: area.maxY + outside, width: size.width, height: size.height)
        let above = CGRect(x: x, y: area.minY - outside - size.height, width: size.width, height: size.height)
        return [below, above].first { visible.contains($0) }
    }

    /// Delivers a finished recording that is already in the save folder: copies its file URL (both after-capture settings copy),
    /// then shows the toast with the first frame; clicking the toast reveals the file.
    static func deliver(_ file: URL, pasteboard: NSPasteboard, defaults: UserDefaults) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero).image
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        Toast.show(png: try await Output.png(frame), message: "Copied, saved to \(file.deletingLastPathComponent().lastPathComponent)",
                   detail: file.lastPathComponent, file: file, defaults: defaults)
        return frame
    }

}
