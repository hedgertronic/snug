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
        #expect(TextLayout.readingOrder(rows) == "Product $12\nBrief\nTotal")
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
        #expect(TextLayout.readingOrder(TextLayout.rows(lines)) == "Product name\nunread")
    }

    @Test func tableSplitsColumnsOnWideGapsOnly() {
        let rows = TextLayout.rows([
            line("Product", 10, 100), line("name", 95, 100, width: 40), line("$12", 300, 100),
            line("Second", 10, 140), line("$8", 300, 140)
        ])
        #expect(TextLayout.table(rows) == "Product name\t$12\nSecond\t$8")
    }
}
