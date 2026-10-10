import AppKit
import AVFoundation
import ScreenCaptureKit

/// A screen recording of one area of a display: H.264 at up to 60 fps with the cursor and no audio, written to a .mov by
/// `SCRecordingOutput`. Every Snug window, including ones opened while recording, is left out of the video.
@MainActor
final class ScreenRecording: NSObject, SCRecordingOutputDelegate {
    /// V hands the display and its area (display points, top-left origin, whole even pixels) here; the app starts the recording.
    /// Debug runs replace it.
    static var requested: (CGDirectDisplayID, CGRect) -> Void = { _, _ in }

    let file: URL
    let started = ContinuousClock.now
    /// Called on the main actor if the recording fails before `stop`.
    var onFailure: (any Error) -> Void = { _ in }
    private let stream: SCStream
    private var output: SCRecordingOutput!
    private let outline: NSPanel?
    /// The recording output's end: nil once the file is finished, or the error that ended it.
    private let ended: AsyncStream<(any Error)?>
    private let end: AsyncStream<(any Error)?>.Continuation
    private var stopping = false

    private init(file: URL, stream: SCStream, configuration: SCRecordingOutputConfiguration, outline: NSPanel?) throws {
        self.file = file
        self.stream = stream
        self.outline = outline
        (ended, end) = AsyncStream.makeStream()
        super.init()
        output = SCRecordingOutput(configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
    }

    /// Starts recording `area` of the display into `file`, with a thin accent outline just outside the area unless `showsOutline` is off.
    static func start(displayID: CGDirectDisplayID, area: CGRect, file: URL, showsOutline: Bool) async throws -> ScreenRecording {
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
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = file
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let outline = showsOutline ? makeOutline(around: area, on: displayID) : nil
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recording = try ScreenRecording(file: file, stream: stream, configuration: recordingConfiguration, outline: outline)
        try await stream.startCapture()
        return recording
    }

    /// Ends the recording and waits until the file is written.
    func stop() async throws {
        stopping = true
        outline?.orderOut(nil)
        try await stream.stopCapture()
        for await error in ended {
            if let error { throw error }
            return
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

    /// A click-through, borderless window with a 2 pt accent border drawn outside `area`.
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
