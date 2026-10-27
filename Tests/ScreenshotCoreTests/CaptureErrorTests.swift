import Foundation
import Testing
@testable import ScreenshotCore

struct CaptureErrorTests {
    @Test func eachCaseDescribesItselfForTheFailureToast() {
        for error in [CaptureError.displayUnavailable, .noDisplayUnderPointer, .noImage] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect((error as NSError).localizedDescription == error.errorDescription, "the toast reads localizedDescription")
        }
    }
}
