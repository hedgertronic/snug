import Foundation

/// What a capture was taken of, for its file name: the app that owns the window under the capture's center and that window's title.
public struct CaptureContext: Sendable, Equatable {
    public var app: String?
    public var title: String?

    public init(app: String?, title: String?) {
        self.app = app
        self.title = title
    }
}

/// File names for captures, from a pattern of literal text and tokens: {app} (the app's name), {title} (the window's title), {date} (yyyy-MM-dd) and {time} (HH.mm.ss). The default, "{app} - {title} {date} at {time}", gives
/// "Safari - Lisbon flight 2026-11-14 at 18.03.12"; a capture with neither app nor title takes "Snug" for its app.
public enum CaptureName {
    /// The longest description kept, in characters; a longer one is cut at a word break.
    public static let maxDescription = 60
    /// The pattern Snug names files with unless another is set (Settings > General > File names).
    public static let defaultPattern = "{app} - {title} {date} at {time}"
    /// The tokens a pattern can hold.
    public static let tokens = ["app", "title", "date", "time"]
    /// Characters that only separate tokens: dropped next to an empty token and trimmed from the ends of a name.
    static let separators = CharacterSet(charactersIn: " -–—_|,")

    /// The name, without extension, `pattern` gives a capture of `app` described by `description` (a window title already cleaned with
    /// `description(fromWindowTitle:app:)`) taken at `date`. A description that only repeats the app is left out. An
    /// empty pattern, or one that renders to nothing, uses `defaultPattern`.
    public static func name(pattern: String, app: String?, description: String?, date: Date, timeZone: TimeZone = .current) -> String {
        let app = app.map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
        var description = description.map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
        if let shown = description, let app, shown.caseInsensitiveCompare(app) == .orderedSame { description = nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd"
        let day = format.string(from: date)
        format.dateFormat = "HH.mm.ss"
        let values = ["app": app ?? (description == nil ? "Snug" : ""), "title": description ?? "", "date": day, "time": format.string(from: date)]
        let rendered = render(pattern, values: values)
        return rendered.isEmpty ? render(defaultPattern, values: values) : rendered
    }

    /// `pattern` with each known token replaced by its value. An empty value drops its token together with the separator-only text
    /// before it (or, at the start, after it), so "{app} - {title} {date}" without a title reads "Safari 2026-11-14". The result is made
    /// fit for a file name (`sanitized`) and trimmed of separators at both ends; an unknown token stays as typed.
    public static func render(_ pattern: String, values: [String: String]) -> String {
        enum Part { case text(String), token(String) }
        var parts: [Part] = []
        var rest = Substring(pattern)
        while let match = rest.firstMatch(of: /\{(app|title|date|time)\}/) {
            if match.range.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<match.range.lowerBound]))) }
            parts.append(.token(String(match.output.1)))
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        func separatorOnly(_ part: Part) -> Bool {
            if case let .text(text) = part { text.trimmingCharacters(in: separators).isEmpty } else { false }
        }
        var index = 0
        while index < parts.count {
            guard case let .token(token) = parts[index], values[token, default: ""].isEmpty else {
                index += 1
                continue
            }
            parts.remove(at: index)
            if index > 0, separatorOnly(parts[index - 1]) {
                parts.remove(at: index - 1)
                index -= 1
            } else if index < parts.count, separatorOnly(parts[index]) {
                parts.remove(at: index)
            }
        }
        let joined = parts.map { part -> String in
            switch part {
            case let .text(text): text
            case let .token(token): sanitized(values[token, default: ""])
            }
        }.joined()
        return sanitized(joined).trimmingCharacters(in: separators)
    }

    /// The description a window title gives: unread counts ("(3) ", "• ") and a trailing " - App" dropped, cut to `maxDescription`.
    /// Nil when nothing is left or the title only repeats the app's name.
    public static func description(fromWindowTitle raw: String?, app: String?) -> String? {
        guard var title = raw.map(sanitized), !title.isEmpty else { return nil }
        title = title.replacing(/^(\(\d+\+?\)|[•●])\s*/, with: "")
        if let app = app.map(sanitized), !app.isEmpty {
            for separator in [" - ", " — ", " – ", " | "] where title.lowercased().hasSuffix((separator + app).lowercased()) {
                title = String(title.dropLast(separator.count + app.count))
            }
            if title.caseInsensitiveCompare(app) == .orderedSame { return nil }
        }
        return shortened(title)
    }

    /// `text` fit for a file name: "/" and ":" become "-", control characters and line breaks become spaces, runs of spaces collapse, and
    /// leading dots (which would hide the file) and spaces are dropped.
    public static func sanitized(_ text: String) -> String {
        var result = String(text.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        })
        result = result.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `text` cut to `maxDescription` characters at the last word break past half that length (or hard at the limit), without
    /// trailing separators.
    static func shortened(_ text: String) -> String? {
        var result = text
        if result.count > maxDescription {
            let limit = result.index(result.startIndex, offsetBy: maxDescription)
            let head = result[..<limit]
            if let space = head.lastIndex(of: " "), result.distance(from: result.startIndex, to: space) > maxDescription / 2 {
                result = String(head[..<space])
            } else {
                result = String(head)
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " -–—,;|"))
        return result.isEmpty ? nil : result
    }
}
