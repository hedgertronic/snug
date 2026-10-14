import AppKit
import AVFoundation
import os
import ScreenCaptureKit

let recordingLog = Logger(subsystem: "local.snug", category: "recording")

extension Pref {
    /// Seconds of the count shown over the area before a recording starts: 0 (off), 3 or 5; I cycles it while armed.
    static let recordCountIn = "SnugRecordCountIn"
    /// Whether recordings show the cursor; H switches it while armed.
    static let recordCursor = "SnugRecordCursor"
    /// Whether recordings carry the system's audio (no microphone); J switches it while armed. Off until chosen.
    static let recordAudio = "SnugRecordAudio"
}

/// A click-through, borderless panel over everything that recordings leave out of the video: the dim, the outline around the area, and
/// the stop reminder. It starts transparent.
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

    /// The stop reminder's time recorded so far, which `ScreenRecording.start` counts.
    var clock: NSTextField?
}

/// A screen recording of one area of a display: H.264 at up to 60 fps, with or without the cursor, and with the system's audio (never
/// the microphone, and never Snug's own sound) when asked, written to a .mov by `SCRecordingOutput`. Snug is left out of the video by application (the overlay, the toast, the dim, the outline and the stop
/// reminder), all but its listed windows that captures do not exclude: Settings and Snug's other windows show.
@MainActor
final class ScreenRecording: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// The armed overlay hands the display, its area (display points, top-left origin, whole even pixels), whether the cursor shows
    /// and whether system audio is recorded, once the count-in ends; the app starts the recording. Debug runs replace it.
    static var requested: (CGDirectDisplayID, CGRect, Bool, Bool) -> Void = { _, _, _, _ in }
    /// How long `stop` waits for the recording output to finish the file before it fails.
    nonisolated static let finishTimeout = Duration.seconds(5)
    /// Space between the outline and the stop reminder.
    static let reminderGap: CGFloat = 8
    /// Space between the bottom of the visible frame and the stop reminder inside a full-screen area.
    static let fullScreenInset: CGFloat = 24

    let file: URL
    /// Called on the main actor if the recording fails before `stop`, with no frames written.
    var onFailure: (any Error) -> Void = { _ in }
    /// Called on the main actor when the stream stops without `stop`, as when the system's screen-recording indicator in the menu bar
    /// stops it, or when the recording output finishes or fails after it wrote frames without `stop`; `stop` then returns on that end.
    var onStop: () -> Void = {}
    private var stream: SCStream!
    private var output: SCRecordingOutput!
    private let panels: [RecordingPanel]
    /// The recording output's end: nil once the file is finished, or the error that ended it.
    private let ended: AsyncStream<(any Error)?>
    private let end: AsyncStream<(any Error)?>.Continuation
    private var stopping = false
    private var streamStopped = false
    /// Counts the reminder's time once a second until the recording stops.
    private var ticking: Task<Void, any Error>?

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

    /// Starts recording `area` of the display into `file`, with the system's audio when `capturesAudio`. With `showsPanels`, the rest of the display dims, a thin red outline just
    /// outside the area pulses once as capture starts, and the stop reminder sits outside it. The handlers are set before capture starts,
    /// so no stop or failure is missed.
    static func start(displayID: CGDirectDisplayID, area: CGRect, file: URL, showsCursor: Bool, capturesAudio: Bool, showsPanels: Bool, defaults: UserDefaults,
                      onFailure: @escaping (any Error) -> Void = { _ in }, onStop: @escaping () -> Void = {}) async throws -> ScreenRecording {
        // Ordered in while transparent, so the window server lists them for the filter that leaves them out.
        let dim = showsPanels ? makeDim(around: area, on: displayID, defaults: defaults) : nil
        let outline = showsPanels ? makeOutline(around: area, on: displayID) : nil
        let reminder = showsPanels ? makeReminder(around: area, on: displayID, defaults: defaults) : nil
        let panels = [dim, outline, reminder].compactMap(\.self)
        panels.forEach { $0.orderFrontRegardless() }
        // The dim shows at once, so the screen stays dimmed from the overlay's close through the stream's start; Snug is left out of
        // the video by application whether or not a window is listed yet.
        dim?.alphaValue = 1
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
            configuration.capturesAudio = capturesAudio
            configuration.excludesCurrentProcessAudio = true
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = file
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .h264
            recording = try ScreenRecording(file: file, filter: filter, configuration: configuration, recordingConfiguration: recordingConfiguration, panels: panels)
            recording.onFailure = onFailure
            recording.onStop = onStop
            try await recording.stream.startCapture()
        } catch {
            // A failed start leaves nothing on screen.
            panels.forEach { $0.orderOut(nil) }
            throw error
        }
        panels.forEach { $0.alphaValue = 1 }
        if let clock = reminder?.clock {
            let started = ContinuousClock.now
            recording.ticking = Task {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    clock.stringValue = elapsed(Int(started.duration(to: .now).components.seconds))
                }
            }
        }
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
        ticking?.cancel()
        panels.forEach { $0.orderOut(nil) }
        // A failed stop ends the wait with its error; a stop that never returns is caught by the timeout.
        if !streamStopped {
            Task { [stream, end] in
                do { try await stream!.stopCapture() } catch { end.yield(error) }
            }
        }
        try await Self.waitForEnd(ended, file: file)
        recordingLog.notice("stop() returned")
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
        let failure = error as NSError
        Task { @MainActor in
            recordingLog.notice("stream stopped, error \(failure.domain, privacy: .public) \(failure.code), stopping \(self.stopping)")
            streamStopped = true
            if !stopping { onStop() }
        }
    }

    /// A stop from the system's screen-recording indicator can end here alone, with no stream stop or failure to follow.
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            recordingLog.notice("output finished, stopping \(self.stopping)")
            finished(nil)
        }
    }

    /// A stop from outside Snug (the system's screen-recording indicator) may end the output with `userStopped`, or with another code
    /// that arrives before the stream's own stop; once frames are written the file is as complete as after `stop`, so it delivers like
    /// one. Only an output that fails with nothing written is a failure.
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let failure = error as NSError
        Task { @MainActor in
            let wroteFrames = output.recordedDuration > .zero
            recordingLog.notice("output failed, error \(failure.domain, privacy: .public) \(failure.code), frames written \(wroteFrames), stopping \(self.stopping)")
            finished(wroteFrames || (error as? SCStreamError)?.code == .userStopped ? nil : error)
        }
    }

    /// Ends the wait in `stop`; an end that `stop` didn't ask for delivers through `onStop` (or `onFailure` with an error).
    private func finished(_ error: (any Error)?) {
        end.yield(error)
        guard !stopping else { return }
        ticking?.cancel()
        panels.forEach { $0.orderOut(nil) }
        if let error { onFailure(error) } else { onStop() }
    }

    /// Seconds recorded as minutes and seconds: "0:07", "12:30".
    static func elapsed(_ seconds: Int) -> String { "\(seconds / 60):" + String(format: "%02d", seconds % 60) }

    /// `rect`, in display points with a top-left origin, in AppKit's global coordinates.
    private static func screenFrame(_ rect: CGRect, on displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        return CGRect(x: bounds.minX + rect.minX, y: CGDisplayBounds(CGMainDisplayID()).height - (bounds.minY + rect.maxY), width: rect.width, height: rect.height)
    }

    /// The dim: the whole display at the overlay's outside dim (`highlight.fade`) with the area cut out, so the recorded area reads as the
    /// target; clicks go through to the apps.
    static func makeDim(around area: CGRect, on displayID: CGDirectDisplayID, defaults: UserDefaults) -> RecordingPanel {
        let size = CGDisplayBounds(displayID).size
        let panel = RecordingPanel(frame: screenFrame(CGRect(origin: .zero, size: size), on: displayID))
        let shape = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        // The panel's layer has a bottom-left origin.
        path.addRect(CGRect(x: area.minX, y: size.height - area.maxY, width: area.width, height: area.height))
        shape.path = path
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.black.withAlphaComponent(defaults.double(forKey: Pref.highlightFade)).cgColor
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer!.addSublayer(shape)
        panel.contentView = view
        return panel
    }

    /// The outline: a 2 pt red border, the armed outline's color, just outside `area`, or inside the display's edge where `area` reaches it.
    static func makeOutline(around area: CGRect, on displayID: CGDirectDisplayID) -> RecordingPanel {
        // Clipped to the display, so an area that reaches an edge gets its outline just inside that edge.
        let display = CGRect(origin: .zero, size: CGDisplayBounds(displayID).size)
        let panel = RecordingPanel(frame: screenFrame(area.insetBy(dx: -3, dy: -3).intersection(display), on: displayID))
        let border = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        border.wantsLayer = true
        border.layer!.borderWidth = 2
        border.layer!.borderColor = NSColor.systemRed.cgColor
        border.layer!.cornerRadius = 4
        panel.contentView = border
        return panel
    }

    /// The stop reminder: two floating pills 8 pt apart on the chrome surface in the overlay's look, the time recorded so far ("0:12",
    /// counted by `start`), then "stop" and the capture shortcut's key cap (with no shortcut, "Stop from the menu bar"); placed by
    /// `reminderFrame` within the display's visible frame. The panel draws the
    /// shadow, since a pill's own would be clipped at the panel's edge.
    static func makeReminder(around area: CGRect, on displayID: CGDirectDisplayID, defaults: UserDefaults) -> RecordingPanel {
        // Sized for "00:00" so the pill holds ten minutes and more; mono digits keep the width.
        let clock = NSTextField("00:00", size: 12, weight: .medium, mono: true, color: .chromeText)
        clock.alignment = .center
        clock.stringValue = elapsed(0)
        let pills = [[clock] as [NSView], [defaults.integer(forKey: Pref.hotKeyCode) < 0
            ? NSTextField("Stop from the menu bar", size: 12, weight: .medium, color: .chromeText)
            : Pill.hint([Shortcut.label(from: defaults)], "stop")]].map { views in
            // Both take the control height, like the keys line, so they match.
            let pill = Pill(radius: 11, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14), spacing: 0, height: Chrome.controlHeight)
            pill.show("reminder") { views }
            return pill
        }
        pills[1].frame.origin.x = pills[0].frame.maxX + 8
        let pair = NSView(frame: CGRect(x: 0, y: 0, width: pills[1].frame.maxX, height: pills.map(\.frame.height).max()!))
        for pill in pills {
            pill.frame.origin.y = ((pair.frame.height - pill.frame.height) / 2).rounded()
            pair.addSubview(pill)
        }
        pair.appearance = Chrome.appearance(defaults)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == displayID }!
        let visible = CGRect(x: screen.visibleFrame.minX - screen.frame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        let panel = RecordingPanel(frame: screenFrame(reminderFrame(size: pair.frame.size, around: area, within: visible), on: displayID))
        panel.hasShadow = true
        panel.contentView = pair
        panel.clock = clock
        return panel
    }

    /// Where the stop reminder of `size` goes, in display points with a top-left origin: centered under `area`, `reminderGap` outside
    /// the outline, or over it when there is no room below within `visible`, and kept inside `visible` sideways. When neither fits, as for
    /// a full-screen area, it goes inside the area: bottom center, `fullScreenInset` above the bottom of `visible`.
    static func reminderFrame(size: CGSize, around area: CGRect, within visible: CGRect) -> CGRect {
        let outside = 3 + reminderGap
        let x = min(max(area.midX - size.width / 2, visible.minX), visible.maxX - size.width).rounded()
        let below = CGRect(x: x, y: area.maxY + outside, width: size.width, height: size.height)
        let above = CGRect(x: x, y: area.minY - outside - size.height, width: size.width, height: size.height)
        return [below, above].first { visible.contains($0) } ?? CGRect(x: x, y: visible.maxY - fullScreenInset - size.height, width: size.width, height: size.height)
    }

    /// Delivers a finished recording that is already in the save folder: copies its file URL (both after-capture settings copy),
    /// then shows the toast with the first frame; clicking the toast reveals the file.
    static func deliver(_ file: URL, pasteboard: NSPasteboard, defaults: UserDefaults) async throws -> CGImage {
        recordingLog.notice("deliver started")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero).image
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        recordingLog.notice("toast shown")
        Toast.show(png: try await Output.png(frame), message: "Copied, saved to \(file.deletingLastPathComponent().lastPathComponent)",
                   detail: file.lastPathComponent, file: file, defaults: defaults)
        return frame
    }

}
