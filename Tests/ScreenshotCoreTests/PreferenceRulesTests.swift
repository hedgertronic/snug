import Foundation
import Testing
@testable import ScreenshotCore

struct PreferenceRulesTests {
    let suite = "snug-preferences-\(UUID().uuidString)"

    @Test func invalidStoredValuesFallBackToTheirDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ["icon": "q", "padding": 24, "fade": 0.5, "color": "", "shadow": "#000000", "code": 49, "modifiers": 393_216,
                                     "countIn": 3, "folder": "/Users/me/Desktop"])
        let rules: [String: PreferenceRule] = ["icon": .oneOf(["q", "p", "h", "a"]), "padding": .integer(0...64), "fade": .number(0...1),
                                               "color": .hexColor(emptyAllowed: true), "shadow": .hexColor(emptyAllowed: false),
                                               "code": .integerIn([-1, 0, 49]), "modifiers": .flags(mask: 0x1E0000), "countIn": .integerIn([0, 3, 5]),
                                               "folder": .nonEmptyString]
        defaults.set("z", forKey: "icon")
        defaults.set(500, forKey: "padding")
        defaults.set(Double.nan, forKey: "fade")
        defaults.set("#12345G", forKey: "color")
        defaults.set("", forKey: "shadow")
        defaults.set(999, forKey: "code")
        defaults.set(-1, forKey: "modifiers")
        defaults.set(true, forKey: "countIn")
        defaults.set("", forKey: "folder")
        #expect(PreferenceRules.sanitize(defaults, rules: rules) == rules.keys.sorted())
        #expect(defaults.string(forKey: "icon") == "q" && defaults.integer(forKey: "padding") == 24 && defaults.double(forKey: "fade") == 0.5)
        #expect(defaults.string(forKey: "color") == "" && defaults.string(forKey: "shadow") == "#000000" && defaults.integer(forKey: "code") == 49)
        #expect(defaults.integer(forKey: "modifiers") == 393_216 && defaults.integer(forKey: "countIn") == 3 && defaults.string(forKey: "folder") == "/Users/me/Desktop")
    }

    @Test func validValuesAndMissingKeysStay() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("a", forKey: "icon")
        defaults.set(64, forKey: "padding")
        defaults.set("#3a7BD5", forKey: "color")
        defaults.set(-1, forKey: "code")
        defaults.set(0x1E0000, forKey: "modifiers")
        let rules: [String: PreferenceRule] = ["icon": .oneOf(["q", "a"]), "padding": .integer(0...64), "color": .hexColor(emptyAllowed: false),
                                               "code": .integerIn([-1, 49]), "modifiers": .flags(mask: 0x1E0000), "unset": .number(0...1)]
        #expect(PreferenceRules.sanitize(defaults, rules: rules).isEmpty)
        #expect(defaults.string(forKey: "icon") == "a" && defaults.integer(forKey: "padding") == 64 && defaults.integer(forKey: "modifiers") == 0x1E0000)
    }

    @Test func numbersAreNotStringsAndWholeNumbersAreWhole() {
        #expect(!PreferenceRule.integer(0...64).accepts("24") && !PreferenceRule.integer(0...64).accepts(2.5) && PreferenceRule.integer(0...64).accepts(24.0))
        #expect(!PreferenceRule.number(0...1).accepts("0.5") && PreferenceRule.number(0...1).accepts(1))
    }
}
