import AppKit
import ScreenshotCore

/// Selection editing: opening an element as a selection, growing it, corner dots, and edge nudges.
extension OverlayController {
    /// The chip shows while a selection has edited corners that differ.
    var showsApplyChip: Bool {
        guard scrollArea == nil, let rect = selection?.rect, let edited = editedRadii[rect] else { return false }
        return Set(CornerRadii.corners.map { edited[$0] }).count > 1
    }

    /// The corner whose dot is under `point` (image pixels), if a selection is open.
    func cornerDot(at point: CGPoint) -> Handle? {
        guard let rect = selection?.rect else { return nil }
        return cornerRadii(of: rect).corner(at: point, in: rect, tolerance: 6 * scale, minimumInset: 8 * scale)
    }

    /// E and Shift-click on a hovered rectangle: it becomes an editable selection that keeps its corner radii, once they are measured.
    func openAsSelection(_ rect: CGRect) {
        cancelWork()
        selection = AreaSelection(extent: extent, exact: rect)
        let measuring = ([rect] + [container(of: rect)].compactMap { $0 }).compactMap { radiusTasks[$0] }
        Task {
            for task in measuring { _ = await task.value }
            guard selection?.rect == rect, editedRadii[rect] == nil else { return }
            editedRadii[rect] = cornerRadii(of: rect)
            refresh()
        }
    }

    /// Shift-click with a selection open: the selection becomes the union of itself and `rect`, keeping its edited corners.
    func growSelection(toInclude rect: CGRect) {
        let old = selection!.rect
        cancelWork()
        selection = AreaSelection(extent: extent, exact: old.union(rect))
        carryRadii(from: old)
        refresh()
    }

    /// A selection that moved or resized keeps its edited corners, clamped to its new size.
    func carryRadii(from old: CGRect) {
        guard let new = selection?.rect, new != old, let radii = editedRadii[old] else { return }
        editedRadii[new] = radii.offset(by: 0, in: new.size)
    }

    /// `=` and the chip: the last-edited corner's radius (the largest one when none was edited) goes to all four corners.
    func applyRadiusToAll() {
        guard let rect = selection?.rect else { return }
        let current = cornerRadii(of: rect)
        let radius = lastEditedCorner.map { current[$0] } ?? CornerRadii.corners.map { current[$0] }.max()!
        let applied = CornerRadii(radius).offset(by: 0, in: rect.size)
        editedRadii[rect] = applied
        showRadiusReadout(applied)
        refresh()
    }

    /// The size badge's text for a radius edit, e.g. "r 12" or "r 12 0 0 12" (top-left, top-right, bottom-left, bottom-right), for 1.5 s.
    func showRadiusReadout(_ radii: CornerRadii) {
        let points = CornerRadii.corners.map { Int((radii[$0] / scale).rounded()) }
        radiusReadout = "r " + (Set(points).count == 1 ? "\(points[0])" : points.map(String.init).joined(separator: " "))
        radiusReadoutTask?.cancel()
        radiusReadoutTask = Task {
            try await Task.sleep(for: .seconds(1.5))
            radiusReadout = nil
            refresh()
        }
    }

    /// An arrow-key move of the selection, keeping its edited corners.
    func nudge(_ delta: CGPoint) {
        guard let old = selection?.rect else { return }
        selection!.move(by: delta)
        carryRadii(from: old)
    }

    /// Option-arrow moves only the side facing the arrow, outward; Option-Command-arrow moves it inward.
    func nudgeSide(keyCode: UInt16, outward: Bool, by points: CGFloat) {
        let (side, direction): (Handle, CGPoint) = switch keyCode {
        case 123: (.left, CGPoint(x: -1, y: 0))
        case 124: (.right, CGPoint(x: 1, y: 0))
        case 125: (.bottom, CGPoint(x: 0, y: 1))
        default: (.top, CGPoint(x: 0, y: -1))
        }
        let old = selection!.rect
        let from = side.position(on: old)
        let distance = (outward ? points : -points) * scale
        selection!.resize(side, to: CGPoint(x: from.x + direction.x * distance, y: from.y + direction.y * distance))
        carryRadii(from: old)
    }
}
