import AppKit
import ApplicationServices
import ScreenshotCore

/// Live accessibility lookups for Capture hover and snap. Nothing here prompts; `requestTrust()` is the only prompt and runs from a click.
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
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            frames.append(AXFrame(roleDescription: description as? String ?? "", rect: CGRect(origin: position, size: size), role: role as? String ?? "",
                                  title: title as? String ?? ""))
            var parent: CFTypeRef?
            guard role as? String != kAXWindowRole, AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            element = parent as! AXUIElement
        }
        return frames
    }

    /// The frames (global points, top-left origin) of the top-level `AXList` elements of `pid`'s app; for the Dock, its icon strips.
    /// Empty without permission or on a timeout.
    @concurrent
    static func listFrames(pid: pid_t) async -> [CGRect] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return [] }
        return children.compactMap { child in
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole,
                  let position = value(kAXPositionAttribute, of: child, type: .cgPoint, as: CGPoint.zero),
                  let size = value(kAXSizeAttribute, of: child, type: .cgSize, as: CGSize.zero) else { return nil }
            return CGRect(origin: position, size: size)
        }
    }

    /// The titles of the Dock's items (separators excluded) in list order, top to bottom or left to right. Empty without permission or on a timeout.
    @concurrent
    static func dockItemTitles(pid: pid_t) async -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var lists: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &lists) == .success,
              let lists = lists as? [AXUIElement] else { return [] }
        return lists.flatMap { list -> [String] in
            AXUIElementSetMessagingTimeout(list, messagingTimeout)
            var items: CFTypeRef?
            AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items)
            return (items as? [AXUIElement] ?? []).compactMap { item in
                AXUIElementSetMessagingTimeout(item, messagingTimeout)
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subrole)
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
                return subrole as? String == "AXSeparatorDockItem" ? nil : title as? String ?? ""
            }
        }
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
