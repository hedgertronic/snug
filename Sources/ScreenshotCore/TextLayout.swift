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
    /// Groups lines into rows top to bottom, each row left to right: a line joins the last row when it overlaps any line of it vertically
    /// by more than half the smaller height. (Against the row's first line alone, a price a few pixels lower than its item's name,
    /// which joined a row on the other column, started a row of its own.)
    public static func rows(_ lines: [TextLine]) -> [[TextLine]] {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
            let joins = rows.last?.contains { member in
                min(member.bounds.maxY, line.bounds.maxY) - max(member.bounds.minY, line.bounds.minY) > 0.5 * min(member.bounds.height, line.bounds.height)
            } ?? false
            if joins { rows[rows.count - 1].append(line) } else { rows.append([line]) }
        }
        return rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    /// Full-width bands `height` tall covering `crop` top to bottom, each starting a quarter band before the previous one ends, the
    /// last ending at the crop's bottom. A crop up to 1.5 bands tall is one band. Accurate OCR reads a tall image's lines less well
    /// (on a 2560 x 1600 terminal screen it dropped list items' "- " markers) than the same lines in bands.
    public static func bands(_ crop: CGRect, height: CGFloat) -> [CGRect] {
        guard crop.height > 1.5 * height else { return [crop] }
        var bands: [CGRect] = []
        var y = crop.minY
        while y + height < crop.maxY {
            bands.append(CGRect(x: crop.minX, y: y, width: crop.width, height: height))
            y += (0.75 * height).rounded()
        }
        return bands + [CGRect(x: crop.minX, y: crop.maxY - height, width: crop.width, height: height)]
    }

    /// The lines read in each band, as one read: a line within 3 px of a band edge inside `crop` is cut by it and drops (the overlap
    /// holds it whole in the next band), and of lines from different bands that overlap by more than half the smaller box, the one
    /// with the longer text stays. They come back top to bottom, then left to right, so `lines(of:in:)` takes the topmost
    /// of repeated lines (a cart's three "Brief description" lines) whatever order the bands finish in.
    public static func merge(_ reads: [(band: CGRect, lines: [TextLine])], in crop: CGRect) -> [TextLine] {
        let whole = reads.indices.flatMap { index in
            let band = reads[index].band
            return reads[index].lines.filter {
                !(band.minY > crop.minY && $0.bounds.minY < band.minY + 3) && !(band.maxY < crop.maxY && $0.bounds.maxY > band.maxY - 3)
            }.map { (index, $0) }
        }
        var kept: [(Int, TextLine)] = []
        for (index, line) in whole.sorted(by: { $0.1.text.count > $1.1.text.count }) {
            let overlaps = kept.contains { other in
                let shared = other.1.bounds.intersection(line.bounds)
                return other.0 != index && !shared.isNull
                    && shared.width * shared.height > 0.5 * min(other.1.bounds.width * other.1.bounds.height, line.bounds.width * line.bounds.height)
            }
            if !overlaps { kept.append((index, line)) }
        }
        return kept.map(\.1).sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    }

    /// Places each line of `selected` (Live Text, which has no boxes) on the OCR line it came from, in order. A selected line holding
    /// several OCR lines (Live Text joins columns) gives each of them, longest first, each taking its text out of the selected line so a
    /// short OCR line ("x") matches only letters the longer ones left. One inside an OCR line (a partly selected line) takes that
    /// line's box, and one that goes on where the previous one ended inside the same OCR line (Live Text splits a row) joins it.
    /// Matching ignores case and whitespace. A line inside an OCR line takes the first one at or below the previous placed line, so a
    /// short one ("Snug") is not placed on a line far above. A selected line found nowhere goes on its own row below the previous one.
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
                // Live Text can pair a wrapped line's start with its wrap ("Nice, team."): text the OCR lines left, 2 letters or more,
                // goes on the OCR line just above or below them that holds it, with that line's own text, so the next selected line
                // ("I've saved ...") joins it.
                let near = inside.map(\.bounds).reduce(inside[0].bounds) { $0.union($1) }.insetBy(dx: 0, dy: -inside[0].bounds.height)
                for piece in rest.split(separator: "\n") where piece.count >= 2 {
                    guard let index = unused.firstIndex(where: { $0.bounds.intersects(near) && key($0.text).contains(piece) }) else { continue }
                    let line = unused.remove(at: index)
                    let letters = line.text.indices.filter { !line.text[$0].isWhitespace }
                    let start = key(line.text).distance(from: key(line.text).startIndex, to: key(line.text).range(of: piece)!.lowerBound)
                    placed.append(TextLine(text: String(line.text[letters[start]...letters[start + piece.count - 1]]), bounds: line.bounds))
                }
            } else if let last = placed.last, ocr.contains(where: { $0.bounds == last.bounds && key($0.text).contains(key(last.text + text)) }) {
                placed[placed.count - 1].text += " " + text
            } else if let index = unused.firstIndex(where: { key($0.text).contains(key(text)) && $0.bounds.minY >= (placed.last?.bounds.minY ?? 0) })
                        ?? unused.firstIndex(where: { key($0.text).contains(key(text)) }) {
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
    /// matched lines' columns, with Live Text's partly selected text only in the first and last rows (where the selection starts and
    /// ends inside a line); rows between take OCR's text, which keeps what Live Text dropped (a list item's "- "). Selected lines that
    /// match no OCR line drop out, unless none match. A box that covers most of the height of two other lines, one below the other,
    /// is OCR reading across two rows and drops out first; pieces of one row whose edges touch (a long terminal line OCR splits) stay.
    public static func selection(_ selected: String, in ocr: [TextLine]) -> [TextLine] {
        let ocr = ocr.filter { line in
            let covered = ocr.filter { $0 != line && $0.bounds.intersection(line.bounds).height > $0.bounds.height / 2 }
            return !covered.contains { upper in covered.contains { $0.bounds.minY >= upper.bounds.maxY } }
        }
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
                if let partial = placed.first(where: { $0.bounds == line.bounds }) { return index == first || index == last ? partial : line }
                let inside = line.bounds.minX < column.maxX && line.bounds.maxX > column.minX
                return inside && (index > first || line.bounds.minX > start) && (index < last || line.bounds.maxX < end) ? line : nil
            }
        }
    }

    /// Splits rows into blocks in reading order: where two or more rows of an unbroken run have a cell (the table rule's wide gap)
    /// starting at the same x, within half a line height, and no line of the run crosses that x, the run may be two columns. It is
    /// when it is prose side by side: in one part, soft wraps (`wraps`) after rows of 4 or more words number at least 2 and at least
    /// a third of its rows. A label over its value or a title over its subtitle (a cart's "Product name" over "Brief description",
    /// whose OCR boxes can be the same height) has fewer words. Then its left part comes before its right part, and the rows above
    /// and below the run, and each part, split again the same way. Rows that each stand alone (label and value, item and price) and
    /// a single row with a wide gap stay whole.
    static func columns(_ rows: [[TextLine]]) -> [[[TextLine]]] {
        guard !rows.isEmpty else { return [] }
        let heights = rows.joined().map(\.bounds.height).sorted()
        let tolerance = heights[heights.count / 2] / 2
        let edges = rows.flatMap { row in zip(row, row.dropFirst()).filter { $1.bounds.minX - $0.bounds.maxX > $0.bounds.height }.map(\.1.bounds.minX) }
        func prose(_ part: [[TextLine]]) -> Bool {
            let joins = zip(wraps(part), part.indices).filter { $0 && part[$1 - 1].flatMap { $0.text.split(separator: " ") }.count >= 4 }.count
            return joins >= 2 && 3 * joins >= part.count
        }
        for x in Set(edges).sorted() {
            func crosses(_ line: TextLine) -> Bool { line.bounds.minX < x - tolerance && line.bounds.maxX > x }
            var start = 0
            while start < rows.count, let first = rows[start...].firstIndex(where: { !$0.contains(where: crosses) }) {
                let end = rows[first...].firstIndex { $0.contains(where: crosses) } ?? rows.count
                let run = rows[first..<end]
                let left = run.map { $0.filter { $0.bounds.minX < x - tolerance } }.filter { !$0.isEmpty }
                let right = run.map { $0.filter { $0.bounds.minX >= x - tolerance } }.filter { !$0.isEmpty }
                if run.filter({ $0.contains { abs($0.bounds.minX - x) <= tolerance } }).count >= 2 && (prose(left) || prose(right)) {
                    return columns(Array(rows[..<first])) + columns(left) + columns(right) + columns(Array(rows[end...]))
                }
                start = end
            }
        }
        return [rows]
    }

    /// For each row, whether it continues the previous one as a soft wrap, in units of the rows' median height h: the gap between
    /// them is under 0.6 h, it starts no list marker, and its left edge is within 0.4 h of the previous row's or of where the text
    /// after the previous row's marker starts (a hanging indent), and the previous row was full: its first word and a space (its share
    /// of the row's width by characters) would not have fit after the previous row, within 0.5 h of the rows' right edge. On a
    /// terminal a soft wrap leaves a gap of about 0.1 h; a bullet's hanging indent is about 0.7 h, so an outdent back to the bullet is
    /// no soft wrap; a short header over its message (a chat's name and time) was not full.
    static func wraps(_ rows: [[TextLine]]) -> [Bool] {
        guard !rows.isEmpty else { return [] }
        // A bullet (Claude Code's message dot and tool-result corner too), or a hyphen, dash, star, plus or number with a period or
        // parenthesis before a space, and the spaces after it.
        let marker = /(?:[\u{2022}\u{25E6}\u{25AA}\u{2023}\u{2043}\u{23FA}\u{23BF}]|(?:[-*+\u{2013}\u{2014}]|\d{1,3}[.)])(?=\s|$))\s*/
        let boxes = rows.map { $0.dropFirst().reduce($0[0].bounds) { $0.union($1.bounds) } }
        let height = boxes.map(\.height).sorted()[boxes.count / 2]
        let right = boxes.map(\.maxX).max()!
        return rows.indices.map { index in
            guard index > 0 else { return false }
            let previous = rows[index - 1][0], box = boxes[index]
            var hang = boxes[index - 1].minX
            if let match = previous.text.prefixMatch(of: marker) {
                let count = previous.text.distance(from: match.range.lowerBound, to: match.range.upperBound)
                hang = count == previous.text.count && rows[index - 1].count > 1 ? rows[index - 1][1].bounds.minX
                    : previous.bounds.minX + previous.bounds.width * CGFloat(count) / CGFloat(previous.text.count)
            }
            let aligned = [boxes[index - 1].minX, hang].contains { abs(box.minX - $0) <= 0.4 * height }
            let first = rows[index][0]
            let word = first.bounds.width * CGFloat(first.text.prefix { !$0.isWhitespace }.count + 1) / CGFloat(first.text.count)
            let full = boxes[index - 1].maxX + word > right - 0.5 * height
            return box.minY - boxes[index - 1].maxY < 0.6 * height && aligned && full && first.text.prefixMatch(of: marker) == nil
        }
    }

    /// Rows as text, column blocks (`columns`) one after another with a blank line between. Lines of a row join with a space, and a
    /// row that is a soft wrap (`wraps`) joins the previous one with a space. Any other row starts a new line, after a blank line when
    /// the gap is 0.6 row heights or more and at least twice the block's median gap (the lower one of an even count). On a terminal a
    /// soft wrap leaves a gap of about 0.1 h and an empty row about 1.2 h, so empty rows give blank lines; a form's labels and fields
    /// sit about 1.3 h apart throughout, so they give none.
    public static func paragraphs(_ rows: [[TextLine]]) -> String {
        let blocks = columns(rows)
        guard blocks.count == 1 else { return blocks.map(paragraphs).joined(separator: "\n\n") }
        let boxes = rows.map { $0.dropFirst().reduce($0[0].bounds) { $0.union($1.bounds) } }
        let height = boxes.map(\.height).sorted()[boxes.count / 2]
        let gaps = zip(boxes, boxes.dropFirst()).map { $1.minY - $0.maxY }.sorted()
        let spacing = gaps.isEmpty ? 0 : gaps[(gaps.count - 1) / 2]
        let wrapped = wraps(rows)
        var text = ""
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let gap = boxes[index].minY - boxes[index - 1].maxY
                text += wrapped[index] ? " " : gap >= 0.6 * height && gap >= 2 * spacing ? "\n\n" : "\n"
            }
            text += row.map(\.text).joined(separator: " ")
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
