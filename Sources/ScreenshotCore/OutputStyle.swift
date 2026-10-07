import Foundation
import CoreGraphics

/// How a copied or saved area is framed.
public enum OutputStyle: String, CaseIterable, Sendable {
    case tight, margin, backdrop

    /// Surrounding screen kept by `margin`, in points.
    public static let marginPoints: CGFloat = 16
    /// Padding around the image in `backdrop`, in points.
    public static let backdropPoints: CGFloat = 24

    /// The next style, wrapping around.
    public var next: OutputStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The output's footprint around a crop in image pixels. `margin` is clamped to the extent;
    /// `backdrop` may extend past it because its padding is synthetic.
    public func frame(around crop: CGRect, in extent: CGRect, scale: CGFloat) -> CGRect {
        switch self {
        case .tight: crop
        case .margin: crop.insetBy(dx: -Self.marginPoints * scale, dy: -Self.marginPoints * scale).intersection(extent)
        case .backdrop: crop.insetBy(dx: -Self.backdropPoints * scale, dy: -Self.backdropPoints * scale)
        }
    }

    /// Renders the output image for a crop given in source-image pixels.
    public func render(_ image: CGImage, crop: CGRect, scale: CGFloat, cornerRadius: CGFloat = 0) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = crop.integral.intersection(extent)
        let frame = frame(around: crop, in: extent, scale: scale).integral
        guard let source = image.cropping(to: self == .backdrop ? crop : frame) else { throw CocoaError(.fileReadCorruptFile) }
        if self == .tight, cornerRadius > 0 {
            guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw CocoaError(.fileWriteUnknown) }
            context.setShouldAntialias(true)
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                                   cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.clip()
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            return output
        }
        guard self == .backdrop else { return source }

        let width = Int(frame.width), height = Int(frame.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.91, green: 0.89, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext has a bottom-left origin; the padding is symmetric so the image rect needs no flip.
        let target = CGRect(x: crop.minX - frame.minX, y: crop.minY - frame.minY, width: crop.width, height: crop.height)
        let radius = cornerRadius > 0 ? cornerRadius : 10 * scale
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0)
        context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(source, in: target)
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
