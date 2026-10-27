import Foundation

/// Why a capture or recording could not use the display it was asked for. Its description is what the failure toast shows.
public enum CaptureError: LocalizedError, Equatable, Sendable {
    /// The display was disconnected, or its arrangement changed, between choosing it and capturing it.
    case displayUnavailable
    /// The pointer is on no display, as while displays are being rearranged.
    case noDisplayUnderPointer
    /// ScreenCaptureKit answered without an image.
    case noImage

    public var errorDescription: String? {
        switch self {
        case .displayUnavailable: "The display changed or was disconnected. Try again."
        case .noDisplayUnderPointer: "There is no display under the pointer. Try again."
        case .noImage: "The screenshot came back empty. Try again."
        }
    }
}
