import AppKit
import ScreenshotCore

/// One undo step: everything an edit of the selection changes. `ratioBase` is the base and conformed rectangles.
struct SelectionState: Equatable {
    var selection: AreaSelection?
    var radii: CornerRadii?
    var lockedRatio: CGFloat?
    var ratioBase: [CGRect]?
    var ratioPortrait: Bool?
    var lastEditedCorner: Handle?
}

/// Selection editing: opening an element as a selection, growing it, corner dots, edge nudges, and undo.
extension OverlayController {
    var selectionState: SelectionState {
        get {
            SelectionState(selection: selection, radii: selection.flatMap { editedRadii[$0.rect] }, lockedRatio: lockedRatio,
                           ratioBase: ratioBase.map { [$0.base, $0.conformed] }, ratioPortrait: ratioPortrait, lastEditedCorner: lastEditedCorner)
        }
        set {
            selection = newValue.selection
            if let rect = selection?.rect { editedRadii[rect] = newValue.radii }
            lockedRatio = newValue.lockedRatio
            ratioBase = newValue.ratioBase.map { ($0[0], $0[1]) }
            ratioPortrait = newValue.ratioPortrait
            lastEditedCorner = newValue.lastEditedCorner
        }
    }

    /// After a change that started from `before`: a selection edited from one that existed is an undo step, unless `key` repeats the
    /// last edit's key within 0.5 s; a new selection, or none, starts the history over.
    func recordEdit(from before: SelectionState, key: String? = nil) {
        guard selectionState != before else { return }
        let now = ContinuousClock.now
        defer { lastEdit = key.map { ($0, now) } }
        redoStack = []
        guard before.selection != nil, selection != nil else { return undoStack = [] }
        if let key, let last = lastEdit, last.key == key, last.at.duration(to: now) < .milliseconds(500) { return }
        undoStack.append(before)
    }

    /// Cmd-Z: back to the state before the last edit; with `redo` (Cmd-Shift-Z), forward again. Nothing left: a beep.
    func undoEdit(redo: Bool) {
        guard let state = redo ? redoStack.popLast() : undoStack.popLast() else { return beep() }
        if redo { undoStack.append(selectionState) } else { redoStack.append(selectionState) }
        selectionState = state
        lastEdit = nil
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

    /// Shift-click with a selection open: the selection becomes the union of itself and `rect`, keeping its edited corners and
    /// dropping a locked ratio.
    func growSelection(toInclude rect: CGRect) {
        let old = selection!.rect
        cancelWork()
        selection = AreaSelection(extent: extent, exact: old.union(rect))
        lockedRatio = nil
        ratioBase = nil
        ratioPortrait = nil
        carryRadii(from: old)
        refresh()
    }

    /// A selection that moved or resized keeps its edited corners, clamped to its new size.
    func carryRadii(from old: CGRect) {
        guard let new = selection?.rect, new != old, let radii = editedRadii[old] else { return }
        editedRadii[new] = radii.offset(by: 0, in: new.size)
    }

    /// The radius Rounded detects at `corner` of `rect`: the radius measured for `rect` (the corner's own arc when its corners agree on
    /// none), or its window's where the corner sits on the window's corner. Nil until measured, or when it is 0 (square, or nothing
    /// consistent found).
    func detectedRadius(_ corner: Handle, of rect: CGRect) -> CGFloat? {
        let radius = radii[rect] ?? 0, arcs = arcs[rect] ?? .zero
        var detected = radius > 0 ? CornerRadii(radius) : arcs
        if let window = container(of: rect), let windowRadius = radii[window] {
            detected = detected.replacingCorners(sharedWith: window, in: rect, with: windowRadius, arcs: arcs)
        }
        return detected[corner] > 0 ? detected[corner] : nil
    }

    /// `=` and the chip: the hovered corner's radius (else the last-edited corner's, else the largest) goes to all four corners.
    func applyRadiusToAll() {
        guard let rect = selection?.rect else { return }
        let current = cornerRadii(of: rect)
        let radius = (hoveredCorner ?? lastEditedCorner).map { current[$0] } ?? CornerRadii.corners.map { current[$0] }.max()!
        editedRadii[rect] = CornerRadii(radius).offset(by: 0, in: rect.size)
        refresh()
    }

    /// The hovered corner follows the pointer onto a dot and stays while it travels from the dot to that corner's chip.
    func updateHoveredCorner() {
        let viewPoint = CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale)
        let corner = selection == nil ? nil : hoveredCorner != nil && cornerChipPath.contains(viewPoint) ? hoveredCorner : cornerDot(at: pointer)
        guard corner != hoveredCorner else { return }
        hoveredCorner = corner
        refresh()
    }

    /// The chip and the gap between it and the hovered corner's dot, in view points.
    private var cornerChipPath: CGRect {
        guard let corner = hoveredCorner, let rect = selection?.rect else { return .null }
        let dot = cornerRadii(of: rect).dot(of: corner, in: rect, minimumInset: 8 * scale)
        let dotBox = CGRect(x: dot.x / scale - 6, y: view.bounds.height - dot.y / scale - 6, width: 12, height: 12)
        return cornerChip.frame.union(dotBox).insetBy(dx: -2, dy: -2)
    }

