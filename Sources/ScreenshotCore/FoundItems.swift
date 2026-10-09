import CoreGraphics
import Foundation

/// A link, email address, phone number, or barcode payload found in the frozen image. `bounds` is in image pixels with a top-left
/// origin; `url` is what opens it, when it opens anything.
public struct FoundItem: Equatable, Sendable {
    public var text: String
    public var url: URL?
    public var bounds: CGRect

    public init(text: String, url: URL?, bounds: CGRect) {
        self.text = text
        self.url = url
        self.bounds = bounds
    }
}

public enum FoundItems {
    /// Links (email addresses come as mailto links) and phone numbers in `text`, each with the URL that opens it.
    public static func matches(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let range = Range(match.range, in: text)!
            if let url = match.url { return (range, url) }
            let digits = match.phoneNumber!.filter { $0.isNumber || $0 == "+" }
            return URL(string: "tel:\(digits)").map { (range, $0) }
        }
    }

    /// Items in reading order: top to bottom by their top edge, items whose top edges are within half a height side by side left to right.
    public static func readingOrder(_ items: [FoundItem]) -> [FoundItem] {
        items.sorted { a, b in
            abs(a.bounds.minY - b.bounds.minY) < min(a.bounds.height, b.bounds.height) / 2 ? a.bounds.minX < b.bounds.minX : a.bounds.minY < b.bounds.minY
        }
    }
}
