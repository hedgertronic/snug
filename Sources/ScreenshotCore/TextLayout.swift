import CoreGraphics
import Foundation

/// One recognized line of text. `bounds` is in image pixels with a top-left origin.
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// Pure layout logic for recognized text: reading order, paragraphs and table clustering.
public enum TextLayout {
    /// Groups lines into rows by vertical overlap with the row's first line, top to bottom, each row left to right.
    public static func rows(_ lines: [TextLine]) -> [[TextLine]] {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
            if let anchor = rows.last?.first?.bounds {
                let overlap = min(anchor.maxY, line.bounds.maxY) - max(anchor.minY, line.bounds.minY)
                if overlap > 0.5 * min(anchor.height, line.bounds.height) {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    /// Places each line of `selected` (Live Text, which has no boxes) on the OCR line it came from, in order. A selected line holding
    /// several OCR lines (Live Text joins columns) gives each of them, longest first, each taking its text out of the selected line so a
    /// short OCR line ("x") matches only letters the longer ones left. One inside an OCR line (a partly selected line) takes that
    /// line's box, and one that goes on where the previous one ended inside the same OCR line (Live Text splits a row) joins it.
    /// Matching ignores case and whitespace. A selected line found nowhere goes on its own row below the previous one.
    public static func lines(of selected: String, in ocr: [TextLine]) -> [TextLine] {
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        var unused = ocr.filter { !key($0.text).isEmpty }
        var placed: [TextLine] = []
        for text in selected.split(whereSeparator: \.isNewline).map(String.init) where !key(text).isEmpty {
            var rest = key(text)
            let inside = unused.sorted { key($0.text).count > key($1.text).count }.filter { line in
                guard let range = rest.range(of: key(line.text)) else { return false }
                rest.replaceSubrange(range, with: "\n")
                return true
            }
            if !inside.isEmpty {
                placed += unused.filter(inside.contains)
                unused.removeAll { line in inside.contains(line) }
            } else if let last = placed.last, ocr.contains(where: { $0.bounds == last.bounds && key($0.text).contains(key(last.text + text)) }) {
                placed[placed.count - 1].text += " " + text
            } else if let index = unused.firstIndex(where: { key($0.text).contains(key(text)) }) {
                placed.append(TextLine(text: text, bounds: unused.remove(at: index).bounds))
            } else {
                let previous = placed.last?.bounds ?? .zero
                placed.append(TextLine(text: text, bounds: CGRect(x: previous.minX, y: previous.maxY + 1, width: previous.width, height: previous.height)))
            }
        }
        return placed
    }

    /// The OCR lines a Live Text selection covers. Live Text's transcript can drop or split lines, so `selected` only marks a span:
    /// placed on `ocr` in reading order (`lines(of:in:)`), it gives every OCR line from the first matched one to the last within the
    /// matched lines' columns, with the partly selected text of the lines the selection starts and ends inside. Selected lines that
    /// match no OCR line drop out, unless none match. A box that covers most of the height of two other lines is OCR reading across
    /// two rows and drops out first.
    public static func selection(_ selected: String, in ocr: [TextLine]) -> [TextLine] {
        let ocr = ocr.filter { line in ocr.filter { $0 != line && $0.bounds.intersection(line.bounds).height > $0.bounds.height / 2 }.count < 2 }
        let rows = rows(ocr)
        let placed = lines(of: selected, in: Array(rows.joined()))
        let matched = ocr.filter { line in placed.contains { $0.bounds == line.bounds } }
        guard let anchor = matched.first?.bounds else { return placed }
        let column = matched.reduce(anchor) { $0.union($1.bounds) }
        let span = rows.indices.filter { rows[$0].contains(where: matched.contains) }
        let first = span.first!, last = span.last!
        let start = rows[first].first(where: matched.contains)!.bounds.minX, end = rows[last].last(where: matched.contains)!.bounds.maxX
        return (first...last).flatMap { index in
            rows[index].compactMap { line in
                if let partial = placed.first(where: { $0.bounds == line.bounds }) { return partial }
                let inside = line.bounds.minX < column.maxX && line.bounds.maxX > column.minX
                return inside && (index > first || line.bounds.minX > start) && (index < last || line.bounds.maxX < end) ? line : nil
            }
        }
    }

    /// Splits rows into blocks in reading order: where two or more rows of an unbroken run have a cell (the table rule's wide gap)
    /// starting at the same x, within half a line height, and no line of the run crosses that x, the run is two columns and its left
    /// part comes before its right part. The rows above and below the run, and each part, split again the same way. A single row with
    /// a wide gap ("label   value") stays one block.
    static func columns(_ rows: [[TextLine]]) -> [[[TextLine]]] {
        guard !rows.isEmpty else { return [] }
        let heights = rows.joined().map(\.bounds.height).sorted()
        let tolerance = heights[heights.count / 2] / 2
        let edges = rows.flatMap { row in zip(row, row.dropFirst()).filter { $1.bounds.minX - $0.bounds.maxX > $0.bounds.height }.map(\.1.bounds.minX) }
        for x in Set(edges).sorted() {
            func crosses(_ line: TextLine) -> Bool { line.bounds.minX < x - tolerance && line.bounds.maxX > x }
            var start = 0
            while start < rows.count, let first = rows[start...].firstIndex(where: { !$0.contains(where: crosses) }) {
                let end = rows[first...].firstIndex { $0.contains(where: crosses) } ?? rows.count
                let run = rows[first..<end]
                if run.filter({ $0.contains { abs($0.bounds.minX - x) <= tolerance } }).count >= 2 {
                    let left = run.map { $0.filter { $0.bounds.minX < x - tolerance } }.filter { !$0.isEmpty }
                    let right = run.map { $0.filter { $0.bounds.minX >= x - tolerance } }.filter { !$0.isEmpty }
                    return columns(Array(rows[..<first])) + columns(left) + columns(right) + columns(Array(rows[end...]))
                }
                start = end
            }
        }
        return [rows]
    }

    /// Rows as text with soft wraps joined, column blocks (`columns`) one after another with a blank line between, each in units of
    /// its median row height h. Lines of a row join with a space. A row joins the previous one with a space when the gap between them
    /// is under 0.6 h, it starts no list marker, and its left edge is within 0.4 h of the previous row's or of where the text after the
    /// previous row's marker starts (a hanging indent). Otherwise it starts a new line, after a blank line when the gap is 0.6 h or
    /// more. On a terminal a soft wrap leaves a gap of about 0.1 h and an empty row about 1.2 h; a bullet's hanging indent is about
    /// 0.7 h, so an outdent back to the bullet starts a new line.
    public static func paragraphs(_ rows: [[TextLine]]) -> String {
        let blocks = columns(rows)
        guard blocks.count == 1 else { return blocks.map(paragraphs).joined(separator: "\n\n") }
        // A bullet, or a hyphen, dash, star, plus or number with a period or parenthesis before a space, and the spaces after it.
        let marker = /(?:[\u{2022}\u{25E6}\u{25AA}\u{2023}\u{2043}]|(?:[-*+\u{2013}\u{2014}]|\d{1,3}[.)])(?=\s|$))\s*/
        let boxes = rows.map { $0.dropFirst().reduce($0[0].bounds) { $0.union($1.bounds) } }
        let height = boxes.map(\.height).sorted()[boxes.count / 2]
        var text = ""
        for (index, row) in rows.enumerated() {
            let line = row.map(\.text).joined(separator: " ")
            if index > 0 {
                let previous = rows[index - 1][0], box = boxes[index]
                var hang = boxes[index - 1].minX
                if let match = previous.text.prefixMatch(of: marker) {
                    let count = previous.text.distance(from: match.range.lowerBound, to: match.range.upperBound)
                    hang = count == previous.text.count && rows[index - 1].count > 1 ? rows[index - 1][1].bounds.minX
                        : previous.bounds.minX + previous.bounds.width * CGFloat(count) / CGFloat(previous.text.count)
                }
                let gap = box.minY - boxes[index - 1].maxY
                let aligned = [boxes[index - 1].minX, hang].contains { abs(box.minX - $0) <= 0.4 * height }
                text += gap >= 0.6 * height ? "\n\n" : aligned && line.prefixMatch(of: marker) == nil ? " " : "\n"
            }
            text += line
        }
        return text
    }

    /// Tab-separated rows. A gap wider than the previous line's height starts a new column; smaller gaps join with a space.
    public static func table(_ rows: [[TextLine]]) -> String {
        rows.map { row in
            var cells = [row[0].text]
            for (previous, line) in zip(row, row.dropFirst()) {
                if line.bounds.minX - previous.bounds.maxX > previous.bounds.height {
                    cells.append(line.text)
                } else {
                    cells[cells.count - 1] += " " + line.text
                }
            }
            return cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
