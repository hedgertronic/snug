import AppKit

/// The scroll session's thumbnail of the stitched image so far, with a thin outline over the part the area shows now: the bottom of
/// the image. It sits in the overlay window, which captures leave out, so it never reaches a frame.
@MainActor
final class Minimap: NSView {
    private let marker = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = 4
        layer!.masksToBounds = true
        layer!.contentsGravity = .resize
        marker.borderWidth = 1.5
        marker.cornerRadius = 2
        layer!.addSublayer(marker)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `thumbnail` at `size` points, the outline `shown` of its height from the bottom.
    func show(_ thumbnail: CGImage, size: CGSize, shown: CGFloat, tint: NSColor) {
        frame.size = size
        layer!.contents = thumbnail
        marker.frame = CGRect(x: 0, y: 0, width: size.width, height: max(size.height * shown, 3))
        effectiveAppearance.performAsCurrentDrawingAppearance { marker.borderColor = tint.cgColor }
    }
}
