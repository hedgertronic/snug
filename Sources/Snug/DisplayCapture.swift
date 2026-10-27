import AppKit
import ScreenCaptureKit
import ScreenshotCore

/// Marks the windows Snug's own captures leave out: the overlay, the toast and its preview. Settings, About and First Run are not marked,
/// so they can be captured and hovered like any other window.
protocol CaptureExcluded {}

extension OverlayWindow: CaptureExcluded {}
extension Toast: CaptureExcluded {}
extension ToastPreview: CaptureExcluded {}

/// Captures the display under the pointer at full pixel resolution. Display shots take an `SCScreenshotConfiguration`: with an
/// `SCStreamConfiguration`, a display capture on macOS 27 leaves out every window's shadow (measured against `screencapture`), so a
/// window in front cast no shadow on the windows behind it.
enum DisplayCapture {
    /// The window IDs of Snug's marked windows.
    @MainActor
    static func excludedWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0 is CaptureExcluded }.map { CGWindowID($0.windowNumber) })
    }

    /// The screen showing `displayID`, nil once that display is gone.
    @MainActor
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }

    /// The display with Snug's windows left out but for its listed windows that are not `excluded` (from `excludedWindowIDs`): Settings,
    /// About. Leaving Snug out by application also covers a Snug window `content` does not list. Throws `CaptureError.displayUnavailable`
    /// when `content` no longer lists the display, as after it was disconnected.
    static func filter(for displayID: CGDirectDisplayID, in content: SCShareableContent, excluding excluded: Set<CGWindowID>) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayUnavailable }
        let pid = ProcessInfo.processInfo.processIdentifier
        let shown = content.windows.filter { $0.owningApplication?.processID == pid && !excluded.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == pid }, exceptingWindows: shown)
    }

    /// The display's current contents, sized from the stream's point-to-pixel scale.
    @concurrent
    static func image(of displayID: CGDirectDisplayID) async throws -> CGImage {
        let listing = signposter.beginInterval("shareable content")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        signposter.endInterval("shareable content", listing)
        let filter = try filter(for: displayID, in: content, excluding: await excludedWindowIDs())
        let info = SCShareableContent.info(for: filter)
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        configuration.showsCursor = false
        let shot = signposter.beginInterval("screenshot")
        defer { signposter.endInterval("screenshot", shot) }
        guard let image = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration).sdrImage else {
            throw CaptureError.noImage
        }
        return image
    }

    /// The display without Snug's windows (see `filter(for:in:excluding:)`), from the shareable content listed now. A scrolling capture
    /// builds it once and passes it to each `image(with:area:)`.
    @concurrent
    static func filter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try filter(for: displayID, in: content, excluding: await excludedWindowIDs())
    }

    /// One area of the display through `filter`, `area` in display points with a top-left origin, at full pixel resolution.
    @concurrent
    static func image(with filter: SCContentFilter, area: CGRect) async throws -> CGImage {
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = area
        configuration.width = Int((area.width * scale).rounded())
        configuration.height = Int((area.height * scale).rounded())
        configuration.showsCursor = false
        guard let image = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration).sdrImage else {
            throw CaptureError.noImage
        }
        return image
    }

    /// One window as macOS captures it: real rounded corners and, unless `shadow` is false, its shadow, on a transparent
    /// background, including parts other windows cover. With `interior` (the window cut from the frozen display), the window's opaque
    /// pixels are the frozen ones, so a translucent or blurred background looks as it did on screen. Needs Screen Recording.
    @concurrent
    static func image(ofWindow id: CGWindowID, shadow: Bool, interior: CGImage?) async throws -> CGImage {
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
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // With the shadow on, window and shadow are fitted into a canvas the window's size, so the window comes back shrunk (0.8 for a
        // 920 pt Finder window). The fully opaque bounding box against the canvas gives the shrink on each axis; when both agree, a
        // second capture on a canvas that much larger brings the window back at one pixel per device pixel. Translucent window content
        // can only shrink the box on one axis, so the axes disagree and the first capture stands.
        let pixels = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let alpha = pixels.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var (minX, minY, maxX, maxY) = (image.width, image.height, -1, -1)
        for y in 0..<image.height {
            for x in 0..<image.width where alpha[(y * image.width + x) * 4 + 3] == 255 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let shrinkX = Double(maxX - minX + 1) / Double(configuration.width), shrinkY = Double(maxY - minY + 1) / Double(configuration.height)
        if shadow, maxX >= 0, shrinkX > 0.5, shrinkX < 0.99, abs(shrinkX - shrinkY) < 0.01 {
            configuration.width = Int((Double(configuration.width) / shrinkX).rounded())
            configuration.height = Int((Double(configuration.height) / shrinkX).rounded())
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        Pref.logHoverLine("window \(id) frame \(window.frame) contentRect \(info.contentRect) scale \(info.pointPixelScale) shadow \(shadow) "
                          + "shrink \(shrinkX) x \(shrinkY) configured \(configuration.width)x\(configuration.height) image \(image.width)x\(image.height)")
        guard let interior else { return image }
        let filled = fillingWindowInterior(image, from: interior)
        Pref.logHoverLine("window \(id) interior \(interior.width)x\(interior.height) " + (filled == nil ? "size mismatch, captured pixels" : "frozen pixels"))
        return filled ?? image
    }

    /// Window levels besides normal windows that are targets: the Dock, the menu bar, status items, and open menus.
    private static let systemLevels = [CGWindowLevelKey.dockWindow, .mainMenuWindow, .statusWindow, .popUpMenuWindow]
        .map { Int(CGWindowLevelForKey($0)) }

    /// Visible windows on a display, front to back, leaving out `excluded` (from `excludedWindowIDs`): rectangles in image pixels
    /// with a top-left origin, titles (the owning app's name when a window has none), window IDs, and whether the window is a Dock,
    /// menu bar, or menu target that only the frozen capture can crop. Those are skipped when they cover the whole display, except
    /// the Dock, which (with Accessibility trusted) becomes its AXList union. Runs entirely off main.
    @concurrent
    static func windows(on displayID: CGDirectDisplayID, pixelScale: CGFloat, excluding excluded: Set<CGWindowID>) async -> [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] {
        let display = CGDisplayBounds(displayID)
        // The window server can answer nil, and a window's entry can lack a field; such a window is skipped.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] = []
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, let number = window[kCGWindowNumber as String] as? Int,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  let boundsInfo = window[kCGWindowBounds as String], CFGetTypeID(boundsInfo as CFTypeRef) == CFDictionaryGetTypeID(),
                  let rawBounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary) else { continue }
            guard layer == 0 || systemLevels.contains(layer), !excluded.contains(CGWindowID(number)), alpha > 0 else { continue }
            let bounds = rawBounds.intersection(display)
            guard bounds.width >= 8, bounds.height >= 8 else { continue }
            let id = CGWindowID(number)
            if layer != 0, bounds == display {
                // The Dock's only window can span the display; its real shape is the union of its AXLists.
                guard layer == Int(CGWindowLevelForKey(.dockWindow)), AXIsProcessTrusted(), let pid = window[kCGWindowOwnerPID as String] as? Int32,
                      let dock = AccessibilityBounds.dockRect(
                        lists: await Accessibility.listFrames(pid: pid),
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
