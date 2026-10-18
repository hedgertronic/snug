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
         "description": "Returns a screenshot the user handed you with Snug's Copy for Agent (Cmd-Return): the image, unstyled and at full "
            + "resolution, and its manifest (app, window, the element's accessibility role and title, its ancestors, and coordinates). Pass "
            + "the id from the user's \"[Snug capture ID: ...]\" reference, or \"latest\" for the current capture. Only the most "
            + "recent capture is kept: the next Copy for Agent replaces it. Image pixel (x, y) is the global screen point "
            + "(geometry.crop_global.x + x / image.scale, geometry.crop_global.y + y / image.scale). Snug never takes a new "
            + "screenshot: a replaced capture is an error. A capture over \(imageSide) px on its long side or 3.75 MB "
            + "comes back as a smaller copy, with returned_image giving its size and scale_to_capture; zoom returns full resolution.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."]], "required": ["id"]]],
        ["name": "zoom",
         "description": "Returns a crop of a capture's stored image, in image pixels, at most \(zoomLimit) px a side. Pixel (u, v) of the crop "
            + "is pixel (x + u, y + v) of the capture.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."],
                                                          "x": ["type": "integer"], "y": ["type": "integer"],
                                                          "width": ["type": "integer"], "height": ["type": "integer"]],
                         "required": ["id", "x", "y", "width", "height"]]]
    ] }

    /// The response line to `line`, or nil for a notification.
    public func respond(to line: String) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
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
                var structured = try JSONSerialization.jsonObject(with: manifest.json()) as! [String: Any]
                var note: [[String: Any]] = []
                let (width, height) = (manifest.image.width, manifest.image.height)
                // Clients reject or shrink large images: past the limits the result is a smaller copy, and `zoom` gives full resolution.
                if max(width, height) > Self.imageSide || png.count > Self.imageBytes {
                    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
                    var side = min(Self.imageSide, max(width, height))
                    var size = (width: 0, height: 0)
                    repeat {
                        let factor = Double(side) / Double(max(width, height))
                        size = (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
                        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.interpolationQuality = .high
                        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                        png = Self.png(context.makeImage()!)
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
                      w <= width - x, h <= height - y, max(w, h) <= Self.zoomLimit else {
                    throw ToolError(code: "invalid_rect", message: "The rect must be whole pixels inside the \(width) x \(height) image, "
                                    + "at most \(Self.zoomLimit) px a side.")
                }
                let source = CGImageSourceCreateWithData(try store.png(of: manifest) as CFData, nil)!
                let crop = CGImageSourceCreateImageAtIndex(source, 0, nil)!.cropping(to: CGRect(x: x, y: y, width: w, height: h))!
                let offset: [String: Any] = ["capture_id": manifest.captureId, "offset": ["x": x, "y": y], "width": w, "height": h]
                return ["content": [["type": "image", "data": Self.png(crop).base64EncodedString(), "mimeType": "image/png"],
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

    private static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
