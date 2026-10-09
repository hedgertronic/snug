import AppKit
import ScreenshotCore

/// Accessibility frames as snap targets in Area mode.
extension OverlayController {
    /// The frames (image pixels) of the elements at the center and corners of `rect`, from the apps under those points.
    /// Only live captures with Accessibility allowed ask; debug runs use `snapFrameSource`. No permission, a timeout, or no
    /// elements gives no frames.
    func snapFrames(around rect: CGRect) async throws -> [CGRect] {
        if let snapFrameSource { return await snapFrameSource(rect) }
        guard displayID != nil, !isHeadless, AXIsProcessTrusted() else { return [] }
        let origin = CGPoint(x: window.frame.minX, y: NSScreen.screens[0].frame.height - window.frame.maxY)
        let inner = rect.insetBy(dx: min(3 * scale, rect.width / 4), dy: min(3 * scale, rect.height / 4))
        var fits: [CGRect] = []
        for pixel in [CGPoint(x: inner.midX, y: inner.midY), CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                      CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
            guard let index = windows.firstIndex(where: { $0.contains(pixel) }), windowIDs.indices.contains(index),
                  let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowIDs[index]) as? [[String: Any]],
                  let pid = info.first?[kCGWindowOwnerPID as String] as? Int32 else { continue }
            // Each point's chain is clipped and collapsed on its own: viewports and padding only make sense within one chain.
            let frames = await Accessibility.frames(at: AccessibilityBounds.point(forPixel: pixel, displayOrigin: origin, scale: scale), pid: pid)
            if Task.isCancelled { return [] }
            fits += try await AccessibilityBounds.candidates(frames: frames, displayOrigin: origin, scale: scale, extent: extent).map(\.bounds)
        }
        return fits
    }
}
