import AppKit
import ApplicationServices
import ScreenshotCore

extension ScreenTextReader {
    /// Apps whose `AXWebArea`s are WebKit's and answer the text-marker attributes (measured on Safari; Mail's message view is the same
    /// engine). Chromium's web areas fail those calls.
    static let webKitApps: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.mail"]
    /// One app's budget once its web areas are found: its lines take at most `webLineBudget`, then word boxes are added until
    /// `webWordBudget`. Finding the areas has a budget of its own, `webFindBudget` and `webFindElements`, so a slow window walk (every
    /// app is read at once) still leaves time for lines and the whole read stays bounded.
    private static let webLineBudget = Duration.milliseconds(90)
    private static let webWordBudget = Duration.milliseconds(140)
    private static let webFindBudget = Duration.milliseconds(150)
    private static let webFindElements = 3000
    /// The most lines one web area walks, and the most off-screen lines in a row it walks past (DOM order is not visual order, so a
    /// column below the fold can sit before a visible one).
    private static let maxWebLines = 600
    private static let maxOffscreenLines = 40

    /// The visible text of each web area in `pid`'s windows as visual lines in DOM order, in global points. A web area's frame is
    /// clipped to its scroll area and window; Safari can report both a screen height off (`AccessibilityBounds.displacement`), then the
    /// scroll area is moved so its bottom and right meet the window's and the area is dropped if that does not put it inside the
    /// window. Empty without permission, on a timeout, or for an area that does not answer the text-marker attributes.
    @concurrent
    static func webKitTexts(pid: pid_t) async -> [ScreenText] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Accessibility.messagingTimeout)
        func frame(of element: AXUIElement) -> CGRect? {
            guard let position = AXValues.point(Accessibility.attribute(kAXPositionAttribute, of: element)),
                  let size = AXValues.size(Accessibility.attribute(kAXSizeAttribute, of: element)) else { return nil }
            return CGRect(origin: position, size: size)
        }
        var areas: [(element: AXUIElement, visible: CGRect, offset: CGSize)] = []
        let finding = AXBudget(time: webFindBudget, elements: webFindElements)
        func walk(_ element: AXUIElement, depth: Int, window: CGRect, scroll: AXUIElement?) {
            guard finding.visit() else { return }
            AXUIElementSetMessagingTimeout(element, Accessibility.messagingTimeout)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                let tolerance = AccessibilityBounds.paddingTolerance
                let held = window.insetBy(dx: -tolerance, dy: -tolerance)
                guard let area = frame(of: element), let viewport = frame(of: scroll ?? element) else { return }
                let offset = held.contains(viewport) ? CGSize.zero : CGSize(width: window.maxX - viewport.maxX, height: window.maxY - viewport.maxY)
                let visible = area.intersection(viewport)
                guard held.contains(viewport.offsetBy(dx: offset.width, dy: offset.height)), !visible.isEmpty,
                      !visible.offsetBy(dx: offset.width, dy: offset.height).intersection(window).isEmpty else { return }
                return areas.append((element, visible, offset))
            }
            guard depth < Accessibility.maxDepth else { return }
            let scroll = role as? String == kAXScrollAreaRole ? element : scroll
            for child in Accessibility.children(of: element, kAXChildrenAttribute) ?? [] { walk(child, depth: depth + 1, window: window, scroll: scroll) }
        }
        for window in Accessibility.children(of: application, kAXWindowsAttribute) ?? [] {
            AXUIElementSetMessagingTimeout(window, Accessibility.messagingTimeout)
            if let frame = frame(of: window) { walk(window, depth: 0, window: frame, scroll: nil) }
        }
        let found = ContinuousClock.now
        let lines = areas.map { webLines(of: $0.element, in: $0.visible, until: found + webLineBudget) }
        return zip(areas, lines).compactMap { area, lines in
            let (dx, dy) = (area.offset.width, area.offset.height)
            let sources = lines.compactMap { line -> ScreenText.Source? in
                let pieces = ContinuousClock.now < found + webWordBudget ? webWords(of: area.element, from: line.start, length: WebText.significantLength(of: line.text)) : nil
                return WebText.source(line: line.text, box: line.box.offsetBy(dx: dx, dy: dy), pieces: pieces?.map { ($0.text, $0.box.offsetBy(dx: dx, dy: dy)) })
            }
            return sources.isEmpty ? nil : ScreenText(lines: sources, frame: area.visible.offsetBy(dx: dx, dy: dy), window: 0)
        }
    }

    /// The visual lines of a WebKit web area from the first one in `visible` (the area's own coordinates) on: each line's string, its
    /// box and the marker that starts it, skipping lines whose box does not have its middle in `visible` and zero-size boxes. The
    /// walk goes line to line by `AXNextLineEndTextMarkerForTextMarker`, which stops advancing where a line is the last of its
    /// block (measured: "39" in a table cell); then up to three characters on are tried. It ends when nothing advances, after
    /// `maxWebLines` lines, `maxOffscreenLines` off-screen in a row, or at `deadline`.
    static func webLines(of area: AXUIElement, in visible: CGRect, until deadline: ContinuousClock.Instant) -> [(text: String, box: CGRect, start: AXTextMarker)] {
        var bounds = visible
        guard let first = markerAttribute("AXStartTextMarkerForBounds", of: area, AXValueCreate(.cgRect, &bounds)!),
              var range = markerAttribute("AXLineTextMarkerRangeForTextMarker", of: area, first) else { return [] }
        var marker = first
        var lines: [(text: String, box: CGRect, start: AXTextMarker)] = []
        var offscreen = 0
        for _ in 0..<maxWebLines where ContinuousClock.now < deadline && offscreen < maxOffscreenLines {
            let start = AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
            if let box = AXValues.rect(markerAttribute("AXBoundsForTextMarkerRange", of: area, range)), box.width > 0, box.height > 0, visible.contains(CGPoint(x: box.midX, y: box.midY)) {
                offscreen = 0
                if let text = markerAttribute("AXStringForTextMarkerRange", of: area, range) as? String { lines.append((text, box, start)) }
            } else {
                offscreen += 1
            }
            func line(at marker: CFTypeRef) -> CFTypeRef? {
                markerAttribute("AXLineTextMarkerRangeForTextMarker", of: area, marker).flatMap { CFEqual(AXTextMarkerRangeCopyStartMarker($0 as! AXTextMarkerRange), start) ? nil : $0 }
            }
            var next = markerAttribute("AXNextLineEndTextMarkerForTextMarker", of: area, marker).flatMap { marker in line(at: marker).map { (marker, $0) } }
            var step = marker
            for _ in 0..<3 where next == nil {
                guard let character = markerAttribute("AXNextTextMarkerForTextMarker", of: area, step) else { break }
                step = character
                next = line(at: character).map { (character, $0) }
            }
            guard let next else { break }
            (marker, range) = next
        }
        return lines
    }

    /// The word ranges of one line, from its start marker: each range's string and box (the area's coordinates), consecutive, until
    /// they have read `length` characters. Nil when a range comes back empty or without a box.
    static func webWords(of area: AXUIElement, from start: AXTextMarker, length: Int) -> [(text: String, box: CGRect)]? {
        var pieces: [(text: String, box: CGRect)] = []
        var marker: CFTypeRef = start
        var read = 0
        while read < length {
            guard let range = markerAttribute("AXRightWordTextMarkerRangeForTextMarker", of: area, marker),
                  let text = markerAttribute("AXStringForTextMarkerRange", of: area, range) as? String, !text.isEmpty,
                  let box = AXValues.rect(markerAttribute("AXBoundsForTextMarkerRange", of: area, range)) else { return nil }
            pieces.append((text, box))
            read += text.count
            marker = AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange)
        }
        return pieces
    }

    private static func markerAttribute(_ attribute: String, of element: AXUIElement, _ argument: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, argument, &result) == .success ? result : nil
    }
}
