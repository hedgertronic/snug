import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScreenshotCore

/// Drives the MCP request handler with JSON-RPC lines against a scratch store holding one capture, B, which replaced A.
final class HandoffServerTests {
    let server: HandoffServer

    init() throws {
        let store = HandoffStore(root: FileManager.default.temporaryDirectory.appending(path: "snug-mcp-\(UUID().uuidString)"))
        for id in ["AAAAAAAA", "BBBBBBBB"] {
            var manifest = handoffManifest(id: id, capturedAt: .now)
            manifest.image = .init(width: 40, height: 20, scale: 2)
            try store.write(png: handoffPNG(), manifest: manifest)
        }
        server = HandoffServer(store: store, version: "test")
    }

    deinit {
        try! FileManager.default.removeItem(at: server.store.root)
    }

    /// The response to one request, parsed.
    func send(_ line: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(try #require(server.respond(to: line)).utf8)) as! [String: Any]
    }

    func call(_ tool: String, _ arguments: String) throws -> [String: Any] {
        let response = try send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        #expect(response["id"] as? Int == 7 && response["error"] == nil)
        return response["result"] as! [String: Any]
    }

    func errorCode(_ result: [String: Any]) -> String? {
        guard result["isError"] as? Bool == true else { return nil }
        return (result["structuredContent"] as! [String: Any])["code"] as? String
    }

    func image(_ content: [String: Any]) throws -> CGImage {
        #expect(content["type"] as? String == "image" && content["mimeType"] as? String == "image/png")
        let data = try #require(Data(base64Encoded: content["data"] as! String))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func initializeAnswersWithAKnownProtocolVersion() throws {
        let response = try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = response["result"] as! [String: Any]
        #expect(response["jsonrpc"] as? String == "2.0" && response["id"] as? Int == 1 && result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as! [String: Any])["name"] as? String == "snug" && (result["capabilities"] as! [String: Any])["tools"] != nil)
        let unknown = try send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(unknown["id"] as? String == "a" && (unknown["result"] as! [String: Any])["protocolVersion"] as? String == "2025-06-18")
        #expect(server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect((try send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] as! [String: Any]).isEmpty)
    }

    @Test func toolsListNamesTheTwoReadOnlyTools() throws {
        let tools = (try send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.map { $0["name"] as! String } == ["get_capture", "zoom"])
        let description = tools[0]["description"] as! String
        #expect(description.contains("Only the most recent capture is kept") && description.contains("global screen point (geometry.crop_global.x + x / image.scale"))
        #expect(tools.allSatisfy { ($0["inputSchema"] as! [String: Any])["type"] as? String == "object" && $0["outputSchema"] == nil })
    }

    @Test func getCaptureReturnsTheImageAndManifestByIdOrLatest() throws {
        let latest = try call("get_capture", #"{"id":"latest"}"#)
        let manifest = latest["structuredContent"] as! [String: Any]
        #expect(errorCode(latest) == nil && manifest["capture_id"] as? String == "BBBBBBBB")
        let content = latest["content"] as! [[String: Any]]
        #expect(content.count == 2)
        let png = try image(content[0])
        #expect((png.width, png.height) == (40, 20))
        let text = try HandoffManifest(json: Data((content[1]["text"] as! String).utf8))
        #expect(text.captureId == "BBBBBBBB" && text.target.title == "Documents")
        let byId = try call("get_capture", #"{"id":"bbbbbbbb"}"#)
        #expect((byId["structuredContent"] as! [String: Any])["capture_id"] as? String == "BBBBBBBB")
    }

    @Test func aLargeCaptureComesBackDownscaledAndSaysSo() throws {
        let small = try call("get_capture", #"{"id":"BBBBBBBB"}"#)
        #expect((small["structuredContent"] as! [String: Any])["returned_image"] == nil && (small["content"] as! [[String: Any]]).count == 2)
        var manifest = handoffManifest(id: "WWWWWWWW", capturedAt: .now)
        manifest.image = .init(width: 3000, height: 200, scale: 2)
        try server.store.write(png: handoffPNG(width: 3000, height: 200), manifest: manifest)
        let large = try call("get_capture", #"{"id":"WWWWWWWW"}"#)
        let content = large["content"] as! [[String: Any]]
        let png = try image(content[0])
        #expect((png.width, png.height) == (1568, 105))
        let returned = (large["structuredContent"] as! [String: Any])["returned_image"] as! [String: Any]
        #expect(returned["width"] as? Int == 1568 && returned["height"] as? Int == 105 && returned["scale_to_capture"] as? Double == 3000.0 / 1568)
        let text = try JSONSerialization.jsonObject(with: Data((content[1]["text"] as! String).utf8)) as! [String: Any]
        #expect(text["capture_id"] as? String == "WWWWWWWW" && text["returned_image"] != nil)
        #expect(content.count == 3 && (content[2]["text"] as! String).contains("Call zoom for full resolution"))
        let zoom = try call("zoom", #"{"id":"WWWWWWWW","x":1000,"y":0,"width":2000,"height":200}"#)
        #expect(try image((zoom["content"] as! [[String: Any]])[0]).width == 2000)
    }

    @Test func aReplacedOrUnknownCaptureIsAnError() throws {
        let replaced = try call("get_capture", #"{"id":"AAAAAAAA"}"#)
        #expect(errorCode(replaced) == "capture_replaced")
        let message = (replaced["structuredContent"] as! [String: Any])["message"] as? String
        #expect(message == "Capture AAAAAAAA was replaced by a newer capture. Ask the user to copy it again.")
        #expect(errorCode(try call("zoom", #"{"id":"AAAAAAAA","x":0,"y":0,"width":1,"height":1}"#)) == "capture_replaced")
        #expect(errorCode(try call("get_capture", #"{"id":"ZZZZZZZZ"}"#)) == "capture_replaced")
        #expect(errorCode(try call("get_capture", #"{"id":"../../etc"}"#)) == "capture_not_found")
        #expect(errorCode(try call("zoom", #"{"id":"latest","x":0,"y":0,"width":1,"height":1}"#)) == nil)
        let empty = HandoffServer(store: HandoffStore(root: FileManager.default.temporaryDirectory.appending(path: "snug-mcp-\(UUID().uuidString)")), version: "test")
        for id in ["latest", "AAAAAAAA"] {
            let response = try JSONSerialization.jsonObject(with: Data(empty.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_capture","arguments":{"id":"\#(id)"}}}"#)!.utf8)) as! [String: Any]
            #expect(errorCode(response["result"] as! [String: Any]) == "capture_not_found")
        }
    }

    @Test(arguments: [40, 3000]) func damagedImagesReturnAToolError(width: Int) throws {
        var manifest = handoffManifest(id: "CCCCCCCC", capturedAt: .now)
        manifest.image = .init(width: width, height: 20, scale: 2)
        try server.store.write(png: Data("damaged PNG".utf8), manifest: manifest)
        #expect(errorCode(try call("get_capture", #"{"id":"latest"}"#)) == "capture_unreadable")
        #expect(errorCode(try call("zoom", #"{"id":"latest","x":0,"y":0,"width":1,"height":1}"#)) == "capture_unreadable")
        #expect((try send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)["result"] as! [String: Any]).isEmpty)
    }

    @Test func anImageThatDoesNotMatchItsManifestIsAnError() throws {
        var manifest = handoffManifest(id: "CCCCCCCC", capturedAt: .now)
        manifest.image = .init(width: 40, height: 20, scale: 2)
        try server.store.write(png: handoffPNG(width: 1, height: 1), manifest: manifest)
        #expect(errorCode(try call("get_capture", #"{"id":"latest"}"#)) == "capture_unreadable")
        #expect(errorCode(try call("zoom", #"{"id":"latest","x":10,"y":5,"width":20,"height":10}"#)) == "capture_unreadable")
    }

    @Test func negativeManifestDimensionsCannotOverflowZoomValidation() throws {
        var manifest = handoffManifest(id: "CCCCCCCC", capturedAt: .now)
        manifest.image = .init(width: Int.min, height: 20, scale: 2)
        try server.store.write(png: handoffPNG(), manifest: manifest)
        #expect(errorCode(try call("zoom", #"{"id":"latest","x":1,"y":0,"width":1,"height":1}"#)) == "invalid_rect")
    }

    @Test func aLargeGrayscaleCaptureCanBeDownscaled() throws {
        let context = try #require(CGContext(data: nil, width: 3000, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 200))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        var manifest = handoffManifest(id: "CCCCCCCC", capturedAt: .now)
        manifest.image = .init(width: 3000, height: 200, scale: 2)
        try server.store.write(png: data as Data, manifest: manifest)
        let result = try call("get_capture", #"{"id":"latest"}"#)
        #expect(errorCode(result) == nil)
        let resized = try image((result["content"] as! [[String: Any]])[0])
        #expect((resized.width, resized.height) == (1568, 105))
    }

    @Test func zoomCropsTheStoredPixelsWithTheirOffset() throws {
        let zoom = try call("zoom", #"{"id":"BBBBBBBB","x":10,"y":5,"width":20,"height":10}"#)
        let png = try image((zoom["content"] as! [[String: Any]])[0])
        #expect((png.width, png.height) == (20, 10))
        let offset = zoom["structuredContent"] as! [String: Any]
        #expect(offset["capture_id"] as? String == "BBBBBBBB" && offset["offset"] as! [String: Int] == ["x": 10, "y": 5])
        for rect in [#""x":30,"y":0,"width":20,"height":10"#, #""x":-1,"y":0,"width":5,"height":5"#, #""x":0,"y":0,"width":0,"height":5"#,
                     #""x":1.5,"y":0,"width":5,"height":5"#, #""x":0,"y":0,"width":5"#, #""x":9223372036854775807,"y":0,"width":5,"height":5"#] {
            #expect(errorCode(try call("zoom", #"{"id":"BBBBBBBB",\#(rect)}"#)) == "invalid_rect", "\(rect)")
        }
    }

    @Test func badRequestsAreJSONRPCErrors() throws {
        let parse = try send("{not json")
        #expect(parse["id"] is NSNull && (parse["error"] as! [String: Any])["code"] as? Int == -32700)
        #expect((try send(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)["error"] as! [String: Any])["code"] as? Int == -32601)
        let unknownTool = try send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_captures","arguments":{"id":"latest"}}}"#)
        #expect((unknownTool["error"] as! [String: Any])["code"] as? Int == -32602)
        let noId = try send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_capture","arguments":{}}}"#)
        #expect((noId["error"] as! [String: Any])["code"] as? Int == -32602)
    }
}
