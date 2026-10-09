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
    static let accessibilityAsked = "SnugAccessibilityAsked"
    /// Whether crops take the corner radius measured on screen (and their window's at shared corners); off, they are square unless
    /// edited with [ and ].
    static let roundCorners = "SnugRoundCorners"
    /// Off unless set with `defaults write local.snug SnugLogHover -bool true`: each hover lookup and the Dock's window rect append to
    /// ~/Library/Logs/Snug/hover.log, so live accessibility frames can be read back without Accessibility in a terminal.
    static let logHover = "SnugLogHover"

    static func logHoverLine(_ line: String) {
        guard UserDefaults.standard.bool(forKey: logHover) else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Snug")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "hover.log")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try! FileHandle(forWritingTo: file)
        defer { try! handle.close() }
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data((line + "\n").utf8))
    }

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
            shadow: true,
            roundCorners: true
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
    static func encode(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat, cornerRadii: CornerRadii = .zero) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try style.render(image, crop: crop, scale: scale, cornerRadii: cornerRadii)
        return (try await png(rendered), rendered.width, rendered.height)
    }

    /// Encodes a crop, then copies it to the pasteboard and/or saves it, and shows a toast.
    @MainActor
    static func deliver(_ image: CGImage, crop: CGRect, style: OutputStyle, scale: CGFloat, cornerRadii: CornerRadii = .zero,
                        copy: Bool, save: Bool, destination: URL? = nil, pasteboard: NSPasteboard, defaults: UserDefaults) async throws {
        let id = signposter.beginInterval("encode")
        let output = try await encode(image, crop: crop, style: style, scale: scale, cornerRadii: cornerRadii)
        signposter.endInterval("encode", id)
        try publish(png: output.png, detail: "\(output.width) x \(output.height)  \(style.rawValue)", copy: copy, save: save, destination: destination,
                    pasteboard: pasteboard, defaults: defaults)
    }

    /// The usual file for a saved capture: the save folder and a timestamped name.
    static func defaultFile(defaults: UserDefaults) -> URL {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!).appending(path: "Snug \(format.string(from: .now)).png")
    }

    /// Copies a PNG to the pasteboard and/or saves it, and shows a toast. `detail` is the toast's size line for a plain copy.
    /// A save goes to `destination` (Save As) or the usual file.
    @MainActor
    static func publish(png: Data, detail: String, copy: Bool, save: Bool, destination: URL? = nil, pasteboard: NSPasteboard, defaults: UserDefaults) throws {
        if copy {
            let id = signposter.beginInterval("pasteboard")
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            signposter.endInterval("pasteboard", id)
        }
        var file: URL?
        if save {
            file = destination ?? defaultFile(defaults: defaults)
            try png.write(to: file!)
        }
        let folder = (file?.deletingLastPathComponent() ?? URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!)).lastPathComponent
        let (message, detail) = switch (copy, save) {
        case (true, true): ("Copied, saved to \(folder)", file!.lastPathComponent)
        case (true, false): ("Copied", detail)
        default: ("Saved to \(folder)", file!.lastPathComponent)
        }
        Toast.show(png: png, message: message, detail: detail, file: file)
    }
}
