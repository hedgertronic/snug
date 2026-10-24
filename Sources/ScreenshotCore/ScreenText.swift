import CoreGraphics
import Foundation

/// Text that accessibility read for one area of a window as the screen was captured (a terminal's grid, a web page, a window's text
/// views and labels), in image pixels, so Text mode selects, highlights and copies its exact characters instead of OCR's. Lines are
/// in reading order, and each knows the x of every boundary between its characters.
public struct ScreenText: Sendable, Equatable {
    /// A caret between characters: `column` characters into `line`'s text.
    public struct Position: Sendable, Comparable {
        public var line: Int
        public var column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
        public static func < (a: Position, b: Position) -> Bool { (a.line, a.column) < (b.line, b.column) }
    }

    /// One line as a reader gives it, in image pixels: its text, its box, and the boxes of its words (runs of non-spaces) in order when
    /// the reader has them. Characters spread evenly across their word's box, spaces across the gaps between words, and without word
    /// boxes (or with a count that does not match) across the line's box. `edges`, the x of each boundary between characters (one
    /// more than the characters), takes the place of both when the reader knows them (a terminal's cells).
    public struct Source: Sendable {
        public var text: String
        public var box: CGRect
        public var words: [CGRect]?
        public var edges: [CGFloat]?
        public init(text: String, box: CGRect, words: [CGRect]? = nil, edges: [CGFloat]? = nil) {
            self.text = text
            self.box = box
            self.words = words
            self.edges = edges
        }
    }

    /// Each line's text without trailing spaces and its box, from its first character to its text's end.
    public private(set) var lines: [TextLine]
    /// The area's frame in image pixels, and the index (front to back) of the window that holds it.
    public let frame: CGRect
    public let window: Int
    /// A terminal takes every press in its frame; elsewhere only a press on or near a line is a text press (`takes(_:)`).
    public let claimsFrame: Bool
    private let edges: [[CGFloat]]

    public init(lines sources: [Source], frame: CGRect, window: Int, claimsFrame: Bool = false) {
        var lines: [TextLine] = []
        var edges: [[CGFloat]] = []
        for source in sources {
            let characters = Array(String(source.text.reversed().drop(while: \.isWhitespace).reversed()))
            var runs: [Range<Int>] = []
            var index = 0
            while let start = characters[index...].firstIndex(where: { !$0.isWhitespace }) {
                let end = characters[start...].firstIndex(where: \.isWhitespace) ?? characters.count
                runs.append(start..<end)
                index = end
            }
            let box = source.box
            var x = (0...characters.count).map { box.minX + box.width * CGFloat($0) / CGFloat(max(characters.count, 1)) }
            if let given = source.edges, given.count >= characters.count + 1 {
                x = Array(given.prefix(characters.count + 1))
            } else if let words = source.words, words.count == runs.count, !runs.isEmpty {
                func spread(_ range: ClosedRange<Int>, from left: CGFloat, to right: CGFloat) {
                    for k in range { x[k] = left + (right - left) * CGFloat(k - range.lowerBound) / CGFloat(max(range.count - 1, 1)) }
                }
                spread(0...runs[0].lowerBound, from: min(box.minX, words[0].minX), to: words[0].minX)
                for (run, word) in zip(runs, words) { spread(run.lowerBound...run.upperBound, from: word.minX, to: word.maxX) }
                for i in runs.indices.dropLast() { spread(runs[i].upperBound...runs[i + 1].lowerBound, from: words[i].maxX, to: words[i + 1].minX) }
            }
            edges.append(x)
            lines.append(TextLine(text: String(characters), bounds: CGRect(x: x[0], y: box.minY, width: x[characters.count] - x[0], height: box.height)))
        }
        self.lines = lines
        self.edges = edges
        self.frame = frame
        self.window = window
        self.claimsFrame = claimsFrame
    }

    /// A terminal's rows as accessibility gives them (iTerm2), in image pixels: a fixed-width grid, one cell per UTF-16 unit (an
    /// emoji's two units are its two cells), each row's box spanning its whole range, padding and newline included, and a blank
    /// cell reading as a NUL anywhere in a row. A row that fills the grid with no newline gets a box that runs into the next row
    /// (iTerm2: no width, two rows tall), so the cell width and row height are the grid's, from the rows of the most common height,
    /// and a row's own box gives only its top-left corner. The terminal takes every press in its frame.
    public static func grid(rows: [(text: String, box: CGRect)], frame: CGRect, window: Int) -> ScreenText {
        let heights = rows.map(\.box.height).filter { $0 > 0 }
        let height = heights.max { a, b in heights.count { $0 == a } < heights.count { $0 == b } } ?? 0
        let widths = rows.filter { $0.box.height == height && $0.box.width > 0 && !$0.text.utf16.isEmpty }.map { $0.box.width / CGFloat($0.text.utf16.count) }.sorted()
        let cell = widths.isEmpty ? 0 : widths[widths.count / 2]
        return ScreenText(lines: rows.map { row in
            let text = String(row.text.replacingOccurrences(of: "\0", with: " ").reversed().drop { [" ", "\n", "\r"].contains($0) }.reversed())
            var offset = 0
            let edges = [row.box.minX] + text.map { character in
                offset += character.utf16.count
                return row.box.minX + cell * CGFloat(offset)
            }
            return Source(text: text, box: CGRect(x: row.box.minX, y: row.box.minY, width: cell * CGFloat(offset), height: height), edges: edges)
        }, frame: frame, window: window, claimsFrame: true)
    }

