import Foundation

/// Pure selection state shared by the app and navigation tests.
public struct SelectionSession: Sendable {
    public private(set) var candidates: [Candidate]
    public private(set) var selected: Candidate?
    public private(set) var isLocked = false
    public private(set) var anchor: CGPoint
    public let extent: CGRect
    /// Stable alternatives at the anchor, best first.
    public private(set) var shortlist: [Candidate] = []
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
        let elements = content.filter { $0.kind == .element }
        let containers = content.filter { $0.kind != .cell && $0.kind != .text && $0.kind != .element }
        let remainingDetails = content.filter { item in
            (item.kind == .cell || item.kind == .text) && !detail.contains(where: { $0.id == item.id })
        }
        shortlist = Array(elements.prefix(4)) + Array(detail.prefix(4)) + Array(containers.prefix(4)) + Array(remainingDetails.prefix(2))
            + local.filter { $0.kind == .window || $0.kind == .display }
        // A regular grid's cell beats an accessibility element more than 4 times its size around it (a board drawn inside one web element).
        let cell = detail.first { cell in
            cell.label == GeometryDetector.gridCellLabel && elements.first.map { $0.bounds.contains(cell.bounds) && $0.bounds.width * $0.bounds.height > 4 * cell.bounds.width * cell.bounds.height } == true
        }
        selected = anchorAtEdge ? candidates.first(where: { $0.kind == .display }) : cell ?? elements.first ?? detail.first ?? containers.first
            ?? local.first(where: { $0.kind == .window || $0.kind == .display })
            ?? candidates.first(where: { $0.kind == .display })
        expansionPath = []
        specialReturn = nil
    }

    /// Whether the anchor is in the outermost 2 units of the extent, where a pointer pinned against the screen edge rests.
    public var anchorAtEdge: Bool { !extent.insetBy(dx: 2, dy: 2).contains(anchor) }

    /// Cycles stable alternative regions at the current anchor.
    public mutating func cycle(backward: Bool = false) {
        isLocked = true
        guard !shortlist.isEmpty else { return }
        let current = shortlist.firstIndex(where: { $0.id == selected?.id }) ?? (backward ? 0 : -1)
        selected = shortlist[(current + (backward ? -1 : 1) + shortlist.count) % shortlist.count]
        expansionPath = []
    }

    /// Selects the shortlist entry at `index`, if there is one.
    public mutating func pick(_ index: Int) {
        guard shortlist.indices.contains(index) else { return }
        isLocked = true
        selected = shortlist[index]
        expansionPath = []
    }

    /// The smallest proposal that encloses `candidate` and is larger than it.
    private func enclosing(_ candidate: Candidate) -> Candidate? {
        candidates.filter {
            // Accessibility frames and pixel edges of one element can disagree by a pixel or two.
            $0.id != candidate.id && $0.bounds.insetBy(dx: -3, dy: -3).contains(candidate.bounds)
                && $0.bounds.width * $0.bounds.height > candidate.bounds.width * candidate.bounds.height + 1
        }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// The selected region's parents, nearest first: what repeated `expand()` would select.
    public var parents: [Candidate] {
        var chain: [Candidate] = []
        var current = selected
        while let candidate = current, let parent = enclosing(candidate) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// Adds late results to the pool. Once the user has picked, the selection, shortlist, and expansion path stay as they are.
    public mutating func merge(_ added: [Candidate]) {
        let keep = (selected, shortlist, expansionPath, specialReturn)
        candidates = Detection.normalized(candidates + added, within: extent)
        if !isLocked {
            hover(at: anchor)
        } else {
            (selected, shortlist, expansionPath, specialReturn) = keep
        }
    }

    /// Selects the smallest larger enclosing proposal.
    public mutating func expand() {
        isLocked = true
        guard let current = selected, let larger = enclosing(current) else { return }
        expansionPath.append(current)
        selected = larger
    }

    /// What `shrink()` would select: the region expansion came from, else the largest smaller region inside the selection at the anchor.
    public var child: Candidate? {
        if let previous = expansionPath.last { return previous }
        guard let current = selected else { return nil }
        return candidates.filter {
            $0.id != current.id && current.bounds.insetBy(dx: -3, dy: -3).contains($0.bounds) && $0.bounds.contains(anchor)
                && $0.bounds.width * $0.bounds.height < current.bounds.width * current.bounds.height - 1
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// Reverses expansion, or finds a contained region at the anchor.
    public mutating func shrink() {
        isLocked = true
        guard let next = child else { return }
        if expansionPath.last?.id == next.id { expansionPath.removeLast() }
        selected = next
    }

    /// Whether a level picked with a key still holds with the pointer at `point`: while the pointer stays inside it, or for the
    /// display, which the pointer can never leave, while it stays within 12 units of where the level was picked.
    public func holds(at point: CGPoint) -> Bool {
        guard let selected else { return false }
        return selected.kind == .display ? hypot(point.x - anchor.x, point.y - anchor.y) <= 12 : selected.bounds.contains(point)
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
