import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

struct TextLayoutTests {
    func line(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 80) -> TextLine {
        TextLine(text: text, bounds: CGRect(x: x, y: y, width: width, height: 20))
    }

    @Test func rowsReadTopToBottomThenLeftToRight() {
        let lines = [line("$12", 300, 103), line("Brief", 10, 140), line("Product", 10, 100), line("Total", 10, 200)]
        let rows = TextLayout.rows(lines)
        #expect(rows.map { $0.map(\.text) } == [["Product", "$12"], ["Brief"], ["Total"]])
    }

    @Test func aLineJoinsTheRowOfAnyLineItOverlaps() {
        // form-test's boxes read in bands: Product name joins First name's row by 19 px of 34, and $12, 15 px into First name but all
        // of Product name, joins it too.
        let rows = TextLayout.rows([TextLine(text: "First name", bounds: CGRect(x: 338, y: 398, width: 160, height: 34)),
                                    TextLine(text: "Product name", bounds: CGRect(x: 1685, y: 413, width: 217, height: 37.6)),
                                    TextLine(text: "$12", bounds: CGRect(x: 2125, y: 417, width: 60, height: 33.5))])
        #expect(rows.map { $0.map(\.text) } == [["First name", "Product name", "$12"]])
    }

    @Test func linesWithBarelyTouchingBandsStaySeparateRows() {
        let rows = TextLayout.rows([line("a", 0, 100), line("b", 0, 118)])
        #expect(rows.count == 2)
    }

    @Test func selectedLinesTakeTheirOCRBoxesAndLayOutAsRows() {
        let ocr = [line("Billing address", 10, 40), line("Product name", 10, 100), line("$12", 300, 100), line("Brief description", 10, 140),
                   line("Second product", 10, 180), line("$8", 300, 180)]
        // Live Text joins the two columns of a row into one line, puts the price column after, and the first line is partly selected.
        let selected = "name\nBrief description\nSecond product\n$12\n$8"
        let rows = TextLayout.rows(TextLayout.lines(of: selected, in: ocr))
        #expect(TextLayout.table(rows) == "name\t$12\nBrief description\nSecond product\t$8")
        #expect(TextLayout.table(TextLayout.rows(TextLayout.lines(of: "Product name $12", in: ocr))) == "Product name\t$12")
    }

    @Test func aSelectedLineWithoutOCRGoesOnItsOwnRowAfterThePrevious() {
        let lines = TextLayout.lines(of: "Product name\nunread", in: [line("Product name", 10, 100), line("Total", 10, 300)])
        #expect(TextLayout.rows(lines).map { $0.map(\.text) } == [["Product name"], ["unread"]])
    }

    @Test func aSelectionCoversEveryOCRLineInItsSpanAndColumn() {
        let ocr = [line("x", 10, 10, width: 10), line("Product name", 10, 100), line("$12", 300, 100), line("Brief description", 10, 140),
                   line("Username", 500, 140), line("Second product", 10, 180), line("$8", 300, 180), line("Third item", 10, 220)]
        // Live Text drops "Brief description" and misreads "Second product"; the selection starts inside "Product name" and ends at "$8".
        let selected = TextLayout.selection("name\n$12\nsecnd prodct garbled\n$8", in: ocr)
        #expect(TextLayout.table(TextLayout.rows(selected)) == "name\t$12\nBrief description\nSecond product\t$8")
        // The selection's first row keeps only what follows its start, and its last row what precedes its end.
        #expect(TextLayout.selection("$12\nBrief description\nSecond product", in: ocr).map(\.text) == ["$12", "Brief description", "Second product"])
        #expect(TextLayout.selection("unread", in: ocr).map(\.text) == ["unread"])
        // Live Text splits one OCR line in two.
        #expect(TextLayout.selection("Brief\ndescription", in: ocr).map(\.text) == ["Brief description"])
    }

    @Test func aSelectionTakesOCRTextForRowsBetweenItsEnds() {
        let ocr = [line("Plan", 10, 100), line("- shadow opacity;", 10, 140), line("- corner radius;", 10, 180), line("Next steps", 10, 220)]
        // Live Text drops the middle item's marker and the selection starts inside the first line: the middle row keeps OCR's marker,
        // the first row Live Text's partial text.
        #expect(TextLayout.selection("lan\n- shadow opacity;\ncorner radius;\nNext steps", in: ocr).map(\.text) == ["lan", "- shadow opacity;", "- corner radius;", "Next steps"])
    }

    @Test func aSelectionDropsABoxReadAcrossTwoRows() {
        let ocr = [line("first row", 10, 100), line("second row", 10, 119), TextLine(text: "first second", bounds: CGRect(x: 60, y: 100, width: 60, height: 39))]
        #expect(TextLayout.selection("first row\nsecond row", in: ocr).map(\.text) == ["first row", "second row"])
    }

    /// A terminal line as accurate OCR boxes it on a 1000 px tall shot: 17 px tall, 6 px per character, its row's top at `y`.
    func term(_ text: String, _ x: CGFloat, _ y: CGFloat) -> TextLine {
        TextLine(text: text, bounds: CGRect(x: x, y: y, width: CGFloat(text.count) * 6, height: 17))
    }

