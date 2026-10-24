import CoreGraphics
import CoreText
import ScreenshotCore
import Testing

struct TextStyleTests {
    /// Each line drawn in dark ink on a cream card, 40 px rows from y 20, and its box (top-left origin).
    func card(_ lines: [(text: String, size: CGFloat, bold: Bool)]) -> (CGImage, [CGRect]) {
        let (width, height) = (600, 40 * lines.count + 40)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var boxes: [CGRect] = []
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateUIFontForLanguage(line.bold ? .emphasizedSystem : .system, line.size, nil)!
            let attributed = CFAttributedStringCreate(nil, line.text as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0.2, green: 0.25, blue: 0.6, alpha: 1)] as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let top = CGFloat(20 + 40 * index)
            context.textPosition = CGPoint(x: 20, y: CGFloat(height) - top - CTFontGetAscent(font))
            CTLineDraw(ctLine, context)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            boxes.append(CGRect(x: 16, y: top - 3, width: width + 8, height: CTFontGetAscent(font) + CTFontGetDescent(font) + 6))
        }
        return (context.makeImage()!, boxes)
    }

    @Test func aBoldTitleDiffersFromItsSubtitleButTheSubtitlesLinesMatch() {
        let (image, boxes) = card([("Sam needs a tent", 26, true), ("Camping Fri to Sun - 2", 22, false), ("blocks", 22, false)])
        let styles = boxes.map { TextStyle.measure(in: image, box: $0)! }
        #expect(styles[0].differs(from: styles[1]), "\(styles)")
        #expect(!styles[1].differs(from: styles[2]), "\(styles)")
    }

    @Test func aBlankBoxOrOneOffTheImageHasNoStyle() {
        let (image, _) = card([("x", 20, false)])
        #expect(TextStyle.measure(in: image, box: CGRect(x: 300, y: 10, width: 100, height: 20)) == nil)
        #expect(TextStyle.measure(in: image, box: CGRect(x: 900, y: 900, width: 50, height: 20)) == nil)
    }

    @Test func rowsInDifferentStylesNeverJoinAsASoftWrap() {
        // A Neighborly card's lines as OCR boxes them: a bold title, then a subtitle that wraps.
        let title = TextStyle(band: 17, weight: 8.1), subtitle = TextStyle(band: 14, weight: 5)
        let lines = [TextLine(text: "Sam needs a tent", bounds: CGRect(x: 182, y: 1108, width: 246, height: 26), style: title),
                     TextLine(text: "Camping Fri to Sun - 2", bounds: CGRect(x: 182, y: 1146, width: 268, height: 28), style: subtitle),
                     TextLine(text: "blocks", bounds: CGRect(x: 182, y: 1176, width: 82, height: 26), style: subtitle)]
        #expect(TextLayout.paragraphs(TextLayout.rows(lines)) == "Sam needs a tent\nCamping Fri to Sun - 2 blocks")
        // Without styles (accessibility text) the title still joins, as before.
        #expect(TextLayout.paragraphs(TextLayout.rows(lines.map { TextLine(text: $0.text, bounds: $0.bounds) })) == "Sam needs a tent Camping Fri to Sun - 2 blocks")
    }
}
