import AppKit
import ApplicationServices
import ScreenshotCore

extension ScreenTextReader {
    private static let messagingTimeout: Float = 0.1
    private static let maxDepth = 60
    private static let maxWords = 3000
    /// The longest one app takes to read; a slow or large page gets the words before the cut.
    private static let budget = Duration.milliseconds(120)

    /// The visible text of `pid`'s Chromium web areas, one `ScreenText` each in global points. The tree is in document order, which
    /// is the reading order. Chromium's text markers answer nothing useful (positions fail, line boxes span the page), so the words come
    /// from its `AXStaticText` values and text fields, with `AXBoundsForRange` for each word, clipped to the element's own frame
    /// (Chromium clips frames to the scroller, not ranges). Subtrees with no visible part are skipped. An area whose multi-word
    /// elements mostly answer with empty boxes (the app has not built its word boxes yet) gives nothing, so its text stays OCR.
    @concurrent
    static func chromiumTexts(pid: pid_t) async -> [ScreenText] {
        guard pid != getpid(), AXIsProcessTrusted() else { return [] }
        let began = ContinuousClock.now
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success, let windows = windows as? [AXUIElement] else { return [] }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXFrame", kAXChildrenAttribute, kAXValueAttribute] as CFArray
        func node(_ element: AXUIElement) -> (role: String?, subrole: String?, frame: CGRect, children: [AXUIElement], value: String?)? {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            var values: CFArray?
            var frame = CGRect.zero
            guard began.duration(to: .now) < budget, AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success, let values = values as? [Any],
                  CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID(), AXValueGetValue(values[2] as! AXValue, .cgRect, &frame) else { return nil }
            return (values[0] as? String, values[1] as? String, frame, values[3] as? [AXUIElement] ?? [], values[4] as? String)
        }
        var areas: [(element: AXUIElement, frame: CGRect)] = []
        func find(_ element: AXUIElement, depth: Int) {
            guard depth < maxDepth, let node = node(element) else { return }
            if node.role == "AXWebArea" { return areas.append((element, node.frame)) }
            for child in node.children { find(child, depth: depth + 1) }
        }
        for window in windows { find(window, depth: 0) }
        return areas.compactMap { area in
            var pieces: [ChromiumText.Piece] = []
            var multiWord = 0, unanswered = 0
            var spaced = true
            func walk(_ element: AXUIElement, depth: Int) {
                guard depth < maxDepth, pieces.count < maxWords, let node = node(element) else { return }
                let visible = node.frame.intersection(area.frame)
                guard !visible.isNull, visible.width > 1, visible.height > 1 else { return }
                let text = node.role == kAXStaticTextRole || ([kAXTextFieldRole, kAXTextAreaRole].contains(node.role) && node.children.isEmpty && node.subrole != kAXSecureTextFieldSubrole)
                guard text, let value = node.value else { return node.children.forEach { walk($0, depth: depth + 1) } }
                let words = ChromiumText.words(in: value)
                var answered = false
                for (index, word) in words.enumerated() where pieces.count < maxWords {
                    var range = CFRange(location: word.utf16.lowerBound, length: word.utf16.count)
                    var raw: CFTypeRef?
                    var box = CGRect.zero
                    guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString, AXValueCreate(.cfRange, &range)!, &raw) == .success,
                          AXValueGetValue(raw as! AXValue, .cgRect, &box), box.width > 0, box.height > 0 else { continue }
                    answered = true
                    // Icon fonts (Slack's) are private-use characters, which no one reads or copies as text.
                    if visible.contains(CGPoint(x: box.midX, y: box.midY)), !word.text.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .privateUse }) {
                        pieces.append(.init(text: word.text, box: box.intersection(visible), spaceBefore: index > 0 || spaced || value.first!.isWhitespace))
                    }
                }
                if words.count > 1 {
                    multiWord += 1
                    if !answered { unanswered += 1 }
                }
                spaced = value.last?.isWhitespace ?? spaced
            }
            walk(area.element, depth: 0)
            return pieces.isEmpty || unanswered * 2 > multiWord ? nil : ScreenText(lines: ChromiumText.sources(of: pieces), frame: area.frame, window: 0)
        }
    }
}
