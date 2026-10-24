import CoreGraphics
import ScreenshotCore
import Testing

struct ChromiumTextTests {
    @Test func aBundleEmbedsChromiumWhenItHasAProductFramework() {
        #expect(ChromiumText.embedsChromium(frameworks: ["Electron Framework.framework", "Mantle.framework", "Squirrel.framework"]))
        #expect(ChromiumText.embedsChromium(frameworks: ["Google Chrome Framework.framework"]))
        #expect(ChromiumText.embedsChromium(frameworks: ["Microsoft Edge Framework.framework", "Sparkle.framework"]))
        #expect(ChromiumText.embedsChromium(frameworks: ["Brave Browser Framework.framework"]))
        #expect(ChromiumText.embedsChromium(frameworks: ["Chromium Framework.framework"]))
        #expect(!ChromiumText.embedsChromium(frameworks: ["Sparkle.framework", "Framework.framework", "Electron.framework"]))
        #expect(!ChromiumText.embedsChromium(frameworks: []))
    }

    @Test func wordsSplitAtCharacterWhitespaceWithUTF16Ranges() {
        // A no-break space is whitespace to `Character`; the emoji is two UTF-16 units.
        let words = ChromiumText.words(in: " a\u{00A0}b  \u{1F600}x c\n")
        #expect(words.map(\.text) == ["a", "b", "\u{1F600}x", "c"])
        #expect(words.map(\.utf16) == [1..<2, 3..<4, 6..<9, 10..<11])
        #expect(ChromiumText.words(in: "").isEmpty && ChromiumText.words(in: " \n ").isEmpty)
    }

    func piece(_ text: String, _ x: CGFloat, _ y: CGFloat = 100, width: CGFloat? = nil, spaced: Bool = true) -> ChromiumText.Piece {
        .init(text: text, box: CGRect(x: x, y: y, width: width ?? CGFloat(text.count) * 7, height: 14), spaceBefore: spaced)
    }

    @Test func wordsOnOneRowAreOneLineAndAWrapStartsAnother() {
        let sources = ChromiumText.sources(of: [piece("Delaying", 904), piece("push", 970), piece("changes", 545, 118), piece("until", 600, 118)])
        #expect(sources.map(\.text) == ["Delaying push", "changes until"])
        #expect(sources[0].words == [CGRect(x: 904, y: 100, width: 56, height: 14), CGRect(x: 970, y: 100, width: 28, height: 14)])
        #expect(sources[1].box == CGRect(x: 545, y: 118, width: 90, height: 14))
    }

    @Test func fragmentsOfOneRowJoinAndTouchingOnesFuse() {
        // "link" then "." from the next element, touching and with no space before it, then a word after a space.
        let sources = ChromiumText.sources(of: [piece("See", 10), piece("link", 40), piece(".", 68, spaced: false), piece("Next", 82)])
        #expect(sources.map(\.text) == ["See link. Next"])
        #expect(sources[0].words == [CGRect(x: 10, y: 100, width: 21, height: 14), CGRect(x: 40, y: 100, width: 35, height: 14), CGRect(x: 82, y: 100, width: 28, height: 14)])
        // Unspaced neighbors with a gap between them (table cells) are words of their own.
        #expect(ChromiumText.sources(of: [piece("Name", 10), piece("Status", 60, spaced: false)]).map(\.text) == ["Name Status"])
    }

    @Test func cellsFarApartAreLinesOfTheirOwnInDocumentOrder() {
        // A sidebar's two items and the page's two rows, in document order: the page's first row sits at the first item's height but far
        // to its right, so it is a line of its own and the second item does not join it.
        let sources = ChromiumText.sources(of: [piece("Home", 20, 100), piece("Title", 400, 100), piece("DMs", 20, 140), piece("Body", 400, 140)])
        #expect(sources.map(\.text) == ["Home", "Title", "DMs", "Body"])
    }

    @Test func eachLineCarriesOneBoxPerRunOfItsText() {
        // The emoji word and the "c" touching it from the next element are one word with one box, and ScreenText spreads the
        // characters of that box.
        let sources = ChromiumText.sources(of: [piece("a", 0), piece("b", 10), piece("\u{1F600}x", 30), piece("c", 44, spaced: false)])
        #expect(sources.map(\.text) == ["a b \u{1F600}xc"])
        #expect(ChromiumText.words(in: sources[0].text).count == sources[0].words!.count)
        let text = ScreenText(lines: sources, frame: CGRect(x: 0, y: 90, width: 100, height: 40), window: 0)
        #expect(text.highlight(from: .init(line: 0, column: 4), to: .init(line: 0, column: 5)) == [CGRect(x: 30, y: 100, width: 7, height: 14)])
        #expect(text.position(at: CGPoint(x: 50, y: 105)) == .init(line: 0, column: 7))
    }
}
