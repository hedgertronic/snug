import Foundation

extension ScreenText {
    /// The words of `text` (runs of non-whitespace characters, as `Source` counts them) as UTF-16 ranges, in order: the ranges a reader
    /// asks accessibility for the boxes of.
    public static func wordRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        var start: Int?
        for character in text {
            if character.isWhitespace {
                if let begun = start { ranges.append(begun..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += character.utf16.count
        }
        if let begun = start { ranges.append(begun..<offset) }
        return ranges
    }
}
