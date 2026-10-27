import AppKit
import ApplicationServices
import ScreenshotCore

/// Live accessibility lookups for Capture hover and snap. Nothing here prompts; `requestTrust()` is the only prompt and runs from a click.
enum Accessibility {
    static let messagingTimeout: Float = 0.1
    static let maxDepth = 24
    /// The longest the peers of one lookup take to read; a slow app gets the peers it answered for.
    private static let peerBudget = Duration.milliseconds(100)
    /// The longest a walk down from the window by frames takes; a slow app gets the depth it reached.
    private static let walkBudget = Duration.milliseconds(100)

    /// The frames of the element at `point` (global points, top-left origin) in `pid`'s app and its parents up to the window,
    /// innermost first, each with its role, title, subrole, identifier and description. When the hit test's answer and its parents are
    /// all unhoverable inside a window (`AccessibilityBounds.hoverLevel` is empty), the chain is instead the window walked down by
    /// frames to the deepest element containing `point`. A sidebar's full panel is added above its scroll area (`sidebarFrames`).
    /// Empty without permission, on a timeout, when nothing is there, or for Snug's own windows: AX against
    /// its own pid runs in this process, off main, and AppKit's hit test there trips the MainActor isolation check.
    @concurrent
    static func frames(at point: CGPoint, pid: pid_t) async -> [AXFrame] {
        sidebarFrames(chain(at: point, pid: pid))
    }

    /// `frames(at:pid:)` and, with them, the chains of the hovered element's peers (see `peers(of:)`).
    @concurrent
    static func framesAndPeers(at point: CGPoint, pid: pid_t) async -> (frames: [AXFrame], peers: [[AXFrame]]) {
        let chain = chain(at: point, pid: pid)
        return (sidebarFrames(chain), peers(of: chain))
    }

