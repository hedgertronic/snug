import AppKit
import ScreenCaptureKit

/// Captures the display under the pointer at full pixel resolution.
enum DisplayCapture {
    /// The display's current contents, sized from the stream's point-to-pixel scale.
    @concurrent
    static func image(of displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == displayID }!
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let info = SCShareableContent.info(for: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// One window as macOS captures it: real rounded corners and, unless `shadow` is false, its shadow, on a transparent
    /// background, including parts other windows cover. Needs Screen Recording.
    @concurrent
    static func image(ofWindow id: CGWindowID, shadow: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        configuration.shouldBeOpaque = false
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.ignoreShadowsSingleWindow = !shadow
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Window levels besides normal windows that are targets: the Dock, the menu bar, status items, and open menus.
    private static let systemLevels = [CGWindowLevelKey.dockWindow, .mainMenuWindow, .statusWindow, .popUpMenuWindow]
        .map { Int(CGWindowLevelForKey($0)) }

    /// Visible windows on a display, front to back: rectangles in image pixels with a top-left origin, titles
    /// (the owning app's name when a window has none), window IDs, and whether the window is a Dock, menu bar, or menu
    /// target that only the frozen capture can crop. Those are skipped when they cover the whole display.
    @concurrent
    static func windows(on displayID: CGDirectDisplayID, pixelScale: CGFloat) async -> [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] {
        let display = CGDisplayBounds(displayID)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        return info.compactMap { window in
            let layer = window[kCGWindowLayer as String] as! Int
            guard layer == 0 || systemLevels.contains(layer),
                  window[kCGWindowOwnerPID as String] as! Int32 != getpid(),
                  window[kCGWindowAlpha as String] as! Double > 0 else { return nil }
            let bounds = CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)!
                .intersection(display)
            guard bounds.width >= 8, bounds.height >= 8, layer == 0 || bounds != display else { return nil }
            let title = window[kCGWindowName as String] as? String
            return (CGRect(x: (bounds.minX - display.minX) * pixelScale, y: (bounds.minY - display.minY) * pixelScale,
                           width: bounds.width * pixelScale, height: bounds.height * pixelScale),
                    title.flatMap { $0.isEmpty ? nil : $0 } ?? window[kCGWindowOwnerName as String] as? String ?? "Window",
                    CGWindowID(window[kCGWindowNumber as String] as! Int), layer != 0)
        }
    }
}
