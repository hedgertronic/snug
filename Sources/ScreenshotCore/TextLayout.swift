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

/// Pure layout logic for recognized text: reading order and table clustering.
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
    /// several OCR lines (Live Text joins columns) gives each of them; one inside an OCR line (a partly selected line) takes that
    /// line's box. Matching ignores case and whitespace. A selected line found nowhere goes on its own row below the previous one.
    public static func lines(of selected: String, in ocr: [TextLine]) -> [TextLine] {
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        var unused = ocr.filter { !key($0.text).isEmpty }
        var placed: [TextLine] = []
        for text in selected.split(whereSeparator: \.isNewline).map(String.init) where !key(text).isEmpty {
            let inside = unused.filter { key(text).contains(key($0.text)) }
            if !inside.isEmpty {
                placed += inside
                unused.removeAll { line in inside.contains(line) }
            } else if let index = unused.firstIndex(where: { key($0.text).contains(key(text)) }) {
                placed.append(TextLine(text: text, bounds: unused.remove(at: index).bounds))
            } else {
                let previous = placed.last?.bounds ?? .zero
                placed.append(TextLine(text: text, bounds: CGRect(x: previous.minX, y: previous.maxY + 1, width: previous.width, height: previous.height)))
            }
        }
        return placed
    }

    /// Lines of one row joined by a space, rows joined by newlines.
    public static func readingOrder(_ rows: [[TextLine]]) -> String {
        rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
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
