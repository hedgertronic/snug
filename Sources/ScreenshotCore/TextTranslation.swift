import Foundation
import NaturalLanguage
import Translation

/// Decides what Option-Return does with a language pair. The Translation framework supplies the status; nothing here downloads.
public enum TextTranslation {
    public enum Plan: Equatable, Sendable {
        case translate
        case sameLanguage(String)
        /// The notice to show: the pair exists but is not installed, or does not exist.
        case unavailable(String)
    }

    public static func plan(source: Locale.Language, target: Locale.Language, status: LanguageAvailability.Status) -> Plan {
        let from = name(source), to = name(target)
        if source.minimalIdentifier == target.minimalIdentifier { return .sameLanguage("Text is already in \(to).") }
        switch status {
        case .installed: return .translate
        case .supported:
            return .unavailable("\(from) to \(to) is not installed. Add it in System Settings > General > Language & Region > Translation Languages.")
        case .unsupported: return .unavailable("\(from) to \(to) is not supported by system translation.")
        @unknown default: return .unavailable("\(from) to \(to) is not available.")
        }
    }

    /// The dominant language of the text, or nil when it cannot be told.
    public static func language(of text: String) -> Locale.Language? {
        NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue) }
    }

    /// The language's name in the user's language.
    public static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}
