import Foundation
import Testing
@testable import ScreenshotCore

struct AXBudgetTests {
    @Test func theElementCountEndsTheWalk() {
        let budget = AXBudget(time: .seconds(60), elements: 3)
        #expect((0..<5).map { _ in budget.visit() } == [true, true, true, false, false])
        #expect(budget.isSpent && budget.visited == 3)
    }

    @Test func theDeadlineEndsTheWalk() async throws {
        let budget = AXBudget(time: .milliseconds(20), elements: 1000)
        #expect(budget.visit())
        try await Task.sleep(for: .milliseconds(40))
        #expect(!budget.visit() && budget.isSpent)
    }

    @Test func aCanceledTaskHasSpentIt() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return AXBudget(time: .seconds(60), elements: 1000).visit()
        }
        #expect(await task.value == false)
    }
}
