import CoreGraphics
import Foundation

/// A web page's visual lines as WebKit's accessibility text markers give them (Safari, Mail's message view): a line's string as the
/// line's marker range reads it, with its newline and the object-replacement characters (U+FFFC) it carries for images and
/// attachments, and the pieces its word ranges split it into.
public enum WebText {
    private static let attachment: Character = "\u{FFFC}"

    private static func isPadding(_ character: Character) -> Bool { character.isWhitespace || character == attachment }

    /// The number of characters in `line` before its trailing newline, spaces and attachment characters: where its word ranges end.
    public static func significantLength(of line: String) -> Int {
        line.reversed().drop(while: isPadding).count
    }

    /// `line` as a `ScreenText.Source`: its text without attachment characters, leading padding and trailing padding, its newlines
    /// inside read as spaces. When `pieces` (consecutive word ranges, each a string and its box) cover the line's characters up to
    /// `significantLength(of:)` exactly, the words are the runs of non-spaces in that text, each the union of the boxes its characters
    /// take from their piece (spread evenly across the piece), and the box runs from the first word to the last; otherwise the words
    /// are nil and `box` stays as given. Nil when nothing remains.
    public static func source(line: String, box: CGRect, pieces: [(text: String, box: CGRect)]?) -> ScreenText.Source? {
        let characters = Array(line.prefix(significantLength(of: line)))
        var slots: [CGRect]?
        if let pieces, pieces.map(\.text).joined() == String(characters) {
            slots = pieces.flatMap { piece in
                piece.text.indices.map { index in
                    let count = CGFloat(piece.text.count), offset = CGFloat(piece.text.distance(from: piece.text.startIndex, to: index))
                    return CGRect(x: piece.box.minX + piece.box.width * offset / count, y: piece.box.minY, width: piece.box.width / count, height: piece.box.height)
                }
            }
        }
        let kept = characters.indices.filter { characters[$0] != attachment }.drop(while: { characters[$0].isWhitespace })
        guard !kept.isEmpty else { return nil }
        let text = String(kept.map { characters[$0].isNewline ? " " : characters[$0] })
        guard let slots, slots.count == characters.count else { return ScreenText.Source(text: text, box: box) }
        var words: [CGRect] = []
        var run = CGRect.null
        for index in kept + [characters.count] {
            if index < characters.count, !characters[index].isWhitespace {
                run = run.union(slots[index])
            } else if !run.isNull {
                words.append(run)
                run = .null
            }
        }
        let (left, right) = (words[0].minX, words[words.count - 1].maxX)
        return ScreenText.Source(text: text, box: CGRect(x: left, y: box.minY, width: right - left, height: box.height), words: words)
    }
}
