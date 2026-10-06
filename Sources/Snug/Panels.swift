import AppKit

/// The segmented A / E / T bar at the top center of the overlay.
@MainActor
final class ModeBar: NSVisualEffectView {
    var onMode: (OverlayController.Mode) -> Void = { _ in }
    private let segments = NSSegmentedControl()
    private(set) var modes: [OverlayController.Mode] = []

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 10
        segments.trackingMode = .selectOne
        segments.target = self
        segments.action = #selector(picked)
        addSubview(segments)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the modes in order, highlighting `mode`. Element only appears when `elementEnabled`.
    func update(mode: OverlayController.Mode, elementEnabled: Bool) {
        let wanted: [OverlayController.Mode] = elementEnabled ? [.area, .element, .text] : [.area, .text]
        if wanted != modes {
            modes = wanted
            segments.segmentCount = wanted.count
            for (index, mode) in wanted.enumerated() { segments.setLabel(String(describing: mode).capitalized, forSegment: index) }
            segments.sizeToFit()
            segments.frame.origin = CGPoint(x: 6, y: 6)
            frame.size = CGSize(width: segments.frame.width + 12, height: segments.frame.height + 12)
        }
        segments.selectedSegment = modes.firstIndex(of: mode)!
    }

    /// Clicks the segment for `mode`, as the pointer would.
    func click(_ mode: OverlayController.Mode) {
        segments.selectedSegment = modes.firstIndex(of: mode)!
        segments.sendAction(segments.action, to: segments.target)
    }

    @objc private func picked() { onMode(modes[segments.selectedSegment]) }
}

/// A material panel with tab-aligned text, used for the help sheet and the candidate list.
@MainActor
final class InfoPanel: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 14, y: 12)
            frame.size = CGSize(width: label.frame.width + 28, height: label.frame.height + 24)
        }
    }

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 12
        isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}
