import CoreGraphics

/// One of the eight resize handles on a selection rectangle.
public enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// The handle's position on a rectangle.
    public func position(on rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
    }
}

/// A rectangle being drawn by dragging, in source-image pixels with a top-left origin.
public struct AreaDrag: Sendable {
    public let extent: CGRect
    public private(set) var origin: CGPoint
    public private(set) var current: CGPoint
    /// Where `current` was when the rectangle started moving, for locking the move to one axis.
    private var moveStart: CGPoint?

    /// Starts a drag at a point inside the extent.
    public init(extent: CGRect, origin: CGPoint) {
        self.extent = extent
        self.origin = origin
        self.current = origin
    }

    /// The dragged rectangle, clamped to the extent.
    public var rect: CGRect {
        CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
               width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    /// Follows the pointer. While `moving`, the whole rectangle translates instead of resizing, along only the axis with the larger
    /// travel since the move began when `axisLocked`. A resize with a `ratio` keeps it, portrait when the drag is taller than wide.
    public mutating func update(to point: CGPoint, moving: Bool, axisLocked: Bool = false, ratio: RatioLock? = nil) {
        let clamped = CGPoint(x: min(max(point.x, extent.minX), extent.maxX),
                              y: min(max(point.y, extent.minY), extent.maxY))
        guard moving else {
            moveStart = nil
            guard let ratio else { current = clamped; return }
            let dx = clamped.x - origin.x, dy = clamped.y - origin.y
            let r = ratio.ratio(portrait: abs(dy) > abs(dx))
            let sx: CGFloat = dx >= 0 ? 1 : -1, sy: CGFloat = dy >= 0 ? 1 : -1
            let availableWidth = sx > 0 ? extent.maxX - origin.x : origin.x - extent.minX
            let availableHeight = sy > 0 ? extent.maxY - origin.y : origin.y - extent.minY
            let width = min(max(abs(dx), abs(dy) * r), availableWidth, availableHeight * r)
            current = CGPoint(x: origin.x + sx * width, y: origin.y + sy * width / r)
            return
        }
        let start = moveStart ?? current
        moveStart = start
        var target = point
        if axisLocked {
            if abs(point.x - start.x) >= abs(point.y - start.y) { target.y = start.y } else { target.x = start.x }
        }
        let r = rect
        let dx = min(max(target.x - current.x, extent.minX - r.minX), extent.maxX - r.maxX)
        let dy = min(max(target.y - current.y, extent.minY - r.minY), extent.maxY - r.maxY)
        origin.x += dx; origin.y += dy
        current.x += dx; current.y += dy
    }
}

/// An editable area selection with a Tab-cycled list of fits.
public struct AreaSelection: Sendable {
    /// Smallest width or height a resize can produce.
    public static let minimumSize: CGFloat = 8

    public let extent: CGRect
    public private(set) var rect: CGRect
    /// Snap suggestions followed by the exact drag; Tab cycles through them.
    public private(set) var fits: [CGRect]
    public private(set) var fitIndex: Int
    /// A resize, move, or nudge replaced the drag and its fits.
    public private(set) var isEdited = false

    /// Creates a selection from the user's drag, optionally taking the first suggestion.
    public init(extent: CGRect, exact: CGRect, suggestions: [CGRect] = [], takingFirst: Bool = false) {
        self.extent = extent
        fits = suggestions + [exact]
        fitIndex = takingFirst && !suggestions.isEmpty ? 0 : suggestions.count
        rect = fits[fitIndex]
    }

    /// The rectangle the user drew before any suggestion was applied.
    public var exact: CGRect { fits[fits.count - 1] }

    /// Adds suggestions computed after release, keeping the current rectangle selected.
    public mutating func setSuggestions(_ suggestions: [CGRect]) {
        guard fits.count == 1 else { return }
        fits = suggestions + [rect]
        fitIndex = suggestions.count
    }

    /// Selects the exact drag.
    public mutating func selectExact() {
        fitIndex = fits.count - 1
        rect = fits[fitIndex]
    }

    /// Selects the best fit: the first suggestion, or the exact drag when there are none.
    public mutating func selectBest() {
        fitIndex = 0
        rect = fits[0]
    }

    /// Selects the next or previous fit, wrapping around.
    public mutating func cycle(backward: Bool = false) {
        fitIndex = (fitIndex + (backward ? -1 : 1) + fits.count) % fits.count
        rect = fits[fitIndex]
    }

