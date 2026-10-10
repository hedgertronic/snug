import AppKit

/// Screen recording: V on a released selection, or on the hovered element or window, closes the overlay and asks the app to
/// record that area of the display.
extension OverlayController {
    func startRecording() {
        guard let displayID, let area = selection?.rect ?? hoverRect else { return NSSound.beep() }
        // Whole pixels, shrunk to even sizes for H.264, then display points.
        var pixels = area.integral
        pixels.size.width -= pixels.width.truncatingRemainder(dividingBy: 2)
        pixels.size.height -= pixels.height.truncatingRemainder(dividingBy: 2)
        let points = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        dismiss()
        ScreenRecording.requested(displayID, points)
    }
}
