import AppKit
import ImageIO
import OSLog
import ScreenshotCore
import UniformTypeIdentifiers

let signposter = OSSignposter(subsystem: "local.snug", category: "capture")

/// UserDefaults keys and their registered defaults.
enum Pref {
    static let snap = "SnugSnap"
    /// Whether output sits on a framed card with padding and a shadow (Frame). Replaces the "SnugStyle" string, which `register` migrates once.
    static let frame = "SnugFrame"
    private static let legacyStyle = "SnugStyle"
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
    /// The highlight: a hex color ("" is the system accent), fill and background fade as opacities, and the hover glow as an intensity from 0 to 1.
    static let highlightColor = "SnugHighlightColor"
    static let highlightFill = "SnugHighlightFill"
    static let highlightFade = "SnugHighlightFade"
    static let highlightGlow = "SnugHighlightGlow"
    /// Whether the toast shows a thumbnail of the capture, and where the toast sits: bottomCenter, bottomRight, or topRight.
    static let toastPreview = "SnugToastPreview"
    static let toastPosition = "SnugToastPosition"
    /// Off unless set with `defaults write local.snug SnugLogHover -bool true`: each hover lookup and the Dock's window rect append to
    /// ~/Library/Logs/Snug/hover.log, so live accessibility frames can be read back without Accessibility in a terminal.
    static let logHover = "SnugLogHover"
    /// Off unless set with `defaults write local.snug SnugLogText -bool true`: each Text mode press, drag event and release appends
    /// Live Text's selection before and after Snug's fix to ~/Library/Logs/Snug/text.log.
    static let logText = "SnugLogText"
    /// The modification date of the Snug binary whose first Text mode warmed Vision's accurate OCR models.
    static let visionWarmedBuild = "SnugVisionWarmedBuild"
    /// The menu bar icon variant, "a" or "d" (see `SnugApp.menuBarIcon`). The status item redraws as soon as it changes, so
    /// `defaults write local.snug SnugMenuBarIcon d` switches the icon live.
    static let menuBarIcon = "SnugMenuBarIcon"

    static func logHoverLine(_ line: String, key: String = logHover, file name: String = "hover.log") {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Snug")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try! FileHandle(forWritingTo: file)
        defer { try! handle.close() }
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data((line + "\n").utf8))
    }

    static func register(in defaults: UserDefaults) {
        if let style = defaults.string(forKey: legacyStyle) {
            defaults.set(style == "backdrop", forKey: frame)
            defaults.removeObject(forKey: legacyStyle)
        }
        defaults.register(defaults: [
            snap: true,
            frame: false,
            afterCapture: "copy",
            saveFolder: NSHomeDirectory() + "/Desktop",
            hotKeyCode: 49,
            hotKeyModifiers: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue),
            modeBar: true,
            colorFormat: ColorFormat.hex.rawValue,
            shadow: true,
            highlightColor: "",
            highlightFill: 0.0,
            highlightFade: 0.42,
            highlightGlow: 0.5,
            toastPreview: true,
            toastPosition: "bottomCenter",
            roundCorners: true,
            menuBarIcon: "a"
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

    /// Renders the frame (or not) and encodes a PNG off the main thread.
    @concurrent
    static func encode(_ image: CGImage, crop: CGRect, framed: Bool, scale: CGFloat, cornerRadii: CornerRadii = .zero) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try OutputFrame.render(image, crop: crop, scale: scale, framed: framed, cornerRadii: cornerRadii)
        return (try await png(rendered), rendered.width, rendered.height)
    }

    /// Encodes a crop, then copies it to the pasteboard and/or saves it, and shows a toast.
    @MainActor
    static func deliver(_ image: CGImage, crop: CGRect, framed: Bool, scale: CGFloat, cornerRadii: CornerRadii = .zero,
                        copy: Bool, save: Bool, destination: URL? = nil, pasteboard: NSPasteboard, defaults: UserDefaults) async throws {
        let id = signposter.beginInterval("encode")
        let output = try await encode(image, crop: crop, framed: framed, scale: scale, cornerRadii: cornerRadii)
        signposter.endInterval("encode", id)
        try publish(png: output.png, detail: "\(output.width) x \(output.height)" + (framed ? "  frame" : ""), copy: copy, save: save, destination: destination,
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
        Toast.show(png: png, message: message, detail: detail, file: file, defaults: defaults)
    }
}
