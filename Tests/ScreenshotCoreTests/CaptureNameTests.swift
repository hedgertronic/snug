import Foundation
import Testing
@testable import ScreenshotCore

struct CaptureNameTests {
    let stamp = "2026-11-14 at 18.03.12"
    let date = Date(timeIntervalSince1970: 1_794_679_392) // 2026-11-14 18:03:12 UTC
    let utc = TimeZone(identifier: "UTC")!

    func name(_ pattern: String = CaptureName.contextPattern, app: String?, description: String?) -> String {
        CaptureName.name(pattern: pattern, app: app, description: description, date: date, timeZone: utc)
    }

    @Test func theDefaultPatternIsSnugAndTheMacOSStamp() {
        #expect(name(CaptureName.defaultPattern, app: "Safari", description: "Lisbon flight") == "Snug \(stamp)")
        #expect(name(CaptureName.defaultPattern, app: nil, description: nil) == "Snug \(stamp)")
    }

    @Test func onlyPatternsWithATitleUseOne() {
        #expect(!CaptureName.usesTitle(CaptureName.defaultPattern))
        #expect(!CaptureName.usesTitle(""), "an empty pattern means the default")
        #expect(CaptureName.usesTitle(CaptureName.contextPattern))
        #expect(CaptureName.usesTitle("{date} {title}"))
    }

    @Test func theContextPatternJoinsAppAndDescriptionBeforeTheMacOSStamp() {
        #expect(name(app: "Safari", description: "Lisbon flight confirmation") == "Safari - Lisbon flight confirmation \(stamp)")
        #expect(name(app: "Safari", description: nil) == "Safari \(stamp)", "a missing title drops its separator too")
        #expect(name(app: "Safari", description: "safari") == "Safari \(stamp)", "a description that repeats the app is dropped")
        #expect(name(app: nil, description: "Notes") == "Notes \(stamp)", "a missing app drops the separator after it")
        #expect(name(app: nil, description: nil) == "Snug \(stamp)", "no context keeps the usual name")
        #expect(name(app: "  ", description: " ") == "Snug \(stamp)")
    }

    @Test func customPatternsPlaceEachToken() {
        #expect(name("{date} {time} {app}", app: "Safari", description: "Flight") == "2026-11-14 18.03.12 Safari")
        #expect(name("{title} ({app})", app: "Safari", description: "Flight") == "Flight (Safari)")
        #expect(name("Shot {date}", app: "Safari", description: nil) == "Shot 2026-11-14", "literal text stays")
        #expect(name("{title}_{date}", app: "Safari", description: nil) == "2026-11-14", "a missing title at the start drops the separator after it")
        #expect(name("{app}/{title}: {time}", app: "Safari", description: "Flight") == "Safari-Flight- 18.03.12", "pattern text is made fit for a file name")
        #expect(name("{nope} {date}", app: "Safari", description: nil) == "{nope} 2026-11-14", "an unknown token stays as typed")
    }

    @Test func anEmptyPatternFallsBackToTheDefault() {
        #expect(name("", app: "Safari", description: "Flight") == "Snug \(stamp)")
        #expect(name("{title}", app: "Safari", description: nil) == "Snug \(stamp)", "a pattern that renders to nothing uses the default")
        #expect(name(" - ", app: "Safari", description: nil) == "Snug \(stamp)")
    }

    @Test func windowTitlesLoseUnreadCountsAndTheAppSuffix() {
        #expect(CaptureName.description(fromWindowTitle: "(3) Inbox - Gmail - Google Chrome", app: "Google Chrome") == "Inbox - Gmail")
        #expect(CaptureName.description(fromWindowTitle: "• Slack | general", app: "Slack") == "Slack | general")
        #expect(CaptureName.description(fromWindowTitle: "README.md — snug", app: "Code") == "README.md — snug")
        #expect(CaptureName.description(fromWindowTitle: "Pull requests — Safari", app: "Safari") == "Pull requests")
        #expect(CaptureName.description(fromWindowTitle: "Finder", app: "Finder") == nil)
        #expect(CaptureName.description(fromWindowTitle: "", app: "Finder") == nil)
        #expect(CaptureName.description(fromWindowTitle: nil, app: "Finder") == nil)
    }

    @Test func titlesBecomeSafeFileNames() {
        #expect(CaptureName.description(fromWindowTitle: "josh@mac: ~/Developer/tools", app: "Terminal") == "josh@mac- ~-Developer-tools")
        #expect(CaptureName.description(fromWindowTitle: "..hidden\nline", app: nil) == "hidden line")
        #expect(CaptureName.sanitized("  a\t\tb  ") == "a b")
    }

    @Test func longTitlesAreCutAtAWordBreak() {
        let title = "Quarterly planning notes for the pitching development group and the research team"
        let cut = CaptureName.description(fromWindowTitle: title, app: "Notion")!
        #expect(cut == "Quarterly planning notes for the pitching development group")
        #expect(cut.count <= CaptureName.maxDescription)
        let unbroken = String(repeating: "x", count: 80)
        #expect(CaptureName.description(fromWindowTitle: unbroken, app: nil)!.count == CaptureName.maxDescription)
    }

    @Test func modelRepliesAreCleanedOrRejected() {
        #expect(CaptureName.description(fromModel: "\"Lisbon Flight Confirmation\"") == "Lisbon Flight Confirmation")
        #expect(CaptureName.description(fromModel: "Title: Harbor Street Coffee Order.") == "Harbor Street Coffee Order")
        #expect(CaptureName.description(fromModel: "\n**Build Errors in Xcode**\n\nThis screenshot shows...") == "Build Errors in Xcode")
        #expect(CaptureName.description(fromModel: "settings-panel.png") == "settings-panel")
        #expect(CaptureName.description(fromModel: "   ") == nil)
        #expect(CaptureName.description(fromModel: "This screenshot shows a web page with a list of flights from Lisbon to New York on Friday") == nil,
                "a sentence is not a title")
    }

    @Test func typedNamesKeepTheFolderAndExtension() {
        let file = URL(fileURLWithPath: "/Users/me/Desktop/Safari \(stamp).png")
        #expect(CaptureName.renamed(file, to: "Flight") == URL(fileURLWithPath: "/Users/me/Desktop/Flight.png"))
        #expect(CaptureName.renamed(file, to: "Flight.png") == URL(fileURLWithPath: "/Users/me/Desktop/Flight.png"), "a typed extension is not doubled")
        #expect(CaptureName.renamed(file, to: "a/b: c") == URL(fileURLWithPath: "/Users/me/Desktop/a-b- c.png"))
        #expect(CaptureName.renamed(file, to: "  ") == nil)
        #expect(CaptureName.renamed(file, to: "Safari \(stamp)") == nil, "an unchanged name renames nothing")
        let movie = URL(fileURLWithPath: "/tmp/Snug \(stamp).mov")
        #expect(CaptureName.renamed(movie, to: "Demo") == URL(fileURLWithPath: "/tmp/Demo.mov"))
    }
}
