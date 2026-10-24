import CoreGraphics

/// How a line of text is set, measured from its pixels: the height of its dense band of ink (the x-height for lowercase, the cap
/// height for capitals) and its weight (the mean length of the ink runs across that band, longer for bold). Lines of one paragraph
/// measured within 10% of each other on a card list, where a bold title over its regular subtitle differed by 1.2x in band and 1.6x
/// in weight.
public struct TextStyle: Equatable, Sendable {
    public var band: CGFloat
    public var weight: CGFloat

    public init(band: CGFloat, weight: CGFloat) {
        self.band = band
        self.weight = weight
    }

    /// The style of the text in `box` (image pixels) of `image`: ink is a pixel more than 60 gray levels from the background (the
    /// median of the box's border), and the band is the rows holding at least 40% of the inkiest row's ink. Nil for a box off the
    /// image or with no ink.
    public static func measure(in image: CGImage, box: CGRect) -> TextStyle? {
        let box = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !box.isEmpty, let crop = image.cropping(to: box) else { return nil }
        let (width, height) = (Int(box.width), Int(box.height))
        var gray = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let border = (0..<width).flatMap { [gray[$0], gray[(height - 1) * width + $0]] } + (0..<height).flatMap { [gray[$0 * width], gray[$0 * width + width - 1]] }
        let background = Int(border.sorted()[border.count / 2])
        func ink(_ x: Int, _ y: Int) -> Bool { abs(Int(gray[y * width + x]) - background) > 60 }
        let rows = (0..<height).map { y in (0..<width).count { ink($0, y) } }
        let peak = rows.max()!
        guard peak > 0 else { return nil }
        let band = (0..<height).filter { rows[$0] * 10 >= peak * 4 }
        var runs = 0
        for y in band {
            for x in 0..<width where ink(x, y) && (x == 0 || !ink(x - 1, y)) { runs += 1 }
        }
        return TextStyle(band: CGFloat(band.count), weight: CGFloat(band.map { rows[$0] }.reduce(0, +)) / CGFloat(runs))
    }

    /// Whether two lines are set in clearly different styles: bands 15% or more apart, or weights 35% or more.
    public func differs(from other: TextStyle) -> Bool {
        max(band, other.band) >= 1.15 * min(band, other.band) || max(weight, other.weight) >= 1.35 * min(weight, other.weight)
    }
}
