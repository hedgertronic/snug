import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The MCP server's requests, one JSON-RPC 2.0 message per line: `initialize`, `ping`, `tools/list` and `tools/call` for the read-only
/// tools `get_capture` and `zoom` over a `HandoffStore`. It never captures.
public struct HandoffServer: Sendable {
    public let store: HandoffStore
    public let version: String
    /// The protocol versions an `initialize` may name; any other gets the last.
    public static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// The largest side `zoom` returns, in pixels.
    public static let zoomLimit = 2000
    /// The largest image `get_capture` returns as is: the long side the Anthropic API keeps without downsampling, and bytes under its 5 MB
    /// limit once base64 grows them by a third.
    public static let imageSide = 1568
    public static let imageBytes = 3_750_000
    /// The longest request line read, in bytes; a longer one is answered with an Invalid Request error and dropped.
    public static let requestBytes = 1_048_576
    /// The most pixels a stored capture may declare before the server decodes it: 100 megapixels, larger than any display's capture.
    public static let imagePixels = 100_000_000

    public init(store: HandoffStore, version: String) {
        self.store = store
        self.version = version
    }

    /// A JSON-RPC error: the request cannot be answered.
    struct RequestError: Error {
        let code: Int
        let message: String
    }

    /// A tool's failure, returned as its result with `isError`.
    struct ToolError: Error {
        let code: String
        let message: String
    }

