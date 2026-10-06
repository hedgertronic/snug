import AppKit
import ScreenshotCore

/// The bar under a released selection: output style, Save, and Copy.
@MainActor
final class StyleBar: NSVisualEffectView {
    var onStyle: (OutputStyle) -> Void = { _ in }
    var onSave: () -> Void = {}
    var onCopy: () -> Void = {}
    private let segments = NSSegmentedControl(labels: OutputStyle.allCases.map { $0.rawValue.capitalized },
                                              trackingMode: .selectOne, target: nil, action: nil)

    var style: OutputStyle {
        get { OutputStyle.allCases[segments.selectedSegment] }
        set { segments.selectedSegment = OutputStyle.allCases.firstIndex(of: newValue)! }
    }

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 10
        segments.target = self
        segments.action = #selector(styleChanged)
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copy.bezelColor = .controlAccentColor
        for button in [save, copy] { button.bezelStyle = .rounded; button.controlSize = .regular }
        let stack = NSStackView(views: [segments, save, copy])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        frame.size = stack.frame.size
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func styleChanged() { onStyle(style) }
    @objc private func saveTapped() { onSave() }
    @objc private func copyTapped() { onCopy() }
}
