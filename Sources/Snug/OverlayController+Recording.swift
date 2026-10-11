import AppKit

/// V's armed state: the cursor choice for this recording, the running count-in and its seconds left, and the red outline and count
/// drawn over the selection.
@MainActor
final class ArmedRecording {
    var showsCursor: Bool
    var remaining: Int?
    var countIn: Task<Void, any Error>?
    let outline = CAShapeLayer()
    let count = Pill(fill: NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.86), radius: 22,
                     insets: NSEdgeInsets(top: 6, left: 26, bottom: 6, right: 26), spacing: 0)

    init(showsCursor: Bool) {
        self.showsCursor = showsCursor
        outline.fillColor = nil
        outline.strokeColor = NSColor.systemRed.cgColor
        outline.lineWidth = 2
    }
}

/// Screen recording: V on a released selection, or on the hovered element or window (which becomes the selection), arms recording.
/// Armed, the selection has a red outline; Return or V starts after the count-in, H shows or hides the cursor, Esc disarms. The
/// overlay closes before the app starts recording the area.
extension OverlayController {
    func armRecording() {
        guard displayID != nil, let area = selection?.rect ?? session?.selected?.bounds else { return NSSound.beep() }
        if selection == nil { openAsSelection(area) }
        let armed = ArmedRecording(showsCursor: defaults.bool(forKey: Pref.recordCursor))
        view.layer!.addSublayer(armed.outline)
        view.addSubview(armed.count)
        armedRecording = armed
        refresh()
    }

    func disarmRecording() {
        guard let armed = armedRecording else { return }
        armed.countIn?.cancel()
        armed.outline.removeFromSuperlayer()
        armed.count.removeFromSuperview()
        armedRecording = nil
    }

    /// While armed: Return or V starts the count-in, H switches the cursor, Esc stops a running count-in or disarms; other keys do nothing.
    func handleRecordingKey(_ event: NSEvent) -> Bool {
        let armed = armedRecording!
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (53, _) where armed.remaining != nil:
            armed.countIn?.cancel()
            armed.remaining = nil
        case (53, _): disarmRecording()
        case (36, _) where armed.remaining == nil, (76, _) where armed.remaining == nil, (_, "v") where armed.remaining == nil: countIn()
        case (_, "h") where armed.remaining == nil: armed.showsCursor.toggle()
        default: break
        }
        refresh()
        return true
    }

    /// Counts down `Pref.recordCountIn` seconds over the selection, one per second, then records; with no count-in, records at once.
    private func countIn() {
        let armed = armedRecording!
        let seconds = defaults.integer(forKey: Pref.recordCountIn)
        guard seconds > 0 else { return recordSelection() }
        armed.remaining = seconds
        armed.countIn = Task {
            while true {
                try await Task.sleep(for: .seconds(1))
                // Esc or a dismiss can cancel after the sleep returned but before this resumes.
                try Task.checkCancellation()
                armed.remaining! -= 1
                if armed.remaining == 0 { return recordSelection() }
                refresh()
            }
        }
    }

    /// Closes the overlay, then asks the app to record the selection's whole even pixels (H.264 needs even sizes) in display points.
    private func recordSelection() {
        guard let displayID, let area = selection?.rect else { return NSSound.beep() }
        let showsCursor = armedRecording!.showsCursor
        var pixels = area.integral
        pixels.size.width -= pixels.width.truncatingRemainder(dividingBy: 2)
        pixels.size.height -= pixels.height.truncatingRemainder(dividingBy: 2)
        let points = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        dismiss()
        ScreenRecording.requested(displayID, points, showsCursor)
    }

    /// Armed: the red outline on the selection and the count in its middle, with no handles or action bar.
    func refreshRecording() {
        guard let armed = armedRecording, let rect = selection?.rect else { return }
        chrome.actionBar.isHidden = true
        view.overlays.showsHandles = false
        let box = view.viewRect(rect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        armed.outline.path = view.overlays.radii.scaled(by: 1 / scale).path(in: box.insetBy(dx: 1, dy: 1))
        armed.count.isHidden = armed.remaining == nil
        if let remaining = armed.remaining {
            armed.count.show("\(remaining)") { [NSTextField("\(remaining)", size: 64, weight: .semibold, mono: true, color: .white)] }
            armed.count.frame.origin = CGPoint(x: (box.midX - armed.count.frame.width / 2).rounded(), y: (box.midY - armed.count.frame.height / 2).rounded())
        }
    }
}
