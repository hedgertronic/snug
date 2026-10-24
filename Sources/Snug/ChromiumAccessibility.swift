import AppKit
import ApplicationServices
import ScreenshotCore
import Synchronization

/// Chromium-based apps give accessibility only the basic tree (no word boxes) until the app is asked to turn its accessibility on,
/// which it keeps until it quits. Text mode asks for the apps with a window on its display (`OverlayController.enableChromiumText`).
enum ChromiumAccessibility {
    private static let detected = Mutex<[URL: Bool]>([:])

    /// Whether the app at `bundle` embeds Chromium (`ChromiumText.embedsChromium` over its Frameworks folder), cached per bundle URL.
    static func isChromium(bundle: URL) -> Bool {
        detected.withLock { cache in
            if let known = cache[bundle] { return known }
            let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appending(path: "Contents/Frameworks").path)) ?? []
            let chromium = ChromiumText.embedsChromium(frameworks: frameworks)
            cache[bundle] = chromium
            return chromium
        }
    }

    /// The pids of the Chromium apps with a window on screen that meets `display` (global points, top-left origin). Empty without
    /// Accessibility, which both turning it on and reading it need.
    @concurrent
    static func owners(on display: CGRect) async -> [pid_t] {
        guard AXIsProcessTrusted() else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pids = Set(info.filter {
            $0[kCGWindowLayer as String] as? Int == 0 && CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)!.intersects(display)
        }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        return pids.filter { $0 != getpid() && NSRunningApplication(processIdentifier: $0)?.bundleURL.map(isChromium) == true }.sorted()
    }

    /// Turns on `pid`'s accessibility with Electron's light switch, `AXManualAccessibility`. An app whose setter answers that the
    /// attribute is unsupported gets `AXEnhancedUserInterface` instead, which can disturb window managers' animations (untested on
    /// any app). The app takes about two seconds to build what word boxes need.
    @concurrent
    static func enable(pid: pid_t) async {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        if AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .attributeUnsupported {
            AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
