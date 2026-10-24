import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--probe-terminal-text`: reads the running terminal apps' text areas through accessibility, as Text mode does at capture, and
    /// prints each area's frame, row count, read time, and its non-empty rows with their boxes (global points). Opens no window.
    static func probeTerminalText() async {
        for app in NSWorkspace.shared.runningApplications where Accessibility.terminalApps.contains(app.bundleIdentifier ?? "") {
            let began = ContinuousClock.now
            let areas = await Accessibility.terminalRows(pid: app.processIdentifier)
            print("\(app.bundleIdentifier!): \(areas.count) text areas in \(String(format: "%.1f", began.duration(to: .now).milliseconds)) ms")
            for area in areas {
                let text = TerminalText(rows: area.rows, frame: area.frame, window: 0)
                print("  area \(area.frame), \(area.rows.count) rows")
                for row in text.rows where !row.text.isEmpty { print("    \(row.bounds) \(row.text.prefix(100).debugDescription)") }
            }
        }
    }
}