    /// `frames(at:pid:)` for Copy for Agent, with `details`: the element `HandoffManifest.Target.match` picks for `crop` gets its
    /// `HandoffManifest.Details`, its first children and nearest siblings read for at most `peerBudget`, and every element inside a web
    /// area its DOM id and classes. Also the window's `AXDocument` and the innermost web area's `AXURL` and `AXTitle`. Only the
    /// elements at `point`, the target's label element, children and siblings are read, in `pid`'s app; a window's siblings, the app's
    /// other windows, are not, nor a secure text field's value.
    @concurrent
    static func handoff(at point: CGPoint, pid: pid_t, crop: CGRect, display: CGRect, tolerance: CGFloat) async
        -> (frames: [AXFrame], document: String?, url: String?, pageTitle: String?) {
        let chain = chain(at: point, pid: pid)
        var frames = sidebarFrames(chain)
        // The sidebar panel `sidebarFrames` adds has no element.
        let elements = frames.map { frame in chain.first { $0.frame == frame }?.element }
        func read(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        func text(_ attribute: String, of element: AXUIElement) -> String? {
            let value = read(attribute, of: element)
            return value as? String ?? (value as? URL)?.absoluteString ?? (value as? NSNumber)?.stringValue
        }
        let web = frames.firstIndex { $0.role == "AXWebArea" }
        for index in frames.indices where index < web ?? 0 {
            guard let element = elements[index] else { continue }
            frames[index].details = .init(domId: text("AXDOMIdentifier", of: element), domClasses: read("AXDOMClassList", of: element) as? [String])
        }
        if let index = HandoffManifest.Target.match(frames, crop: crop, display: display, tolerance: tolerance)?.index, let element = elements[index] {
            let began = ContinuousClock.now
            func neighbors(_ list: ArraySlice<AXUIElement>) -> [HandoffManifest.Neighbor] {
                var named: [HandoffManifest.Neighbor] = []
                for neighbor in list {
                    guard began.duration(to: .now) < peerBudget else { break }
                    let secure = text(kAXSubroleAttribute, of: neighbor) == kAXSecureTextFieldSubrole
                    named.append(.init(role: text(kAXRoleAttribute, of: neighbor), name: ([kAXTitleAttribute, kAXDescriptionAttribute] + (secure ? [] : [kAXValueAttribute]))
                        .lazy.compactMap { text($0, of: neighbor) }.first { !$0.isEmpty }))
                }
                return named
            }
            let parent = read(kAXParentAttribute, of: element).map { $0 as! AXUIElement }
            let siblings = frames[index].role == kAXWindowRole || parent.flatMap { text(kAXRoleAttribute, of: $0) } == kAXApplicationRole ? []
                : parent.flatMap { children(of: $0, kAXChildrenAttribute) } ?? []
            let at = siblings.firstIndex { CFEqual($0, element) } ?? 0
            let around = siblings[max(0, at - HandoffManifest.maxNeighbors / 2)..<min(siblings.count, at + HandoffManifest.maxNeighbors / 2 + 1)].filter { !CFEqual($0, element) }
            frames[index].details = .init(
                value: frames[index].subrole == kAXSecureTextFieldSubrole ? nil : text(kAXValueAttribute, of: element), help: text(kAXHelpAttribute, of: element),
                placeholder: text(kAXPlaceholderValueAttribute, of: element),
                labeledBy: read(kAXTitleUIElementAttribute, of: element).map { $0 as! AXUIElement }.flatMap { text(kAXTitleAttribute, of: $0) ?? text(kAXValueAttribute, of: $0) },
                url: text(kAXURLAttribute, of: element), domId: frames[index].details?.domId, domClasses: frames[index].details?.domClasses,
                enabled: read(kAXEnabledAttribute, of: element) as? Bool, focused: read(kAXFocusedAttribute, of: element) as? Bool,
                selected: read(kAXSelectedAttribute, of: element) as? Bool,
                children: neighbors((children(of: element, kAXChildrenAttribute) ?? []).prefix(HandoffManifest.maxNeighbors)), siblings: neighbors(around[...]))
        }
        let window = frames.lastIndex { $0.role == kAXWindowRole }.flatMap { elements[$0] }
        let page = web.flatMap { elements[$0] }
        return (frames, window.flatMap { text(kAXDocumentAttribute, of: $0) }, page.flatMap { text(kAXURLAttribute, of: $0) }, page.flatMap { text(kAXTitleAttribute, of: $0) })
    }

    /// `chain`'s frames, with a sidebar's full panel above its scroll area (`AccessibilityBounds.withSidebarPanel`) when no other
    /// element of the window lies in the title-bar band the panel adds.
    private static func sidebarFrames(_ chain: [(element: AXUIElement, frame: AXFrame)]) -> [AXFrame] {
        guard let sidebar = AccessibilityBounds.withSidebarPanel(chain.map(\.frame)), !occupied(sidebar.band, under: chain.last!.element) else { return chain.map(\.frame) }
        return sidebar.frames
    }

    /// Whether an element under `element` lies in `band` (`AccessibilityBounds.occupies`). The walk looks inside the elements that span
    /// the whole band (Finder's toolbar and split groups) and not inside the others.
    private static func occupied(_ band: CGRect, under element: AXUIElement) -> Bool {
        (children(of: element, kAXChildrenAttribute) ?? []).contains { child in
            guard let frame = frame(of: child) else { return false }
            return frame.rect.contains(band) ? occupied(band, under: child) : AccessibilityBounds.occupies(frame, band)
        }
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
        guard let live = frame(of: chain[level].element)?.rect else { return [] }
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
        guard let position = AXValues.point(attribute(kAXPositionAttribute, of: element)),
              let size = AXValues.size(attribute(kAXSizeAttribute, of: element)) else { return nil }
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

    static func children(of element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
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
                  let position = AXValues.point(attribute(kAXPositionAttribute, of: child)),
                  let size = AXValues.size(attribute(kAXSizeAttribute, of: child)) else { return nil }
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

    /// Apps whose text areas are terminal grids, one cell per UTF-16 unit, that answer `AXRangeForLine` and `AXBoundsForRange` with a
    /// box per visual row (measured on iTerm2 3.6: the visible rows only, 8 pt cells, each row padded to the grid's width).
    static let terminalApps: Set<String> = ["com.googlecode.iterm2"]

    /// The text areas in `pid`'s windows, each one's frame and its visible rows' text and boxes, in global points. Empty without
    /// permission, on a timeout, or for an area that does not answer for its rows.
    @concurrent
    static func terminalRows(pid: pid_t) async -> [(frame: CGRect, rows: [(text: String, box: CGRect)])] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        func parameter(_ attribute: String, _ element: AXUIElement, _ argument: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, argument, &result) == .success ? result : nil
        }
        var areas: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard let frame = frame(of: element) else { return }
            if frame.role == kAXTextAreaRole { return areas.append(element) }
            guard depth < maxDepth else { return }
            for child in children(of: element, kAXChildrenAttribute) ?? [] { walk(child, depth: depth + 1) }
        }
        for window in children(of: application, kAXWindowsAttribute) ?? [] { walk(window, depth: 0) }
        return areas.compactMap { area in
            var raw: CFTypeRef?
            guard let frame = frame(of: area)?.rect, AXUIElementCopyAttributeValue(area, kAXValueAttribute as CFString, &raw) == .success,
                  let value = raw as? String as NSString?, value.length > 0,
                  let last = AXValues.index(parameter("AXLineForIndex", area, value.length - 1 as CFNumber)) else { return nil }
            var rows: [(text: String, box: CGRect)] = []
            for line in 0...last {
                guard let lineRange = parameter("AXRangeForLine", area, line as CFNumber),
                      let range = AXValues.range(lineRange).flatMap({ AXValues.range($0, within: value.length) }),
                      let box = AXValues.rect(parameter("AXBoundsForRange", area, lineRange)) else { return nil }
                rows.append((value.substring(with: range), box))
            }
            return (frame, rows)
        }
    }

    /// The element's raw value for `name`, nil when it does not answer; `AXValues` reads it as a point, size, rect or range.
    static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }

    /// Shows the system's Accessibility prompt. Call only from a user click in a live (non-headless) overlay.
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
