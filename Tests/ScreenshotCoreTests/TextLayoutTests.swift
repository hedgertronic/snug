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
        #expect(paragraphs([term("- Return copies the selection with", 25, 100), term("soft wraps", 37, 119), term("joined", 37, 138)])
            == "- Return copies the selection with soft wraps joined")
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
                    term("First paragraph wraps", 25, 100), term("onto a second row.", 25, 119), term("Second paragraph.", 25, 156),
                    term("Settings", 600, 100), term("Keys", 600, 130), term("About", 600, 160)]
        #expect(paragraphs(page) == "Page title\n\nFirst paragraph wraps onto a second row.\n\nSecond paragraph.\n\nSettings\nKeys\nAbout")
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

    @Test func oneRowWithAWideGapStaysOneLine() {
        #expect(paragraphs([term("Total", 25, 100), term("$20", 300, 100)]) == "Total $20")
    }

    @Test func anIndentedRowStartsANewLine() {
        #expect(paragraphs([term("Run:", 25, 100), term("swift test", 49, 119)]) == "Run:\nswift test")
        #expect(paragraphs([]) == "")
    }

    @Test func tableSplitsColumnsOnWideGapsOnly() {
        let rows = TextLayout.rows([
            line("Product", 10, 100), line("name", 95, 100, width: 40), line("$12", 300, 100),
            line("Second", 10, 140), line("$8", 300, 140)
        ])
        #expect(TextLayout.table(rows) == "Product name\t$12\nSecond\t$8")
    }
}
