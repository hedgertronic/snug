import CoreGraphics

/// Which display a point (the pointer, in AppKit's global coordinates) is on.
public enum ScreenPick {
    /// The index in `frames` of the frame holding `point`: first the frame that contains it (`CGRect.contains`, max edges left out), so
    /// a point on an edge two displays share is on the one starting there; then a frame with the point on its max edge, as the pointer
    /// pushed against the top of the menu bar or the right edge of the rightmost display is. A point on no frame (in a gap between
    /// displays of different sizes) takes the nearest one. Nil only when there are no frames.
    public static func index(of point: CGPoint, in frames: [CGRect]) -> Int? {
        if let holding = frames.firstIndex(where: { $0.contains(point) }) { return holding }
        if let edge = frames.firstIndex(where: { $0.minX <= point.x && point.x <= $0.maxX && $0.minY <= point.y && point.y <= $0.maxY }) {
            return edge
        }
        return frames.indices.min { distance(point, frames[$0]) < distance(point, frames[$1]) }
    }

    private static func distance(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
    }
}
