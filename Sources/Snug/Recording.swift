import AppKit
import AVFoundation
import ScreenCaptureKit

extension Pref {
    /// Seconds of the count shown over the area before a recording starts: 0 (off), 3 or 5; C cycles it while armed.
    static let recordCountIn = "SnugRecordCountIn"
    /// Whether recordings show the cursor; H switches it while armed.
    static let recordCursor = "SnugRecordCursor"
}

/// A screen recording of one area of a display: H.264 at up to 60 fps, with or without the cursor, and no audio, written to a .mov by
/// `SCRecordingOutput`. Every Snug window, including ones opened while recording, is left out of the video.
@MainActor
final class ScreenRecording: NSObject, SCRecordingOutputDelegate {
    /// The armed overlay hands the display, its area (display points, top-left origin, whole even pixels) and whether the cursor
    /// shows here once the count-in ends; the app starts the recording. Debug runs replace it.
    static var requested: (CGDirectDisplayID, CGRect, Bool) -> Void = { _, _, _ in }
    /// How long `stop` waits for the recording output to finish the file before it fails.
    nonisolated static let finishTimeout = Duration.seconds(5)

    let file: URL
    let started = ContinuousClock.now
    /// Called on the main actor if the recording fails before `stop`.
    var onFailure: (any Error) -> Void = { _ in }
    private let stream: SCStream
    private var output: SCRecordingOutput!
    private var outline: NSPanel?
    /// The recording output's end: nil once the file is finished, or the error that ended it.
    private let ended: AsyncStream<(any Error)?>
    private let end: AsyncStream<(any Error)?>.Continuation
    private var stopping = false

    private init(file: URL, stream: SCStream, configuration: SCRecordingOutputConfiguration) throws {
        self.file = file
        self.stream = stream
        (ended, end) = AsyncStream.makeStream()
        super.init()
        output = SCRecordingOutput(configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
    }

    /// Starts recording `area` of the display into `file`, with a thin accent outline just outside the area that pulses once as
    /// capture starts, unless `showsOutline` is off.
    static func start(displayID: CGDirectDisplayID, area: CGRect, file: URL, showsCursor: Bool, showsOutline: Bool) async throws -> ScreenRecording {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = content.displays.first { $0.displayID == displayID }!
        let snug = content.applications.first { $0.processID == getpid() }!
        let filter = SCContentFilter(display: display, excludingApplications: [snug], exceptingWindows: [])
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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recording = try ScreenRecording(file: file, stream: stream, configuration: recordingConfiguration)
        try await stream.startCapture()
        // Shown only once capture runs, so a failed start leaves nothing on screen; the app-wide exclusion keeps it out of the video.
        if showsOutline { recording.outline = makeOutline(around: area, on: displayID) }
        return recording
    }

    /// Ends the recording and waits until the file is written, or fails after `finishTimeout`.
    func stop() async throws {
        stopping = true
        outline?.orderOut(nil)
        // A failed stop ends the wait with its error; a stop that never returns is caught by the timeout.
        Task { [stream, end] in
            do { try await stream.stopCapture() } catch { end.yield(error) }
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

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in finished(nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in finished(error) }
    }

    private func finished(_ error: (any Error)?) {
        end.yield(error)
        if let error, !stopping {
            outline?.orderOut(nil)
            onFailure(error)
        }
    }

    /// A click-through, borderless window with a 2 pt accent border drawn outside `area`, flashing once as it appears.
    private static func makeOutline(around area: CGRect, on displayID: CGDirectDisplayID) -> NSPanel {
        let bounds = CGDisplayBounds(displayID)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let inset: CGFloat = 3
        let frame = CGRect(x: bounds.minX + area.minX - inset, y: primaryHeight - (bounds.minY + area.maxY) - inset,
                           width: area.width + 2 * inset, height: area.height + 2 * inset)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let border = NSView(frame: CGRect(origin: .zero, size: frame.size))
        border.wantsLayer = true
        border.layer!.borderWidth = 2
        border.layer!.borderColor = NSColor.controlAccentColor.cgColor
        border.layer!.cornerRadius = 4
        panel.contentView = border
        panel.orderFrontRegardless()
        // The start cue: the outline flashes once.
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0.25, 1]
        pulse.duration = 0.5
        border.layer!.add(pulse, forKey: "pulse")
        return panel
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
