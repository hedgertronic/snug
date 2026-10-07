import AppKit
import ApplicationServices
import ScreenshotCore

/// Live accessibility lookups for Element mode. Nothing here prompts; `requestTrust()` is the only prompt and runs from a click.
enum Accessibility {
    private static let messagingTimeout: Float = 0.1
    private static let maxDepth = 24

    /// The frames of the element at `point` (global points, top-left origin) in `pid`'s app and its parents up to the window,
    /// innermost first. Empty without permission, on a timeout, or when nothing is there.
    @concurrent
    static func frames(at point: CGPoint, pid: pid_t) async -> [AXFrame] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return [] }
        var frames: [AXFrame] = []
        for _ in 0..<maxDepth {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let position = value(kAXPositionAttribute, of: element, type: .cgPoint, as: CGPoint.zero),
                  let size = value(kAXSizeAttribute, of: element, type: .cgSize, as: CGSize.zero) else { break }
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &description)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            frames.append(AXFrame(roleDescription: description as? String ?? "", rect: CGRect(origin: position, size: size), role: role as? String ?? ""))
            var parent: CFTypeRef?
            guard role as? String != kAXWindowRole, AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            element = parent as! AXUIElement
        }
        return frames
    }

    private static func value<T>(_ attribute: String, of element: AXUIElement, type: AXValueType, as seed: T) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        var result = seed
        return AXValueGetValue(raw as! AXValue, type, &result) ? result : nil
    }

    /// Shows the system's Accessibility prompt. Call only from a user click in a live (non-headless) overlay.
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
