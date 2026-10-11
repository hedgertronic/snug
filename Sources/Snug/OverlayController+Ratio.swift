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

    /// P and the ratio chip: the preset menu, under the chip. A pick conforms the selection once and locks that ratio: Free unlocks and
    /// leaves the rectangle alone, Original takes the ratio at release, and Portrait flips the presets and the current lock.
    func showRatioMenu() {
        guard let selection else { return }
        // Picks conform the selection from before the first pick, so ratios do not compound; any other edit starts a new base.
        let base = ratioBase?.conformed == selection.rect ? ratioBase!.base : selection.rect
        let portrait = ratioPortrait ?? (base.height > base.width)
        let original = selection.original.width / selection.original.height
        let presets = RatioLock.allCases.map { preset in
            let ratio = preset.ratio(portrait: portrait)
            return RatioMenu.Item(title: preset.label(portrait: portrait), on: lockedRatio == ratio) { [self] in conformSelection(base, to: ratio) }
        }
        let free = RatioMenu.Item(title: "Free", on: lockedRatio == nil) { [self] in
            lockedRatio = nil
            refresh()
        }
        let flip = RatioMenu.Item(title: "Portrait", on: portrait) { [self] in
            ratioPortrait = !portrait
            if let lockedRatio { conformSelection(base, to: 1 / lockedRatio) }
        }
        chrome.ratioMenu.open([free, RatioMenu.Item(title: "Original", on: lockedRatio == original) { [self] in conformSelection(base, to: original) }]
                                + presets + [RatioMenu.Item(title: "", on: false) {}, flip], under: chrome.ratio.frame)
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