    /// Shows the "All corners" chip just outside the hovered corner, beside the selection's side: left of the left corners, right of the
    /// right ones, hanging inward from the top corners' edge and rising from the bottom ones'. Inside the corner when there is no room outside.
    func layoutCornerChip() {
        guard let corner = hoveredCorner, let rect = selection?.rect, scrollArea == nil, mode == .capture else { return cornerChip.isHidden = true }
        let box = view.viewRect(rect)
        let size = cornerChip.frame.size
        let gap: CGFloat = 6
        let outside = corner.movesLeft ? box.minX - gap - size.width : box.maxX + gap
        let fits = outside >= 8 && outside + size.width <= view.bounds.width - 8
        let inside = corner.movesLeft ? box.minX + 14 : box.maxX - 14 - size.width
        cornerChip.frame.origin = CGPoint(x: fits ? outside : inside, y: corner.movesTop ? box.maxY - size.height : box.minY)
        cornerChip.isHidden = false
    }

    /// An arrow-key move of the selection, keeping its edited corners.
    func nudge(_ delta: CGPoint) {
        guard let old = selection?.rect else { return }
        selection!.move(by: delta)
        carryRadii(from: old)
    }

    /// Option-arrow moves only the side facing the arrow, outward; Option-Command-arrow moves it inward, by `pixels` image pixels.
    /// A locked ratio holds: the other dimension follows about the center.
    func nudgeSide(keyCode: UInt16, outward: Bool, by pixels: CGFloat) {
        let (side, direction): (Handle, CGPoint) = switch keyCode {
        case 123: (.left, CGPoint(x: -1, y: 0))
        case 124: (.right, CGPoint(x: 1, y: 0))
        case 125: (.bottom, CGPoint(x: 0, y: 1))
        default: (.top, CGPoint(x: 0, y: -1))
        }
        let old = selection!.rect
        let from = side.position(on: old)
        let distance = outward ? pixels : -pixels
        selection!.resize(side, to: CGPoint(x: from.x + direction.x * distance, y: from.y + direction.y * distance), ratio: lockedRatio)
        carryRadii(from: old)
    }

    /// `+` / `-`: every side moves out (or in, with a negative count) by `pixels` image pixels, within the extent and the minimum size.
    /// A locked ratio holds: each corner follows the larger travel from the opposite one.
    func growSides(by pixels: CGFloat) {
        guard let old = selection?.rect else { return }
        selection!.resize(.topLeft, to: CGPoint(x: old.minX - pixels, y: old.minY - pixels), ratio: lockedRatio)
        let grown = selection!.rect
        selection!.resize(.bottomRight, to: CGPoint(x: grown.maxX + pixels, y: grown.maxY + pixels), ratio: lockedRatio)
        carryRadii(from: old)
    }

    /// Command-arrow moves the side facing the arrow outward to the next pixel edge along it, up to the extent; Command-Shift-arrow
    /// moves it inward, keeping the minimum size. The search steps away from the side 128 px at a time, so a near edge is found
    /// without scanning to the extent. A sharp edge reads as a run of neighboring positions, so each run counts once, at its middle,
    /// and the run the side sits on is skipped. With no edge in the way, nothing moves.
    func moveSideToEdge(keyCode: UInt16, outward: Bool) {
        guard let image, let rect = selection?.rect else { return }
        let vertical = keyCode == 123 || keyCode == 124
        let maxSide = keyCode == 124 || keyCode == 125
        let (low, high) = vertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
        let side = maxSide ? high : low
        let limit = outward ? (maxSide ? (vertical ? extent.maxX : extent.maxY) : 0)
            : maxSide ? low + AreaSelection.minimumSize : high - AreaSelection.minimumSize
        let direction: CGFloat = limit > side ? 1 : -1
        var start = side
        while (limit - start) * direction > 0 {
            let end = direction > 0 ? min(start + 128, limit) : max(start - 128, limit)
            // 2 px past each end, so a run at either end is whole. Cancellation is the only error and a key press is never cancelled.
            let found = try! SmartSnap().edges(in: image, of: rect, vertical: vertical, near: (start + end) / 2, band: Int(abs(end - start) / 2) + 2, limit: .max)
            var runs: [[CGFloat]] = []
            for position in found.sorted() {
                if let last = runs.last?.last, position - last <= 1 { runs[runs.count - 1].append(position) } else { runs.append([position]) }
            }
            let edges = runs.map { $0[$0.count / 2] }.filter { abs($0 - side) > 1 && ($0 - start) * direction > 0 && ($0 - end) * direction <= 0 }
            if let edge = edges.min(by: { abs($0 - side) < abs($1 - side) }) { return nudgeSide(keyCode: keyCode, outward: outward, by: abs(edge - side)) }
            start = end
        }
        beep()
    }
}
