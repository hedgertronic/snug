import Foundation

/// One accessibility operation's allowance across all of its messages: a deadline and a number of elements. Each message's own timeout
/// bounds one call; this bounds the whole walk, so a slow app or a wide or cyclic tree cannot outlast it. A canceled task has spent it.
/// It belongs to one walk on one thread.
public final class AXBudget {
    public let deadline: ContinuousClock.Instant
    public let elements: Int
    public private(set) var visited = 0

    public init(time: Duration, elements: Int) {
        deadline = .now + time
        self.elements = elements
    }

    /// Whether the time, the elements or the task is spent.
    public var isSpent: Bool { visited >= elements || ContinuousClock.now >= deadline || Task.isCancelled }

    /// Counts one more element and returns whether it may be read: false once the budget is spent.
    public func visit() -> Bool {
        guard !isSpent else { return false }
        visited += 1
        return true
    }
}
