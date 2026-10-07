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

/// A link, phone number, date, address, or barcode payload found in recognized text.
public struct FoundItem: Equatable, Sendable {
    public enum Kind: String, Sendable { case link, phone, date, address, barcode }

    public var kind: Kind
    public var text: String
    public var bounds: CGRect
    /// Set only for http, https, and mailto targets; the only items Cmd-Return opens.
    public var url: URL?

    public init(kind: Kind, text: String, bounds: CGRect, url: URL?) {
        self.kind = kind
        self.text = text
        self.bounds = bounds
        self.url = url
    }
}

/// Pure layout logic for recognized text: reading order, table clustering, and found items.
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

    /// The paragraph-like block of lines under a point, or the single line under it; empty over whitespace.
    public static func block(at point: CGPoint, in lines: [TextLine]) -> [TextLine] {
        let hit = lines.first { $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
        guard let hit else { return [] }
        let block = groupedTextCandidates(from: lines.map(\.bounds)).first { $0.hitRegions!.contains(hit.bounds) }
        return block.map { block in lines.filter { block.hitRegions!.contains($0.bounds) } } ?? [hit]
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

    /// Returns `url` only when it uses a scheme that is safe to open on request.
    public static func openable(_ url: URL?) -> URL? {
        url.flatMap { ["http", "https", "mailto"].contains($0.scheme) ? $0 : nil }
    }

    /// Links, phone numbers, dates, and addresses in reading order; each box is the union of the lines the match touches.
    public static func foundItems(in lines: [TextLine]) throws -> [FoundItem] {
        let ordered = rows(lines).flatMap { $0 }
        var string = ""
        var ranges: [NSRange] = []
        for line in ordered {
            let start = (string as NSString).length
            string += line.text
            ranges.append(NSRange(location: start, length: (line.text as NSString).length))
            string += "\n"
        }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue)
        return detector.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).map { match in
            let touched = zip(ordered, ranges).filter { NSIntersectionRange($0.1, match.range).length > 0 }.map(\.0.bounds)
            let kind: FoundItem.Kind = switch match.resultType {
            case .link: .link
            case .phoneNumber: .phone
            case .date: .date
            default: .address
            }
            return FoundItem(kind: kind, text: (string as NSString).substring(with: match.range),
                             bounds: touched.dropFirst().reduce(touched[0]) { $0.union($1) },
                             url: kind == .link ? openable(match.url) : nil)
        }
    }
}
