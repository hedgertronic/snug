import AppKit
import ApplicationServices
import ScreenshotCore

/// Live accessibility lookups for Capture hover and snap. Nothing here prompts; `requestTrust()` is the only prompt and runs from a click.
enum Accessibility {
    private static let messagingTimeout: Float = 0.1
    private static let maxDepth = 24
    /// The longest the peers of one lookup take to read; a slow app gets the peers it answered for.
    private static let peerBudget = Duration.milliseconds(100)
    /// The longest a walk down from the window by frames takes; a slow app gets the depth it reached.
    private static let walkBudget = Duration.milliseconds(100)

    /// The frames of the element at `point` (global points, top-left origin) in `pid`'s app and its parents up to the window,
    /// innermost first, each with its role, title, subrole, identifier and description. When the hit test's answer and its parents are
    /// all unhoverable inside a window (`AccessibilityBounds.hoverLevel` is empty), the chain is instead the window walked down by
    /// frames to the deepest element containing `point`.
    /// Empty without permission, on a timeout, when nothing is there, or for Snug's own windows: AX against
    /// its own pid runs in this process, off main, and AppKit's hit test there trips the MainActor isolation check.
    @concurrent
    static func frames(at point: CGPoint, pid: pid_t) async -> [AXFrame] {
        chain(at: point, pid: pid).map(\.frame)
    }

    /// `frames(at:pid:)` and, with them, the chains of the hovered element's peers (see `peers(of:)`).
    @concurrent
    static func framesAndPeers(at point: CGPoint, pid: pid_t) async -> (frames: [AXFrame], peers: [[AXFrame]]) {
        let chain = chain(at: point, pid: pid)
        return (chain.map(\.frame), peers(of: chain))
    }

    private static func chain(at point: CGPoint, pid: pid_t) -> [(element: AXUIElement, frame: AXFrame)] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return [] }
        var chain: [(element: AXUIElement, frame: AXFrame)] = []
        for _ in 0..<maxDepth {
            guard let frame = frame(of: element) else { break }
            chain.append((element, frame))
            var parent: CFTypeRef?
            guard frame.role != kAXWindowRole, AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            element = parent as! AXUIElement
        }
        // Safari can report a page's frames a screen height off (`AccessibilityBounds.displacement`): moved back, or dropped when that
        // does not put the hit under the pointer.
        if let displaced = AccessibilityBounds.displacement(chain.map(\.frame), at: point) {
            if let offset = displaced.offset {
                for index in 0...displaced.through { chain[index].frame = chain[index].frame.translated(by: offset) }
            } else {
                chain.removeFirst(displaced.through + 1)
            }
        }
        guard AccessibilityBounds.hoverLevel(chain.map(\.frame)).isEmpty, let window = chain.last, window.frame.role == kAXWindowRole else { return chain }
        // Finder's column view can answer with its AXBrowser, 1 pt past the window on every side and spanning the sidebar, which is a
        // sibling of the browser's split group. Then the window is walked down by frames: at each level, the smallest child that contains the point.
        var path = [window]
        let began = ContinuousClock.now
        while path.count < maxDepth, began.duration(to: .now) < walkBudget, let children = children(of: path.last!.element, kAXChildrenAttribute),
              let smallest = children.compactMap({ child in frame(of: child).map { (element: child, frame: $0) } })
                  .filter({ $0.frame.rect.contains(point) }).min(by: { $0.frame.rect.width * $0.frame.rect.height < $1.frame.rect.width * $1.frame.rect.height }) {
            path.append(smallest)
        }
        return path.reversed()
    }

    /// The chains of the peers of the hovered element in `chain`: the other children of the container (`AXRows` for an outline or a
    /// table, else `AXChildren`) around the hovered element's padding-collapsed run, at most `AccessibilityBounds.maximumPeers`
    /// around it and for at most `peerBudget`. Each is the sibling's frames, innermost first, collapsed to its single padded-in
    /// child as hover collapses a row to its cell, then the container's ancestors. Empty when nothing hovers or it has no container.
    static func peers(of chain: [(element: AXUIElement, frame: AXFrame)]) -> [[AXFrame]] {
        let frames = chain.map(\.frame)
        guard let level = AccessibilityBounds.peerLevel(frames), level + 1 < chain.count,
              let siblings = children(of: chain[level + 1].element, [kAXOutlineRole, kAXTableRole].contains(frames[level + 1].role) ? kAXRowsAttribute : kAXChildrenAttribute)
        else { return [] }
        let start = max(0, min((siblings.firstIndex { CFEqual($0, chain[level].element) } ?? 0) - AccessibilityBounds.maximumPeers / 2, siblings.count - AccessibilityBounds.maximumPeers))
        // A displaced chain was moved back (see `chain(at:pid:)`); its siblings are displaced the same way.
        let live = frame(of: chain[level].element)!.rect
        let shift = CGSize(width: frames[level].rect.minX - live.minX, height: frames[level].rect.minY - live.minY)
        let began = ContinuousClock.now
        var chains: [[AXFrame]] = []
        for sibling in siblings[start..<min(siblings.count, start + AccessibilityBounds.maximumPeers)] where !CFEqual(sibling, chain[level].element) {
            guard began.duration(to: .now) < peerBudget else { break }
            guard let frame = frame(of: sibling)?.translated(by: shift) else { continue }
            var down = [frame]
            var element = sibling
            while let only = children(of: element, kAXChildrenAttribute), only.count == 1, let child = self.frame(of: only[0])?.translated(by: shift),
                  child.rect.isNear(down.last!.rect, within: AccessibilityBounds.paddingTolerance) {
                down.append(child)
                element = only[0]
            }
            chains.append(down.reversed() + frames[(level + 1)...])
        }
        return chains
    }

    private static func frame(of element: AXUIElement) -> AXFrame? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard let position = value(kAXPositionAttribute, of: element, type: .cgPoint, as: CGPoint.zero),
              let size = value(kAXSizeAttribute, of: element, type: .cgSize, as: CGSize.zero) else { return nil }
        var description: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &description)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        var identifier: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
        var elementDescription: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &elementDescription)
        return AXFrame(roleDescription: description as? String ?? "", rect: CGRect(origin: position, size: size), role: role as? String ?? "", title: title as? String ?? "",
                       subrole: subrole as? String ?? "", identifier: identifier as? String ?? "", elementDescription: elementDescription as? String ?? "")
    }

    private static func children(of element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var children: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &children) == .success ? children as? [AXUIElement] : nil
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
