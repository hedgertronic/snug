import Foundation
import Testing
@testable import ScreenshotCore

struct ProcessWatchTests {
    private func launch(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    @Test func aChildThatExitsInTimeIsLeftAlone() async throws {
        let child = try launch("sleep 0.1")
        #expect(await ProcessWatch.wait(for: child, timeout: .seconds(10), poll: .milliseconds(20)) == .exited)
        #expect(child.terminationReason == .exit && child.terminationStatus == 0)
    }

    @Test func aChildPastTheDeadlineIsTerminatedAndReaped() async throws {
        let child = try launch("sleep 30")
        let began = ContinuousClock.now
        #expect(await ProcessWatch.wait(for: child, timeout: .milliseconds(200), poll: .milliseconds(20)) == .timedOut)
        #expect(!child.isRunning && child.terminationReason == .uncaughtSignal)
        // Far under the child's 30 s, with room for a loaded machine running the other suites at once.
        #expect(began.duration(to: .now) < .seconds(20), "\(began.duration(to: .now))")
    }

    @Test func aChildThatIgnoresTerminateIsKilledAfterTheGrace() async throws {
        let child = try launch("trap '' TERM; sleep 30")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await ProcessWatch.wait(for: child, timeout: .milliseconds(100), poll: .milliseconds(20), grace: .milliseconds(200)) == .timedOut)
        #expect(!child.isRunning && child.terminationStatus == SIGKILL)
    }

    @Test func aCanceledWaitStopsTheChild() async throws {
        let child = try launch("sleep 30")
        let waiting = Task { await ProcessWatch.wait(for: child, timeout: .seconds(60), poll: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        #expect(await waiting.value == .canceled)
        #expect(!child.isRunning)
    }
}
