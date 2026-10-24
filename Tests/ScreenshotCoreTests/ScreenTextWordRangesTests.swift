import ScreenshotCore
import Testing

struct ScreenTextWordRangesTests {
    @Test func wordsAreRunsOfNonSpaces() {
        #expect(ScreenText.wordRanges(in: "  Hello, world \n") == [2..<8, 9..<14])
        #expect(ScreenText.wordRanges(in: "   ").isEmpty)
    }

    @Test func rangesCountUTF16Units() {
        #expect(ScreenText.wordRanges(in: "a \u{1F600}\u{1F600} b") == [0..<1, 2..<6, 7..<8])
    }
}
