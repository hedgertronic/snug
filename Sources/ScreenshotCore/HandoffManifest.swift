import CoreGraphics
import Foundation
import zlib

/// What an agent handoff (Copy for Agent) records about its capture, schema version 2: the image, where it sat on screen, the app and
/// window it came from, and what the target is. Every field is observed; an unknown one is nil and left out of the JSON.
public struct HandoffManifest: Codable, Sendable, Equatable {
    public var schemaVersion = 2
    /// 8 characters of Crockford base32.
    public var captureId: String
    /// When the pixels were frozen.
    public var capturedAt: Date
    public var image: Image
    public var geometry: Geometry
    public var source: Source?
    public var target: Target
    public var warnings: [Warning]

    public init(captureId: String, capturedAt: Date, image: Image, geometry: Geometry, source: Source?, target: Target, warnings: [Warning]) {
        self.captureId = captureId
        self.capturedAt = capturedAt
        self.image = image
        self.geometry = geometry
        self.source = source
        self.target = target
        self.warnings = warnings
    }

    /// A rectangle with a top-left origin.
    public struct Rect: Codable, Sendable, Equatable {
        public var x, y, width, height: Double

        public init(_ rect: CGRect) {
            (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height)
        }
    }

    /// The PNG: its file in the bundle, its size in pixels, and pixels per point.
    public struct Image: Codable, Sendable, Equatable {
        public var file = "capture.png"
        public var width: Int
        public var height: Int
        public var scale: Double

        public init(width: Int, height: Int, scale: Double) {
            (self.width, self.height, self.scale) = (width, height, scale)
        }
    }

    /// The crop in the display's pixels and points, and in global points: the primary display's top-left is the origin, as Accessibility
    /// uses. The image's pixel (x, y) is the global point (cropGlobal.x + x / scale, cropGlobal.y + y / scale).
    public struct Geometry: Codable, Sendable, Equatable {
        public var cropPixels: Rect
        public var cropPoints: Rect
        public var cropGlobal: Rect
        public var displayId: UInt32?
        /// The display's frame in global points.
        public var displayFrame: Rect

