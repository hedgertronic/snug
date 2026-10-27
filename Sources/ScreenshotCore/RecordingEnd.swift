import Foundation

/// How a recording's output ended, from whether it failed, whether that failure is the user's own stop, and whether it wrote frames.
public enum RecordingEnd: Equatable, Sendable {
    /// The file is complete: the output finished, or the user stopped it (from Snug or the system's screen-recording indicator).
    case finished
    /// The output failed after writing frames, as on a full disk: the file holds what was written and is kept, with a warning.
    case partial
    /// The output failed with nothing written.
    case failed

    public init(failed: Bool, userStopped: Bool, wroteFrames: Bool) {
        self = if !failed || userStopped { .finished } else if wroteFrames { .partial } else { .failed }
    }
}
