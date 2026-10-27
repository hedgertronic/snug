import Foundation

/// Waits for a child process with a deadline, and never leaves one running behind a wait that ended.
public enum ProcessWatch {
    public enum End: Equatable, Sendable {
        case exited, timedOut, canceled
    }

    /// Waits for `process` to exit, checking every `poll`. Past `timeout`, or once the waiting task is canceled, it asks the process to
    /// terminate, kills it if it is still running `grace` later, and waits until it has exited, so it is reaped.
    @concurrent
    public static func wait(for process: Process, timeout: Duration, poll: Duration = .milliseconds(250), grace: Duration = .seconds(1)) async -> End {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                let end: End = Task.isCancelled ? .canceled : .timedOut
                stop(process, grace: grace)
                return end
            }
            try? await Task.sleep(for: min(poll, max(.zero, ContinuousClock.now.duration(to: deadline))))
        }
        return .exited
    }

    private static func stop(_ process: Process, grace: Duration) {
        process.terminate()
        let killAt = ContinuousClock.now + grace
        while process.isRunning, ContinuousClock.now < killAt { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
