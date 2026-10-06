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

    @Test func tableSplitsColumnsOnWideGapsOnly() {
        let rows = TextLayout.rows([
            line("Product", 10, 100), line("name", 95, 100, width: 40), line("$12", 300, 100),
            line("Second", 10, 140), line("$8", 300, 140)
        ])
        #expect(TextLayout.table(rows) == "Product name\t$12\nSecond\t$8")
    }

    @Test func foundItemsCarryTheirLineBoxes() throws {
        let lines = [line("Write to", 10, 100), line("you@example.com", 10, 140, width: 150), line("or call (206) 555-0134", 10, 180, width: 200)]
        let items = try TextLayout.foundItems(in: lines)
        let email = try #require(items.first { $0.kind == .link })
        #expect(email.text == "you@example.com")
        #expect(email.bounds == lines[1].bounds)
        #expect(email.url?.scheme == "mailto")
        #expect(items.contains { $0.kind == .phone && $0.bounds == lines[2].bounds })
    }

    @Test func onlyWebAndMailSchemesOpen() {
        #expect(TextLayout.openable(URL(string: "https://example.com")) != nil)
        #expect(TextLayout.openable(URL(string: "file:///etc/passwd")) == nil)
        #expect(TextLayout.openable(URL(string: "x-apple.systempreferences:")) == nil)
        #expect(TextLayout.openable(nil) == nil)
    }
}
