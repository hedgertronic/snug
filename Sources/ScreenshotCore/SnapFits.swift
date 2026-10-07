import CoreGraphics

/// Pure merging of accessibility frames with pixel snap results, in image pixels with a top-left origin.
public enum SnapFits {
    /// Fits for a drag: accessibility frames whose four sides all lie within the snap band of the drag's sides (the one
    /// with the smallest total offset first, at most three), then the pixel fits that do not repeat one of them.
    public static func merge(frames: [CGRect], pixel: [CGRect], drag: CGRect, scale: CGFloat) -> [CGRect] {
        let bandX = CGFloat(SmartSnap.band(side: drag.width, scale: scale))
        let bandY = CGFloat(SmartSnap.band(side: drag.height, scale: scale))
        func offset(_ r: CGRect) -> CGFloat {
            abs(r.minX - drag.minX) + abs(r.maxX - drag.maxX) + abs(r.minY - drag.minY) + abs(r.maxY - drag.maxY)
        }
        var fits: [CGRect] = []
        for frame in frames.sorted(by: { offset($0) < offset($1) })
        where abs(frame.minX - drag.minX) <= bandX && abs(frame.maxX - drag.maxX) <= bandX
            && abs(frame.minY - drag.minY) <= bandY && abs(frame.maxY - drag.maxY) <= bandY
            && !fits.contains(where: { snapOverlap($0, frame) > 0.94 }) {
            fits.append(frame)
            if fits.count == 3 { break }
        }
        return fits + pixel.filter { candidate in !fits.contains { snapOverlap($0, candidate) > 0.94 } }
    }

    /// The edge position nearest `value` and within `band` of it, from the sides of accessibility `frames` (preferred on
    /// a tie) and the scanned `pixel` edges. `vertical` selects x positions (left and right sides) over y positions.
    public static func edge(near value: CGFloat, band: CGFloat, frames: [CGRect], pixel: [CGFloat], vertical: Bool) -> CGFloat? {
        let sides = frames.flatMap { vertical ? [$0.minX, $0.maxX] : [$0.minY, $0.maxY] }
        return (sides + pixel).filter { abs($0 - value) <= band }.min { abs($0 - value) < abs($1 - value) }
    }
}
