import AppKit
import ScreenCaptureKit
import ScreenshotCore

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

    /// One area of the display, `area` in display points with a top-left origin, at full pixel resolution, without Snug's windows.
    @concurrent
    static func image(of displayID: CGDirectDisplayID, area: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == displayID }!
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = Int((area.width * scale).rounded())
        configuration.height = Int((area.height * scale).rounded())
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
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        Pref.logHoverLine("window \(id) frame \(window.frame) contentRect \(info.contentRect) scale \(info.pointPixelScale) shadow \(shadow) "
                          + "configured \(configuration.width)x\(configuration.height) image \(image.width)x\(image.height)")
        return image
    }

    /// Window levels besides normal windows that are targets: the Dock, the menu bar, status items, and open menus.
    private static let systemLevels = [CGWindowLevelKey.dockWindow, .mainMenuWindow, .statusWindow, .popUpMenuWindow]
        .map { Int(CGWindowLevelForKey($0)) }

    /// Visible windows on a display, front to back: rectangles in image pixels with a top-left origin, titles
    /// (the owning app's name when a window has none), window IDs, and whether the window is a Dock, menu bar, or menu
    /// target that only the frozen capture can crop. Those are skipped when they cover the whole display, except the Dock, which
    /// (with Accessibility trusted) becomes its AXList union.
    @concurrent
    static func windows(on displayID: CGDirectDisplayID, pixelScale: CGFloat) async -> [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] {
        let display = CGDisplayBounds(displayID)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        var result: [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] = []
        for window in info {
            let layer = window[kCGWindowLayer as String] as! Int
            guard layer == 0 || systemLevels.contains(layer),
                  window[kCGWindowOwnerPID as String] as! Int32 != getpid(),
                  window[kCGWindowAlpha as String] as! Double > 0 else { continue }
            let bounds = CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)!
                .intersection(display)
            guard bounds.width >= 8, bounds.height >= 8 else { continue }
            let id = CGWindowID(window[kCGWindowNumber as String] as! Int)
            if layer != 0, bounds == display {
                // The Dock's only window can span the display; its real shape is the union of its AXLists.
                guard layer == Int(CGWindowLevelForKey(.dockWindow)), AXIsProcessTrusted(),
                      let dock = AccessibilityBounds.dockRect(
                        lists: await Accessibility.listFrames(pid: window[kCGWindowOwnerPID as String] as! Int32),
                        displayOrigin: display.origin, scale: pixelScale,
                        extent: CGRect(x: 0, y: 0, width: display.width * pixelScale, height: display.height * pixelScale)) else { continue }
                result.append((dock, "Dock", id, true))
                continue
            }
            let title = window[kCGWindowName as String] as? String
            result.append((CGRect(x: (bounds.minX - display.minX) * pixelScale, y: (bounds.minY - display.minY) * pixelScale,
                                  width: bounds.width * pixelScale, height: bounds.height * pixelScale),
                           title.flatMap { $0.isEmpty ? nil : $0 } ?? window[kCGWindowOwnerName as String] as? String ?? "Window",
                           id, layer != 0))
        }
        return result
    }
}
