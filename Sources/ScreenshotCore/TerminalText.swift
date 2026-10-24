import CoreGraphics

/// A terminal's visible text as accessibility reads it (iTerm2, Terminal): one row per visual row of a fixed-width grid, with exact
/// text, so Text mode selects and copies it without OCR. A row's accessibility box spans its whole range, padding and newline
/// included, one cell per UTF-16 unit (an emoji's two units are its two cells).
public struct TerminalText: Sendable, Equatable {
    /// A caret between characters: `column` characters into `row`'s text.
    public struct Position: Sendable, Comparable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
        public static func < (a: Position, b: Position) -> Bool { (a.row, a.column) < (b.row, b.column) }
    }

    /// Each row's text without its trailing spaces, NULs and newline, and its box in image pixels from its first cell to its text's end.
    public private(set) var rows: [TextLine]
    /// The rows as accessibility gave them; two reads that differ here mean the terminal changed.
    public let raw: [String]
    /// The text area's frame in image pixels, and the index (front to back) of the window that holds it.
    public let frame: CGRect
    public let window: Int
    private let starts: [[Int]]
    private let cells: [CGFloat]

    /// `rows` are each row's text and accessibility box, already in image pixels.
    public init(rows: [(text: String, box: CGRect)], frame: CGRect, window: Int) {
        raw = rows.map(\.text)
        self.frame = frame
        self.window = window
        var lines: [TextLine] = []
        var starts: [[Int]] = []
        var cells: [CGFloat] = []
        for row in rows {
            let cell = row.text.utf16.isEmpty ? 0 : row.box.width / CGFloat(row.text.utf16.count)
            let text = String(row.text.reversed().drop { [" ", "\0", "\n", "\r"].contains($0) }.reversed())
            var start = 0
            starts.append(text.map { character in
                defer { start += character.utf16.count }
                return start
            } + [text.utf16.count])
            cells.append(cell)
            lines.append(TextLine(text: text, bounds: CGRect(x: row.box.minX, y: row.box.minY, width: cell * CGFloat(text.utf16.count), height: row.box.height)))
        }
        self.rows = lines
        self.starts = starts
        self.cells = cells
    }

    /// The caret nearest `point` (image pixels): on the row whose box spans its y (the first row above them all, the last below), before
    /// the first character whose middle is right of it; past a row's text, at its end.
    public func position(at point: CGPoint) -> Position {
        guard let row = rows.firstIndex(where: { point.y < $0.bounds.maxY }) else { return Position(row: rows.count - 1, column: rows.last!.text.count) }
        let box = rows[row].bounds, starts = starts[row], cell = cells[row]
        let column = zip(starts, starts.dropFirst()).prefix { box.minX + cell * CGFloat($0 + $1) / 2 < point.x }.count
        return Position(row: row, column: column)
    }

    /// The word (a run of non-space characters) at `position`, or the spaces there, as a range of carets.
    public func word(at position: Position) -> (Position, Position) {
        let text = Array(rows[position.row].text)
        guard !text.isEmpty else { return (position, position) }
        let column = min(position.column, text.count - 1)
        let space = text[column].isWhitespace
        let start = text[..<column].lastIndex { $0.isWhitespace != space }.map { $0 + 1 } ?? 0
        let end = text[column...].firstIndex { $0.isWhitespace != space } ?? text.count
        return (Position(row: position.row, column: start), Position(row: position.row, column: end))
    }

    /// The selected text between two carets in either order, a line per row that has any, each with its row's whole box so
    /// `TextLayout` joins soft wraps and spaces paragraphs as it does OCR lines.
    public func lines(from a: Position, to b: Position) -> [TextLine] {
        spans(from: a, to: b).map { TextLine(text: $0.text, bounds: rows[$0.row].bounds) }
    }

    /// The selection's highlight between two carets in either order: on each row, the box of its selected characters.
    public func highlight(from a: Position, to b: Position) -> [CGRect] {
        spans(from: a, to: b).map { span in
            let box = rows[span.row].bounds, starts = starts[span.row], cell = cells[span.row]
            return CGRect(x: box.minX + cell * CGFloat(starts[span.columns.lowerBound]), y: box.minY,
                          width: cell * CGFloat(starts[span.columns.upperBound] - starts[span.columns.lowerBound]), height: box.height)
        }
    }

    private func spans(from a: Position, to b: Position) -> [(row: Int, columns: Range<Int>, text: String)] {
        let (start, end) = (min(a, b), max(a, b))
        return (start.row...end.row).compactMap { row in
            let text = Array(rows[row].text)
            let lower = row == start.row ? min(start.column, text.count) : 0
            let upper = row == end.row ? min(end.column, text.count) : text.count
            return lower < upper ? (row, lower..<upper, String(text[lower..<upper])) : nil
        }
    }
}
