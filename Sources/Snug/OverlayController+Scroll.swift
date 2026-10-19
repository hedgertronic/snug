import AppKit
// The display's filter is built once and shared by every frame's capture; it never changes after it is built.
@preconcurrency import ScreenCaptureKit
import ScreenshotCore

/// Scrolling capture: G on a released selection or the hovered element inside one window shows the live screen in that area, lets
/// the pointer scroll the app underneath, and stitches the area's frames as its content moves. Return delivers, Esc cancels.
extension OverlayController {
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
        // The loop only captures and stitches; the display's filter is built once, and each frame's thumbnail is drawn in a task of its
        // own, which a newer frame's replaces.
        scrollTask = Task {
            do {
                let filter = scrollFrames == nil ? try await DisplayCapture.filter(for: displayID!) : nil
                let source = scrollFrames ?? { area in
                    try await DisplayCapture.image(with: filter!, area: CGRect(x: area.minX / scale, y: area.minY / scale, width: area.width / scale, height: area.height / scale))
                }
                let stitcher = ScrollStitcher(first: try await source(area))
                try Task.checkCancellation()
                self.stitcher = stitcher
                var shown = showStitched(stitcher, area: area)
                while true {
                    try await Task.sleep(for: .milliseconds(70))
                    if await stitcher.add(try await source(area)) {
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

    /// The stitched image takes the area's corner radii (Rounded, or edited with [ and ]) and Frame, as a crop of the area would.
    private func finishScroll() {
        guard let stitcher, let scrollArea else { return }
        let (scale, framed, radii, copy, save) = (scale, framed, cornerRadii(of: scrollArea), true, afterCaptureSaves)
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let image = await stitcher.image()
                try await Output.deliver(image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height), framed: framed, scale: scale,
                                         cornerRadii: radii, copy: copy, save: save, pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }
}
