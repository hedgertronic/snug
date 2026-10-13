import CoreGraphics

extension OutputFrame {
    /// macOS's window shadow in points, fitted to round 8's shadowed Finder window capture (a Gaussian of sigma 19.7 pt, which
    /// `CGContext` draws with a blur of 42 pt, 17.5 pt down, black at 70%). It fades out within 52 pt to the sides, 35 pt above and 70 pt
    /// below the shape that casts it.
    public static let windowShadow = (blur: 42.0, offset: 17.5, opacity: 0.7, sides: 52.0, top: 35.0, bottom: 70.0)

    /// The canvas the window shadow adds around a shape, in whole pixels at `scale`: on each side, above, and below.
    public static func shadowPadding(scale: CGFloat) -> (sides: Int, top: Int, bottom: Int) {
        (Int((windowShadow.sides * scale).rounded(.up)), Int((windowShadow.top * scale).rounded(.up)), Int((windowShadow.bottom * scale).rounded(.up)))
    }

    /// The cut-out output of `subject`, an image transparent outside the subject: trimmed to `bounds` (pixels, top-left origin) when
    /// given, else at full size with its corners masked by `cornerRadii`. Framed, it sits on the usual card, whose shadow follows the
    /// subject's alpha. Unframed with `shadow`, the window shadow follows the subject's alpha on a canvas grown to hold it.
    public static func renderCutout(_ subject: CGImage, bounds: CGRect?, cornerRadii: CornerRadii, framed: Bool, shadow: Bool, scale: CGFloat) throws -> CGImage {
        let image = bounds.map { subject.cropping(to: $0)! } ?? subject
        let shaped = try render(image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height), scale: scale, framed: framed,
                                cornerRadii: bounds == nil ? cornerRadii : .zero)
        guard shadow, !framed else { return shaped }
        let (sides, top, bottom) = shadowPadding(scale: scale)
        let context = CGContext(data: nil, width: image.width + 2 * sides, height: image.height + top + bottom, bitsPerComponent: 8, bytesPerRow: 0,
                                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShadow(offset: CGSize(width: 0, height: -windowShadow.offset * scale), blur: windowShadow.blur * scale,
                          color: CGColor(gray: 0, alpha: windowShadow.opacity))
        // CGContext has a bottom-left origin, so the bottom padding comes first.
        context.draw(shaped, in: CGRect(x: sides, y: bottom, width: image.width, height: image.height))
        return context.makeImage()!
    }
}
