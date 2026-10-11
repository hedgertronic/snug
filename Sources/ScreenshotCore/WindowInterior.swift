import CoreGraphics

/// A window capture whose window pixels are replaced by `interior`, the same window cut from the frozen display. ScreenCaptureKit renders
/// a single window without what is behind it, so a translucent or blurred background (iTerm's blur) comes back as the material's flat
/// gray; the frozen display shows it as it looked. The window is every fully opaque pixel of `window`; the shadow and the antialiased
/// corners keep the capture's pixels, so the shape stays the capture's. `interior` is copied one pixel per pixel from the window's top-left.
/// Nil when the window's opaque bounding box is more than 2 px off `interior`'s size on either axis (a capture still shrunk with its
/// shadow, a window partly off the display, or one resized since the freeze).
public func fillingWindowInterior(_ window: CGImage, from interior: CGImage) -> CGImage? {
    let width = window.width, height = window.height, bytesPerRow = width * 4
    let space = window.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo)!
    context.draw(window, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = context.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

    // Rows are top-down in memory.
    var (minX, minY, maxX, maxY) = (width, height, -1, -1)
    for y in 0..<height {
        for x in 0..<width where bytes[y * bytesPerRow + x * 4 + 3] == 255 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0, abs(maxX - minX + 1 - interior.width) <= 2, abs(maxY - minY + 1 - interior.height) <= 2 else { return nil }

    let behind = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo)!
    behind.draw(interior, in: CGRect(x: minX, y: height - minY - interior.height, width: interior.width, height: interior.height))
    let behindBytes = behind.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    for y in minY...maxY {
        for x in minX...maxX {
            let offset = y * bytesPerRow + x * 4
            guard bytes[offset + 3] == 255, behindBytes[offset + 3] == 255 else { continue }
            for channel in 0..<3 { bytes[offset + channel] = behindBytes[offset + channel] }
        }
    }
    return context.makeImage()!
}
