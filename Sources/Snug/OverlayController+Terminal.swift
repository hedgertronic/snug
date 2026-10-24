import AppKit
import ScreenshotCore

/// Text mode in a terminal (`Accessibility.terminalApps`): its text comes from accessibility, not OCR, so the selection, its highlight
/// and the copy are its exact characters. Accessibility reads the live terminal while the image is frozen, so a terminal whose text
/// changes while it is read (output streaming in) keeps Live Text.
extension OverlayController {
    /// Reads the terminal windows' text areas twice, 250 ms apart, and keeps those that read the same both times, in image pixels, each
    /// with the index of the frontmost window of its app that holds it. Headless debug runs set `terminals` themselves.
    func readTerminals() {
        terminalTask?.cancel()
        terminals = []
        guard !isHeadless, AXIsProcessTrusted() else { return }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = windowIDs.map { id in info.first { $0[kCGWindowNumber as String] as? CGWindowID == id }?[kCGWindowOwnerPID as String] as? pid_t }
        let pids = Set(owners.compactMap { $0 }).filter { Accessibility.terminalApps.contains(NSRunningApplication(processIdentifier: $0)?.bundleIdentifier ?? "") }
        guard !pids.isEmpty else { return }
        let origin = CGPoint(x: window.frame.minX, y: NSScreen.screens[0].frame.height - window.frame.maxY)
        let (scale, windows) = (scale, windows)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale, width: rect.width * scale, height: rect.height * scale)
        }
        terminalTask = Task {
            var read: [TerminalText] = []
            for pid in pids {
                let first = await Accessibility.terminalRows(pid: pid)
                try? await Task.sleep(for: .milliseconds(250))
                let second = await Accessibility.terminalRows(pid: pid)
                guard !Task.isCancelled else { return }
                for area in first where second.contains(where: { $0.frame == area.frame && $0.rows.map(\.text) == area.rows.map(\.text) }) {
                    let frame = pixels(area.frame)
                    guard let window = windows.indices.first(where: { owners[$0] == pid && windows[$0].contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { continue }
                    read.append(TerminalText(rows: area.rows.map { ($0.text, pixels($0.box)) }, frame: frame, window: window))
                }
            }
            terminals = read
            terminalTask = nil
        }
    }

    /// The terminal whose text area holds `pixel` where its window is the frontmost one there.
    func terminal(at pixel: CGPoint) -> Int? {
        terminals.firstIndex { $0.frame.contains(pixel) && windows.firstIndex { $0.contains(pixel) } == $0.window }
    }

    /// A press in a terminal: puts a caret there, or selects the word (a double click) or the row (a triple click).
    func pressTerminalText(_ index: Int, event: NSEvent) {
        let terminal = terminals[index]
        let caret = terminal.position(at: view.pixelPoint(event))
        let (anchor, focus) = switch event.clickCount {
        case 2: terminal.word(at: caret)
        case 3...: (TerminalText.Position(row: caret.row, column: 0), TerminalText.Position(row: caret.row, column: terminal.rows[caret.row].text.count))
        default: (caret, caret)
        }
        text.terminalSelection = (index, anchor, focus)
        refresh()
    }

    /// A drag or release after a press in a terminal moves the selection's end to the caret nearest the pointer; a double or triple
    /// click's word or row stays selected on its release.
    func dragTerminalText(_ event: NSEvent) {
        guard let selected = text.terminalSelection, event.type == .leftMouseDragged || event.clickCount < 2 else { return }
        text.terminalSelection = (selected.terminal, selected.anchor, terminals[selected.terminal].position(at: view.pixelPoint(event)))
        refresh()
    }

    /// The selected terminal text as `TextLayout` lines; nil with no terminal selection or an empty one.
    var terminalLines: [TextLine]? {
        guard let selected = text.terminalSelection else { return nil }
        let lines = terminals[selected.terminal].lines(from: selected.anchor, to: selected.focus)
        return lines.isEmpty ? nil : lines
    }

    /// The terminal selection's highlight in view points, for the Text strip; nil without one.
    var terminalSelectionBox: CGRect? {
        guard let selected = text.terminalSelection else { return nil }
        let boxes = terminals[selected.terminal].highlight(from: selected.anchor, to: selected.focus)
        return boxes.first.map { first in view.viewRect(boxes.reduce(first) { $0.union($1) }) }
    }
}