    /// This text moved from global points to an image's pixels, `origin` (the display's top-left in points) at 0 and `scale` pixels per
    /// point, held by window `window`.
    public func inPixels(origin: CGPoint, scale: CGFloat, window: Int) -> ScreenText {
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale, width: rect.width * scale, height: rect.height * scale)
        }
        return ScreenText(lines: lines.indices.map { Source(text: lines[$0].text, box: pixels(lines[$0].bounds), edges: edges[$0].map { ($0 - origin.x) * scale }) },
                          frame: pixels(frame), window: window, claimsFrame: claimsFrame)
    }

    /// Whether a press at `point` is a press in this text: anywhere in a terminal's frame, elsewhere on a line or within a line height
    /// beside it or half one above or below.
    public func takes(_ point: CGPoint) -> Bool {
        claimsFrame ? frame.contains(point) : lines.contains { $0.bounds.insetBy(dx: -$0.bounds.height, dy: -$0.bounds.height / 2).contains(point) }
    }

    /// The caret nearest `point`: on the line nearest it (vertically first, then across), before the first character whose middle is
    /// right of it; past a line's text, at its end. Below every line, the end of the last line, as a drag past the end of a document.
    public func position(at point: CGPoint) -> Position {
        if lines.allSatisfy({ point.y >= $0.bounds.maxY }) { return Position(line: lines.count - 1, column: lines[lines.count - 1].text.count) }
        func distance(_ box: CGRect) -> (CGFloat, CGFloat) {
            (max(box.minY - point.y, point.y - box.maxY, 0), max(box.minX - point.x, point.x - box.maxX, 0))
        }
        let line = lines.indices.min { distance(lines[$0].bounds) < distance(lines[$1].bounds) }!
        let x = edges[line]
        return Position(line: line, column: zip(x, x.dropFirst()).prefix { ($0 + $1) / 2 < point.x }.count)
    }

    /// The word (a run of non-space characters) at `position`, or the spaces there, as a range of carets.
    public func word(at position: Position) -> (Position, Position) {
        let text = Array(lines[position.line].text)
        guard !text.isEmpty else { return (position, position) }
        let column = min(position.column, text.count - 1)
        let space = text[column].isWhitespace
        let start = text[..<column].lastIndex { $0.isWhitespace != space }.map { $0 + 1 } ?? 0
        let end = text[column...].firstIndex { $0.isWhitespace != space } ?? text.count
        return (Position(line: position.line, column: start), Position(line: position.line, column: end))
    }

    /// The whole line at `position`, as a range of carets.
    public func line(at position: Position) -> (Position, Position) {
        (Position(line: position.line, column: 0), Position(line: position.line, column: lines[position.line].text.count))
    }

    /// The selected text between two carets in either order, a line per line that has any, as OCR would box it so `TextLayout` joins
    /// soft wraps and spaces paragraphs as it does OCR lines: without leading or trailing spaces, with the box of its line's text from its first
    /// non-space character (a partly selected line keeps its whole line's box, as Live Text's partial text does). Lines of only spaces
    /// drop.
    public func lines(from a: Position, to b: Position) -> [TextLine] {
        spans(from: a, to: b).compactMap { span in
            let text = span.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let box = lines[span.line].bounds
            let x = edges[span.line][lines[span.line].text.prefix { $0.isWhitespace }.count]
            return TextLine(text: text, bounds: CGRect(x: x, y: box.minY, width: box.maxX - x, height: box.height))
        }
    }

    /// The selection's highlight between two carets in either order: on each line, the box of its selected characters.
    public func highlight(from a: Position, to b: Position) -> [CGRect] {
        spans(from: a, to: b).map { span in
            let box = lines[span.line].bounds, x = edges[span.line]
            return CGRect(x: x[span.columns.lowerBound], y: box.minY, width: x[span.columns.upperBound] - x[span.columns.lowerBound], height: box.height)
        }
    }

    private func spans(from a: Position, to b: Position) -> [(line: Int, columns: Range<Int>, text: String)] {
        let (start, end) = (min(a, b), max(a, b))
        return (start.line...end.line).compactMap { line in
            let text = Array(lines[line].text)
            let lower = line == start.line ? min(start.column, text.count) : 0
            let upper = line == end.line ? min(end.column, text.count) : text.count
            return lower < upper ? (line, lower..<upper, String(text[lower..<upper])) : nil
        }
    }
}
