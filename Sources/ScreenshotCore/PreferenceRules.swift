import Foundation

/// What a stored preference may hold; anything else is set aside for its registered default.
public enum PreferenceRule: Sendable {
    /// One of these strings.
    case oneOf(Set<String>)
    /// A whole number, one of these.
    case integerIn(Set<Int>)
    /// A whole number in the range.
    case integer(ClosedRange<Int>)
    /// A finite number in the range.
    case number(ClosedRange<Double>)
    /// "#RRGGBB" in hex digits, or with `emptyAllowed` also "" (the system accent).
    case hexColor(emptyAllowed: Bool)
    /// A whole number of flag bits, all inside `mask`.
    case flags(mask: Int)
    /// A string that is not empty.
    case nonEmptyString

    public func accepts(_ value: Any) -> Bool {
        // Booleans are NSNumbers too; no rule here takes one.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
        switch self {
        case .oneOf(let allowed): return (value as? String).map(allowed.contains) ?? false
        case .integerIn(let allowed): return Self.integer(value).map(allowed.contains) ?? false
        case .integer(let range): return Self.integer(value).map(range.contains) ?? false
        case .number(let range):
            guard let number = Self.number(value) else { return false }
            return number.isFinite && range.contains(number)
        case .hexColor(let emptyAllowed):
            guard let text = value as? String else { return false }
            if text.isEmpty { return emptyAllowed }
            return text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy(\.isHexDigit)
        case .flags(let mask): return Self.integer(value).map { $0 >= 0 && $0 & ~mask == 0 } ?? false
        case .nonEmptyString: return (value as? String).map { !$0.isEmpty } ?? false
        }
    }

    /// A number, or a string that reads as one: `defaults write` without a type stores "30", which UserDefaults reads as 30.
    private static func number(_ value: Any) -> Double? {
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any) -> Int? {
        number(value).flatMap { Int(exactly: $0) }
    }
}

public enum PreferenceRules {
    /// Removes every value saved in `domain` (the app's own defaults) that its rule does not accept, so the registered default answers in
    /// its place, as after an upgrade that dropped a choice or a manual `defaults write`. A value given only as a launch argument is not
    /// saved and is left alone. With no domain (a binary without a bundle identifier) the value `defaults` answers with is checked.
    /// Returns the keys removed, sorted.
    @discardableResult
    public static func sanitize(_ defaults: UserDefaults, domain: String?, rules: [String: PreferenceRule]) -> [String] {
        let saved = domain.map { defaults.persistentDomain(forName: $0) ?? [:] }
        var removed: [String] = []
        for (key, rule) in rules {
            guard let value = saved.map({ $0[key] }) ?? defaults.object(forKey: key), !rule.accepts(value) else { continue }
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        return removed.sorted()
    }
}
