import Foundation
import CoreGraphics
import Testing
@testable import ScreenshotCore

struct WindowCornersTests {
    /// A white opaque window inside a `border` of translucent black shadow (alpha 100), premultiplied RGBA.
    private func capture(width: Int, height: Int, border: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let window = (border..<width - border).contains(x) && (border..<height - border).contains(y)
                let index = (y * width + x) * 4
                (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]) = window ? (255, 255, 255, 255) : (0, 0, 0, 100)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    @Test func squareCornersBecomeShadowAndTheRestStaysOpaque() {
        let rounded = roundingWindowCorners(capture(width: 100, height: 80, border: 10), radius: 12)
        #expect(alpha(rounded, 10, 10) == 100 && alpha(rounded, 89, 69) == 100)
        #expect(alpha(rounded, 22, 10) == 255 && alpha(rounded, 10, 22) == 255 && alpha(rounded, 50, 40) == 255)
        #expect(alpha(rounded, 5, 5) == 100)
    }

    @Test func withoutAShadowTheCornersBecomeTransparent() {
        let rounded = roundingWindowCorners(capture(width: 60, height: 50, border: 0), radius: 10)
        #expect(alpha(rounded, 0, 0) == 0 && alpha(rounded, 59, 49) == 0 && alpha(rounded, 30, 25) == 255)
    }

    /// An opaque 200 x 160 screen of blue wallpaper with a white window of rounded corners at (20, 20, 160 x 120).
    private func screen(radius: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 20, y: 20, width: 160, height: 120), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return context.makeImage()!
    }

    @Test func aCropReachingTheWindowBottomClearsOnlyThoseCorners() {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120), crop = CGRect(x: 20, y: 60, width: 160, height: 80)
        let image = screen(radius: 16).cropping(to: crop)!
        #expect(alpha(image, 0, 79) == 255 && alpha(image, 159, 79) == 255) // wallpaper-coloured, opaque before clearing
        let cleared = clearingWindowCorners(image, crop: crop, window: window, radius: 16)
        #expect(alpha(cleared, 0, 79) == 0 && alpha(cleared, 159, 79) == 0)
        #expect(alpha(cleared, 0, 0) == 255 && alpha(cleared, 159, 0) == 255 && alpha(cleared, 80, 40) == 255 && alpha(cleared, 80, 79) == 255)
    }

    @Test func aCropAwayFromTheWindowCornersIsUntouched() {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120), crop = CGRect(x: 40, y: 40, width: 100, height: 60)
        let image = screen(radius: 16).cropping(to: crop)!
        #expect(clearingWindowCorners(image, crop: crop, window: window, radius: 16) === image)
    }
}
