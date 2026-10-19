import AppKit
import ScreenshotCore

/// Scrolling capture: G on a released selection or the hovered element inside one window shows the live screen in that area, lets
/// the pointer scroll the app underneath, and stitches the area's frames as its content moves. Return delivers, Esc cancels.
extension OverlayController {
    func startScroll() {
        let scale = scale
        let live = displayID.map { id in { (area: CGRect) in
            try await DisplayCapture.image(of: id, area: CGRect(x: area.minX / scale, y: area.minY / scale, width: area.width / scale, height: area.height / scale))
        } }
        guard let area = selection?.rect ?? hoverRect, let source = scrollFrames ?? live,
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
        scrollTask = Task {
            do {
                let stitcher = ScrollStitcher(first: try await source(area))
                self.stitcher = stitcher
                await showStitched(stitcher)
                while true {
                    try await Task.sleep(for: .milliseconds(70))
                    if await stitcher.add(try await source(area)) { await showStitched(stitcher) }
                }
            } catch is CancellationError {
            } catch {
                report(error)
            }
        }
    }

    /// The stitched height and a thumbnail that fits beside the area: at most 72 pt wide and 16 pt shorter than the area.
    private func showStitched(_ stitcher: ScrollStitcher) async {
        scrollThumbnail = await stitcher.thumbnail(fitting: CGSize(width: 72 * scale, height: scrollArea!.height - 16 * scale))
        scrollHeight = await stitcher.height
        refresh()
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
