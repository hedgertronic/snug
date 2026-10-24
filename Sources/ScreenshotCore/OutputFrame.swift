import Foundation
import CoreGraphics

/// How a copied or saved area is framed: tight (`padding` nil), or (Frame on) a card on `padding` points of transparent padding with a
/// soft shadow sized to fit inside it.
public enum OutputFrame {
    /// The output's footprint around a crop in image pixels. A frame may extend past the image because its padding is synthetic.
    public static func rect(around crop: CGRect, scale: CGFloat, padding: CGFloat?) -> CGRect {
        padding.map { crop.insetBy(dx: -$0 * scale, dy: -$0 * scale) } ?? crop
    }

    /// Renders the output image for a crop given in source-image pixels. Unframed output is transparent outside `cornerRadii`; framed
    /// output rounds its card with them, or by 10 pt when they are all square.
    public static func render(_ image: CGImage, crop: CGRect, scale: CGFloat, padding: CGFloat?, cornerRadii: CornerRadii = .zero) throws -> CGImage {
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
