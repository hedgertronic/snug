import CoreGraphics
import ScreenshotCore
import Testing

struct TerminalTextTests {
    /// iTerm2's rows as accessibility gives them, in image pixels: 20 cells of 8 px from x 100, rows 16 px tall from y 200, each padded
    /// to the grid's width and ending in a newline but the last, which ends in NULs.
    func terminal(_ rows: [String]) -> TerminalText {
        TerminalText(rows: rows.enumerated().map { index, text in
            let padded = index == rows.count - 1 ? text.padding(toLength: 20, withPad: "\0", startingAt: 0) : text.padding(toLength: 19, withPad: " ", startingAt: 0) + "\n"
            return (padded, CGRect(x: 100, y: 200 + CGFloat(index) * 16, width: CGFloat(padded.utf16.count) * 8, height: 16))
        }, frame: CGRect(x: 90, y: 190, width: 200, height: 100), window: 0)
    }

    @Test func rowsDropTheirPaddingAndKeepABoxAsWideAsTheirText() {
        let text = terminal(["  hello world", "", "last"])
        #expect(text.rows.map(\.text) == ["  hello world", "", "last"])
        #expect(text.rows.map(\.bounds) == [CGRect(x: 100, y: 200, width: 104, height: 16), CGRect(x: 100, y: 216, width: 0, height: 16),
                                             CGRect(x: 100, y: 232, width: 32, height: 16)])
    }

    @Test func aPointPicksTheCaretNearestItOnItsRow() {
        let text = terminal(["hello world", "second"])
        // Cell 2 ("l") spans x 116-124: left of its middle the caret goes before it, right of it after.
        #expect(text.position(at: CGPoint(x: 119, y: 205)) == .init(row: 0, column: 2))
        #expect(text.position(at: CGPoint(x: 121, y: 205)) == .init(row: 0, column: 3))
        // Left of the text, past its end, above every row and below them all.
        #expect(text.position(at: CGPoint(x: 50, y: 220)) == .init(row: 1, column: 0))
        #expect(text.position(at: CGPoint(x: 400, y: 205)) == .init(row: 0, column: 11))
        #expect(text.position(at: CGPoint(x: 120, y: 100)) == .init(row: 0, column: 2))
        #expect(text.position(at: CGPoint(x: 120, y: 900)) == .init(row: 1, column: 6))
    }

    @Test func anEmojiTakesTwoCells() {
        let text = terminal(["a\u{1F600}b"])
        // The emoji spans cells 1-2 (x 108-124), its middle at 116, so "b" is cell 3.
        #expect(text.highlight(from: .init(row: 0, column: 2), to: .init(row: 0, column: 3)) == [CGRect(x: 124, y: 200, width: 8, height: 16)])
        #expect(text.position(at: CGPoint(x: 115, y: 205)) == .init(row: 0, column: 1))
        #expect(text.position(at: CGPoint(x: 125, y: 205)) == .init(row: 0, column: 2))
    }

    @Test func aSelectionAcrossRowsTakesTheEndsPartlyAndTheRowsBetweenWhole() {
        let text = terminal(["- first item here", "", "- second item", "- third item"])
        let start = TerminalText.Position(row: 0, column: 8), end = TerminalText.Position(row: 3, column: 7)
        #expect(text.lines(from: start, to: end).map(\.text) == ["item here", "- second item", "- third"])
        // Backward gives the same; the empty row has nothing to highlight.
        #expect(text.lines(from: end, to: start) == text.lines(from: start, to: end))
        #expect(text.highlight(from: end, to: start) == [CGRect(x: 164, y: 200, width: 72, height: 16), CGRect(x: 100, y: 232, width: 104, height: 16),
                                                         CGRect(x: 100, y: 248, width: 56, height: 16)])
        // Each line keeps its row's whole box, so TextLayout spaces it as it does OCR rows: the empty row gives a blank line.
        #expect(TextLayout.paragraphs(TextLayout.rows(text.lines(from: start, to: end))) == "item here\n\n- second item\n- third")
    }

    @Test func aSoftWrappedRowJoinsThePreviousOne() {
        // A paragraph Claude Code wrapped at the grid's width, then a list item under a blank row.
        let text = terminal(["the copy keeps the", "whole sentence.", "", "- next"])
        let lines = text.lines(from: .init(row: 0, column: 4), to: .init(row: 3, column: 6))
        #expect(TextLayout.paragraphs(TextLayout.rows(lines)) == "copy keeps the whole sentence.\n\n- next")
    }

    @Test func blankCellsReadAsNULsAreSpacesAndIndentsStartTheLayoutBox() {
        // iTerm2 reads a diff's blank gutter cells as NULs; a row's text keeps them as spaces, so columns stay on the grid.
        let text = terminal(["\0\0 12 +  }", "    indented"])
        #expect(text.rows.map(\.text) == ["   12 +  }", "    indented"])
        #expect(text.position(at: CGPoint(x: 129, y: 205)) == .init(row: 0, column: 4))
        // The copied lines drop the indent, and their boxes start at the first non-space cell, as OCR boxes would.
        let lines = text.lines(from: .init(row: 0, column: 0), to: .init(row: 1, column: 12))
        #expect(lines.map(\.text) == ["12 +  }", "indented"])
        #expect(lines.map(\.bounds.minX) == [124, 132])
    }

    @Test func aClaudeCodeMessageWrappedUnderItsDotJoins() {
        // Claude Code starts a message with a dot and wraps it under the text after the dot.
        let text = terminal(["\u{23FA} The paste is ok", "  and the highlight."])
        let lines = text.lines(from: .init(row: 0, column: 0), to: .init(row: 1, column: 20))
        #expect(TextLayout.paragraphs(TextLayout.rows(lines)) == "\u{23FA} The paste is ok and the highlight.")
    }

    @Test func aRowThatFillsTheGridKeepsTheGridsCellsThoughItsBoxRunsOn() {
        // iTerm2 boxes a full row with no newline from its start to the next row's start: no width, two rows tall.
        let text = TerminalText(rows: [("abc\n", CGRect(x: 100, y: 200, width: 32, height: 16)), ("defg", CGRect(x: 100, y: 216, width: 0, height: 32)),
                                       ("hi", CGRect(x: 100, y: 232, width: 16, height: 16))], frame: .zero, window: 0)
        #expect(text.rows.map(\.bounds) == [CGRect(x: 100, y: 200, width: 24, height: 16), CGRect(x: 100, y: 216, width: 32, height: 16),
                                             CGRect(x: 100, y: 232, width: 16, height: 16)])
        #expect(text.position(at: CGPoint(x: 117, y: 220)) == .init(row: 1, column: 2))
    }

    @Test func anEmptySelectionHasNoLines() {
        let text = terminal(["hello"])
        #expect(text.lines(from: .init(row: 0, column: 2), to: .init(row: 0, column: 2)).isEmpty)
        #expect(text.highlight(from: .init(row: 0, column: 9), to: .init(row: 0, column: 12)).isEmpty)
    }

    @Test func aDoubleClickWordIsARunOfNonSpaces() {
        let text = terminal(["  git status -sb"])
        #expect(text.word(at: .init(row: 0, column: 3)) == (.init(row: 0, column: 2), .init(row: 0, column: 5)))
        #expect(text.word(at: .init(row: 0, column: 14)) == (.init(row: 0, column: 13), .init(row: 0, column: 16)))
        #expect(text.word(at: .init(row: 0, column: 0)) == (.init(row: 0, column: 0), .init(row: 0, column: 2)))
    }

    @Test func readsThatDifferMeanTheTerminalChanged() {
        #expect(terminal(["a", "b"]) == terminal(["a", "b"]))
        #expect(terminal(["a", "b"]).raw != terminal(["a", "c"]).raw)
    }
}