        public init(cropPixels: CGRect, scale: CGFloat, displayId: UInt32?, displayFrame: CGRect) {
            let points = CGRect(x: cropPixels.minX / scale, y: cropPixels.minY / scale, width: cropPixels.width / scale, height: cropPixels.height / scale)
            self.cropPixels = Rect(cropPixels)
            cropPoints = Rect(points)
            cropGlobal = Rect(points.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY))
            self.displayId = displayId
            self.displayFrame = Rect(displayFrame)
        }
    }

    /// The app and window under the target. A window id names a window only while it is open.
    public struct Source: Codable, Sendable, Equatable {
        public var app: String?
        public var bundleId: String?
        public var pid: Int32?
        public var windowId: UInt32?
        public var windowTitle: String?
        /// Global points.
        public var windowFrame: Rect?

        public init(app: String?, bundleId: String?, pid: Int32?, windowId: UInt32?, windowTitle: String?, windowFrame: CGRect?) {
            (self.app, self.bundleId, self.pid, self.windowId, self.windowTitle) = (app, bundleId, pid, windowId, windowTitle)
            self.windowFrame = windowFrame.map(Rect.init)
        }
    }

    public enum Kind: String, Codable, Sendable { case element, window, area, display, fill }
    public enum Provenance: String, Codable, Sendable { case accessibility, geometry, windowList = "window_list", userArea = "user_area" }
    public enum Warning: String, Codable, Sendable {
        /// No live Accessibility data: the permission is off, or the capture is an imported image.
        case accessibilityUnavailable = "accessibility_unavailable"
        /// The Accessibility data was read more than `staleAfter` after the pixels were frozen.
        case accessibilityStale = "accessibility_stale"
        /// No window list: the capture is an imported image.
        case sourceUnavailable = "source_unavailable"
    }

    /// Seconds between the frozen pixels and an Accessibility read past which the read is marked stale.
    public static let staleAfter: TimeInterval = 5

    /// One enclosing Accessibility element, its frame in global points.
    public struct Ancestor: Codable, Sendable, Equatable {
        public var role: String?
        public var title: String?
        public var frame: Rect
    }

    /// What was captured. The Accessibility fields come from one element, never its value (a field's contents may be private).
    public struct Target: Codable, Sendable, Equatable {
        public var kind: Kind
        public var label: String
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var title: String?
        public var identifier: String?
        public var description: String?
        /// Innermost first.
        public var ancestors: [Ancestor]?
        public var provenance: Provenance
        /// When the Accessibility data was read.
        public var observedAt: Date?

        /// A target with the Accessibility fields of the innermost of `frames` (innermost first, global points) whose frame, clipped to
        /// its scroll viewports (as hover candidates are) and to `display`, is within `tolerance` points of `crop` on every side, and the
        /// frames after it, unclipped, as its ancestors; its provenance is then `accessibility`. Without such a frame it has no
        /// Accessibility fields and keeps `provenance`.
        public init(kind: Kind, label: String, provenance: Provenance, frames: [AXFrame], observedAt: Date?, crop: CGRect, display: CGRect,
                    tolerance: CGFloat = 4) {
            (self.kind, self.label, self.provenance) = (kind, label, provenance)
            // Outermost first, so each viewport is already clipped to its own.
            var visible = frames.map { $0.rect.intersection(display) }
            for index in frames.indices.reversed() {
                if let viewport = frames.indices.dropFirst(index + 1).first(where: { ["AXScrollArea", "AXWebArea"].contains(frames[$0].role) }) {
                    visible[index] = visible[index].intersection(visible[viewport])
                }
            }
            guard let index = visible.firstIndex(where: { $0.isNear(crop, within: tolerance) }) else { return }
            let element = frames[index]
            let known = { (value: String) in value.isEmpty ? nil : value }
            role = known(element.role)
            subrole = known(element.subrole)
            roleDescription = known(element.roleDescription)
            title = known(element.title)
            identifier = known(element.identifier)
            description = known(element.elementDescription)
            ancestors = frames[(index + 1)...].map { Ancestor(role: known($0.role), title: known($0.title), frame: Rect($0.rect)) }
            self.provenance = .accessibility
            self.observedAt = observedAt
        }
    }

    // MARK: JSON

    /// Pretty-printed JSON with snake_case keys, sorted, and ISO 8601 dates with milliseconds.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return try encoder.encode(self)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(decoder.singleValueContainer().decode(String.self))
        }
        self = try decoder.decode(Self.self, from: json)
    }

    // MARK: Id and reference

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A random capture id: 8 characters of Crockford base32.
    public static func newId() -> String { String((0..<8).map { _ in alphabet.randomElement()! }) }

    /// Whether `id` has the form of a capture id (uppercase).
    public static func isId(_ id: String) -> Bool { id.count == 8 && id.allSatisfy(alphabet.contains) }

    /// The clipboard's text, ASCII only: `[Snug capture K7F3Q2XM: Finder, row "Documents", 236 x 44 pt. Use the snug MCP tool get_capture
    /// to see it.]`. The app and title are screen text, so quotes and brackets in them become plain marks and each is cut to 40 characters.
    public var reference: String {
        func ascii(_ text: String) -> String {
            let latin = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? ""
            let plain = String(String.UnicodeScalarView(latin.unicodeScalars.map { $0 == "\"" ? "'" : $0 == "[" ? "(" : $0 == "]" ? ")" : $0 }
                .filter { (0x20...0x7E).contains($0.value) }))
            return plain.count > 40 ? plain.prefix(37) + "..." : plain
        }
        let title = target.title ?? (target.kind == .window ? source?.windowTitle : nil)
        let what = ascii((target.roleDescription ?? target.label).lowercased()) + (title.map { " \"\(ascii($0))\"" } ?? "")
        let size = "\(Int(geometry.cropPoints.width.rounded())) x \(Int(geometry.cropPoints.height.rounded())) pt"
        return "[Snug capture \(captureId): " + (source?.app.map { ascii($0) + ", " } ?? "") + "\(what), \(size). Use the snug MCP tool get_capture to see it.]"
    }

    // MARK: PNG text

    /// The PNG text keyword the manifest is stored under.
    public static let pngKeyword = "Snug.Manifest"

    /// `png` with `json` in an uncompressed iTXt chunk under `pngKeyword`, right after the header chunk. The image data is unchanged.
    public static func embedding(_ json: Data, in png: Data) -> Data {
        let bytes = [UInt8](png)
        precondition(bytes.count > 33 && bytes[12..<16].elementsEqual("IHDR".utf8), "not a PNG")
        // Keyword, null, compression flag and method (none), empty language tag and translated keyword, each null-terminated, then the text.
        let data = [UInt8](pngKeyword.utf8) + [0, 0, 0, 0, 0] + [UInt8](json)
        let type = [UInt8]("iTXt".utf8)
        let crc = (type + data).withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        let chunk = bigEndian(UInt32(data.count)) + type + data + bigEndian(crc)
        // The signature (8 bytes) and the header chunk (25) come first.
        return Data(bytes[..<33] + chunk + bytes[33...])
    }

    /// The text of the iTXt chunk under `pngKeyword` in `png`, if it has one.
    public static func embedded(in png: Data) -> Data? {
        let bytes = [UInt8](png)
        let keyword = [UInt8](pngKeyword.utf8) + [0]
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let data = bytes[(offset + 8)...].prefix(length)
            if bytes[offset + 4..<offset + 8].elementsEqual("iTXt".utf8), data.starts(with: keyword), data.dropFirst(keyword.count).first == 0 {
                // After the keyword: the compression flag and method, then the language tag and translated keyword, each null-terminated.
                var rest = data.dropFirst(keyword.count + 2)
                for _ in 0..<2 { rest = rest.drop { $0 != 0 }.dropFirst() }
                return Data(rest)
            }
            offset += 12 + length
        }
        return nil
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
}

