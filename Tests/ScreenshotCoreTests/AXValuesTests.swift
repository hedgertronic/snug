import ApplicationServices
import Foundation
import Testing
@testable import ScreenshotCore

struct AXValuesTests {
    private func wrapped<T>(_ value: T, _ type: AXValueType) -> CFTypeRef {
        var value = value
        return AXValueCreate(type, &value)!
    }

    @Test func eachReaderTakesOnlyItsOwnValueType() throws {
        let point = wrapped(CGPoint(x: 3, y: 4), .cgPoint)
        let size = wrapped(CGSize(width: 5, height: 6), .cgSize)
        let rect = wrapped(CGRect(x: 1, y: 2, width: 3, height: 4), .cgRect)
        let range = wrapped(CFRange(location: 2, length: 3), .cfRange)
        #expect(AXValues.point(point) == CGPoint(x: 3, y: 4) && AXValues.size(size) == CGSize(width: 5, height: 6))
        #expect(AXValues.rect(rect) == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(AXValues.range(range).map { [$0.location, $0.length] } == [2, 3])
        #expect(AXValues.point(size) == nil && AXValues.size(point) == nil && AXValues.rect(range) == nil && AXValues.range(rect) == nil,
                "a value of another AXValue type reads as nil")
    }

    @Test func answersThatAreNotAXValuesOrAreNotFiniteReadAsNil() {
        let notValues: [CFTypeRef?] = [nil, "text" as CFString, 3 as CFNumber, [1, 2] as CFArray, kCFNull]
        for raw in notValues {
            #expect(AXValues.point(raw) == nil && AXValues.size(raw) == nil && AXValues.rect(raw) == nil && AXValues.range(raw) == nil)
        }
        #expect(AXValues.rect(wrapped(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), .cgRect)) == nil)
        #expect(AXValues.size(wrapped(CGSize(width: CGFloat.infinity, height: 1), .cgSize)) == nil)
    }

    @Test func rangesMustLieInsideTheTextWithoutOverflow() {
        #expect(AXValues.range(CFRange(location: 2, length: 3), within: 5) == NSRange(location: 2, length: 3))
        #expect(AXValues.range(CFRange(location: 5, length: 0), within: 5) == NSRange(location: 5, length: 0))
        let outside = [CFRange(location: -1, length: 2), CFRange(location: 0, length: -1), CFRange(location: 4, length: 2),
                       CFRange(location: 6, length: 0), CFRange(location: 1, length: Int.max), CFRange(location: Int.max, length: Int.max)]
        for range in outside { #expect(AXValues.range(range, within: 5) == nil, "\(range.location), \(range.length)") }
    }

    @Test func clampedRangesKeepThePartInsideTheText() {
        #expect(AXValues.range(CFRange(location: 2, length: 3), clampedTo: 5) == NSRange(location: 2, length: 3))
        #expect(AXValues.range(CFRange(location: 3, length: 4), clampedTo: 5) == NSRange(location: 3, length: 2), "a range past the end keeps its last line")
        #expect(AXValues.range(CFRange(location: 0, length: 9), clampedTo: 5) == NSRange(location: 0, length: 5))
        #expect(AXValues.range(CFRange(location: 7, length: 2), clampedTo: 5)?.length == 0, "a range wholly past the end is empty")
        let invalid = [CFRange(location: -1, length: 2), CFRange(location: 0, length: -1), CFRange(location: 1, length: Int.max), CFRange(location: Int.max, length: Int.max)]
        for range in invalid { #expect(AXValues.range(range, clampedTo: 5) == nil, "\(range.location), \(range.length)") }
    }

    @Test func elementsMustBeElements() {
        #expect(AXValues.element(AXUIElementCreateApplication(getpid())) != nil)
        #expect(AXValues.element("AXWindow" as CFString) == nil && AXValues.element(wrapped(CGPoint.zero, .cgPoint)) == nil && AXValues.element(nil) == nil)
    }

    @Test func lineIndexesAreNonnegativeNumbers() {
        #expect(AXValues.index(7 as CFNumber) == 7 && AXValues.index(0 as CFNumber) == 0)
        #expect(AXValues.index(-1 as CFNumber) == nil && AXValues.index("7" as CFString) == nil && AXValues.index(nil) == nil)
    }
}
