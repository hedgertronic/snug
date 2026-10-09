import CoreGraphics

/// Rounds the corners of a window capture that came back square. The window is the opaque bounding box of `image`; any
/// transparent border around it is the window's shadow. Each corner outside a circle of `radius` pixels is replaced by the shadow
/// just past that corner (black at the alpha found diagonally outside it), or by transparency when there is no shadow.
public func roundingWindowCorners(_ image: CGImage, radius: CGFloat) -> CGImage {
    let width = image.width, height = image.height, bytesPerRow = width * 4
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = context.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

    // Rows are top-down in memory. The window is every fully opaque pixel; the shadow never reaches alpha 255.
    var (minX, minY, maxX, maxY) = (width, height, -1, -1)
    for y in 0..<height {
        for x in 0..<width where bytes[y * bytesPerRow + x * 4 + 3] == 255 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let r = Int(radius.rounded())
    guard maxX >= 0, r > 0, maxX - minX + 1 >= 2 * r, maxY - minY + 1 >= 2 * r else { return image }

    for (cornerX, cornerY, stepX, stepY) in [(minX, minY, 1, 1), (maxX, minY, -1, 1), (minX, maxY, 1, -1), (maxX, maxY, -1, -1)] {
        let outsideX = cornerX - stepX, outsideY = cornerY - stepY
        let shadow = (0..<width).contains(outsideX) && (0..<height).contains(outsideY)
            ? Double(bytes[outsideY * bytesPerRow + outsideX * 4 + 3]) : 0
        let center = (x: Double(cornerX + stepX * r) , y: Double(cornerY + stepY * r))
        for dy in 0..<r {
            for dx in 0..<r {
                let x = cornerX + stepX * dx, y = cornerY + stepY * dy
                let distance = ((Double(x) - center.x) * (Double(x) - center.x) + (Double(y) - center.y) * (Double(y) - center.y)).squareRoot()
                let coverage = min(1, max(0, Double(r) + 0.5 - distance))
                guard coverage < 1 else { continue }
                let offset = y * bytesPerRow + x * 4
                for channel in 0..<3 { bytes[offset + channel] = UInt8((Double(bytes[offset + channel]) * coverage).rounded()) }
                bytes[offset + 3] = UInt8((255 * coverage + shadow * (1 - coverage)).rounded())
            }
        }
    }
    return context.makeImage()!
}
