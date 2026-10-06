import Foundation

/// Pure selection state shared by the app and navigation tests.
public struct SelectionSession: Sendable {
    public private(set) var candidates: [Candidate]
    public private(set) var selected: Candidate?
    public private(set) var isLocked = false
    public private(set) var anchor: CGPoint
    public let extent: CGRect
    private var shortlist: [Candidate] = []
    private var expansionPath: [Candidate] = []
    private var specialReturn: Candidate?

    /// Starts with supplied content regions and a full-image fallback.
    public init(candidates: [Candidate], extent: CGRect, anchor: CGPoint) {
        self.extent = extent
        self.anchor = anchor
        self.candidates = Detection.normalized(candidates, within: extent)
        if !self.candidates.contains(where: { $0.kind == .display }) {
            self.candidates.append(Candidate(id: "display", label: "Full image", bounds: extent, score: -100, kind: .display))
        }
        hover(at: anchor)
    }

    /// Updates the anchor and selection only while hover is unlocked.
    public mutating func hover(at point: CGPoint) {
        guard !isLocked else { return }
        anchor = point
        let local = candidates.filter { $0.bounds.contains(point) }
        let content = local.filter { $0.kind != .display && $0.kind != .window }
            .sorted { a, b in a.score == b.score ? a.bounds.width * a.bounds.height < b.bounds.width * b.bounds.height : a.score > b.score }
        let detail = content.filter {
            if $0.kind == .text {
                let text = $0
                if let hits = text.hitRegions, !hits.contains(where: { $0.contains(point) }) { return false }
                // Broad OCR blocks spanning cells should not hide the table's grid.
                return !content.contains {
                    $0.kind == .cell && text.bounds.intersection($0.bounds).width > $0.bounds.width * 0.8
                        && text.bounds.intersection($0.bounds).height > $0.bounds.height * 0.8
                }
            }
            if $0.kind == .cell {
                let inset = min(6, min($0.bounds.width, $0.bounds.height) * 0.15)
                return $0.bounds.insetBy(dx: inset, dy: inset).contains(point)
            }
            return false
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .text }
            return $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
        let containers = content.filter { $0.kind != .cell && $0.kind != .text }
        let remainingDetails = content.filter { item in
            (item.kind == .cell || item.kind == .text) && !detail.contains(where: { $0.id == item.id })
        }
        shortlist = Array(detail.prefix(4)) + Array(containers.prefix(4)) + Array(remainingDetails.prefix(2))
            + local.filter { $0.kind == .window || $0.kind == .display }
        selected = detail.first ?? containers.first
            ?? local.first(where: { $0.kind == .window || $0.kind == .display })
            ?? candidates.first(where: { $0.kind == .display })
        expansionPath = []
        specialReturn = nil
    }

    /// Cycles stable alternative regions at the current anchor.
    public mutating func cycle(backward: Bool = false) {
        isLocked = true
        guard !shortlist.isEmpty else { return }
        let current = shortlist.firstIndex(where: { $0.id == selected?.id }) ?? (backward ? 0 : -1)
        selected = shortlist[(current + (backward ? -1 : 1) + shortlist.count) % shortlist.count]
        expansionPath = []
    }

    /// Selects the smallest larger enclosing proposal.
    public mutating func expand() {
        isLocked = true
        guard let current = selected else { return }
        let larger = candidates.filter {
            $0.id != current.id && $0.bounds.insetBy(dx: -1, dy: -1).contains(current.bounds)
                && $0.bounds.width * $0.bounds.height > current.bounds.width * current.bounds.height + 1
        }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        if let larger { expansionPath.append(current); selected = larger }
    }

    /// Reverses expansion, or finds a contained region at the anchor.
    public mutating func shrink() {
        isLocked = true
        if let previous = expansionPath.popLast() { selected = previous; return }
        guard let current = selected else { return }
        selected = candidates.filter {
            $0.id != current.id && current.bounds.contains($0.bounds) && $0.bounds.contains(anchor)
                && $0.bounds.width * $0.bounds.height < current.bounds.width * current.bounds.height - 1
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height } ?? current
    }

    /// Changes pointer locking without modifying the selected rectangle.
    public mutating func toggleLock() { isLocked.toggle() }

    /// Selects a window/display fallback; repeating restores the preceding selection.
    public mutating func select(kind: CandidateKind) {
        isLocked = true
        if selected?.kind == kind, let previous = specialReturn {
            selected = previous; specialReturn = nil
        } else if let next = candidates.first(where: { $0.kind == kind && $0.bounds.contains(anchor) }) {
            specialReturn = selected; selected = next
        }
    }

    /// Sets an explicit crop, constrained to the source image.
    public mutating func setManual(_ rectangle: CGRect) {
        let rectangle = rectangle.standardized.intersection(extent)
        guard !rectangle.isNull, rectangle.width >= 1, rectangle.height >= 1 else { return }
        isLocked = true
        selected = Candidate(id: "manual", label: "Manual crop", bounds: rectangle, score: 1, kind: .manual)
        expansionPath = []
    }

    /// Moves a manual rectangle while preserving its dimensions at the image edges.
    public mutating func moveManual(dx: CGFloat, dy: CGFloat) {
        guard let selected, selected.kind == .manual else { return }
        var rectangle = selected.bounds.offsetBy(dx: dx, dy: dy)
        rectangle.origin.x = max(extent.minX, min(rectangle.origin.x, extent.maxX - rectangle.width))
        rectangle.origin.y = max(extent.minY, min(rectangle.origin.y, extent.maxY - rectangle.height))
        setManual(rectangle)
    }
}
