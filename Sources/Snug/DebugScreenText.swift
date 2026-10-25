import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--probe-screen-text`: reads every on-screen app's accessibility text as a capture does (`ScreenTextReader.read`) and prints, per
    /// app, the read time and each area's frame, its non-empty lines with their boxes (global points), and what copying all of it would
    /// paste. The Chromium apps with a window on screen are read as if Text mode had turned them on, which this does not do. Each
    /// app is then read once more alone for its time. Opens no window.
    static func probeScreenText() async {
        let began = ContinuousClock.now
        let chromium = Set(await ChromiumAccessibility.owners(on: .infinite))
        let read = await ScreenTextReader.read(chromium: chromium)
        print("read \(read.count) apps in \(String(format: "%.1f", began.duration(to: .now).milliseconds)) ms")
        for (pid, texts) in read {
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let alone = ContinuousClock.now
            _ = await ScreenTextReader.texts(pid: pid, bundle: bundle, chromium: chromium.contains(pid))
            print("\(bundle.isEmpty ? "\(pid)" : bundle): \(texts.count) areas, \(String(format: "%.1f", alone.duration(to: .now).milliseconds)) ms alone\(chromium.contains(pid) ? ", Chromium" : "")")
            for text in texts {
                print("  area \(text.frame), \(text.lines.count) lines\(text.claimsFrame ? ", takes its whole frame" : "")")
                for line in text.lines where !line.text.isEmpty { print("    \(line.bounds) \(line.text.prefix(100).debugDescription)") }
                let all = text.lines(from: .init(line: 0, column: 0), to: .init(line: text.lines.count - 1, column: text.lines.last!.text.count))
                print("  copy of the whole area:\n" + TextLayout.paragraphs(TextLayout.rows(all)))
            }
        }
    }
}

extension DebugRun {
    /// `--verify-screen-text-ui`: Text mode on accessibility text, through synthesized events on form-test.png with a terminal laid
    /// over its blank lower middle (`screenTexts` set directly; headless runs read no real app). Checks the highlight and the copy of a
    /// drag, a backward drag, a double and a triple click, Shift-Return's rows, F, that a press on the form's text still selects in Live
    /// Text, that a window in front of the terminal keeps its part of the area for Live Text, and that a page's text (word boxes, not a
    /// grid) takes presses on its lines only and copies a title and its subtitle on their own lines.
    static func verifyScreenText(image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        let liveText = overlay.view.liveText
        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Screen text UI verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            print("ok: \(message)")
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<10000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            require(condition(), message)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, clicks: Int = 1) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!)
        }
        func drag(from start: CGPoint, to end: CGPoint) {
            mouse(.leftMouseDown, start)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            mouse(.leftMouseUp, end)
        }
        func click(_ pixel: CGPoint, times: Int) {
            for count in 1...times {
                mouse(.leftMouseDown, pixel, clicks: count)
                mouse(.leftMouseUp, pixel, clicks: count)
            }
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: overlay.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        func copied() async -> String? {
            await overlay.textTask?.value
            return overlay.pasteboard.string(forType: .string)
        }
        // A 32-cell grid of 16 px cells and 32 px rows from (900, 1000): a prompt, a paragraph wrapped at the grid's width, a blank row
        // and a list item.
        let rows = ["$ git status -sb", "this sentence wraps right at the", "edge and joins.", "", "- next item"]
        let grid = rows.map(\.count).max()!
        func row(_ index: Int) -> CGFloat { 1000 + CGFloat(index) * 32 + 16 }
        func column(_ caret: Int) -> CGFloat { 900 + CGFloat(caret) * 16 }
        /// Opens Text mode with the terminal in `windows[window]`.
        func open(windows: [CGRect], window: Int) async throws {
            overlay.present(image: image, frame: frame, displayID: nil)
            key(17, "t")
            try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
            overlay.windows = windows
            overlay.screenTexts = [ScreenText.grid(rows: rows.enumerated().map { index, text in
                let padded = index == rows.count - 1 ? text.padding(toLength: grid + 1, withPad: "\0", startingAt: 0) : text.padding(toLength: grid, withPad: " ", startingAt: 0) + "\n"
                return (padded, CGRect(x: 900, y: 1000 + CGFloat(index) * 32, width: CGFloat(padded.utf16.count) * 16, height: 32))
            }, frame: CGRect(x: 880, y: 990, width: 600, height: 180), window: window)]
        }
        let terminalWindow = CGRect(x: 860, y: 960, width: 700, height: 260)

        try await open(windows: [terminalWindow], window: 0)
        // From just past the middle of row 1's fifth character to past the end of the last row.
        drag(from: CGPoint(x: column(5) - 4, y: row(1)), to: CGPoint(x: 1450, y: row(4)))
        require(overlay.text.screenSelection != nil && liveText.selectedRanges.allSatisfy(\.isEmpty), "a drag in the terminal selects its text, not Live Text's")
        require(overlay.view.overlays.textPills == [CGRect(x: column(5), y: 1032, width: 16 * 27, height: 32), CGRect(x: 900, y: 1064, width: 16 * 15, height: 32),
                                                     CGRect(x: 900, y: 1128, width: 16 * 11, height: 32)],
                "the highlight covers the selected characters of each row, none on the blank row: \(overlay.view.overlays.textPills)")
        require(!overlay.chrome.strip.isHidden, "the Text strip shows for the terminal selection")
        key(36, "\r")
        let joined = await copied()
        require(joined == "sentence wraps right at the edge and joins.\n\n- next item", "Return copies the exact text, the soft wrap joined: \(joined.debugDescription)")

        try await open(windows: [terminalWindow], window: 0)
        drag(from: CGPoint(x: column(7), y: row(2)), to: CGPoint(x: column(2) - 4, y: row(0)))
        key(36, "\r", .shift)
        let table = await copied()
        require(table == "git status -sb\nthis sentence wraps right at the\nedge an", "a backward drag selects the same way, and Shift-Return copies it as rows: \(table.debugDescription)")

        try await open(windows: [terminalWindow], window: 0)
        click(CGPoint(x: column(8), y: row(0)), times: 2)
        require(overlay.view.overlays.textPills == [CGRect(x: column(6), y: 1000, width: 16 * 6, height: 32)], "a double click selects the word: \(overlay.view.overlays.textPills)")
        // The strip attaches under that word, over the rows below it, so the triple click starts over in a fresh Text mode.
        try await open(windows: [terminalWindow], window: 0)
        click(CGPoint(x: column(8), y: row(2)), times: 3)
        require(overlay.view.overlays.textPills == [CGRect(x: 900, y: 1064, width: 16 * 15, height: 32)], "a triple click selects the row: \(overlay.view.overlays.textPills)")
        key(8, "c", .command)
        let row2 = await copied()
        require(row2 == "edge and joins.", "Cmd-C copies the clicked row: \(row2.debugDescription)")

        // F selects all of Live Text's text and clears the terminal selection, so Return copies what is highlighted.
        try await open(windows: [terminalWindow], window: 0)
        click(CGPoint(x: column(8), y: row(0)), times: 2)
        key(3, "f")
        require(overlay.text.screenSelection == nil && overlay.view.overlays.textPills.isEmpty && !liveText.selectedText.isEmpty,
                "F selects all of Live Text's text and clears the terminal selection")

        // A press on the form's text goes to Live Text and clears the terminal selection.
        try await open(windows: [terminalWindow], window: 0)
        click(CGPoint(x: column(8), y: row(0)), times: 2)
        drag(from: CGPoint(x: 1692, y: 432), to: CGPoint(x: 1898, y: 432))
        require(overlay.text.screenSelection == nil && overlay.view.overlays.textPills.isEmpty && !liveText.selectedText.isEmpty,
                "a drag on the form's text selects in Live Text and clears the terminal selection: \(liveText.selectedText.debugDescription)")

        // A window in front of the terminal's left part keeps that part: a press there is no terminal press.
        try await open(windows: [CGRect(x: 860, y: 960, width: 200, height: 260), terminalWindow], window: 1)
        click(CGPoint(x: column(2), y: row(0)), times: 2)
        require(overlay.text.screenSelection == nil, "a press where another window is in front of the terminal is not a terminal press")
        click(CGPoint(x: column(14), y: row(0)), times: 2)
        require(overlay.view.overlays.textPills == [CGRect(x: column(13), y: 1000, width: 16 * 3, height: 32)], "a press on the terminal's uncovered part is: \(overlay.view.overlays.textPills)")
        // A page's text, word boxes in a proportional font, over the form's blank lower middle; its frame also covers the form's
        // "Product name", where it has no line, so a press there is Live Text's.
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        let page = CGRect(x: 860, y: 380, width: 1400, height: 840)
        overlay.windows = [page]
        overlay.screenTexts = [ScreenText(lines: [.init(text: "Order summary", box: CGRect(x: 900, y: 1000, width: 260, height: 36),
                                                        words: [CGRect(x: 900, y: 1000, width: 110, height: 36), CGRect(x: 1022, y: 1000, width: 138, height: 36)]),
                                                  .init(text: "Ships in 2 days", box: CGRect(x: 900, y: 1050, width: 230, height: 30))],
                                          frame: page, window: 0)]
        drag(from: CGPoint(x: 1030, y: 1018), to: CGPoint(x: 1075, y: 1065))
        // "summary" fills its word box, so the drag starts at its "s" (x 1022); the second line has no word boxes, so its 15 characters
        // spread over its 230 px and x 1075 is after the eleventh.
        let pills = overlay.view.overlays.textPills
        require(pills.count == 2 && pills[0] == CGRect(x: 1022, y: 1000, width: 138, height: 36)
                && pills[1].minX == 900 && abs(pills[1].width - 230 * 11 / 15) < 0.01, "a drag on a page's lines highlights its characters: \(pills)")
        key(36, "\r", .shift)
        let summary = await copied()
        require(summary == "summary\nShips in 2", "Shift-Return copies the page's exact text as rows: \(summary.debugDescription)")
        // The cart's larger title over its smaller description, as a page's lines whose boxes take the line height around the ink: the
        // title reaches as far right as the description, so only their styles, measured from the pixels, keep them apart.
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        overlay.windows = [page]
        overlay.screenTexts = [ScreenText(lines: [.init(text: "Product name", box: CGRect(x: 1690, y: 404, width: 212, height: 48)),
                                                  .init(text: "Brief description", box: CGRect(x: 1689, y: 452, width: 220, height: 36))],
                                          frame: page, window: 0)]
        drag(from: CGPoint(x: 1692, y: 430), to: CGPoint(x: 1908, y: 470))
        key(36, "\r")
        let cart = await copied()
        require(cart == "Product name\nBrief description", "Return copies a page's title and its subtitle on their own lines: \(cart.debugDescription)")
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await waitFor("the Live Text analysis attaches") { liveText.analysis != nil }
        overlay.windows = [page]
        overlay.screenTexts = [ScreenText(lines: [.init(text: "Order summary", box: CGRect(x: 900, y: 1000, width: 260, height: 36))], frame: page, window: 0)]
        drag(from: CGPoint(x: 1692, y: 432), to: CGPoint(x: 1898, y: 432))
        require(overlay.text.screenSelection == nil && !liveText.selectedText.isEmpty,
                "a press in a page's frame away from its lines (an image in the page) selects in Live Text: \(liveText.selectedText.debugDescription)")

        // Text mode over a Chromium app's window asks for its accessibility once; with the setting off it asks for nothing and the
        // capture reads no Chromium app. The owners and the enabler are fakes, so no real app is touched.
        var requested: [pid_t] = []
        overlay.chromiumOwners = { _ in [4242] }
        overlay.enableChromium = { requested.append($0) }
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await waitFor("entering Text mode over a Chromium app's window asks to turn its accessibility on") { requested == [4242] }
        require(overlay.chromiumReadable == [4242], "the capture reads that app: \(overlay.chromiumReadable)")
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await Task.sleep(for: .milliseconds(200))
        require(requested == [4242], "entering Text mode again does not ask again: \(requested)")
        overlay.defaults.set(false, forKey: Pref.chromiumText)
        overlay.chromiumOwners = { _ in [5151] }
        overlay.present(image: image, frame: frame, displayID: nil)
        key(17, "t")
        try await Task.sleep(for: .milliseconds(200))
        require(requested == [4242] && overlay.chromiumReadable.isEmpty, "with the setting off Text mode asks for no app and the capture reads none: \(requested) \(overlay.chromiumReadable)")
        exit(EXIT_SUCCESS)
    }
}