    func paragraphs(_ lines: [TextLine]) -> String { TextLayout.paragraphs(TextLayout.rows(lines)) }

    // Rows of a wrap sit 19 px apart and paragraphs 37 px; bullets start at x 25 and their text and continuations at x 37.
    @Test func aBulletsWrappedContinuationJoinsItsLine() {
        #expect(paragraphs([term("\u{2022} Return copies the selection with", 25, 100), term("soft wraps joined", 37, 119)])
            == "\u{2022} Return copies the selection with soft wraps joined")
        #expect(paragraphs([term("- Return copies the selection with", 25, 100), term("soft wraps across a second row of", 37, 119), term("joined", 37, 138)])
            == "- Return copies the selection with soft wraps across a second row of joined")
    }

    @Test func aBulletSplitIntoItsOwnPieceHangsAtTheTextAfterIt() {
        #expect(paragraphs([term("\u{2022}", 25, 100), term("Return copies the", 43, 100), term("selection", 43, 119)])
            == "\u{2022} Return copies the selection")
    }

    @Test func eachBulletStartsItsOwnLine() {
        #expect(paragraphs([term("- first item", 25, 100), term("- second item", 25, 119), term("1. third", 25, 138), term("2) fourth", 25, 157)])
            == "- first item\n- second item\n1. third\n2) fourth")
    }

    @Test func anEmptyRowBetweenParagraphsGivesABlankLine() {
        #expect(paragraphs([term("First paragraph runs on", 25, 100), term("to a short end.", 25, 119), term("Second paragraph.", 25, 156)])
            == "First paragraph runs on to a short end.\n\nSecond paragraph.")
    }

    @Test func piecesOfOneRowJoinWithSpaces() {
        #expect(paragraphs([term("Text mode,", 25, 100), term("from the other", 97, 101), term("agent:", 187, 100), term("next row", 25, 119)])
            == "Text mode, from the other agent: next row")
    }

    @Test func aHeadingBeforeABulletStaysItsOwnLine() {
        #expect(paragraphs([term("F and W:", 25, 100), term("- F captures the display", 25, 119)]) == "F and W:\n- F captures the display")
    }

    @Test func anOutdentAfterAHangingContinuationStartsANewLine() {
        #expect(paragraphs([term("- a bullet that wraps", 25, 100), term("onto a second row", 37, 119), term("F and W:", 25, 138)])
            == "- a bullet that wraps onto a second row\nF and W:")
    }

    @Test func columnsComeOneAfterAnotherNotInterleaved() {
        let page = [TextLine(text: "Page title", bounds: CGRect(x: 25, y: 60, width: 700, height: 17)),
                    term("First paragraph wraps here", 25, 100), term("onto a second row and then", 25, 119), term("a third row.", 25, 138),
                    term("Second paragraph.", 25, 175), term("Settings", 600, 100), term("Keys", 600, 130), term("About", 600, 160)]
        #expect(paragraphs(page) == "Page title\n\nFirst paragraph wraps here onto a second row and then a third row.\n\nSecond paragraph.\n\nSettings\nKeys\nAbout")
    }

    @Test func aCartWithOneLabelOverItsValueKeepsPricesInTheirRows() {
        // form-test.png's cart in image pixels: titles over smaller subtitles, a promo label over its code, prices on the right.
        func box(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> TextLine {
            TextLine(text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
        }
        let cart = [box("Product name", 1689, 415, 213, 37), box("$12", 2125, 417, 60, 33), box("Brief description", 1689, 458, 220, 26),
                    box("Second product", 1685, 528, 250, 41), box("$8", 2140, 528, 45, 33), box("Brief description", 1689, 573, 220, 26),
                    box("Third item", 1685, 642, 157, 34), box("$5", 2140, 640, 45, 33), box("Brief description", 1686, 685, 220, 30),
                    box("Promo code", 1685, 752, 187, 37), box("-$5", 2121, 759, 63, 30), box("EXAMPLECODE", 1686, 800, 212, 30),
                    box("Total (USD)", 1685, 878, 175, 34), box("$20", 2117, 878, 67, 33)]
        let text = paragraphs(cart)
        #expect(["Product name $12", "Second product $8", "Third item $5", "Promo code -$5", "Total (USD) $20"].allSatisfy(text.contains), "\(text)")
    }

    @Test func evenlySpacedFormRowsGetNoBlankLines() {
        // Labels and fields 1.26 h apart throughout, fields indented.
        #expect(paragraphs([term("Address", 25, 100), term("1234 Main St", 39, 138), term("Address 2 (Optional)", 25, 176), term("Apartment or suite", 39, 214)])
            == "Address\n1234 Main St\nAddress 2 (Optional)\nApartment or suite")
    }

    @Test func emptyRowsBetweenWrappedParagraphsGiveBlankLines() {
        let lines = [term("First paragraph runs on", 25, 100), term("to its end.", 25, 119), term("Second paragraph runs on", 25, 156),
                     term("to its end too.", 25, 175), term("Third.", 25, 212)]
        #expect(paragraphs(lines) == "First paragraph runs on to its end.\n\nSecond paragraph runs on to its end too.\n\nThird.")
    }

    @Test func anItemAndPriceListKeepsItsRowsWhole() {
        #expect(paragraphs([term("Coffee", 25, 100), term("$4", 300, 100), term("Bagel", 25, 130), term("$3", 300, 130),
                            term("Orange juice", 25, 160), term("$5", 300, 160)]) == "Coffee $4\nBagel $3\nOrange juice $5")
        // A cart: each item's subtitle joins it, but a two-word title over a subtitle is no prose, so the prices stay in their rows.
        func cart(_ text: String, _ x: CGFloat, _ y: CGFloat, _ height: CGFloat) -> TextLine {
            TextLine(text: text, bounds: CGRect(x: x, y: y, width: CGFloat(text.count) * 8, height: height))
        }
        #expect(paragraphs([cart("Product name", 25, 100, 22), cart("$12", 300, 100, 22), cart("Brief description", 25, 124, 15),
                            cart("Second product", 25, 160, 22), cart("$8", 300, 160, 22), cart("Brief description", 25, 184, 15)])
            == "Product name $12 Brief description\n\nSecond product $8 Brief description")
    }

    @Test func oneRowWithAWideGapStaysOneLine() {
        #expect(paragraphs([term("Total", 25, 100), term("$20", 300, 100)]) == "Total $20")
    }

    @Test func aShortHeaderOverItsMessageStaysItsOwnLine() {
        // A chat's bold name and time over the message, left-aligned 0.3 h apart; the header is 0.55 of the message's width.
        let header = TextLine(text: "Jamie Rivers 10:59 PM", bounds: CGRect(x: 25, y: 100, width: 96, height: 17))
        #expect(paragraphs([header, term("Ok can you send me the photos", 25, 122)]) == "Jamie Rivers 10:59 PM\nOk can you send me the photos")
    }

    @Test func aWrappedParagraphWithAShortLastLineJoins() {
        #expect(paragraphs([term("The quick brown fox jumps over", 25, 100), term("the lazy dog and keeps running", 25, 119), term("home.", 25, 138)])
            == "The quick brown fox jumps over the lazy dog and keeps running home.")
    }

    @Test func aShortLineBeforeALongerOneNeverJoins() {
        #expect(paragraphs([term("Short line", 25, 100), term("a much longer line follows here", 25, 119)]) == "Short line\na much longer line follows here")
    }

    @Test func anIndentedRowStartsANewLine() {
        #expect(paragraphs([term("Run:", 25, 100), term("swift test", 49, 119)]) == "Run:\nswift test")
        #expect(paragraphs([]) == "")
    }

    @Test func aTallCropSplitsIntoOverlappingBandsAndAShortOneDoesNot() {
        #expect(TextLayout.bands(CGRect(x: 10, y: 20, width: 2000, height: 600), height: 432) == [CGRect(x: 10, y: 20, width: 2000, height: 600)])
        #expect(TextLayout.bands(CGRect(x: 0, y: 0, width: 2560, height: 1600), height: 432).map(\.minY) == [0, 324, 648, 972, 1168])
        #expect(TextLayout.bands(CGRect(x: 0, y: 0, width: 2560, height: 1600), height: 432).allSatisfy { $0.height == 432 && $0.width == 2560 })
    }

    @Test func bandsMergeDuplicatesAndDropLinesCutByAnEdge() {
        let crop = CGRect(x: 0, y: 0, width: 2560, height: 756)
        let top = CGRect(x: 0, y: 0, width: 2560, height: 432), bottom = CGRect(x: 0, y: 324, width: 2560, height: 432)
        let reads = [(band: top, lines: [line("First", 10, 100), line("In the overlap", 10, 360), line("Cut b", 10, 415)]),
                     (band: bottom, lines: [line("In the overlap.", 12, 361), line("Cut by the edge", 10, 418), line("Last", 10, 700),
                                            line("Ragged top", 10, 325)])]
        // The overlap's line keeps its longer copy; the line the top band's edge cuts keeps the bottom band's whole copy; a line at the
        // bottom band's top edge (cut) drops, though no other copy holds it.
        #expect(TextLayout.merge(reads, in: crop).map(\.text) == ["First", "In the overlap.", "Cut by the edge", "Last"])
        // Lines of one band never merge with each other.
        #expect(TextLayout.merge([(band: crop, lines: [line("a", 10, 100), line("a b", 10, 102)])], in: crop).count == 2)
    }

    @Test func tableSplitsColumnsOnWideGapsOnly() {
        let rows = TextLayout.rows([
            line("Product", 10, 100), line("name", 95, 100, width: 40), line("$12", 300, 100),
            line("Second", 10, 140), line("$8", 300, 140)
        ])
        #expect(TextLayout.table(rows) == "Product name\t$12\nSecond\t$8")
    }
}
