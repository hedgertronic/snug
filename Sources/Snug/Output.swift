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
    static let lastArea = "SnugLastArea"
    static let modeBar = "SnugModeBar"
    static let loupe = "SnugLoupe"
    static let rulers = "SnugRulers"
    static let crosshair = "SnugCrosshair"
    static let colorFormat = "SnugColorFormat"
    static let candidates = "SnugCandidateList"
    static let shadow = "SnugShadow"

    static func register(in defaults: UserDefaults) {
        defaults.register(defaults: [
            snap: true,
            style: OutputStyle.tight.rawValue,
            afterCapture: "copy",
            saveFolder: NSHomeDirectory() + "/Desktop",
            hotKeyCode: 49,
            hotKeyModifiers: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue),
            modeBar: true,
            colorFormat: ColorFormat.hex.rawValue,
            shadow: true
        ])
    }
}

/// Crops, styles, encodes, and delivers captures.
enum Output {
    /// Encodes a PNG off the main thread.
    @concurrent
    static func png(_ image: CGImage) async throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// Renders the style and encodes a PNG off the main thread.
    @concurrent
    static func encode(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat, cornerRadius: CGFloat = 0) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try style.render(image, crop: crop, scale: scale, cornerRadius: cornerRadius)
        return (try await png(rendered), rendered.width, rendered.height)
    }

    /// Encodes a crop, then copies it to the pasteboard and/or saves it, and shows a toast.
    @MainActor
    static func deliver(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat, cornerRadius: CGFloat = 0, copy: Bool, save: Bool,
                        pasteboard: NSPasteboard, defaults: UserDefaults) async throws {
        let id = signposter.beginInterval("encode")
        let output = try await encode(image, crop: crop, style: style, scale: scale, cornerRadius: cornerRadius)
        signposter.endInterval("encode", id)
        try publish(png: output.png, detail: "\(output.width) x \(output.height)  \(style.rawValue)", copy: copy, save: save,
                    pasteboard: pasteboard, defaults: defaults)
    }

    /// Copies a PNG to the pasteboard and/or saves it, and shows a toast. `detail` is the toast's size line for a plain copy.
    @MainActor
    static func publish(png: Data, detail: String, copy: Bool, save: Bool, pasteboard: NSPasteboard, defaults: UserDefaults) throws {
        if copy {
            let id = signposter.beginInterval("pasteboard")
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            signposter.endInterval("pasteboard", id)
        }
        var file: URL?
        if save {
            let folder = URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!)
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            file = folder.appending(path: "Snug \(format.string(from: .now)).png")
            try png.write(to: file!)
        }
        let folder = URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!).lastPathComponent
        let (message, detail) = switch (copy, save) {
        case (true, true): ("Copied, saved to \(folder)", file!.lastPathComponent)
        case (true, false): ("Copied", detail)
        default: ("Saved to \(folder)", file!.lastPathComponent)
        }
        Toast.show(png: png, message: message, detail: detail, file: file)
    }
}