    /// The handle within `tolerance` of the point, nearest first. Away from every handle, a point near a side controls that side.
    public func handle(at point: CGPoint, tolerance: CGFloat) -> Handle? {
        let corner = Handle.allCases
            .map { (handle: $0, distance: hypot($0.position(on: rect).x - point.x, $0.position(on: rect).y - point.y)) }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }?.handle
        if let corner { return corner }
        let alongX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let alongY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let sides: [(handle: Handle, distance: CGFloat)] = [
            (.left, alongY ? abs(point.x - rect.minX) : .infinity), (.right, alongY ? abs(point.x - rect.maxX) : .infinity),
            (.top, alongX ? abs(point.y - rect.minY) : .infinity), (.bottom, alongX ? abs(point.y - rect.maxY) : .infinity)
        ]
        return sides.filter { $0.distance <= tolerance }.min { $0.distance < $1.distance }?.handle
    }

    /// Moves the edges a handle controls to the point, keeping the minimum size inside the extent.
    /// With a `ratio` (width over height) the opposite corner or side holds still and the rectangle keeps that aspect ratio:
    /// a corner follows the pointer's larger travel, a side sets one dimension and the other grows about the rectangle's center.
    public mutating func resize(_ handle: Handle, to point: CGPoint, ratio: CGFloat? = nil) {
        let x = min(max(point.x, extent.minX), extent.maxX)
        let y = min(max(point.y, extent.minY), extent.maxY)
        if let ratio {
            let sx: CGFloat = handle.movesRight ? 1 : -1, sy: CGFloat = handle.movesBottom ? 1 : -1
            let minimumWidth = max(Self.minimumSize, Self.minimumSize * ratio)
            if (handle.movesLeft || handle.movesRight) && (handle.movesTop || handle.movesBottom) {
                let anchor = CGPoint(x: handle.movesLeft ? rect.maxX : rect.minX, y: handle.movesTop ? rect.maxY : rect.minY)
                let availableWidth = sx > 0 ? extent.maxX - anchor.x : anchor.x - extent.minX
                let availableHeight = sy > 0 ? extent.maxY - anchor.y : anchor.y - extent.minY
                let wanted = max(max((x - anchor.x) * sx, 0), max((y - anchor.y) * sy, 0) * ratio, minimumWidth)
                let width = min(wanted, availableWidth, availableHeight * ratio)
                let height = width / ratio
                edit(CGRect(x: sx > 0 ? anchor.x : anchor.x - width, y: sy > 0 ? anchor.y : anchor.y - height, width: width, height: height))
            } else if handle.movesLeft || handle.movesRight {
                let available = sx > 0 ? extent.maxX - rect.minX : rect.maxX - extent.minX
                let width = min(max(sx > 0 ? x - rect.minX : rect.maxX - x, minimumWidth), available, extent.height * ratio)
                let height = width / ratio
                edit(CGRect(x: sx > 0 ? rect.minX : rect.maxX - width, y: min(max(rect.midY - height / 2, extent.minY), extent.maxY - height),
                            width: width, height: height))
            } else {
                let available = sy > 0 ? extent.maxY - rect.minY : rect.maxY - extent.minY
                let height = min(max(sy > 0 ? y - rect.minY : rect.maxY - y, minimumWidth / ratio), available, extent.width / ratio)
                let width = height * ratio
                edit(CGRect(x: min(max(rect.midX - width / 2, extent.minX), extent.maxX - width), y: sy > 0 ? rect.minY : rect.maxY - height,
                            width: width, height: height))
            }
            return
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(x, maxX - Self.minimumSize) }
        if handle.movesRight { maxX = max(x, minX + Self.minimumSize) }
        if handle.movesTop { minY = min(y, maxY - Self.minimumSize) }
        if handle.movesBottom { maxY = max(y, minY + Self.minimumSize) }
        edit(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// Translates the rectangle, stopping at the extent edges. Also used for arrow-key nudges.
    public mutating func move(by delta: CGPoint) {
        let dx = min(max(delta.x, extent.minX - rect.minX), extent.maxX - rect.maxX)
        let dy = min(max(delta.y, extent.minY - rect.minY), extent.maxY - rect.maxY)
        edit(rect.offsetBy(dx: dx, dy: dy))
    }

    private mutating func edit(_ edited: CGRect) {
        rect = edited
        fits = [edited]
        fitIndex = 0
        isEdited = true
    }

    /// Whether a snap preview still lies within the search band of a new drag, so it can stay visible.
    ///
    /// The band is `SmartSnap.band` at the capture's `scale`.
    public static func preview(_ preview: CGRect, stillFits drag: CGRect, scale: CGFloat) -> Bool {
        let bandX = CGFloat(SmartSnap.band(side: drag.width, scale: scale))
        let bandY = CGFloat(SmartSnap.band(side: drag.height, scale: scale))
        return abs(preview.minX - drag.minX) <= bandX && abs(preview.maxX - drag.maxX) <= bandX
            && abs(preview.minY - drag.minY) <= bandY && abs(preview.maxY - drag.maxY) <= bandY
    }
}
