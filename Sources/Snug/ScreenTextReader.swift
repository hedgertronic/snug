import AppKit
import ScreenshotCore

/// Reads the text apps expose through accessibility as `ScreenText` in global points, for Text mode to select instead of OCR. Each app
/// goes to the reader for its kind; an app none reads keeps Live Text and OCR.
enum ScreenTextReader {
    /// The text of every app with a window on screen, read at once, each app's areas in global points (window 0 until
    /// `OverlayController.setScreenTexts` places them). The capture starts this as it grabs the pixels.
    @concurrent
    static func read() async -> [(pid: pid_t, texts: [ScreenText])] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pids = Set(info.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        return await withTaskGroup(of: (pid: pid_t, texts: [ScreenText]).self) { group in
            for pid in pids where pid != getpid() {
                group.addTask { (pid, await texts(pid: pid, bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")) }
            }
            return await group.reduce(into: []) { if !$1.texts.isEmpty { $0.append($1) } }
        }
    }

    /// One app's text areas, by the reader for its kind.
    static func texts(pid: pid_t, bundle: String) async -> [ScreenText] {
        if Accessibility.terminalApps.contains(bundle) {
            return await Accessibility.terminalRows(pid: pid).map { ScreenText.grid(rows: $0.rows, frame: $0.frame, window: 0) }
        }
        if webKitApps.contains(bundle) { return await webKitTexts(pid: pid) }
        return []
    }
}
