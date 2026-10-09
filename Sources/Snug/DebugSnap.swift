import AppKit

extension DebugRun {
    /// A 1280 x 800 capture at 1x, drawn with a top-left origin: a full-width toolbar strip and a small bordered pill.
    static let pillFixture = fixture { context in
        context.setFillColor(gray: 0.80, alpha: 1)
        context.fill(CGRect(x: 0, y: 40, width: 1280, height: 40))
        let pill = CGPath(roundedRect: CGRect(x: 300.5, y: 200.5, width: 159, height: 21), cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 0.6, alpha: 1)
        context.setLineWidth(1)
        context.addPath(pill)
        context.drawPath(using: .fillStroke)
    }

    /// A 1280 x 800 capture at 1x: three white 260 x 230 cards in a row on a gray page, each with a 2 px border.
    static let cardsFixture = fixture { context in
        for x in [280, 580, 880] {
            let card = CGRect(x: x, y: 200, width: 260, height: 230)
            context.setFillColor(gray: 0.74, alpha: 1)
            context.fill(card)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(card.insetBy(dx: 2, dy: 2))
        }
    }

    /// A 1280 x 800 capture at 1x: a Dock-like panel (200 x 500, 30 px corners, a light rim) whose color changes by 60 levels along its length.
    static let dockFixture = fixture { context in
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        let panel = CGRect(x: 100, y: 100, width: 200, height: 500)
        context.saveGState()
        context.addPath(CGPath(roundedRect: panel, cornerWidth: 30, cornerHeight: 30, transform: nil))
        context.clip()
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 0.2, alpha: 1), CGColor(gray: 0.45, alpha: 1)] as CFArray,
                                              locations: nil)!, start: panel.origin, end: CGPoint(x: panel.minX, y: panel.maxY), options: [])
        context.restoreGState()
        context.addPath(CGPath(roundedRect: panel.insetBy(dx: 1, dy: 1), cornerWidth: 29, cornerHeight: 29, transform: nil))
        context.setStrokeColor(gray: 0.7, alpha: 1)
        context.setLineWidth(2)
        context.strokePath()
    }

    /// A 1280 x 800 capture at 1x: a vertical Dock on the left like the user's (4 pt from the screen edge, 69 x 720, 24 px corners,
    /// a light rim) on a gradient wallpaper, with light icons down its middle.
    static let leftDockFixture = fixture { context in
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(red: 0.1, green: 0.08, blue: 0.2, alpha: 1),
                                              CGColor(red: 0.3, green: 0.25, blue: 0.4, alpha: 1)] as CFArray, locations: nil)!,
                                   start: .zero, end: CGPoint(x: 1280, y: 800), options: [])
        let panel = CGRect(x: 4, y: 40, width: 69, height: 720)
        context.addPath(CGPath(roundedRect: panel.insetBy(dx: 1, dy: 1), cornerWidth: 23, cornerHeight: 23, transform: nil))
        context.setStrokeColor(gray: 0.55, alpha: 1)
        context.setLineWidth(2)
        context.setFillColor(gray: 0.22, alpha: 1)
        context.drawPath(using: .fillStroke)
        context.setFillColor(gray: 0.9, alpha: 1)
        for y in stride(from: 60, to: 720, by: 60) { context.fill(CGRect(x: 14, y: CGFloat(y), width: 48, height: 48)) }
    }

    private static func fixture(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 800)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 0.95, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        draw(context)
        return context.makeImage()!
    }
}
