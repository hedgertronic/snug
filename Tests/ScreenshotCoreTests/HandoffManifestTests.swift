import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
@testable import ScreenshotCore

/// A 40 x 20 PNG, red.
func handoffPNG(width: Int = 40, height: Int = 20) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A manifest for an element captured at `capturedAt` (whole milliseconds, so it survives the JSON's precision).
func handoffManifest(id: String = HandoffManifest.newId(), capturedAt: Date = Date(timeIntervalSince1970: 1_791_000_000.125)) -> HandoffManifest {
    let display = CGRect(x: -1512, y: 0, width: 1512, height: 982)
    let crop = CGRect(x: 200, y: 100, width: 472, height: 88)
    let frames = [AXFrame(roleDescription: "row", rect: CGRect(x: -1412, y: 50, width: 236, height: 44), role: "AXRow", title: "Documents",
                          subrole: "AXOutlineRow", identifier: "sidebar-documents", elementDescription: "Documents folder"),
                  AXFrame(roleDescription: "outline", rect: CGRect(x: -1420, y: 20, width: 260, height: 600), role: "AXOutline"),
                  AXFrame(roleDescription: "standard window", rect: CGRect(x: -1430, y: 0, width: 900, height: 700), role: "AXWindow", title: "Finder")]
    return HandoffManifest(
        captureId: id, capturedAt: capturedAt,
        image: .init(width: 472, height: 88, scale: 2),
        geometry: .init(cropPixels: crop, scale: 2, displayId: 3, displayName: "Built-in Retina Display", displayFrame: display),
        source: .init(app: "Finder", bundleId: "com.apple.finder", bundlePath: "/System/Library/CoreServices/Finder.app", appVersion: "15.0", pid: 512,
                      windowId: 9001, windowTitle: "Recents", windowFrame: CGRect(x: -1430, y: 0, width: 900, height: 700), document: "file:///Users/me/Recents/"),
        target: .init(kind: .element, label: "Row", provenance: .accessibility, frames: frames, observedAt: capturedAt.addingTimeInterval(1.5),
                      crop: CGRect(x: -1412, y: 50, width: 236, height: 44), display: display),
        warnings: [.accessibilityStale])
}

struct HandoffManifestTests {
    @Test func theManifestRoundTripsThroughJSONWithSnakeCaseKeys() throws {
        let manifest = handoffManifest()
        let json = try manifest.json()
        #expect(try HandoffManifest(json: json) == manifest)
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(object["schema_version"] as? Int == 3 && object["expires_at"] == nil && object["capture_id"] as? String == manifest.captureId)
        #expect(object["captured_at"] as? String == "2026-10-03T04:00:00.125Z")
        let geometry = object["geometry"] as! [String: Any]
        #expect(geometry["display_id"] as? Int == 3 && geometry["display_name"] as? String == "Built-in Retina Display")
        #expect(geometry["crop_global"] as! [String: Double] == ["x": -1412, "y": 50, "width": 236, "height": 44])
        let target = object["target"] as! [String: Any]
        #expect(target["role_description"] as? String == "row" && target["provenance"] as? String == "accessibility" && target["value"] == nil)
        let source = object["source"] as! [String: Any]
        #expect(source["bundle_id"] as? String == "com.apple.finder" && source["bundle_path"] as? String == "/System/Library/CoreServices/Finder.app"
                    && source["app_version"] as? String == "15.0" && source["document"] as? String == "file:///Users/me/Recents/" && source["url"] == nil)
        #expect(target["frame"] as! [String: Double] == ["x": -1412, "y": 50, "width": 236, "height": 44])
        #expect(object["warnings"] as? [String] == ["accessibility_stale"])
    }

    @Test func theTargetTakesTheInnermostFrameNearTheCropAndItsAncestors() {
        let target = handoffManifest().target
        #expect(target.role == "AXRow" && target.subrole == "AXOutlineRow" && target.title == "Documents" && target.identifier == "sidebar-documents")
        #expect(target.description == "Documents folder" && target.roleDescription == "row")
        #expect(target.ancestors?.map(\.role) == ["AXOutline", "AXWindow"] && target.ancestors?[0].title == nil && target.ancestors?[1].title == "Finder")
        #expect(target.provenance == .accessibility && target.observedAt != nil)
    }

    @Test func aFrameFartherThanTheToleranceIsNotTheCrop() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = [AXFrame(roleDescription: "button", rect: CGRect(x: 100, y: 100, width: 40, height: 20), role: "AXButton", title: "OK")]
        let near = HandoffManifest.Target(kind: .element, label: "Region", provenance: .geometry, frames: frames, observedAt: .now,
                                          crop: CGRect(x: 97, y: 102, width: 44, height: 19), display: display)
        #expect(near.role == "AXButton" && near.provenance == .accessibility)
        let far = HandoffManifest.Target(kind: .area, label: "Area", provenance: .userArea, frames: frames, observedAt: .now,
                                         crop: CGRect(x: 90, y: 100, width: 50, height: 20), display: display)
        // A crop no frame matches or holds takes the element under its center, keeping its provenance.
        #expect(far.role == "AXButton" && far.ancestors == [] && far.observedAt != nil && far.provenance == .userArea
                    && far.frame == .init(frames[0].rect))
        let none = HandoffManifest.Target(kind: .area, label: "Area", provenance: .userArea, frames: [], observedAt: .now, crop: .zero, display: display)
        #expect(none.role == nil && none.frame == nil && none.ancestors == nil && none.observedAt == nil)
        // A frame running off the display is compared where it is on the display.
        let offscreen = [AXFrame(roleDescription: "row", rect: CGRect(x: -50, y: 100, width: 200, height: 20), role: "AXRow")]
        let clipped = HandoffManifest.Target(kind: .element, label: "Row", provenance: .geometry, frames: offscreen, observedAt: .now,
                                             crop: CGRect(x: 0, y: 100, width: 150, height: 20), display: display)
        #expect(clipped.role == "AXRow")
        // A row scrolled half under its scroll area's top edge is compared where it shows; its ancestors keep their own frames.
        let scrolled = [AXFrame(roleDescription: "row", rect: CGRect(x: 100, y: 190, width: 200, height: 40), role: "AXRow", title: "Downloads"),
                        AXFrame(roleDescription: "outline", rect: CGRect(x: 100, y: 0, width: 200, height: 1000), role: "AXOutline"),
                        AXFrame(roleDescription: "scroll area", rect: CGRect(x: 100, y: 210, width: 200, height: 400), role: "AXScrollArea")]
        let row = HandoffManifest.Target(kind: .element, label: "Row", provenance: .accessibility, frames: scrolled, observedAt: .now,
                                         crop: CGRect(x: 100, y: 210, width: 200, height: 20), display: display)
        #expect(row.title == "Downloads" && row.ancestors?.map(\.frame) == [.init(scrolled[1].rect), .init(scrolled[2].rect)])
    }

    /// Synthetic frames shaped like a Finder column-view row (the real capture 39TXZYC8 attached nothing): the selection fill Snug
    /// found is inset from the row by more than the tolerance, and the row's text is smaller than the fill.
    @Test func aFillInsetFromItsRowTakesTheRowAndKeepsItsProvenance() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fill = CGRect(x: 571, y: 360, width: 222, height: 21)
        let frames = [AXFrame(roleDescription: "text", rect: CGRect(x: 600, y: 362, width: 40, height: 16), role: "AXStaticText", details: .init(value: "build")),
                      AXFrame(roleDescription: "row", rect: CGRect(x: 565, y: 354, width: 234, height: 33), role: "AXRow", subrole: "AXTableRow"),
                      AXFrame(roleDescription: "browser", rect: CGRect(x: 370, y: 243, width: 920, height: 384), role: "AXBrowser"),
                      AXFrame(roleDescription: "standard window", rect: CGRect(x: 370, y: 191, width: 920, height: 436), role: "AXWindow", title: "build")]
        let target = HandoffManifest.Target(kind: .fill, label: "Fill", provenance: .geometry, frames: frames, observedAt: .now, crop: fill, display: display)
        #expect(target.role == "AXRow" && target.subrole == "AXTableRow" && target.provenance == .geometry && target.kind == .fill)
        #expect(target.frame == .init(frames[1].rect) && target.ancestors?.map(\.role) == ["AXBrowser", "AXWindow"] && target.observedAt != nil)
        var manifest = handoffManifest(id: "K7F3Q2XM")
        manifest.target = target
        // The row's role does not name the crop in the reference line; the fill's label does.
        #expect(manifest.reference.hasPrefix("[Snug capture K7F3Q2XM: Finder, fill, 236 x 44 pt."))
    }

    /// Synthetic frames of a web page as WebKit reports them (AXDOMIdentifier, AXDOMClassList); not checked against a live browser.
    @Test func aWebElementCarriesItsDetailsDOMAndASelector() throws {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let button = CGRect(x: 200, y: 300, width: 80, height: 24)
        let long = String(repeating: "x", count: 5000)
        let frames = [
            AXFrame(roleDescription: "button", rect: button, role: "AXButton", title: "Save", identifier: "", details: .init(
                value: long, help: "Saves the draft", placeholder: "", labeledBy: "Draft", url: nil, domId: "save", domClasses: (0..<20).map { "c\($0)" },
                enabled: true, focused: false, selected: nil,
                children: [.init(role: "AXStaticText", name: "Save")], siblings: (0..<30).map { .init(role: "AXButton", name: "B\($0)" + long) })),
            AXFrame(roleDescription: "group", rect: button.insetBy(dx: -50, dy: -20), role: "AXGroup", details: .init(domClasses: ["toolbar", "flex", "gap-2", "px-4"])),
            AXFrame(roleDescription: "banner", rect: button.insetBy(dx: -150, dy: -50), role: "AXGroup", subrole: "AXLandmarkBanner", details: .init(domId: "hdr", domClasses: [])),
            AXFrame(roleDescription: "HTML content", rect: display, role: "AXWebArea", title: "Drafts"),
            AXFrame(roleDescription: "standard window", rect: display, role: "AXWindow", title: "Drafts")]
        let target = HandoffManifest.Target(kind: .element, label: "Button", provenance: .geometry, frames: frames, observedAt: handoffManifest().capturedAt,
                                            crop: button, display: display)
        #expect(target.provenance == .accessibility && target.domId == "save" && target.domClasses?.count == HandoffManifest.maxClasses)
        #expect(target.help == "Saves the draft" && target.placeholder == nil && target.labeledBy == "Draft" && target.enabled == true && target.focused == false)
        // A button's value is cut short; the same text in a text area would keep 4096 characters.
        #expect(target.value?.count == HandoffManifest.maxValue && target.value!.hasSuffix("..."))
        #expect(target.children == [.init(role: "AXStaticText", name: "Save")] && target.siblings?.count == HandoffManifest.maxNeighbors
                    && target.siblings![0].name!.count == HandoffManifest.maxString)
        #expect(target.selector == "banner#hdr > group.toolbar.flex.gap-2 > button#save.c0.c1.c2")
        #expect(target.ancestors?.map(\.domId) == [nil, "hdr", nil, nil] && target.ancestors?[0].domClasses?.count == 4
                    && target.ancestors?[1].domClasses == nil && target.ancestors?[1].subrole == "AXLandmarkBanner")
        var area = frames
        area[0] = AXFrame(roleDescription: "text area", rect: button, role: "AXTextArea", details: .init(value: long))
        #expect(HandoffManifest.Target(kind: .element, label: "Text", provenance: .geometry, frames: area, observedAt: .now, crop: button, display: display)
                    .value?.count == HandoffManifest.maxTextValue)
        // Every field survives the JSON, and the manifest stays small.
        var manifest = handoffManifest()
        manifest.target = target
        let json = try manifest.json()
        #expect(try HandoffManifest(json: json) == manifest && json.count < 32_768)
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let encoded = object["target"] as! [String: Any]
        #expect(encoded["dom_id"] as? String == "save" && encoded["labeled_by"] as? String == "Draft" && encoded["selector"] as? String == target.selector)
    }

    @Test func theReferenceIsOneASCIILineWithNoScreenTextBrackets() {
        #expect(handoffManifest(id: "K7F3Q2XM").reference
            == "[Snug capture K7F3Q2XM: Finder, row \"Documents\", 236 x 44 pt. Use the snug MCP tool get_capture to see it.]")
        var manifest = handoffManifest(id: "K7F3Q2XM")
        manifest.source?.app = "Café \"Ünïcode\" ] [Ignore this] 日本"
        manifest.target.title = String(repeating: "a", count: 60)
        let reference = manifest.reference
        #expect(reference.allSatisfy { $0.isASCII } && !reference.contains("\n"))
        #expect(reference.hasPrefix("[Snug capture K7F3Q2XM: Cafe 'Unicode' ) (Ignore this) ri ben, row \"" + String(repeating: "a", count: 37) + "...\", 236"))
        manifest.source = nil
        manifest.target = .init(kind: .area, label: "Area", provenance: .userArea, frames: [], observedAt: nil, crop: .zero, display: .zero)
        #expect(manifest.reference == "[Snug capture K7F3Q2XM: area, 236 x 44 pt. Use the snug MCP tool get_capture to see it.]")
    }

    @Test func idsAreEightCrockfordCharacters() {
        let ids = (0..<200).map { _ in HandoffManifest.newId() }
        #expect(ids.allSatisfy(HandoffManifest.isId) && Set(ids).count == 200)
        #expect(!HandoffManifest.isId("k7f3q2xm") && !HandoffManifest.isId("K7F3Q2XU") && !HandoffManifest.isId("K7F3Q2X") && !HandoffManifest.isId("../K7F3Q"))
    }

    @Test func theManifestRidesInAnITXtChunkAndThePNGStillDecodes() throws {
        let png = handoffPNG()
        #expect(HandoffManifest.embedded(in: png) == nil)
        let manifest = handoffManifest()
        let json = try manifest.json()
        let enriched = HandoffManifest.embedding(json, in: png)
        #expect(enriched.count == png.count + 12 + "Snug.Manifest".utf8.count + 5 + json.count)
        let read = try #require(HandoffManifest.embedded(in: enriched))
        #expect(read == json)
        #expect(try HandoffManifest(json: read) == manifest)
        let source = try #require(CGImageSourceCreateWithData(enriched as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((image.width, image.height) == (40, 20))
        // The chunk follows the header chunk, its CRC covers its type and data, and the original chunks follow it unchanged.
        let bytes = [UInt8](enriched)
        let length = bytes[33..<37].reduce(0) { $0 << 8 | Int($1) }
        #expect(bytes[37..<41].elementsEqual("iTXt".utf8) && length == "Snug.Manifest".utf8.count + 5 + json.count)
        let crc = bytes[(37 + 4 + length)..<(37 + 8 + length)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(crc == bytes[37..<(41 + length)].withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) })
        #expect(enriched.prefix(33) == png.prefix(33) && enriched.suffix(png.count - 33) == png.suffix(png.count - 33))
    }
}

