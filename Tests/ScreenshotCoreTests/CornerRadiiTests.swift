import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotCore

struct CornerRadiiTests {
    /// An opaque 200 x 160 screen of blue wallpaper with a white window of rounded corners at (20, 20, 160 x 120), top-left origin.
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

    private func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    @Test func uniformRadiiAreEqualAndOnlyZeroIsSquare() {
        #expect(CornerRadii(12) == CornerRadii(topLeft: 12, topRight: 12, bottomLeft: 12, bottomRight: 12))
        #expect(CornerRadii(0).isSquare && CornerRadii.zero.isSquare)
        #expect(!CornerRadii(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 1).isSquare)
    }

    @Test func offsetChangesEveryCornerAndClampsToHalfTheShortSide() {
        let radii = CornerRadii(topLeft: 0, topRight: 2, bottomLeft: 10, bottomRight: 30)
        #expect(radii.offset(by: 4, in: CGSize(width: 100, height: 40)) == CornerRadii(topLeft: 4, topRight: 6, bottomLeft: 14, bottomRight: 20))
        #expect(radii.offset(by: -4, in: CGSize(width: 100, height: 40)) == CornerRadii(topLeft: 0, topRight: 0, bottomLeft: 6, bottomRight: 20))
        #expect(radii.scaled(by: 0.5) == CornerRadii(topLeft: 0, topRight: 1, bottomLeft: 5, bottomRight: 15))
    }

    @Test func cornersWithinTwoPixelsOfTheWindowsCornersTakeItsRadius() {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120)
        let bottomHalf = CGRect(x: 20, y: 60, width: 160, height: 80)
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: bottomHalf, with: 16)
                == CornerRadii(topLeft: 3, topRight: 3, bottomLeft: 16, bottomRight: 16))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 22, y: 18, width: 158, height: 122), with: 16)
                == CornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 40, y: 40, width: 100, height: 60), with: 16) == CornerRadii(3))
        #expect(CornerRadii(3).replacingCorners(sharedWith: window, in: CGRect(x: 20, y: 20, width: 80, height: 60), with: 16)
                == CornerRadii(topLeft: 16, topRight: 3, bottomLeft: 3, bottomRight: 3))
    }

    @Test func tightRenderRoundsOnlyTheBottomCornersOfACropOnAWindow() throws {
        let window = CGRect(x: 20, y: 20, width: 160, height: 120), crop = CGRect(x: 20, y: 60, width: 160, height: 80)
        let radii = CornerRadii(0).replacingCorners(sharedWith: window, in: crop, with: 16)
        let plain = try OutputStyle.tight.render(screen(radius: 16), crop: crop, scale: 1)
        #expect(alpha(plain, 0, 79) == 255 && alpha(plain, 159, 79) == 255) // opaque wallpaper before rounding
        let rounded = try OutputStyle.tight.render(screen(radius: 16), crop: crop, scale: 1, cornerRadii: radii)
        #expect((rounded.width, rounded.height) == (160, 80))
        #expect(alpha(rounded, 0, 79) == 0 && alpha(rounded, 159, 79) == 0)
        #expect(alpha(rounded, 0, 0) == 255 && alpha(rounded, 159, 0) == 255 && alpha(rounded, 80, 40) == 255 && alpha(rounded, 80, 79) == 255)
        // A point inside the bottom arc stays opaque: 8 px in from the corner along the diagonal is within the 16 px circle.
        #expect(alpha(rounded, 8, 71) == 255 && alpha(rounded, 151, 71) == 255)
    }

    @Test func eachCornerKeepsItsOwnRadius() throws {
        let radii = CornerRadii(topLeft: 0, topRight: 30, bottomLeft: 10, bottomRight: 0)
        let rounded = try OutputStyle.tight.render(screen(radius: 0), crop: CGRect(x: 0, y: 0, width: 200, height: 160), scale: 1, cornerRadii: radii)
        #expect(alpha(rounded, 0, 0) == 255 && alpha(rounded, 199, 159) == 255)
        #expect(alpha(rounded, 199, 0) == 0 && alpha(rounded, 0, 159) == 0)
        #expect(alpha(rounded, 190, 3) == 0 && alpha(rounded, 1, 150) == 255)
    }
}
