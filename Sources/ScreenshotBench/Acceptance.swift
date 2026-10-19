import CoreGraphics
import ScreenshotCore

/// The v1 acceptance rule: every edge within 8 logical points of an accepted rectangle, measured in the capture's pixels at its scale.
public enum Acceptance {
    public static let edgePoints = 8.0

    public static func accepts(_ rect: CGRect, _ accepted: CGRect, scale: Int) -> Bool {
        max(abs(rect.minX - accepted.minX), abs(rect.maxX - accepted.maxX),
            abs(rect.minY - accepted.minY), abs(rect.maxY - accepted.maxY)) <= edgePoints * Double(scale)
    }

    /// The fewest key presses, at most `limit`, after which the hover selection satisfies `accepts`; nil when none do. The keys are the
    /// ones hover takes in the overlay: Up and Tab expand, Down and Shift-Tab shrink, Left and Right step to a peer, W takes the window
    /// under the pointer, and 1-5 pick from the candidate list when `candidateList` is on (it is off by default).
    public static func corrections(from start: SelectionSession, candidateList: Bool, limit: Int = 2,
                                   accepts: (CGRect) -> Bool) -> Int? {
        var frontier = [start]
        for depth in 0...limit {
            if frontier.contains(where: { $0.selected.map { accepts($0.bounds) } ?? false }) { return depth }
            frontier = frontier.flatMap { state -> [SelectionSession] in
                var next: [SelectionSession] = []
                for key in 0..<(candidateList ? 10 : 5) {
                    var moved = state
                    switch key {
                    case 0: moved.expand()
                    case 1: moved.shrink()
                    case 2: if !moved.step(right: true) { continue }
                    case 3: if !moved.step(right: false) { continue }
                    case 4: moved.select(kind: .window)
                    default: moved.pick(key - 5)
                    }
                    next.append(moved)
                }
                return next
            }
        }
        return nil
    }
}
