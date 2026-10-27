import AppKit
import ApplicationServices
import ScreenshotCore

extension ScreenTextReader {
    private static let nativeTimeout: Float = 0.1
    private static let nativeMaxDepth = 30
    private static let nativeMaxElements = 1500
    private static let nativeMaxLines = 300
    /// One app's walk stops at the budget, and its word boxes a little earlier so the lines it has keep their boxes.
    private static let nativeBudget = Duration.milliseconds(150)
    private static let nativeWordBudget = Duration.milliseconds(100)

    /// The text of `pid`'s standard AppKit text (`AXStaticText`, `AXTextField`, `AXTextArea`), one `ScreenText` per window with every
    /// visible line in tree order, in global points. A multi-line element gives a line per visual line of its visible characters
    /// (`AXLineForIndex`, `AXRangeForLine`, `AXBoundsForRange`), with word boxes while the word budget lasts. Web areas, secure
    /// fields, empty text and text outside the window are skipped. Empty without permission or on a timeout.
    @concurrent
    static func native(pid: pid_t) async -> [ScreenText] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let began = ContinuousClock.now
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, nativeTimeout)
        func parameter(_ name: String, _ element: AXUIElement, _ argument: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &result) == .success ? result : nil
        }
        func bounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
            var range = CFRange(location: range.location, length: range.length)
            guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
            return AXValues.rect(parameter("AXBoundsForRange", element, argument))
        }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute,
                     kAXTitleAttribute, kAXDescriptionAttribute, "AXVisibleCharacterRange"] as CFArray

        var windows: [ScreenText] = []
        var windowList: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowList)
        for window in windowList as? [AXUIElement] ?? [] {
            var fetched: CFArray?
            AXUIElementCopyMultipleAttributeValues(window, names, [], &fetched)
            guard let fetched = fetched as? [CFTypeRef], fetched.count == 9, let origin = AXValues.point(fetched[3]), let size = AXValues.size(fetched[4]) else { continue }
            let windowFrame = CGRect(origin: origin, size: size)
            var sources: [ScreenText.Source] = []
            var elements = 0

            func lines(of element: AXUIElement, text: NSString, visible: CFRange?, elementFrame: CGRect, clip: CGRect) {
                // A visible range past the end is clamped to the text; a negative or overflowing one reads as all of it.
                let visible = visible.flatMap { AXValues.range($0, clampedTo: text.length) } ?? NSRange(location: 0, length: text.length)
                guard visible.length > 0 else { return }
                var ranges = [visible]
                if let first = AXValues.index(parameter("AXLineForIndex", element, visible.location as CFNumber)),
                   let last = AXValues.index(parameter("AXLineForIndex", element, visible.location + visible.length - 1 as CFNumber)), last > first {
                    ranges = (first...min(last, first + nativeMaxLines)).compactMap { line in
                        AXValues.range(parameter("AXRangeForLine", element, line as CFNumber)).flatMap { AXValues.range($0, clampedTo: text.length) }
                            .map { NSIntersectionRange($0, visible) }
                    }
                }
                for var range in ranges {
                    while range.length > 0, text.substring(with: NSRange(location: range.location + range.length - 1, length: 1)).allSatisfy(\.isWhitespace) { range.length -= 1 }
                    let line = text.substring(with: range)
                    guard !line.allSatisfy(\.isWhitespace) else { continue }
                    guard let box = bounds(element, range) ?? (ranges.count == 1 ? elementFrame : nil), box.width > 0, box.height > 0, box.intersects(clip) else { continue }
                    var words: [CGRect]?
                    let wordRanges = ScreenText.wordRanges(in: line)
                    if wordRanges.count > 1, began.duration(to: .now) < nativeWordBudget {
                        let boxes = wordRanges.compactMap { bounds(element, NSRange(location: range.location + $0.lowerBound, length: $0.count)) }
                        if boxes.count == wordRanges.count { words = boxes }
                    }
                    sources.append(.init(text: line, box: box, words: words))
                }
            }

            func walk(_ element: AXUIElement, _ fetched: [CFTypeRef], depth: Int, clip: CGRect) {
                guard let role = fetched[0] as? String, role != "AXWebArea" else { return }
                var clip = clip
                var elementFrame: CGRect?
                if let origin = AXValues.point(fetched[3]), let size = AXValues.size(fetched[4]) {
                    elementFrame = CGRect(origin: origin, size: size)
                    guard elementFrame!.intersects(clip) else { return }
                    if role == kAXScrollAreaRole { clip = clip.intersection(elementFrame!) }
                }
                if role == kAXStaticTextRole || role == kAXTextFieldRole || role == kAXTextAreaRole {
                    if fetched[1] as? String != "AXSecureTextField", let elementFrame,
                       let text = [fetched[5], fetched[6], fetched[7]].lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                        lines(of: element, text: text as NSString, visible: AXValues.range(fetched[8]), elementFrame: elementFrame, clip: clip)
                    }
                    return
                }
                for child in fetched[2] as? [AXUIElement] ?? [] {
                    guard depth < nativeMaxDepth, elements < nativeMaxElements, began.duration(to: .now) < nativeBudget else { return }
                    elements += 1
                    var childFetched: CFArray?
                    AXUIElementCopyMultipleAttributeValues(child, names, [], &childFetched)
                    if let childFetched = childFetched as? [CFTypeRef], childFetched.count == 9 { walk(child, childFetched, depth: depth + 1, clip: clip) }
                }
            }
            walk(window, fetched, depth: 0, clip: windowFrame)
            if !sources.isEmpty { windows.append(ScreenText(lines: sources, frame: windowFrame, window: 0)) }
        }
        return windows
    }
}
