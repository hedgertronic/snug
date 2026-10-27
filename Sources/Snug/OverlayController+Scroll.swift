import AppKit
// The display's filter is built once and shared by every frame's capture; it never changes after it is built.
@preconcurrency import ScreenCaptureKit
import ScreenshotCore

/// Scrolling capture: G on a released selection or the hovered element inside one window shows the live screen in that area, lets
/// the pointer scroll the app underneath, and stitches the area's frames as its content moves. Return delivers, Esc cancels.
extension OverlayController {
    /// The most scroll and drag events kept before the old ones are dropped.
    static let scrollInputLimit = 256

    func startScroll() {
        let (scale, displayID, scrollFrames) = (scale, displayID, scrollFrames)
        guard let area = selection?.rect ?? hoverRect, scrollFrames != nil || displayID != nil,
              windows.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(area) }), area != extent else { return beep() }
        cancelWork()
        detectionTask?.cancel()
        detectionTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
        selection = nil
        session = nil
        scrollArea = area
        // The live screen shows through: no frozen image, a clear window, and the pointer's scrolling reaches the app below.
        view.image = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        refresh()
        // The pointer's scrolling and dragging go to the app below; a global monitor sees a copy of each event.
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollInput = []
        // Only the last half second decides whether a frame moved, and the log takes events as each frame comes, so events over two
        // seconds old go once there are more than `scrollInputLimit`.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollInput.append(event)
                if self.scrollInput.count > Self.scrollInputLimit { self.scrollInput.removeAll { $0.timestamp < event.timestamp - 2 } }
            }
        }
        // The loop only captures and stitches; the display's filter is built once, and each frame's thumbnail is drawn in a task of its
        // own, which a newer frame's replaces.
        let log = defaults.bool(forKey: Pref.logScroll)
            ? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Snug/scroll/\(Date.now.ISO8601Format())") : nil
        scrollTask = Task {
            do {
                let filter = scrollFrames == nil ? try await DisplayCapture.filter(for: displayID!) : nil
                let capture = scrollFrames ?? { area in
                    try await DisplayCapture.image(with: filter!, area: CGRect(x: area.minX / scale, y: area.minY / scale, width: area.width / scale, height: area.height / scale))
                }
                // The log holds each frame as a PNG, and in events.txt each event since the frame before it and the frame's time, all
                // in seconds of system uptime: "scroll <time> <delta y> <precise> <phase> <momentum phase>", "drag <time>",
                // "frame <index> <time>".
                let events = log?.appending(path: "events.txt")
                if let log, let events {
                    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
                    try Data().write(to: events)
                }
                var (logged, loggedUntil) = (0, TimeInterval(0))
                let source: (CGRect) async throws -> (CGImage, TimeInterval) = { area in
                    let frame = try await capture(area)
                    let time = ProcessInfo.processInfo.systemUptime
                    if let log, let events {
                        let input = self.scrollInput.filter { $0.timestamp > loggedUntil }.map { event in
                            event.type == .scrollWheel
                                ? "scroll \(event.timestamp) \(event.scrollingDeltaY) \(event.hasPreciseScrollingDeltas) \(event.phase.rawValue) \(event.momentumPhase.rawValue)\n"
                                : "drag \(event.timestamp)\n"
                        }
                        loggedUntil = self.scrollInput.last?.timestamp ?? loggedUntil
                        let file = try FileHandle(forWritingTo: events)
                        try file.seekToEnd()
                        try file.write(contentsOf: Data((input.joined() + String(format: "frame %04d \(time)\n", logged)).utf8))
                        try file.close()
                        try await Output.png(frame).write(to: log.appending(path: String(format: "%04d.png", logged)))
                        logged += 1
                    }
                    return (frame, time)
                }
                let (first, _) = try await source(area)
                let stitcher = ScrollStitcher(first: first)
                try Task.checkCancellation()
                self.stitcher = stitcher
                var shown = showStitched(stitcher, area: area)
                while true {
                    try await Task.sleep(for: .milliseconds(70))
                    let (frame, time) = try await source(area)
                    // Live, once the monitor has seen an event: a frame with no scrolling or dragging in the last half second only
                    // animated in place. The events' sizes are not used: apps scroll by their own amount per delta (Google Sheets by
                    // whole rows) and bounce back against them at the end of a page.
                    if scrollFrames == nil, !scrollInput.isEmpty, !scrollInput.contains(where: { $0.timestamp > time - 0.5 }) { continue }
                    if await stitcher.add(frame) {
                        shown.cancel()
                        shown = showStitched(stitcher, area: area)
                    }
                }
            } catch is CancellationError {
            } catch {
                report(error)
            }
        }
    }

    /// Shows the stitched height and a thumbnail that fits beside the area, at most 72 pt wide and 16 pt shorter than it, unless the
    /// task is cancelled or the capture has ended by then.
    private func showStitched(_ stitcher: ScrollStitcher, area: CGRect) -> Task<Void, Never> {
        Task {
            let height = await stitcher.height
            let thumbnail = await stitcher.thumbnail(fitting: CGSize(width: 72 * scale, height: area.height - 16 * scale))
            guard !Task.isCancelled, self.stitcher === stitcher else { return }
            (scrollHeight, scrollThumbnail) = (height, thumbnail)
            refresh()
        }
    }

    /// While scrolling: Return delivers the stitched image, Esc closes; other keys do nothing.
    func handleScrollKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: dismiss()
        case 36, 76: finishScroll()
        default: break
        }
        return true
    }

    /// The stitched image takes the area's corner radii (Rounded, or edited with [ and ]) and Frame, as a crop of the area would. When rows
    /// joined after two frames disagreed on them, the toast says the image may be wrong there.
    private func finishScroll() {
        guard let stitcher, let scrollArea else { return }
        let (scale, padding, radii, shadow) = (scale, framed ? framePadding : nil, cornerRadii(of: scrollArea), frameShadow)
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let (image, unmatched) = (await stitcher.image(), await stitcher.unmatchedRows)
                try await Output.deliver(image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height), padding: padding, scale: scale,
                                         cornerRadii: radii, shadow: shadow, copy: true, save: false,
                                         warning: unmatched > 0 ? "Pinned or moving content: \(unmatched) px may repeat" : nil,
                                         pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }
}
