import CoreGraphics

/// Chromium-based apps (Electron, Chrome, Edge, Brave, Arc) and the text their web areas expose through accessibility.
public enum ChromiumText {
    /// Whether an app bundle whose `Contents/Frameworks` folder holds `frameworks` (file names) embeds Chromium: it names its main
    /// library "<product> Framework" ("Electron Framework", "Google Chrome Framework", "Microsoft Edge Framework", "Brave Browser Framework").
    public static func embedsChromium(frameworks: [String]) -> Bool {
        frameworks.contains { $0.hasSuffix(" Framework.framework") }
    }

    /// One word (a run of non-space characters) of an element's text with its box, and whether a space came before it: always but
    /// for an element's first word, which has one when its text starts with a space or the element before it ended in one.
    public struct Piece: Sendable {
        public var text: String
        public var box: CGRect
        public var spaceBefore: Bool
        public init(text: String, box: CGRect, spaceBefore: Bool) {
            self.text = text
            self.box = box
            self.spaceBefore = spaceBefore
        }
    }

    /// The words of `text` split as `ScreenText` splits a line (at `Character.isWhitespace`), each with its range in UTF-16 units, which
    /// is what accessibility's ranges count.
    public static func words(in text: String) -> [(text: String, utf16: Range<Int>)] {
        var words: [(text: String, utf16: Range<Int>)] = []
        var start: (index: String.Index, offset: Int)?
        var offset = 0
        for index in text.indices {
            if text[index].isWhitespace, let begun = start {
                words.append((String(text[begun.index..<index]), begun.offset..<offset))
                start = nil
            } else if !text[index].isWhitespace, start == nil {
                start = (index, offset)
            }
            offset += text[index].utf16.count
        }
        if let begun = start { words.append((String(text[begun.index...]), begun.offset..<offset)) }
        return words
    }

    /// Lines for `ScreenText` from words in document order, which is reading order: a word joins the line before it when its middle
    /// is within that line's height, it starts no further left than the line's last word, and the gap to that word is at most three
    /// word heights (cells of a table row far apart are lines of their own). It is then a word of its own when a space came before it or
    /// the gap is over a quarter of its height, and otherwise it extends the last word ("link" and "." from two elements). Each line
    /// carries the boxes of its words, one per run of non-space characters in its text.
    public static func sources(of pieces: [Piece]) -> [ScreenText.Source] {
        struct Line {
            var words: [(text: String, box: CGRect)]
            var box: CGRect
        }
        var lines: [Line] = []
        for piece in pieces {
            guard var line = lines.last, let last = line.words.last, (line.box.minY...line.box.maxY).contains(piece.box.midY),
                  piece.box.minX >= last.box.minX, piece.box.minX - last.box.maxX <= 3 * piece.box.height else {
                lines.append(Line(words: [(piece.text, piece.box)], box: piece.box))
                continue
            }
            if piece.spaceBefore || piece.box.minX - last.box.maxX > piece.box.height / 4 {
                line.words.append((piece.text, piece.box))
            } else {
                line.words[line.words.count - 1] = (last.text + piece.text, last.box.union(piece.box))
            }
            line.box = line.box.union(piece.box)
            lines[lines.count - 1] = line
        }
        return lines.map { line in
            ScreenText.Source(text: line.words.map(\.text).joined(separator: " "), box: line.box, words: line.words.map(\.box))
        }
    }
}