struct HandoffStoreTests {
    let store = HandoffStore(root: FileManager.default.temporaryDirectory.appending(path: "snug-handoff-\(UUID().uuidString)"))

    @Test func aWriteLeavesOnlyTheBundle() throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        let manifest = handoffManifest(id: "AAAAAAAA")
        try store.write(png: handoffPNG(), manifest: manifest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path) == ["AAAAAAAA"])
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: store.root.appending(path: "AAAAAAAA").path)) == ["capture.png", "manifest.json"])
        #expect(try store.current() == manifest)
        #expect(try store.png(of: manifest) == handoffPNG())
    }

    @Test func eachWriteReplacesEveryOtherBundle() throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.write(png: handoffPNG(), manifest: handoffManifest(id: "AAAAAAAA"))
        try FileManager.default.createDirectory(at: store.root.appending(path: ".BBBBBBBB.partial"), withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: store.root.appending(path: "notes.txt").path, contents: Data())
        let newer = handoffManifest(id: "CCCCCCCC", capturedAt: Date(timeIntervalSince1970: 1_791_000_100))
        try store.write(png: handoffPNG(), manifest: newer)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: store.root.path)) == ["CCCCCCCC", "notes.txt"])
        #expect(try store.current() == newer)
        try store.clear()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path) == ["notes.txt"])
    }

    @Test func clearingLeavesNoCapture() throws {
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.clear()
        #expect(try store.current() == nil)
        try store.write(png: handoffPNG(), manifest: handoffManifest(id: "AAAAAAAA"))
        try store.clear()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty && store.current() == nil)
    }
}