    static var tools: [[String: Any]] { [
        ["name": "get_capture",
         "description": ["Returns a screenshot the user handed you with Snug's Copy for Agent (Cmd-Return): the image, unstyled and at full ",
            "resolution, and its manifest: the app (name, bundle id, bundle path, version), the window (title, frame, and its open ",
            "document's file URL as source.document), a web page's URL and title (source.url, source.page_title), the display, and the target: ",
            "its accessibility role, subrole, role description, title, identifier (AXIdentifier, often set in code), description, value ",
            "(cut short; a few KB for text), help, placeholder, labeled_by, url, enabled/focused/selected, frame, up to 10 children and 10 ",
            "siblings (role and name), and ancestors innermost first; inside a web page also dom_id, dom_classes (on ancestors too) and a ",
            "CSS-like selector to search the source for. target.provenance \"accessibility\" means the element's frame is the capture; ",
            "otherwise the accessibility fields describe the element holding the capture or under its center, at target.frame. Pass ",
            "the id from the user's \"[Snug capture ID: ...]\" reference, or \"latest\" for the current capture. Only the most ",
            "recent capture is kept: the next Copy for Agent replaces it. Image pixel (x, y) is the global screen point ",
            "(geometry.crop_global.x + x / image.scale, geometry.crop_global.y + y / image.scale). Snug never takes a new ",
            "screenshot: a replaced capture is an error. A capture over \(imageSide) px on its long side or 3.75 MB ",
            "comes back as a smaller copy, with returned_image giving its size and scale_to_capture; zoom returns full resolution."].joined(),
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."]], "required": ["id"]]],
        ["name": "zoom",
         "description": "Returns a crop of a capture's stored image, in image pixels, at most \(zoomLimit) px a side. Pixel (u, v) of the crop "
            + "is pixel (x + u, y + v) of the capture.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."],
                                                          "x": ["type": "integer"], "y": ["type": "integer"],
                                                          "width": ["type": "integer"], "height": ["type": "integer"]],
                         "required": ["id", "x", "y", "width", "height"]]]
    ] }

    /// The response to a request line longer than `requestBytes`, which is not parsed.
    public func respondToOverlongRequest() -> String {
        encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request: longer than \(Self.requestBytes) bytes"]])
    }

    /// The response line to `line`, or nil for a notification. A message that is not a JSON-RPC 2.0 request (no "jsonrpc": "2.0", a
    /// method that is not a string, an id that is not a string, number or null, params that are not an object or null) is an Invalid
    /// Request.
    public func respond(to line: String) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let message = parsed as? [String: Any]
        let id = message?["id"]
        let validId = id.map { $0 is String || $0 is NSNull || ($0 as? NSNumber).map { CFGetTypeID($0) == CFNumberGetTypeID() } == true } ?? true
        guard let message, message["jsonrpc"] as? String == "2.0", message["method"] is String, validId,
              message["params"] == nil || message["params"] is NSNull || message["params"] is [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": validId ? id ?? NSNull() : NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result: [String: Any] = switch message["method"] as? String {
            case "initialize":
                ["protocolVersion": Self.protocolVersions.first { $0 == params["protocolVersion"] as? String } ?? Self.protocolVersions.last!,
                 "capabilities": ["tools": ["listChanged": false]],
                 "serverInfo": ["name": "snug", "version": version],
                 "instructions": "Snug is a macOS screenshot app. The user points at something on screen and presses Cmd-Return to hand it to "
                    + "you; the pasted reference names a capture id. Read it with get_capture. Only the most recent capture is kept."]
            case "ping": [:]
            case "tools/list": ["tools": Self.tools]
            case "tools/call": try call(params)
            case let method: throw RequestError(code: -32601, message: "Method not found: \(method ?? "none")")
            }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RequestError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
        }
    }

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let name = params["name"] as? String
        guard arguments["id"] is String else { throw RequestError(code: -32602, message: "Invalid params: id must be a string") }
        do {
            switch name {
            case "get_capture":
                let manifest = try resolve(arguments["id"] as! String)
                var png = try store.png(of: manifest)
                let image = try image(from: png, manifest: manifest)
                var structured = try JSONSerialization.jsonObject(with: manifest.json()) as! [String: Any]
                var note: [[String: Any]] = []
                let (width, height) = (manifest.image.width, manifest.image.height)
                // Clients reject or shrink large images: past the limits the result is a smaller copy, and `zoom` gives full resolution.
                if max(width, height) > Self.imageSide || png.count > Self.imageBytes {
                    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
                    var side = min(Self.imageSide, max(width, height))
                    var size = (width: 0, height: 0)
                    repeat {
                        let factor = Double(side) / Double(max(width, height))
                        size = (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
                        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        context.interpolationQuality = .high
                        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                        guard let resized = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
                        png = try Self.png(resized)
                        side = side * 3 / 4
                    } while png.count > Self.imageBytes
                    let scale = Double(width) / Double(size.width)
                    structured["returned_image"] = ["width": size.width, "height": size.height, "scale_to_capture": scale]
                    note = [["type": "text", "text": "This image is a downscaled copy: \(size.width) x \(size.height) of the capture's \(width) x \(height) pixels, "
                                + "one returned pixel to \(String(format: "%.3f", scale)) capture pixels (returned_image). Call zoom for full resolution."]]
                }
                return ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                                    ["type": "text", "text": encode(structured)]] + note,
                        "structuredContent": structured]
            case "zoom":
                let manifest = try resolve(arguments["id"] as! String)
                let values = ["x", "y", "width", "height"].map { arguments[$0] as? Int }
                let (width, height) = (manifest.image.width, manifest.image.height)
                guard let x = values[0], let y = values[1], let w = values[2], let h = values[3], x >= 0, y >= 0, w > 0, h > 0,
                      x <= width, y <= height,
                      w <= width - x, h <= height - y, max(w, h) <= Self.zoomLimit else {
                    throw ToolError(code: "invalid_rect", message: "The rect must be whole pixels inside the \(width) x \(height) image, "
                                    + "at most \(Self.zoomLimit) px a side.")
                }
                let image = try image(from: store.png(of: manifest), manifest: manifest)
                guard let crop = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { throw CocoaError(.fileReadCorruptFile) }
                let offset: [String: Any] = ["capture_id": manifest.captureId, "offset": ["x": x, "y": y], "width": w, "height": h]
                return ["content": [["type": "image", "data": try Self.png(crop).base64EncodedString(), "mimeType": "image/png"],
                                    ["type": "text", "text": encode(offset)]],
                        "structuredContent": offset]
            default:
                throw RequestError(code: -32602, message: "Unknown tool: \(name ?? "none")")
            }
        } catch let error as ToolError {
            let body: [String: Any] = ["code": error.code, "message": error.message]
            return ["content": [["type": "text", "text": encode(body)]], "structuredContent": body, "isError": true]
        }
    }

    /// The current capture, for its id (any case) or "latest". Any other well-formed id was replaced by a newer capture.
    private func resolve(_ id: String) throws -> HandoffManifest {
        guard let current = try store.current() else {
            throw ToolError(code: "capture_not_found", message: "There is no capture. Ask the user to press Cmd-Return in Snug.")
        }
        if id == "latest" || id.uppercased() == current.captureId { return current }
        guard HandoffManifest.isId(id.uppercased()) else { throw ToolError(code: "capture_not_found", message: "There is no capture \(id).") }
        throw ToolError(code: "capture_replaced", message: "Capture \(id) was replaced by a newer capture. Ask the user to copy it again.")
    }

    private func encode(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func image(from png: Data, manifest: HandoffManifest) throws -> CGImage {
        let (pixels, overflow) = manifest.image.width.multipliedReportingOverflow(by: manifest.image.height)
        guard !overflow, pixels <= Self.imagePixels else {
            throw ToolError(code: "capture_too_large", message: "The stored image is larger than \(Self.imagePixels / 1_000_000) megapixels.")
        }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == manifest.image.width, image.height == manifest.image.height else {
            throw ToolError(code: "capture_unreadable", message: "The stored image is damaged or does not match its manifest. Ask the user to copy it again.")
        }
        return image
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
