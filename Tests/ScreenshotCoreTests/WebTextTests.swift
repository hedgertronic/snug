import CoreGraphics
import ScreenshotCore
import Testing

struct WebTextTests {
    /// Safari's pieces for "pulse@examplefieldhouse.com": word ranges split at the "@".
    let email: [(text: String, box: CGRect)] = [("pulse", CGRect(x: 144, y: 262, width: 34, height: 16)), ("@", CGRect(x: 176, y: 262, width: 13, height: 16)),
                                                ("examplefieldhouse.com", CGRect(x: 187, y: 262, width: 133, height: 16))]

    @Test func significantLengthStopsBeforeTheNewlineSpacesAndAttachments() {
        #expect(WebText.significantLength(of: "INTERDAY DATA\n\u{FFFC}") == 13)
        #expect(WebText.significantLength(of: "RIVER, ") == 6)
        #expect(WebText.significantLength(of: "\n\u{FFFC}") == 0)
        #expect(WebText.significantLength(of: "39") == 2)
    }

    @Test func aLineOfOnlyNewlinesAttachmentsAndTabsIsNothing() {
        let box = CGRect(x: 95, y: 134, width: 289, height: 147)
        for line in ["\n", "\u{FFFC}\n", "\n\u{FFFC}", "\t\n", ""] {
            #expect(WebText.source(line: line, box: box, pieces: nil) == nil, "\(line.debugDescription)")
        }
    }

    @Test func attachmentsAndTheNewlineDropFromTheText() {
        let box = CGRect(x: 427, y: 150, width: 149, height: 17)
        let source = WebText.source(line: "INTERDAY DATA\n\u{FFFC}", box: box, pieces: nil)
        #expect(source?.text == "INTERDAY DATA")
        #expect(source?.box == box)
        #expect(source?.words == nil)
        #expect(WebText.source(line: "\u{FFFC}Hello\n", box: box, pieces: nil)?.text == "Hello")
    }

    @Test func piecesJoinIntoOneWordPerRunOfNonSpaces() throws {
        let source = try #require(WebText.source(line: "pulse@examplefieldhouse.com\n", box: CGRect(x: 144, y: 262, width: 176, height: 17), pieces: email))
        #expect(source.text == "pulse@examplefieldhouse.com")
        #expect(source.words == [CGRect(x: 144, y: 262, width: 176, height: 16)])
        #expect(source.box == CGRect(x: 144, y: 262, width: 176, height: 17))
    }

    @Test func spacePiecesSeparateWordsAndKeepTheirGaps() throws {
        let pieces: [(text: String, box: CGRect)] = [("Long", CGRect(x: 122, y: 386, width: 31, height: 17)), (" ", CGRect(x: 151, y: 386, width: 6, height: 17)),
                                                     ("Term", CGRect(x: 155, y: 386, width: 32, height: 17))]
        let source = try #require(WebText.source(line: "Long Term\n", box: CGRect(x: 122, y: 386, width: 65, height: 17), pieces: pieces))
        #expect(source.words == [CGRect(x: 122, y: 386, width: 31, height: 17), CGRect(x: 155, y: 386, width: 32, height: 17)])
    }

    @Test func aPieceHoldingSeveralWordsSpreadsItsBoxAcrossItsCharacters() throws {
        let pieces: [(text: String, box: CGRect)] = [("ab cd", CGRect(x: 0, y: 0, width: 50, height: 10))]
        let source = try #require(WebText.source(line: "ab cd", box: CGRect(x: 0, y: 0, width: 50, height: 10), pieces: pieces))
        #expect(source.words == [CGRect(x: 0, y: 0, width: 20, height: 10), CGRect(x: 30, y: 0, width: 20, height: 10)])
    }

    @Test func anImageBetweenWordsLeavesNoWordBox() throws {
        let pieces: [(text: String, box: CGRect)] = [("a", CGRect(x: 0, y: 0, width: 10, height: 10)), (" ", CGRect(x: 10, y: 0, width: 5, height: 10)),
                                                     ("\u{FFFC}", CGRect(x: 15, y: 0, width: 30, height: 30)), (" ", CGRect(x: 45, y: 0, width: 5, height: 10)),
                                                     ("b", CGRect(x: 50, y: 0, width: 10, height: 10))]
        let source = try #require(WebText.source(line: "a \u{FFFC} b\n", box: CGRect(x: 0, y: 0, width: 60, height: 10), pieces: pieces))
        #expect(source.text == "a  b")
        #expect(source.words == [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 50, y: 0, width: 10, height: 10)])
    }

    @Test func aLeadingAttachmentAndNewlineDropWithoutShiftingTheWords() throws {
        let pieces: [(text: String, box: CGRect)] = [("\u{FFFC}", CGRect(x: 0, y: 0, width: 20, height: 20)), ("hi", CGRect(x: 20, y: 0, width: 20, height: 10))]
        let source = try #require(WebText.source(line: "\u{FFFC}hi\n", box: CGRect(x: 0, y: 0, width: 40, height: 20), pieces: pieces))
        #expect(source.text == "hi")
        #expect(source.words == [CGRect(x: 20, y: 0, width: 20, height: 10)])
        #expect(source.box == CGRect(x: 20, y: 0, width: 20, height: 20))
    }

    @Test func piecesThatDoNotReproduceTheLineGiveNoWords() throws {
        // A wrapped line's word walk ran into the next line ("RIVER, " then "ANN").
        let wrapped: [(text: String, box: CGRect)] = [("RIVER", CGRect(x: 445, y: 197, width: 34, height: 11)), (",", CGRect(x: 476, y: 197, width: 6, height: 11)),
                                                      ("ANN", CGRect(x: 445, y: 208, width: 20, height: 12))]
        let box = CGRect(x: 445, y: 197, width: 36, height: 12)
        #expect(WebText.source(line: "RIVER, ", box: box, pieces: wrapped)?.words == nil)
        #expect(WebText.source(line: "RIVER, ", box: box, pieces: Array(wrapped.prefix(2)))?.words?.count == 1)
        #expect(WebText.source(line: "RIVER, ", box: box, pieces: [])?.words == nil)
    }

    @Test func theSourceMakesAScreenTextWhoseCaretsFollowTheWordBoxes() throws {
        let source = try #require(WebText.source(line: "pulse@examplefieldhouse.com\n", box: CGRect(x: 144, y: 262, width: 176, height: 17), pieces: email))
        let text = ScreenText(lines: [source], frame: CGRect(x: 100, y: 200, width: 400, height: 200), window: 0)
        #expect(text.lines.map(\.text) == ["pulse@examplefieldhouse.com"])
        #expect(text.highlight(from: .init(line: 0, column: 0), to: .init(line: 0, column: 27)) == [CGRect(x: 144, y: 262, width: 176, height: 17)])
    }
}
