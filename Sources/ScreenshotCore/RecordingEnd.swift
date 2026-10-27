import Foundation

/// How a recording's output ended, from whether it failed, whether that failure is a stop (the user's, Snug's own, or the stream's),
/// whether it is a failure to write the file, and whether it wrote frames.
public enum RecordingEnd: Equatable, Sendable {
    /// The file is complete: the output finished, or the recording was stopped (from Snug or the system's screen-recording indicator).
    case finished
    /// The output failed to write after writing frames, as on a full disk or an encoder error: the file holds what was written and is
    /// kept, with a warning.
    case partial
    /// The output failed with nothing written.
    case failed

    /// A finished output or a `userStopped` failure is complete. Any other failure with no frames written fails. After frames, a
    /// failure is a cut-short file (`partial`) only when it is a write or encoder failure (`isWriteFailure`) outside a deliberate
    /// stop; a failure during a deliberate stop (`stopping`, see `isDeliberateStop`), and any other code (an outside stop can
    /// report codes other than `userStopped`), finishes it.
    public init(failed: Bool, userStopped: Bool, wroteFrames: Bool, stopping: Bool, writeFailure: Bool) {
        self = if !failed || userStopped { .finished }
            else if !wroteFrames { .failed }
            else if stopping || !writeFailure { .finished }
            else { .partial }
    }

    /// Whether a stop ends the recording on purpose, so a failure that follows it finishes the file: Snug's own stop, begun while the
    /// stream ran, or the stream's stop for a reason other than a write failure (the system's screen-recording indicator). A stream that
    /// stopped for insufficient storage is not one.
    public static func isDeliberateStop(snugStopped: Bool, streamStopped: Bool, streamWriteFailure: Bool) -> Bool {
        snugStopped || (streamStopped && !streamWriteFailure)
    }

    /// Whether `error`, or an error under it (`NSUnderlyingErrorKey`), is a failure to write or encode the file: ScreenCaptureKit's
    /// insufficient storage, AVFoundation's out of memory, disk full, file size limit and encoder errors, Cocoa's file write errors,
    /// and POSIX no space, quota, I/O, read-only volume and file too large.
    public static func isWriteFailure(_ error: any Error) -> Bool {
        var next: NSError? = error as NSError
        // A chain that loops ends after a few levels.
        for _ in 0..<8 {
            guard let error = next else { return false }
            if writeFailures[error.domain]?(error.code) == true { return true }
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static let writeFailures: [String: @Sendable (Int) -> Bool] = [
        // SCStreamErrorInsufficientStorage.
        "com.apple.ScreenCaptureKit.SCStreamErrorDomain": { $0 == -3822 },
        // AVErrorOutOfMemory, DiskFull, MaximumFileSizeReached, EncoderNotFound, EncoderTemporarilyUnavailable, EncodeFailed.
        "AVFoundationErrorDomain": { [-11801, -11807, -11811, -11834, -11840, -11883].contains($0) },
        // NSFileWriteErrorMinimum through NSFileWriteErrorMaximum.
        NSCocoaErrorDomain: { (512...767).contains($0) },
        NSPOSIXErrorDomain: { [ENOSPC, EDQUOT, EIO, EROFS, EFBIG].map(Int.init).contains($0) },
    ]
}
