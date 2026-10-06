import AppKit
import ImageIO
import OSLog
import ScreenshotCore
import UniformTypeIdentifiers

let signposter = OSSignposter(subsystem: "local.snug", category: "capture")

/// UserDefaults keys and their registered defaults.
enum Pref {
    static let snap = "SnugSnap"
    static let style = "SnugStyle"
    static let afterCapture = "SnugAfterCapture"
    static let saveFolder = "SnugSaveFolder"
    static let hotKeyCode = "SnugHotKeyCode"
    static let hotKeyModifiers = "SnugHotKeyModifiers"
    static let hotKeyLabel = "SnugHotKeyLabel"
    static let lastArea = "SnugLastArea"

    static func register(in defaults: UserDefaults) {
        defaults.register(defaults: [
            snap: true,
            style: OutputStyle.tight.rawValue,
            afterCapture: "copy",
            saveFolder: NSHomeDirectory() + "/Desktop",
            hotKeyCode: 49,
            hotKeyModifiers: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue),
            hotKeyLabel: "Ctrl-Shift-Space"
        ])
    }
}

/// Crops, styles, encodes, and delivers captures.
enum Output {
    /// Renders the style and encodes a PNG off the main thread.
    @concurrent
    static func encode(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try style.render(image, crop: crop, scale: scale)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return (data as Data, rendered.width, rendered.height)
    }

    /// Encodes a crop, then copies it to the pasteboard and/or saves it, and shows a toast.
    @MainActor
    static func deliver(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat, copy: Bool, save: Bool,
                        pasteboard: NSPasteboard, defaults: UserDefaults) async throws {
        let id = signposter.beginInterval("encode")
        let output = try await encode(image, crop: crop, style: style, scale: scale)
        signposter.endInterval("encode", id)

        if copy {
            let id = signposter.beginInterval("pasteboard")
            pasteboard.clearContents()
            pasteboard.setData(output.png, forType: .png)
            signposter.endInterval("pasteboard", id)
        }
        var file: URL?
        if save {
            let folder = URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!)
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            file = folder.appending(path: "Snug \(format.string(from: .now)).png")
            try output.png.write(to: file!)
        }
        let size = "\(output.width) x \(output.height) px"
        let message = switch (copy, save) {
        case (true, true): "Copied and saved \(size)"
        case (true, false): "Copied \(size), \(style.rawValue)"
        default: "Saved \(size)"
        }
        Toast.show(png: output.png, message: message, file: file)
    }
}
