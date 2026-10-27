import Foundation
import Testing
@testable import ScreenshotCore

struct RecordingEndTests {
    @Test func aFinishedOutputOrTheUsersStopIsComplete() {
        #expect(RecordingEnd(failed: false, userStopped: false, wroteFrames: true, stopping: false, writeFailure: false) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: true, wroteFrames: true, stopping: false, writeFailure: false) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: true, wroteFrames: false, stopping: false, writeFailure: false) == .finished)
    }

    @Test func aWriteFailureAfterFramesKeepsThePartialFileAndAnyFailureBeforeThemFails() {
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: true, stopping: false, writeFailure: true) == .partial)
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: false, stopping: false, writeFailure: true) == .failed)
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: false, stopping: true, writeFailure: false) == .failed)
    }

    /// The system's screen-recording indicator can end the output with a code other than `userStopped`, before or after the stream stops.
    @Test func aFailureWhileStoppingOrThatIsNotAWriteFailureFinishes() {
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: true, stopping: true, writeFailure: false) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: true, stopping: true, writeFailure: true) == .finished)
        #expect(RecordingEnd(failed: true, userStopped: false, wroteFrames: true, stopping: false, writeFailure: false) == .finished)
    }

    @Test func writeFailuresAreStorageEncoderAndFileWriteErrors() {
        let writes = [NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3822),
                      NSError(domain: "AVFoundationErrorDomain", code: -11807), NSError(domain: "AVFoundationErrorDomain", code: -11883),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
        for error in writes { #expect(RecordingEnd.isWriteFailure(error), "\(error.domain) \(error.code)") }
        let others = [NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3817),
                      NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3821),
                      NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3811),
                      NSError(domain: "AVFoundationErrorDomain", code: -11800), NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)]
        for error in others { #expect(!RecordingEnd.isWriteFailure(error), "\(error.domain) \(error.code)") }
    }

    @Test func aWriteFailureUnderAnotherErrorCounts() {
        let disk = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: disk])
        #expect(RecordingEnd.isWriteFailure(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3811, userInfo: [NSUnderlyingErrorKey: wrapped])))
    }
}
