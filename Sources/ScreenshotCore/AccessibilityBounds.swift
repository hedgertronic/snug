import Foundation
import CoreGraphics

/// One accessibility element's frame in global screen points with a top-left origin, its role description, its AX role, and its title;
/// and its subrole, identifier and description ("" where the element has none).
public struct AXFrame: Sendable, Equatable {
    public let roleDescription: String
    public let rect: CGRect
    public let role: String
    public let title: String
    public let subrole: String
    public let identifier: String
    /// The element's `AXDescription`.
    public let elementDescription: String

    public init(roleDescription: String, rect: CGRect, role: String = "", title: String = "", subrole: String = "", identifier: String = "",
                elementDescription: String = "") {
        self.roleDescription = roleDescription
        self.rect = rect
        self.role = role
        self.title = title
        self.subrole = subrole
        self.identifier = identifier
        self.elementDescription = elementDescription
    }
}

extension AXFrame {
    /// The same element moved by `offset` points.
    public func translated(by offset: CGSize) -> AXFrame {
        AXFrame(roleDescription: roleDescription, rect: rect.offsetBy(dx: offset.width, dy: offset.height), role: role, title: title, subrole: subrole,
                identifier: identifier, elementDescription: elementDescription)
    }
}

/// Pure conversion and ranking for accessibility-derived candidates.
public enum AccessibilityBounds {
    /// Score of the innermost element; every accessibility candidate outranks pixel geometry (at most 0.99).
    public static let baseScore = 2.0

