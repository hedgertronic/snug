import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

struct FoundItemsTests {
    @Test func findsLinksEmailsAndPhoneNumbersWithTheURLsThatOpenThem() {
        let text = "Docs at https://example.com/snug, mail you@example.com or call +1 (555) 010-4477."
        let found = FoundItems.matches(in: text).map { (String(text[$0.range]), $0.url.absoluteString) }
        #expect(found.map(\.0) == ["https://example.com/snug", "you@example.com", "+1 (555) 010-4477"])
        #expect(found.map(\.1) == ["https://example.com/snug", "mailto:you@example.com", "tel:+15550104477"])
    }

    @Test func plainTextHasNoItems() {
        #expect(FoundItems.matches(in: "Product name $12").isEmpty)
    }

    @Test func readingOrderGoesByRowsThenLeftToRight() {
        func item(_ text: String, _ x: CGFloat, _ y: CGFloat) -> FoundItem {
            FoundItem(text: text, url: nil, bounds: CGRect(x: x, y: y, width: 100, height: 20))
        }
        let ordered = FoundItems.readingOrder([item("c", 0, 200), item("b", 400, 104), item("a", 10, 100)])
        #expect(ordered.map(\.text) == ["a", "b", "c"])
    }
}
