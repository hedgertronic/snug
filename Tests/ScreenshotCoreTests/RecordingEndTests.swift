import Testing
@testable import ScreenshotCore

struct RecordingEndTests {
    @Test func aFinishedOutputOrTheUsersStopIsComplete() {
        #expect(RecordingEnd(failed: false, userStopped: false, wroteFrames: true) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: true, wroteFrames: true) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: true, wroteFrames: false) == .finished)
    }

    @Test func aFailureAfterFramesKeepsThePartialFileAndOneBeforeThemFails() {
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: true) == .partial)
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: false) == .failed)
    }
}
