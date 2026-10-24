import Foundation
import CoreGraphics

/// How a copied or saved area is framed: tight (`padding` nil), or (Frame on) a card on `padding` points of transparent padding with a
/// soft shadow sized to fit inside it, or with a custom `Shadow`, on at least `padding` points and as much more as the shadow reaches.
public enum OutputFrame {
    /// A custom shadow: opacity 0 to 1, blur and distance in points, `angle` the direction it falls in degrees counterclockwise from
    /// the right (0 right, 90 up, 180 left, 270 straight down), and its color.
    public struct Shadow: Sendable, Equatable {
        public var opacity, blur, distance, angle: CGFloat
        public var color: SRGBColor

        public init(opacity: CGFloat, blur: CGFloat, distance: CGFloat, angle: CGFloat, color: SRGBColor) {
            (self.opacity, self.blur, self.distance, self.angle, self.color) = (opacity, blur, distance, angle, color)
        }

        /// The shadow's offset in points, y up as `CGContext.setShadow` takes it.
        var offset: CGSize {
            CGSize(width: distance * cos(angle * .pi / 180), height: distance * sin(angle * .pi / 180))
        }

        /// The canvas around a shape that holds this shadow on at least `padding` points, in whole pixels at `scale`. The blur fades out
        /// within 1.3 times its value of the offset shape (the window shadow fit gives 52 pt for a blur of 42; at full opacity a little
        /// more is needed).
        public func margins(padding: CGFloat, scale: CGFloat) -> (left: Int, top: Int, right: Int, bottom: Int) {
            let reach = blur * 1.3, offset = offset
            func side(_ extent: CGFloat) -> Int { Int((max(padding, extent) * scale).rounded(.up)) }
            return (side(reach - offset.width), side(reach + offset.height), side(reach + offset.width), side(reach - offset.height))
        }
    }

    /// The output's footprint around a crop in image pixels (top-left origin). A frame may extend past the image because its padding
    /// is synthetic.
    public static func rect(around crop: CGRect, scale: CGFloat, padding: CGFloat?, shadow: Shadow? = nil) -> CGRect {
        guard let padding else { return crop }
        guard let shadow else { return crop.insetBy(dx: -padding * scale, dy: -padding * scale) }
        let m = shadow.margins(padding: padding, scale: scale)
        return CGRect(x: crop.minX - CGFloat(m.left), y: crop.minY - CGFloat(m.top),
                      width: crop.width + CGFloat(m.left + m.right), height: crop.height + CGFloat(m.top + m.bottom))
    }

    /// `shape`, an image transparent outside what casts the shadow, on the canvas `shadow.margins` gives with `shadow` following its alpha.
    public static func shadowed(_ shape: CGImage, shadow: Shadow, padding: CGFloat, scale: CGFloat) throws -> CGImage {
        let m = shadow.margins(padding: padding, scale: scale)
        guard let context = CGContext(data: nil, width: shape.width + m.left + m.right, height: shape.height + m.top + m.bottom,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: shape.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let offset = shadow.offset
        context.setShadow(offset: CGSize(width: offset.width * scale, height: offset.height * scale), blur: shadow.blur * scale,
                          color: CGColor(srgbRed: shadow.color.red, green: shadow.color.green, blue: shadow.color.blue, alpha: shadow.opacity))
        // CGContext has a bottom-left origin, so the bottom margin comes first.
        context.draw(shape, in: CGRect(x: m.left, y: m.bottom, width: shape.width, height: shape.height))
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }

    /// Renders the output image for a crop given in source-image pixels. Unframed output is transparent outside `cornerRadii`; framed
    /// output rounds its card with them, or by 10 pt when they are all square, and casts the card shadow or `shadow`.
    public static func render(_ image: CGImage, crop: CGRect, scale: CGFloat, padding: CGFloat?, cornerRadii: CornerRadii = .zero,
                              shadow: Shadow? = nil) throws -> CGImage {
        if let padding, let shadow {
            let card = try render(image, crop: crop, scale: scale, padding: nil, cornerRadii: cornerRadii.isSquare ? CornerRadii(10 * scale) : cornerRadii)
            return try shadowed(card, shadow: shadow, padding: padding, scale: scale)
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = crop.integral.intersection(extent)
        let frame = rect(around: crop, scale: scale, padding: padding).integral
        guard let source = image.cropping(to: crop) else { throw CocoaError(.fileReadCorruptFile) }
        if padding == nil, !cornerRadii.isSquare {
            guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw CocoaError(.fileWriteUnknown) }
            context.setShouldAntialias(true)
            context.addPath(cornerRadii.path(in: CGRect(x: 0, y: 0, width: source.width, height: source.height)))
            context.clip()
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            return output
        }
        guard let padding else { return source }

        let width = Int(frame.width), height = Int(frame.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        // CGContext has a bottom-left origin; the padding is symmetric so the image rect needs no flip.
        let target = CGRect(x: crop.minX - frame.minX, y: crop.minY - frame.minY, width: crop.width, height: crop.height)
        let radii = cornerRadii.isSquare ? CornerRadii(10 * scale) : cornerRadii
        // The shadow falls a quarter of the padding down and blurs over three quarters of it, so its bottom edge fades out within the padding.
        context.setShadow(offset: CGSize(width: 0, height: -padding / 4 * scale), blur: padding * 3 / 4 * scale, color: CGColor(gray: 0, alpha: 0.28))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(radii.path(in: target))
        context.clip()
        context.draw(source, in: target)
        context.endTransparencyLayer()
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
