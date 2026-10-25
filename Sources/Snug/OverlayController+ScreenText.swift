import AppKit
import ScreenshotCore

/// Text mode over text that accessibility exposes (`ScreenTextReader`): the selection, its highlight and the copy are its exact
/// characters, not OCR's. The text is read as the pixels are grabbed, so it matches the frozen image. Elsewhere Live Text selects.
extension OverlayController {
    /// Takes the text read at capture (global points) into image pixels, each area with the index of the frontmost window of its app that
    /// holds it; an area in no window drops. Clears any selection in it.
    func setScreenTexts(_ read: [(pid: pid_t, texts: [ScreenText])]) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = windowIDs.map { id in info.first { $0[kCGWindowNumber as String] as? CGWindowID == id }?[kCGWindowOwnerPID as String] as? pid_t }
        let origin = CGPoint(x: window.frame.minX, y: NSScreen.screens[0].frame.height - window.frame.maxY)
        screenTexts = []
        text.screenSelection = nil
        for (pid, texts) in read {
            for read in texts {
                let frame = read.inPixels(origin: origin, scale: scale, window: 0).frame
                let window = windows.indices.first { owners[$0] == pid && windows[$0].contains(CGPoint(x: frame.midX, y: frame.midY)) }
                Pref.logHoverLine("screen text pid \(pid) area \(frame) \(read.lines.count) lines: " + (window.map { "kept, window \($0)" } ?? "in no window, Live Text"),
                                  key: Pref.logText, file: "text.log")
                guard let window else { continue }
                screenTexts.append(read.inPixels(origin: origin, scale: scale, window: window))
            }
        }
    }

    /// Entering Text mode with "Read text from Chromium apps" on: turns on the accessibility of each Chromium app with a window on this
    /// display that Text mode has not asked yet, off main. This capture's text was read before, so it keeps OCR; the next capture reads
    /// the apps (`ScreenTextReader.read`).
    func enableChromiumText() {
        guard defaults.bool(forKey: Pref.chromiumText) else { return }
        let display = CGRect(x: window.frame.minX, y: NSScreen.screens[0].frame.height - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        Task {
            for pid in await chromiumOwners(display) where chromiumRequested.insert(pid).inserted { await enableChromium(pid) }
        }
    }

    /// The pids whose text the capture reads through the Chromium reader: the apps Text mode turned on, none with the setting off.
    var chromiumReadable: Set<pid_t> { defaults.bool(forKey: Pref.chromiumText) ? chromiumRequested : [] }

    /// The text that takes a press at `pixel` (`ScreenText.takes`) where its window is the frontmost one there.
    func screenText(at pixel: CGPoint) -> Int? {
        screenTexts.firstIndex { $0.takes(pixel) && windows.firstIndex { $0.contains(pixel) } == $0.window }
    }

    /// A press in accessibility text: puts a caret there, or selects the word (a double click) or the line (a triple click).
    func pressScreenText(_ index: Int, event: NSEvent) {
        let read = screenTexts[index]
        let caret = read.position(at: view.pixelPoint(event))
        let (anchor, focus) = switch event.clickCount {
        case 2: read.word(at: caret)
        case 3...: read.line(at: caret)
        default: (caret, caret)
        }
        text.screenSelection = (index, anchor, focus)
        refresh()
    }

    /// A drag or release after a press in accessibility text moves the selection's end to the caret nearest the pointer; a double or
    /// triple click's word or line stays selected on its release.
    func dragScreenText(_ event: NSEvent) {
        guard let selected = text.screenSelection, event.type == .leftMouseDragged || event.clickCount < 2 else { return }
        text.screenSelection = (selected.text, selected.anchor, screenTexts[selected.text].position(at: view.pixelPoint(event)))
        refresh()
    }

    /// The selected accessibility text as `TextLayout` lines; nil with no such selection or an empty one.
    var screenLines: [TextLine]? {
        guard let selected = text.screenSelection else { return nil }
        let text = screenTexts[selected.text]
        // Outside a terminal (one font throughout, where a bold word in a line would only shift its weight) each line takes its style
        // from the pixels, as OCR's do, so a title never joins its subtitle as a soft wrap.
        let lines = text.lines(from: selected.anchor, to: selected.focus).map { line in
            text.claimsFrame ? line : TextLine(text: line.text, bounds: line.bounds, style: image.flatMap { TextStyle.measure(in: $0, box: line.bounds) })
        }
        return lines.isEmpty ? nil : lines
    }

    /// The accessibility text selection's highlight in view points, for the Text strip; nil without one.
    var screenSelectionBox: CGRect? {
        guard let selected = text.screenSelection else { return nil }
        let boxes = screenTexts[selected.text].highlight(from: selected.anchor, to: selected.focus)
        return boxes.first.map { first in view.viewRect(boxes.reduce(first) { $0.union($1) }) }
    }
}
