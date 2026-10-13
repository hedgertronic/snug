import AppKit
import ScreenCaptureKit
import ScreenshotCore

/// Marks the windows Snug's own captures leave out: the overlay and the toast. Settings, About and First Run are not marked,
/// so they can be captured and hovered like any other window.
protocol CaptureExcluded {}

extension OverlayWindow: CaptureExcluded {}
extension Toast: CaptureExcluded {}

/// Captures the display under the pointer at full pixel resolution. Display shots take an `SCScreenshotConfiguration`: with an
/// `SCStreamConfiguration`, a display capture on macOS 27 leaves out every window's shadow (measured against `screencapture`), so a
/// window in front cast no shadow on the windows behind it.
enum DisplayCapture {
    /// The window IDs of Snug's marked windows.
    @MainActor
    static func excludedWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0 is CaptureExcluded }.map { CGWindowID($0.windowNumber) })
    }

    /// The display with the windows `excluded` (from `excludedWindowIDs`) left out.
    static func filter(for displayID: CGDirectDisplayID, in content: SCShareableContent, excluding excluded: Set<CGWindowID>) -> SCContentFilter {
        let display = content.displays.first { $0.displayID == displayID }!
        return SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
    }

    /// The display's current contents, sized from the stream's point-to-pixel scale.
    @concurrent
    static func image(of displayID: CGDirectDisplayID) async throws -> CGImage {
        let listing = signposter.beginInterval("shareable content")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        signposter.endInterval("shareable content", listing)
        let filter = filter(for: displayID, in: content, excluding: await excludedWindowIDs())
        let info = SCShareableContent.info(for: filter)
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        configuration.showsCursor = false
        let shot = signposter.beginInterval("screenshot")
        defer { signposter.endInterval("screenshot", shot) }
        return try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration).sdrImage!
    }

    /// One area of the display, `area` in display points with a top-left origin, at full pixel resolution, without Snug's windows.
    @concurrent
    static func image(of displayID: CGDirectDisplayID, area: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = filter(for: displayID, in: content, excluding: await excludedWindowIDs())
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = area
        configuration.width = Int((area.width * scale).rounded())
        configuration.height = Int((area.height * scale).rounded())
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration).sdrImage!
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

    /// Visible windows on a display, front to back: rectangles in image pixels with a top-left origin, titles
    /// (the owning app's name when a window has none), window IDs, and whether the window is a Dock, menu bar, or menu
    /// target that only the frozen capture can crop. Those are skipped when they cover the whole display, except the Dock, which
    /// (with Accessibility trusted) becomes its AXList union.
    @concurrent
    static func windows(on displayID: CGDirectDisplayID, pixelScale: CGFloat) async -> [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] {
        let display = CGDisplayBounds(displayID)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        let excluded = await excludedWindowIDs()
        var result: [(rect: CGRect, name: String, id: CGWindowID, frozen: Bool)] = []
        for window in info {
            let layer = window[kCGWindowLayer as String] as! Int
            guard layer == 0 || systemLevels.contains(layer),
                  !excluded.contains(CGWindowID(window[kCGWindowNumber as String] as! Int)),
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
