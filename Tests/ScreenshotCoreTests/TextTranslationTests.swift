import Foundation
import Testing
import Translation
@testable import ScreenshotCore

struct TextTranslationTests {
    let english = Locale.Language(identifier: "en")
    let german = Locale.Language(identifier: "de")

    @Test func installedPairTranslates() {
        #expect(TextTranslation.plan(source: german, target: english, status: .installed) == .translate)
    }

    @Test func supportedButNotInstalledSaysHowToAddIt() {
        let plan = TextTranslation.plan(source: german, target: english, status: .supported)
        let from = TextTranslation.name(german), to = TextTranslation.name(english)
        #expect(plan == .unavailable("\(from) to \(to) is not installed. Add it in System Settings > General > Language & Region > Translation Languages."))
    }

    @Test func unsupportedPairIsNotOfferedAsInstallable() {
        guard case .unavailable(let message) = TextTranslation.plan(source: german, target: english, status: .unsupported) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(message.hasSuffix("is not supported by system translation.") && !message.contains("Add it"))
    }

    @Test func sameLanguageWinsOverStatus() {
        for status in [LanguageAvailability.Status.installed, .supported, .unsupported] {
            guard case .sameLanguage = TextTranslation.plan(source: english, target: Locale.Language(identifier: "en-US"), status: status) else {
                Issue.record("expected sameLanguage for \(status)")
                return
            }
        }
    }

    @Test func detectsLanguage() {
        #expect(TextTranslation.language(of: "The quick brown fox jumps over the lazy dog")?.minimalIdentifier == "en")
        #expect(TextTranslation.language(of: "") == nil)
    }
}
