/// Runs async work over many items with at most a fixed number running at once.
public enum BoundedConcurrency {
    /// `transform` of each item, in the items' order, with at most `limit` running at once. Each item starts only if the task is not
    /// canceled; the first error (or cancellation) ends the map and cancels the work still running.
    public static func map<Item: Sendable, Result: Sendable>(_ items: [Item], limit: Int,
                                                             _ transform: @escaping @Sendable (Item) async throws -> Result) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: items.count)
            var next = 0
            func start() throws {
                try Task.checkCancellation()
                let (index, item) = (next, items[next])
                group.addTask { (index, try await transform(item)) }
                next += 1
            }
            while next < min(max(1, limit), items.count) { try start() }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < items.count { try start() }
            }
            return results.map { $0! }
        }
    }
}
