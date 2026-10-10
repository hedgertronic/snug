import CoreGraphics

/// Stage Manager's strip: each thumbnail is a tilted picture of a window inside a button frame that runs well past it toward the
/// screen's center.
public enum StageManager {
    /// Whether a lookup's frames (innermost first, the application last) belong to Stage Manager, the WindowManager process.
    public static func owns(_ frames: [AXFrame]) -> Bool {
        frames.last.map { $0.role == "AXApplication" && $0.title == "WindowManager" } ?? false
    }

    /// Stage Manager's candidates (thumbnail buttons, once `hoverLevel` has dropped the strip's list) narrowed to their visible
    /// thumbnails in the frozen `image` (`scale` pixels per point); anything else unchanged.
    public static func visibleThumbnails(_ candidates: [Candidate], frames: [AXFrame], in image: CGImage, scale: CGFloat) -> [Candidate] {
        guard owns(frames) else { return candidates }
        return candidates.map {
            Candidate(id: $0.id, label: $0.label, bounds: thumbnail(in: image, button: $0.bounds, scale: scale), score: $0.score, kind: $0.kind)
        }
    }

    /// The visible thumbnail in `button` (image pixels, top-left origin). The thumbnail's side toward the screen's center is a straight
    /// vertical edge: a column whose pixels differ from their neighbors 2 px apart by more than 13 on some channel on 40% of the rows.
    /// Scanning from the center side, it is the first such column with the picture's detail past it: a column within 16 pt beyond it
    /// with that on 15% of the rows. The edge of the window on stage, which the frame can reach, has only wallpaper past it, and the
    /// wallpaper's bright streaks cross a column on a few rows. The other sides stay: the tilt slants the top and bottom, and the far
    /// side runs to the frame under the app icon. The button as is when no column qualifies.
    public static func thumbnail(in image: CGImage, button: CGRect, scale: CGFloat) -> CGRect {
        let bounds = button.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounds.isNull, bounds.width >= 3 else { return button }
        let (width, height) = (Int(bounds.width), Int(bounds.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(image.cropping(to: bounds)!, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func isEdge(_ x: Int, _ y: Int) -> Bool {
            let (left, right) = ((y * width + x - 1) * 4, (y * width + x + 1) * 4)
            return (0..<3).contains { abs(Int(pixels[left + $0]) - Int(pixels[right + $0])) > 13 }
        }
        // The strip sits at the screen's edge, so the side toward the center faces away from the nearer screen edge.
        let towardLeft = bounds.midX > CGFloat(image.width) / 2
        let edges = (0..<width).map { x in (1..<width - 1).contains(x) ? (0..<height).count { isEdge(x, $0) } : 0 }
        let (step, reach) = (towardLeft ? 1 : -1, Int(16 * scale))
        // Past the edge's own 2 px blend.
        func detailBeyond(_ x: Int) -> Bool {
            stride(from: x + 3 * step, through: x + reach * step, by: step).contains { edges.indices.contains($0) && edges[$0] * 20 >= height * 3 }
        }
        guard let edge = (towardLeft ? Array(edges.indices) : edges.indices.reversed()).first(where: { edges[$0] * 5 >= height * 2 && detailBeyond($0) }) else {
            return button
        }
        return towardLeft ? CGRect(x: bounds.minX + CGFloat(edge), y: bounds.minY, width: CGFloat(width - edge), height: bounds.height)
            : CGRect(x: bounds.minX, y: bounds.minY, width: CGFloat(edge + 1), height: bounds.height)
    }
}
