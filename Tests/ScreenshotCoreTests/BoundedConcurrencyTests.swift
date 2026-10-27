import Foundation
import Synchronization
import Testing
@testable import ScreenshotCore

struct BoundedConcurrencyTests {
    final class Counter: Sendable {
        let state = Mutex((active: 0, peak: 0, started: 0))
        func enter() { state.withLock { $0.active += 1; $0.started += 1; $0.peak = max($0.peak, $0.active) } }
        func leave() { state.withLock { $0.active -= 1 } }
    }

    @Test func atMostTheLimitRunAtOnceAndResultsKeepTheirOrder() async throws {
        let counter = Counter()
        let results = try await BoundedConcurrency.map(Array(0..<24), limit: 4) { item in
            counter.enter()
            try await Task.sleep(for: .milliseconds(5 + (item * 7) % 11))
            counter.leave()
            return item * 2
        }
        #expect(results == (0..<24).map { $0 * 2 })
        #expect(counter.state.withLock { $0.peak } == 4)
    }

    @Test func cancellationStartsNoMoreItems() async throws {
        let counter = Counter()
        let mapping = Task {
            try await BoundedConcurrency.map(Array(0..<100), limit: 2) { item in
                counter.enter()
                try await Task.sleep(for: .milliseconds(50))
                counter.leave()
                return item
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        mapping.cancel()
        await #expect(throws: CancellationError.self) { try await mapping.value }
        #expect(counter.state.withLock { $0.started } <= 4)
    }
}
