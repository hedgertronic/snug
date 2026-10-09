import Foundation
import CoreGraphics

/// How a copied or saved area is framed: tight, or (Frame on) a card on transparent padding with a soft shadow.
public enum OutputFrame {
    /// Padding around the image when framed, in points.
    public static let points: CGFloat = 24

    /// The output's footprint around a crop in image pixels. A frame may extend past the image because its padding is synthetic.
    public static func rect(around crop: CGRect, scale: CGFloat, framed: Bool) -> CGRect {
        framed ? crop.insetBy(dx: -points * scale, dy: -points * scale) : crop
    }

    /// Renders the output image for a crop given in source-image pixels. Unframed output is transparent outside `cornerRadii`; framed
    /// output rounds its card with them, or by 10 pt when they are all square.
    public static func render(_ image: CGImage, crop: CGRect, scale: CGFloat, framed: Bool, cornerRadii: CornerRadii = .zero) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = crop.integral.intersection(extent)
        let frame = rect(around: crop, scale: scale, framed: framed).integral
        guard let source = image.cropping(to: framed ? crop : frame) else { throw CocoaError(.fileReadCorruptFile) }
        if !framed, !cornerRadii.isSquare {
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
        guard framed else { return source }

        let width = Int(frame.width), height = Int(frame.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        // CGContext has a bottom-left origin; the padding is symmetric so the image rect needs no flip.
        let target = CGRect(x: crop.minX - frame.minX, y: crop.minY - frame.minY, width: crop.width, height: crop.height)
        let radii = cornerRadii.isSquare ? CornerRadii(10 * scale) : cornerRadii
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale, color: CGColor(gray: 0, alpha: 0.28))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(radii.path(in: target))
        context.clip()
        context.draw(source, in: target)
        context.endTransparencyLayer()
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
