import CoreGraphics
import Foundation
import zlib

/// What an agent handoff (Copy for Agent) records about its capture, schema version 3: the image, where it sat on screen, the app and
/// window it came from, and what the target is. Every field is observed; an unknown one is nil and left out of the JSON. Version 3 attaches
/// the Accessibility element containing (or under the center of) a crop that no element's frame matches, so a target's role no longer
/// implies its frame is the crop: `provenance` `accessibility` says it is, and `target.frame` gives the element's frame either way.
public struct HandoffManifest: Codable, Sendable, Equatable {
    public var schemaVersion = 3
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
        public var displayName: String?
        /// The display's frame in global points.
        public var displayFrame: Rect

        public init(cropPixels: CGRect, scale: CGFloat, displayId: UInt32?, displayName: String? = nil, displayFrame: CGRect) {
            let points = CGRect(x: cropPixels.minX / scale, y: cropPixels.minY / scale, width: cropPixels.width / scale, height: cropPixels.height / scale)
            self.cropPixels = Rect(cropPixels)
            cropPoints = Rect(points)
            cropGlobal = Rect(points.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY))
            (self.displayId, self.displayName) = (displayId, displayName)
            self.displayFrame = Rect(displayFrame)
        }
    }

    /// The app and window under the target. A window id names a window only while it is open. The document, page URL and page title are
    /// read through Accessibility from the window holding the crop's center: its `AXDocument` (the open file's URL) and its innermost web
    /// area's `AXURL` and `AXTitle`. The window title and page title are cut to `maxString` characters, the document and URL to `maxURL`.
    public struct Source: Codable, Sendable, Equatable {
        public var app: String?
        public var bundleId: String?
        public var bundlePath: String?
        /// `CFBundleShortVersionString`.
        public var appVersion: String?
        public var pid: Int32?
        public var windowId: UInt32?
        public var windowTitle: String?
        /// Global points.
        public var windowFrame: Rect?
        public var document: String?
        public var url: String?
        public var pageTitle: String?

        public init(app: String?, bundleId: String?, bundlePath: String? = nil, appVersion: String? = nil, pid: Int32?, windowId: UInt32?,
                    windowTitle: String?, windowFrame: CGRect?, document: String? = nil, url: String? = nil, pageTitle: String? = nil) {
            (self.app, self.bundleId, self.bundlePath, self.appVersion, self.pid, self.windowId) = (app, bundleId, bundlePath, appVersion, pid, windowId)
            (self.windowTitle, self.windowFrame) = (cut(windowTitle, maxString), windowFrame.map(Rect.init))
            (self.document, self.url, self.pageTitle) = (cut(document, maxURL), cut(url, maxURL), cut(pageTitle, maxString))
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

    /// `text` cut to `limit` characters, ending in "..."; nil when it is empty.
    static func cut(_ text: String?, _ limit: Int) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0.count > limit ? $0.prefix(limit - 3) + "..." : $0 }
    }

    /// The most children, and siblings, a target lists; the most classes an element lists; the most steps its selector takes.
    public static let maxNeighbors = 10, maxClasses = 4, maxSelectorSteps = 8
    /// The longest value kept for a text element (`AXStaticText`, `AXTextField`, `AXTextArea`, `AXComboBox`) and for any other; the
    /// longest other string of the target (title, help, placeholder, label...); the longest string of an ancestor or neighbor, and class.
    /// Longer ones are cut, ending in "...". With every list full and every string at its limit the JSON stays under 32 KB in ASCII.
    public static let maxTextValue = 3072, maxValue = 200, maxString = 120, maxName = 40, maxClass = 32, maxURL = 512

    /// What a Copy for Agent read adds to an element's frame, as read (the manifest cuts it): for the target, its value (none for a secure
    /// text field), help, placeholder, the title of its label element (`AXTitleUIElement`), its link (`AXURL`), its state, and its first
    /// children and nearest siblings; for any element inside a web area, its DOM id and classes.
    public struct Details: Sendable, Equatable {
        public var value, help, placeholder, labeledBy, url, domId: String?
        public var domClasses: [String]?
        public var enabled, focused, selected: Bool?
        public var children, siblings: [Neighbor]?

        public init(value: String? = nil, help: String? = nil, placeholder: String? = nil, labeledBy: String? = nil, url: String? = nil, domId: String? = nil,
                    domClasses: [String]? = nil, enabled: Bool? = nil, focused: Bool? = nil, selected: Bool? = nil, children: [Neighbor]? = nil, siblings: [Neighbor]? = nil) {
            (self.value, self.help, self.placeholder, self.labeledBy, self.url, self.domId) = (value, help, placeholder, labeledBy, url, domId)
            (self.domClasses, self.enabled, self.focused, self.selected, self.children, self.siblings) = (domClasses, enabled, focused, selected, children, siblings)
        }
    }

    /// A child or sibling of the target: its role and name (its title, else its description, else its text value).
    public struct Neighbor: Codable, Sendable, Equatable {
        public var role: String?
        public var name: String?

        public init(role: String?, name: String?) {
            (self.role, self.name) = (role, name)
        }
    }

    /// One enclosing Accessibility element, its frame in global points; inside a web area, with its DOM id and classes.
    public struct Ancestor: Codable, Sendable, Equatable {
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var title: String?
        public var identifier: String?
        public var description: String?
        public var domId: String?
        public var domClasses: [String]?
        public var frame: Rect
    }

    /// What was captured. The Accessibility fields come from one element; its value is cut to `maxTextValue` or `maxValue`.
    public struct Target: Codable, Sendable, Equatable {
        public var kind: Kind
        public var label: String
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var title: String?
        public var identifier: String?
        public var description: String?
        public var value: String?
        public var help: String?
        public var placeholder: String?
        public var labeledBy: String?
        public var url: String?
        public var enabled: Bool?
        public var focused: Bool?
        public var selected: Bool?
        public var domId: String?
        public var domClasses: [String]?
        /// Inside a web area, a CSS-like path from below the innermost web area down to the element, each step its role description
        /// (spaces as "-"), `#id` and `.class`es, at most `maxSelectorSteps` steps (the outer ones dropped for "... > "). Class
        /// names are as the page wrote them, unescaped, for searching the source.
        public var selector: String?
        /// The element's frame in global points.
        public var frame: Rect?
        public var children: [Neighbor]?
        public var siblings: [Neighbor]?
        /// Innermost first.
        public var ancestors: [Ancestor]?
        public var provenance: Provenance
        /// When the Accessibility data was read.
        public var observedAt: Date?

        /// The index in `frames` (innermost first, global points) of the element a target for `crop` describes, and whether its frame is
        /// the crop: the innermost whose frame, clipped to its scroll viewports (as hover candidates are) and to `display`, is within
        /// `tolerance` points of `crop` on every side; else the innermost whose clipped frame holds `crop` (give or take `tolerance`);
        /// else the innermost, the element under the crop's center. Nil without frames.
        public static func match(_ frames: [AXFrame], crop: CGRect, display: CGRect, tolerance: CGFloat) -> (index: Int, isCrop: Bool)? {
            // Outermost first, so each viewport is already clipped to its own.
            var visible = frames.map { $0.rect.intersection(display) }
            for index in frames.indices.reversed() {
                if let viewport = frames.indices.dropFirst(index + 1).first(where: { ["AXScrollArea", "AXWebArea"].contains(frames[$0].role) }) {
                    visible[index] = visible[index].intersection(visible[viewport])
                }
            }
            if let index = visible.firstIndex(where: { $0.isNear(crop, within: tolerance) }) { return (index, true) }
            if let index = visible.firstIndex(where: { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(crop) }) { return (index, false) }
            return frames.isEmpty ? nil : (0, false)
        }

        /// A target with the Accessibility fields of the element `match` picks from `frames` and the frames after it, unclipped, as its
        /// ancestors. When that element's frame is the crop, its provenance is `accessibility`; otherwise it keeps `provenance`, and
        /// `frame` shows how the element sits around the crop. Without frames it has no Accessibility fields.
        public init(kind: Kind, label: String, provenance: Provenance, frames: [AXFrame], observedAt: Date?, crop: CGRect, display: CGRect,
                    tolerance: CGFloat = 4) {
            (self.kind, self.label, self.provenance) = (kind, label, provenance)
            guard let (index, isCrop) = Self.match(frames, crop: crop, display: display, tolerance: tolerance) else { return }
            let element = frames[index]
            let details = element.details ?? Details()
            let classes = { (frame: AXFrame) in frame.details?.domClasses.flatMap { $0.isEmpty ? nil : $0.prefix(maxClasses).compactMap { cut($0, maxClass) } } }
            let neighbors = { (list: [Neighbor]?) in list.flatMap { $0.isEmpty ? nil : $0.prefix(maxNeighbors).map { Neighbor(role: cut($0.role, maxName), name: cut($0.name, maxName)) } } }
            role = cut(element.role, maxString)
            subrole = cut(element.subrole, maxString)
            roleDescription = cut(element.roleDescription, maxString)
            title = cut(element.title, maxString)
            identifier = cut(element.identifier, maxString)
            description = cut(element.elementDescription, maxString)
            value = cut(details.value, ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) ? maxTextValue : maxValue)
            (help, placeholder, labeledBy, url) = (cut(details.help, maxString), cut(details.placeholder, maxString), cut(details.labeledBy, maxString), cut(details.url, maxString))
            (enabled, focused, selected) = (details.enabled, details.focused, details.selected)
            domId = cut(details.domId, maxString)
            domClasses = classes(element)
            (children, siblings) = (neighbors(details.children), neighbors(details.siblings))
            if let web = frames[index...].firstIndex(where: { $0.role == "AXWebArea" }), web > index {
                let steps = frames[index..<web].reversed().map { frame in
                    (cut(frame.roleDescription, maxName) ?? cut(String(frame.role.dropFirst(2)), maxName) ?? "").lowercased().replacingOccurrences(of: " ", with: "-")
                        + (cut(frame.details?.domId, maxName).map { "#" + $0 } ?? "") + (classes(frame) ?? []).map { "." + $0 }.joined()
                }
                selector = (steps.count > maxSelectorSteps ? "... > " : "") + steps.suffix(maxSelectorSteps).joined(separator: " > ")
            }
            frame = Rect(element.rect)
            ancestors = frames[(index + 1)...].map {
                Ancestor(role: cut($0.role, maxName), subrole: cut($0.subrole, maxName), roleDescription: cut($0.roleDescription, maxName),
                         title: cut($0.title, maxName), identifier: cut($0.identifier, maxName), description: cut($0.elementDescription, maxName),
                         domId: cut($0.details?.domId, maxName), domClasses: classes($0), frame: Rect($0.rect))
            }
            if isCrop { self.provenance = .accessibility }
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
        // The Accessibility role and title name the crop only when the element's frame is the crop.
        let matched = target.provenance == .accessibility
        let title = (matched ? target.title : nil) ?? (target.kind == .window ? source?.windowTitle : nil)
        let what = ascii(((matched ? target.roleDescription : nil) ?? target.label).lowercased()) + (title.map { " \"\(ascii($0))\"" } ?? "")
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

    /// Writes the bundle into a temporary folder beside it, renames it into place, then removes every other bundle and partial folder, so
    /// a reader never finds the folder empty. Other files in the folder are left alone. The folders are the user's alone (0700) and the
    /// files readable by the user alone (0600), whatever the process's umask. A manifest with an id or image name `png(of:)` would refuse
    /// is not written.
    @discardableResult
    public func write(png: Data, manifest: HandoffManifest) throws -> URL {
        let files = FileManager.default
        guard Self.isValid(manifest) else { throw CocoaError(.fileWriteInvalidFileName) }
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let partial = root.appending(path: ".\(manifest.captureId).partial")
        try files.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, data) in [(manifest.image.file, png), ("manifest.json", try manifest.json())] {
            guard files.createFile(atPath: partial.appending(path: name).path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.appending(path: name).path])
            }
        }
        let bundle = root.appending(path: manifest.captureId)
        try files.moveItem(at: partial, to: bundle)
        for name in try files.contentsOfDirectory(atPath: root.path) where name != manifest.captureId && Self.isBundle(name) {
            try files.removeItem(at: root.appending(path: name))
        }
        return bundle
    }

    /// The manifest of the last capture, or nil when there is none. A manifest whose id is not its folder's name, or whose image is not a
    /// plain PNG name inside its folder, is damaged and throws.
    public func current() throws -> HandoffManifest? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: root.path).filter(HandoffManifest.isId).map { name in
            let manifest = try HandoffManifest(json: Data(contentsOf: root.appending(path: "\(name)/manifest.json")))
            guard manifest.captureId == name, Self.isValid(manifest) else { throw CocoaError(.fileReadCorruptFile) }
            return manifest
        }.max { $0.capturedAt < $1.capturedAt }
    }

    /// Whether the manifest names a well-formed capture id and a plain `.png` file name, so its paths stay inside its bundle folder.
    static func isValid(_ manifest: HandoffManifest) -> Bool {
        let file = manifest.image.file
        return HandoffManifest.isId(manifest.captureId) && file.hasSuffix(".png") && !file.hasPrefix(".") && !file.contains("/") && file.count <= 255
    }

    /// A bundle folder (named by a capture id) or the `.<id>.partial` folder a write builds it in.
    private static func isBundle(_ name: String) -> Bool {
        HandoffManifest.isId(name) || (name.hasPrefix(".") && name.hasSuffix(".partial") && HandoffManifest.isId(String(name.dropFirst().dropLast(8))))
    }

    /// The bundle's PNG; a manifest that names another folder or file (`isValid`) throws.
    public func png(of manifest: HandoffManifest) throws -> Data {
        guard Self.isValid(manifest) else { throw CocoaError(.fileReadInvalidFileName) }
        return try Data(contentsOf: root.appending(path: manifest.captureId).appending(path: manifest.image.file))
    }

    /// Removes the bundle, and any folder a failed write left.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where Self.isBundle(name) {
            try FileManager.default.removeItem(at: root.appending(path: name))
        }
    }
}
