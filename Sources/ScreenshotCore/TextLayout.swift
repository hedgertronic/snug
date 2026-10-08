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
