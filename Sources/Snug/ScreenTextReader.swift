import AppKit
import ScreenshotCore

/// Reads the text apps expose through accessibility as `ScreenText` in global points, for Text mode to select instead of OCR. Each app
/// goes to the reader for its kind; an app none reads keeps Live Text and OCR.
enum ScreenTextReader {
    /// The text of every app with a window on screen, read at once, each app's areas in global points (window 0 until
    /// `OverlayController.setScreenTexts` places them). The capture starts this as it grabs the pixels. `chromium` is the Chromium
    /// apps Snug turned accessibility on for; no other is read, so reading never wakes an app's accessibility.
    @concurrent
    static func read(chromium: Set<pid_t>) async -> [(pid: pid_t, texts: [ScreenText])] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pids = Set(info.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        return await withTaskGroup(of: (pid: pid_t, texts: [ScreenText]).self) { group in
            // A Chromium app Snug has not turned on is not read at all: any reader would wake its accessibility.
            for pid in pids where pid != getpid() {
                let app = NSRunningApplication(processIdentifier: pid)
                guard chromium.contains(pid) || app?.bundleURL.map(ChromiumAccessibility.isChromium) != true else { continue }
                group.addTask { (pid, await texts(pid: pid, bundle: app?.bundleIdentifier ?? "", chromium: chromium.contains(pid))) }
            }
            return await group.reduce(into: []) { if !$1.texts.isEmpty { $0.append($1) } }
        }
    }

    /// One app's text areas, by the readers for its kind: a Chromium app's web areas, a terminal's grid, or its native text and, in a
    /// WebKit app, its web content.
    static func texts(pid: pid_t, bundle: String, chromium: Bool) async -> [ScreenText] {
        if chromium { return await chromiumTexts(pid: pid) }
        if Accessibility.terminalApps.contains(bundle) {
            return await Accessibility.terminalRows(pid: pid).map { ScreenText.grid(rows: $0.rows, frame: $0.frame, window: 0) }
        }
        // A window's native text and its web content are read at once; the native reader skips web areas.
        async let web = webKitApps.contains(bundle) ? webKitTexts(pid: pid) : []
        return await native(pid: pid) + web
    }
}
