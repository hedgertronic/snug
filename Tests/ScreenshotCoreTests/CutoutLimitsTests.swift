import Testing
@testable import ScreenshotCore

struct CutoutLimitsTests {
    @Test func oneInstanceIsOneChoiceAndSeveralAddEachAloneUpToTheCap() {
        #expect(CutoutLimits.choices(instances: 0, pixels: 1_000) == 0)
        #expect(CutoutLimits.choices(instances: 1, pixels: 1_000) == 1)
        #expect(CutoutLimits.choices(instances: 3, pixels: 1_000) == 4)
        #expect(CutoutLimits.choices(instances: 40, pixels: 1_000) == 1 + CutoutLimits.maximumInstances)
    }

    @Test func aLargeCropGetsFewerChoicesAndATooLargeOneNone() {
        // A 6016 x 3384 crop (a 6K display) takes 122 MB a choice: six fit in 768 MiB.
        #expect(CutoutLimits.choices(instances: 12, pixels: 6016 * 3384) == 6)
        #expect(CutoutLimits.choices(instances: 12, pixels: CutoutLimits.maximumPixels) == 2)
        #expect(CutoutLimits.choices(instances: 12, pixels: CutoutLimits.maximumPixels + 1) == nil)
        #expect(CutoutLimits.choices(instances: 2, pixels: 0) == nil)
    }
}
