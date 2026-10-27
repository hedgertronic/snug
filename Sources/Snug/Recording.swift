import AppKit
import AVFoundation
import os
import ScreenCaptureKit
import ScreenshotCore

let recordingLog = Logger(subsystem: "com.hedgertronic.snug", category: "recording")

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

    /// The name the finished recording asks for; `stop` moves the recording to it, or to the next free numbered name.
    let file: URL
    /// Where the output writes while recording, beside `file` under a hidden name, so no other recording's file is ever replaced.
    private let temporary: URL
    /// Called on the main actor if the recording fails before `stop`, with no frames written.
    var onFailure: (any Error) -> Void = { _ in }
    /// Called on the main actor when the stream stops without `stop`, as when the system's screen-recording indicator in the menu bar
    /// stops it, or when the recording output finishes or fails after it wrote frames without `stop`; `stop` then returns on that end.
    var onStop: () -> Void = {}
    /// The recording output's write or encoder failure after it wrote frames, as on a full disk (`RecordingEnd.partial`): `stop` still
    /// returns the file, which holds what was written, and the delivery shows this as a warning.
    private(set) var warning: (any Error)?
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

    private init(file: URL, temporary: URL, filter: SCContentFilter, configuration: SCStreamConfiguration, recordingConfiguration: SCRecordingOutputConfiguration,
                 panels: [RecordingPanel]) throws {
        self.file = file
        self.panels = panels
        self.temporary = temporary
        (ended, end) = AsyncStream.makeStream()
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
    }

    /// Starts recording `area` of the display into `file`, with the system's audio when `capturesAudio`. With `showsPanels`, the rest of the display dims, a thin red outline just
    /// outside the area pulses once as capture starts, the stop reminder sits outside it, and the start sound plays before capture starts. The handlers are set before capture starts,
    /// so no stop or failure is missed. The log gets one line at each step of a start (requested, content fetched, capture started, panels
    /// visible) with the milliseconds since the request, so a slow start shows where the time went.
    static func start(displayID: CGDirectDisplayID, area: CGRect, file: URL, showsCursor: Bool, capturesAudio: Bool, showsPanels: Bool, defaults: UserDefaults,
                      onFailure: @escaping (any Error) -> Void = { _ in }, onStop: @escaping () -> Void = {}) async throws -> ScreenRecording {
        let requested = ContinuousClock.now
        func mark(_ step: String) { recordingLog.notice("start: \(step, privacy: .public) at \(Int(requested.duration(to: .now).milliseconds)) ms, app active \(NSApp.isActive)") }
        mark("requested")
        // The display can be disconnected between choosing the area and the count-in's end.
        guard DisplayCapture.screen(for: displayID) != nil else { throw CaptureError.displayUnavailable }
        // Ordered in while transparent, so the window server lists them for the filter that leaves them out.
        let dim = showsPanels ? makeDim(around: area, on: displayID, defaults: defaults) : nil
        let outline = showsPanels ? makeOutline(around: area, on: displayID) : nil
        let reminder = showsPanels ? makeReminder(around: area, on: displayID, defaults: defaults) : nil
        let panels = [dim, outline, reminder].compactMap(\.self)
        panels.forEach { $0.orderFrontRegardless() }
        // The dim shows at once, so the screen stays dimmed from the overlay's close through the stream's start; Snug is left out of
        // the video by application whether or not a window is listed yet.
        dim?.alphaValue = 1
        // The start sound ends before capture starts, so a recording of the system's audio never holds it.
        let cueEnds = ContinuousClock.now + (showsPanels ? Sound.recordStart.play(defaults: defaults) : .zero)
        let recording: ScreenRecording
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            mark("content fetched")
            let filter = try DisplayCapture.filter(for: displayID, in: content, excluding: DisplayCapture.excludedWindowIDs())
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
            let temporary = UniqueFile.temporary(beside: file)
            recordingConfiguration.outputURL = temporary
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .h264
            recording = try ScreenRecording(file: file, temporary: temporary, filter: filter, configuration: configuration, recordingConfiguration: recordingConfiguration, panels: panels)
            recording.onFailure = onFailure
            recording.onStop = onStop
            try await Task.sleep(until: cueEnds)
            try await recording.stream.startCapture()
            mark("capture started")
        } catch {
            // A failed start leaves nothing on screen.
            panels.forEach { $0.orderOut(nil) }
            throw error
        }
        panels.forEach { $0.alphaValue = 1 }
        mark("panels visible")
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

    /// Ends the recording and waits until the file is written, or fails after `finishTimeout`. Returns the file the recording was moved
    /// to: `file`, or its next free numbered name when another recording or capture already has it.
    func stop() async throws -> URL {
        stopping = true
        ticking?.cancel()
        panels.forEach { $0.orderOut(nil) }
        // A failed stop ends the wait with its error; a stop that never returns is caught by the timeout.
        if !streamStopped {
            Task { [stream, end] in
                do { try await stream!.stopCapture() } catch { end.yield(error) }
            }
        }
        do {
            try await Self.waitForEnd(ended, file: file)
        } catch {
            // A recording that failed to finish stays recoverable at a visible name.
            if FileManager.default.fileExists(atPath: temporary.path) { _ = try UniqueFile.move(temporary, to: file) }
            throw error
        }
        recordingLog.notice("stop() returned")
        return try UniqueFile.move(temporary, to: file)
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

    /// A stop from outside Snug (the system's screen-recording indicator) ends the output with `userStopped` or another code, which
    /// delivers like `stop`, as does any failure while Snug is stopping or after the stream stopped. A write or encoder failure after
    /// frames were written (`RecordingEnd.partial`: a full disk, an encoder error) also delivers the file, which holds what was written,
    /// with the error kept in `warning`. Only an output that fails with nothing written is a failure. The log gets the error's domain
    /// and code and those of the error under it.
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let failure = error as NSError
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        Task { @MainActor in
            let end = RecordingEnd(failed: true, userStopped: (error as? SCStreamError)?.code == .userStopped, wroteFrames: output.recordedDuration > .zero,
                                   stopping: stopping || streamStopped, writeFailure: RecordingEnd.isWriteFailure(error))
            recordingLog.notice("""
                output failed, error \(failure.domain, privacy: .public) \(failure.code), under it \(underlying?.domain ?? "none", privacy: .public) \
                \(underlying?.code ?? 0), end \(String(describing: end), privacy: .public), stopping \(self.stopping), stream stopped \(self.streamStopped)
                """)
            if end == .partial { warning = error }
            finished(end == .failed ? error : nil)
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
            // Both take the control height, like the action strip, so they match.
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
        // A display that is gone has no visible frame; the whole display stands in, so the reminder still has a place.
        let visible = DisplayCapture.screen(for: displayID).map { screen in
            CGRect(x: screen.visibleFrame.minX - screen.frame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY,
                   width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        } ?? CGRect(origin: .zero, size: CGDisplayBounds(displayID).size)
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

    /// Delivers a finished recording that is already in the save folder: copies its file URL,
    /// then shows the toast with the first frame, whose Show in Finder reveals the file. A copy the pasteboard refuses shows a red toast,
    /// "Saved to ..., copy failed", never "Copied". A `warning` (the recording's own failure after it wrote frames) takes the detail line
    /// with an orange mark, so a recording cut short never passes for a complete one.
    static func deliver(_ file: URL, warning: (any Error)? = nil, pasteboard: NSPasteboard, defaults: UserDefaults) async throws -> CGImage {
        recordingLog.notice("deliver started")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero).image
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects([file as NSURL])
        recordingLog.notice("toast shown")
        let message = Output.message(copy: true, save: true, copied: copied, saved: true, folder: file.deletingLastPathComponent().lastPathComponent)
        let detail = !copied ? "The pasteboard did not accept the file."
            : warning.map { "The recording stopped early: \(($0 as NSError).localizedFailureReason ?? $0.localizedDescription)" } ?? file.lastPathComponent
        Toast.show(png: try await Output.png(frame), message: message, detail: detail, file: file,
                   color: !copied ? .systemRed : warning == nil ? nil : .systemOrange, defaults: defaults)
        return frame
    }

}
