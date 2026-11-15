import AppKit
import ScreenshotCore

/// The window server's answer to "what was this capture of": the owning app's name and the window's title.
enum CaptureSource {
    /// The app and title of window `id`; nil when the window server no longer lists it.
    static func context(windowID id: CGWindowID) -> CaptureContext? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first.flatMap(context)
    }

    /// The app and title of the frontmost ordinary window (layer 0, not Snug's own) whose bounds hold `point`, in global top-left
    /// coordinates; nil over the desktop.
    static func context(at point: CGPoint) -> CaptureContext? {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.first { window in
            guard window[kCGWindowLayer as String] as? Int == 0, window[kCGWindowOwnerPID as String] as? Int32 != own,
                  let bounds = window[kCGWindowBounds as String], CFGetTypeID(bounds as CFTypeRef) == CFDictionaryGetTypeID(),
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { return false }
            return rect.contains(point)
        }.flatMap(context)
    }

    private static func context(_ info: [String: Any]) -> CaptureContext? {
        let app = (info[kCGWindowOwnerName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return app == nil && title == nil ? nil : CaptureContext(app: app, title: title)
    }
}
