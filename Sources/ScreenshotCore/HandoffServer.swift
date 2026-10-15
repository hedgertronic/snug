import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The MCP server's requests, one JSON-RPC 2.0 message per line: `initialize`, `ping`, `tools/list` and `tools/call` for the read-only
/// tools `get_capture`, `zoom` and `list_captures` over a `HandoffStore`. It never captures.
public struct HandoffServer: Sendable {
    public let store: HandoffStore
    public let version: String
    /// The protocol versions an `initialize` may name; any other gets the last.
    public static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// The largest side `zoom` returns, in pixels.
    public static let zoomLimit = 2000

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
            + "the id from the user's \"[Snug capture ID: ...]\" reference, or \"latest\" for the newest capture. Image pixel (x, y) is the "
            + "global screen point (geometry.crop_global.x + x / image.scale, geometry.crop_global.y + y / image.scale). Snug never takes a new "
            + "screenshot: an expired or removed capture is an error.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."]], "required": ["id"]]],
        ["name": "zoom",
         "description": "Returns a crop of a capture's stored image, in image pixels, at most \(zoomLimit) px a side. Pixel (u, v) of the crop "
            + "is pixel (x + u, y + v) of the capture.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "A capture id, or \"latest\"."],
                                                          "x": ["type": "integer"], "y": ["type": "integer"],
                                                          "width": ["type": "integer"], "height": ["type": "integer"]],
                         "required": ["id", "x", "y", "width", "height"]]],
        ["name": "list_captures",
         "description": "Lists the captures that haven't expired, newest first: id, time, app and target.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]]
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
                    + "you; the pasted reference names a capture id. Read it with get_capture. Captures expire after 7 days."]
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
        guard name == "list_captures" || arguments["id"] is String else { throw RequestError(code: -32602, message: "Invalid params: id must be a string") }
        do {
            switch name {
            case "get_capture":
                let manifest = try resolve(arguments["id"] as! String)
                let json = try manifest.json()
                return ["content": [["type": "image", "data": try store.png(of: manifest).base64EncodedString(), "mimeType": "image/png"],
                                    ["type": "text", "text": String(decoding: json, as: UTF8.self)]],
                        "structuredContent": try JSONSerialization.jsonObject(with: json)]
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
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, crop, nil)
                precondition(CGImageDestinationFinalize(destination))
                let offset: [String: Any] = ["capture_id": manifest.captureId, "offset": ["x": x, "y": y], "width": w, "height": h]
                return ["content": [["type": "image", "data": (data as Data).base64EncodedString(), "mimeType": "image/png"],
                                    ["type": "text", "text": encode(offset)]],
                        "structuredContent": offset]
            case "list_captures":
                let now = Date.now
                let captures = try store.manifests().filter { $0.expiresAt > now }.map { manifest -> [String: Any] in
                    ["id": manifest.captureId, "captured_at": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(manifest.capturedAt),
                     "app": manifest.source?.app ?? NSNull(), "target": manifest.target.label]
                }
                return ["content": [["type": "text", "text": encode(["captures": captures])]], "structuredContent": ["captures": captures]]
            default:
                throw RequestError(code: -32602, message: "Unknown tool: \(name ?? "none")")
            }
        } catch let error as ToolError {
            let body: [String: Any] = ["code": error.code, "message": error.message]
            return ["content": [["type": "text", "text": encode(body)]], "structuredContent": body, "isError": true]
        }
    }

    /// The manifest for a capture id (any case) or "latest", the newest capture that hasn't expired.
    private func resolve(_ id: String) throws -> HandoffManifest {
        if id == "latest" {
            let now = Date.now
            guard let newest = try store.manifests().first(where: { $0.expiresAt > now }) else {
                throw ToolError(code: "capture_not_found", message: "There are no captures. Ask the user to press Cmd-Return in Snug.")
            }
            return newest
        }
        switch try store.lookup(id.uppercased()) {
        case .found(let manifest): return manifest
        case .expired:
            throw ToolError(code: "capture_expired", message: "Capture \(id) has expired or was deleted. Ask the user for a new capture.")
        case .notFound:
            throw ToolError(code: "capture_not_found", message: "There is no capture \(id).")
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