/// The agent handoff bundle in one folder: the id of the last capture names a folder holding `capture.png` and `manifest.json`. Writing a
/// bundle replaces the previous one, like the clipboard.
public struct HandoffStore: Sendable {
    public let root: URL

    /// `~/Library/Application Support/Snug/Agent`.
    public static var defaultRoot: URL { URL.applicationSupportDirectory.appending(path: "Snug/Agent") }

    public init(root: URL) {
        self.root = root
    }

    /// Writes the bundle into a temporary folder beside it, renames it into place, then removes every other bundle, so a reader never
    /// finds the folder empty.
    @discardableResult
    public func write(png: Data, manifest: HandoffManifest) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appending(path: ".\(manifest.captureId).partial")
        try files.createDirectory(at: partial, withIntermediateDirectories: false)
        try png.write(to: partial.appending(path: manifest.image.file))
        try manifest.json().write(to: partial.appending(path: "manifest.json"))
        let bundle = root.appending(path: manifest.captureId)
        try files.moveItem(at: partial, to: bundle)
        for name in try files.contentsOfDirectory(atPath: root.path) where name != manifest.captureId {
            try files.removeItem(at: root.appending(path: name))
        }
        return bundle
    }

    /// The manifest of the last capture, or nil when there is none.
    public func current() throws -> HandoffManifest? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: root.path).filter(HandoffManifest.isId).map {
            try HandoffManifest(json: Data(contentsOf: root.appending(path: "\($0)/manifest.json")))
        }.max { $0.capturedAt < $1.capturedAt }
    }

    /// The bundle's PNG.
    public func png(of manifest: HandoffManifest) throws -> Data {
        try Data(contentsOf: root.appending(path: "\(manifest.captureId)/\(manifest.image.file)"))
    }

    /// Removes the bundle, and any folder a failed write left.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            try FileManager.default.removeItem(at: root.appending(path: name))
        }
    }
}
