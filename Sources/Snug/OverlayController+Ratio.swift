import AppKit
import ScreenshotCore

/// The selection's aspect ratio: Shift-P locks it as it is, P opens the preset menu.
extension OverlayController {
    /// Shift-P and the ratio chip's lock: locks the selection's ratio as it is, or unlocks it. The selection does not change.
    func toggleRatioLock() {
        guard let rect = selection?.rect else { return }
        lockedRatio = lockedRatio == nil ? rect.width / rect.height : nil
        refresh()
    }

    /// P and the ratio chip: the preset menu, under `anchor`. A pick conforms the selection once and locks that ratio: Free unlocks and
    /// leaves the rectangle alone, Original takes the ratio at release, and Portrait flips the presets and the current lock.
    func showRatioMenu(from anchor: NSView) {
        guard let selection else { return }
        // Picks conform the selection from before the first pick, so ratios do not compound; any other edit starts a new base.
        let base = ratioBase?.conformed == selection.rect ? ratioBase!.base : selection.rect
        let portrait = ratioPortrait ?? (base.height > base.width)
        let original = selection.original.width / selection.original.height
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Free", on: lockedRatio == nil) { [self] in
            lockedRatio = nil
            refresh()
        })
        menu.addItem(ActionMenuItem("Original", on: lockedRatio == original) { [self] in conformSelection(base, to: original) })
        for preset in RatioLock.allCases {
            let ratio = preset.ratio(portrait: portrait)
            menu.addItem(ActionMenuItem(preset.label(portrait: portrait), on: lockedRatio == ratio) { [self] in conformSelection(base, to: ratio) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Portrait", on: portrait) { [self] in
            ratioPortrait = !portrait
            if let lockedRatio { conformSelection(base, to: 1 / lockedRatio) }
        })
        ratioMenu = menu
        if !isHeadless { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.height : 0), in: anchor) }
    }

    /// The selection becomes the largest rectangle of `ratio` that fits inside `base` on its center, in whole pixels, and `ratio` locks.
    private func conformSelection(_ base: CGRect, to ratio: CGFloat) {
        let old = selection!.rect
        selection!.conform(base, to: ratio)
        lockedRatio = ratio
        ratioBase = (base, selection!.rect)
        carryRadii(from: old)
        refresh()
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
