import Foundation
import Testing
@testable import ScreenshotCore

struct TextGroupingTests {
    @Test func keepsColumnsAndDistantFooterSeparate() {
        let lines = [
            CGRect(x: 20, y: 30, width: 150, height: 20),
            CGRect(x: 280, y: 30, width: 350, height: 30),
            CGRect(x: 280, y: 80, width: 500, height: 20),
            CGRect(x: 20, y: 110, width: 100, height: 20),
            CGRect(x: 280, y: 200, width: 100, height: 20),
            CGRect(x: 500, y: 200, width: 80, height: 20),
            CGRect(x: 280, y: 250, width: 100, height: 20),
            CGRect(x: 280, y: 735, width: 170, height: 20)
        ]
        #expect(groupedTextCandidates(from: lines).isEmpty)
    }

    @Test func paragraphGroupsButWhitespaceDoesNotWinHover() {
        let lines = [CGRect(x: 20, y: 20, width: 200, height: 20),
                     CGRect(x: 20, y: 50, width: 90, height: 20),
                     CGRect(x: 20, y: 80, width: 180, height: 20)]
        let blocks = groupedTextCandidates(from: lines)
        #expect(blocks.count == 1)
        #expect(blocks.first?.hitRegions == lines)
        let extent = CGRect(x: 0, y: 0, width: 500, height: 400)
        var session = SelectionSession(candidates: blocks, extent: extent, anchor: CGPoint(x: 150, y: 60))
        #expect(session.selected?.kind == .display)
        session.hover(at: CGPoint(x: 50, y: 60))
        #expect(session.selected?.kind == .text)
        session.hover(at: CGPoint(x: 50, y: 45))
        #expect(session.selected?.kind == .display)
    }

    @Test func spacingAllowanceDoesNotGrowWithParagraphHeight() {
        let paragraph = (0..<10).map { CGRect(x: 20, y: 20 + $0 * 30, width: 180, height: 20) }
        let footer = CGRect(x: 20, y: 500, width: 180, height: 20)
        let blocks = groupedTextCandidates(from: paragraph + [footer])
        #expect(blocks.count == 1)
        #expect(blocks.first?.bounds.maxY == 310)
    }
}