    /// An image pixel as a global accessibility point. `displayOrigin` is the display's top-left in the same space.
    public static func point(forPixel pixel: CGPoint, displayOrigin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: displayOrigin.x + pixel.x / scale, y: displayOrigin.y + pixel.y / scale)
    }

    /// The whole dock in image pixels: the union of the Dock's `AXList` frames (global points), each clipped to `extent`.
    /// Nil when no list has a finite frame at least 8 pixels square on the display.
    public static func dockRect(lists: [CGRect], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) -> CGRect? {
        let union = lists.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }.map {
            CGRect(x: ($0.minX - displayOrigin.x) * scale, y: ($0.minY - displayOrigin.y) * scale, width: $0.width * scale, height: $0.height * scale)
                .intersection(extent)
        }.filter { !$0.isNull && $0.width >= 8 && $0.height >= 8 }.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? nil : union.integral
    }

    /// A parent whose every side is within this many points of the kept inner frame is only padding, not a step.
    public static let paddingTolerance: CGFloat = 12

    /// The smallest side, in points, of an element a hover lands on.
    public static let minimumHoverSide: CGFloat = 16

    /// The frames a hover can land on: not the window (its rectangle comes from the window list, where a click captures it as a window),
    /// nor an element within `paddingTolerance` of the window's frame on every side (Finder's column view AXBrowser is
    /// 1 pt larger than its window on every side, measured on macOS 26), not static text, not Stage Manager's strip list (it would win in the gaps between thumbnails and around their
    /// tilted pictures), nothing under 16 pt on a side, and not an outline's section header (`sectionHeaderRow`): like static text,
    /// hovering one picks what holds it. Roles, not role descriptions: those are localized.
    public static func hoverLevel(_ frames: [AXFrame]) -> [AXFrame] {
        let stageManager = StageManager.owns(frames)
        let window = frames.first { $0.role == "AXWindow" }?.rect
        return frames.dropFirst(sectionHeaderRow(frames).map { $0 + 1 } ?? 0).filter { frame in
            frame.role != "AXWindow" && frame.role != "AXStaticText" && !(stageManager && frame.role == "AXList")
                && frame.rect.width >= minimumHoverSide && frame.rect.height >= minimumHoverSide
                && !(window.map { frame.rect.isNear($0, within: paddingTolerance) } ?? false)
        }
    }

    /// Where a chain read from Safari is displaced: every web frame from an `AXScrollArea` or `AXWebArea` down can be reported a screen
    /// height away from its window while its ancestors are right (user's log, 10-18: scroll area at (0, 1072, 1242, 837) in a window at
    /// (84, 44, 1242, 927), whose parent group has the window's frame; the same scroll area with the window moved to (111, 251), where it
    /// overlaps the window). `frames` is innermost first, ending at the window. The outermost frame its parent does not contain (within
    /// `paddingTolerance`) is the anchor; it is moved so its bottom and right edges meet its parent's (Safari's sidebar is on the left, so
    /// the page is flush right and bottom), and every frame inside it moves the same way. `through` is the anchor's index; `offset` is the
    /// move, set only when it puts the innermost frame around `point`. Otherwise `offset` is nil: a wrong outline is worse than none, so
    /// the caller drops the frames through `through`.
    /// Nil when the innermost frame contains `point`, when the chain has no window, or when every frame is inside its parent.
    public static func displacement(_ frames: [AXFrame], at point: CGPoint) -> (through: Int, offset: CGSize?)? {
        guard frames.last?.role == "AXWindow", let leaf = frames.first, !leaf.rect.contains(point) else { return nil }
        guard let anchor = frames.indices.dropLast().last(where: {
            !frames[$0 + 1].rect.insetBy(dx: -paddingTolerance, dy: -paddingTolerance).contains(frames[$0].rect)
        }) else { return nil }
        let (frame, parent) = (frames[anchor].rect, frames[anchor + 1].rect)
        let offset = CGSize(width: parent.maxX - frame.maxX, height: parent.maxY - frame.maxY)
        return (anchor, leaf.rect.offsetBy(dx: offset.width, dy: offset.height).contains(point) ? offset : nil)
    }

    /// The farthest below its window's top a sidebar's scroll area starts and still sits under the title bar.
    public static let titleBarDepth: CGFloat = 60

    /// `frames` (innermost first, window last) with a sidebar's full panel added above its scroll area, and `band`, the strip of the
    /// title bar above the scroll area that the panel adds. The sidebar is an `AXScrollArea` flush with the window's left or right side
    /// and its bottom (within `paddingTolerance`) whose top is below the window's top by at most `titleBarDepth`. Finder's glass sidebar
    /// is one: its scroll area (341, 214, 159 x 384) stops 52 pt below the top of its window (341, 162, 920 x 436), and no element covers
    /// the traffic-light band above it. The panel is the scroll area's frame run up to the window's top; the scroll area stays, so what it
    /// holds is still clipped to it. Found by frames alone. The caller adds the panel only when no other element of the window
    /// `occupies` the band. Nil when the chain has no such scroll area.
    public static func withSidebarPanel(_ frames: [AXFrame]) -> (frames: [AXFrame], band: CGRect)? {
        guard let window = frames.last, window.role == "AXWindow", let index = frames.firstIndex(where: { frame in
            let rect = frame.rect
            return frame.role == "AXScrollArea" && abs(rect.maxY - window.rect.maxY) <= paddingTolerance
                && (abs(rect.minX - window.rect.minX) <= paddingTolerance || abs(rect.maxX - window.rect.maxX) <= paddingTolerance)
                && rect.minY > window.rect.minY && rect.minY - window.rect.minY <= titleBarDepth
        }) else { return nil }
        let area = frames[index]
        let band = CGRect(x: area.rect.minX, y: window.rect.minY, width: area.rect.width, height: area.rect.minY - window.rect.minY)
        var withPanel = frames
        withPanel.insert(AXFrame(roleDescription: area.roleDescription, rect: band.union(area.rect), role: area.role, title: area.title, subrole: area.subrole,
                                 identifier: area.identifier, elementDescription: area.elementDescription), at: index + 1)
        return (withPanel, band)
    }

    /// Whether `frame`, an element of a window, lies in the title-bar `band` above a sidebar (`withSidebarPanel`): it overlaps the band by
    /// more than 1 pt each way (Finder's outline pokes 1 pt into it), it does not span the whole band (the toolbar and the split groups do,
    /// and what lies in the band is inside them), and it is not one of the window's own title-bar buttons.
    public static func occupies(_ frame: AXFrame, _ band: CGRect) -> Bool {
        let overlap = frame.rect.intersection(band)
        return !overlap.isNull && overlap.width > 1 && overlap.height > 1 && !frame.rect.contains(band)
            && !["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(frame.subrole)
    }

    /// The index in `frames` (innermost first) of the outline row when they start with a section header, such as "Favorites" in
    /// Finder's sidebar: an `AXStaticText` that fills its `AXOutlineRow`, each step out (its cell, then the row) within
    /// `paddingTolerance`. An item row holds an icon beside its text, so its text starts well inside the cell (35 pt in Finder). Nil otherwise.
    public static func sectionHeaderRow(_ frames: [AXFrame]) -> Int? {
        guard frames.first?.role == "AXStaticText" else { return nil }
        var level = 0
        while level + 1 < frames.count, frames[level + 1].rect.isNear(frames[level].rect, within: paddingTolerance) {
            level += 1
            if frames[level].subrole == "AXOutlineRow" { return level }
        }
        return nil
    }

    /// Whether hover looks up accessibility frames in a window: not in the frozen Dock (named "Dock" by the window listing), whose live
    /// frames are the magnified Dock. Its panel (the window's rectangle) and its icon tiles come from the frozen image instead.
    public static func looksUp(inWindowNamed name: String, frozen: Bool) -> Bool { !(frozen && name == "Dock") }

    /// Each frame clipped to the visible area of its nearest `AXScrollArea` or `AXWebArea` ancestor (itself clipped the same way);
    /// frames that end up empty are dropped. Order is kept.
    public static func clippedToViewports(_ frames: [AXFrame]) -> [AXFrame] {
        var clipped = frames
        for index in frames.indices.reversed() {
            if let viewport = frames[(index + 1)...].indices.first(where: { ["AXScrollArea", "AXWebArea"].contains(frames[$0].role) }) {
                let frame = frames[index]
                clipped[index] = AXFrame(roleDescription: frame.roleDescription, rect: frame.rect.intersection(clipped[viewport].rect), role: frame.role, title: frame.title,
                                         subrole: frame.subrole, identifier: frame.identifier, elementDescription: frame.elementDescription)
            }
        }
        return clipped.filter { !$0.rect.isNull && !$0.rect.isEmpty }
    }

    /// A frame (global points) in image pixels: the display's origin and scale applied, clipped to `extent`, to whole pixels.
    public static func pixels(of rect: CGRect, displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) -> CGRect {
        CGRect(x: (rect.minX - displayOrigin.x) * scale, y: (rect.minY - displayOrigin.y) * scale, width: rect.width * scale, height: rect.height * scale)
            .intersection(extent).integral
    }

    /// Candidates from `frames` (innermost element first, window last), in image pixels clipped to `extent` and to scroll viewports.
    /// The innermost element scores highest; repeated rectangles and padding-only parents keep only the innermost. A frame covering all of
    /// `extent` (Stage Manager's full-screen group) is the display, not an element.
    public static func candidates(frames: [AXFrame], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) async throws -> [Candidate] {
        var output: [Candidate] = []
        var inner: CGRect?
        for (index, frame) in clippedToViewports(frames.filter { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].allSatisfy(\.isFinite) }).enumerated() {
            let pixels = pixels(of: frame.rect, displayOrigin: displayOrigin, scale: scale, extent: extent)
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8, pixels != extent else { continue }
            let tolerance = paddingTolerance * scale
            if let inner, abs(pixels.minX - inner.minX) <= tolerance, abs(pixels.minY - inner.minY) <= tolerance,
               abs(pixels.maxX - inner.maxX) <= tolerance, abs(pixels.maxY - inner.maxY) <= tolerance { continue }
            inner = pixels
            // Named by its role description ("Text Field").
            let label = frame.roleDescription.isEmpty ? "Element" : frame.roleDescription.capitalized
            output.append(Candidate(id: "ax-\(Int(pixels.minX))-\(Int(pixels.minY))-\(Int(pixels.width))-\(Int(pixels.height))", label: label,
                                    bounds: pixels, score: baseScore - Double(index) * 0.01, kind: .element))
        }
        return output
    }

    /// The most siblings fetched around the hovered element.
    public static let maximumPeers = 64

    /// Where the hovered element's peers hang: the index in `frames` (innermost element first, window last) of the outermost element
    /// whose frame is only padding around the hovered one (the innermost `hoverLevel` frame), which is the one that has siblings.
    /// Finder's sidebar row is a 159 pt wide `AXRow` around a 139 pt `AXCell`: the cell is what hovers, and its parent row has the
    /// other rows as siblings. The run stops below the window. Over a section header, its row: the other rows are still its peers.
    /// Nil when nothing hovers.
    public static func peerLevel(_ frames: [AXFrame]) -> Int? {
        if let header = sectionHeaderRow(frames) { return header }
        guard let hovered = hoverLevel(frames).first, var level = frames.firstIndex(of: hovered) else { return nil }
        while level + 1 < frames.count, frames[level + 1].role != "AXWindow", frames[level + 1].rect.isNear(frames[level].rect, within: paddingTolerance) { level += 1 }
        return level
    }

    /// The candidates of the hovered element's peers. Each chain is one sibling's frames, innermost first, then the shared ancestors up to
    /// the window, so a sibling is converted, clipped to its scroll viewport and collapsed to its padding-free level (its cell, not its
    /// row) as the hovered element is, and the peers share its depth. Only the first candidate of each chain is kept. Section headers
    /// (`sectionHeaderRow`) are skipped, as Finder's own arrow keys skip them.
    public static func peerCandidates(_ chains: [[AXFrame]], displayOrigin: CGPoint, scale: CGFloat, extent: CGRect) async throws -> [Candidate] {
        var output: [Candidate] = []
        for chain in chains where sectionHeaderRow(chain) == nil {
            output += try await candidates(frames: hoverLevel(chain), displayOrigin: displayOrigin, scale: scale, extent: extent).prefix(1)
        }
        return output
    }
}
