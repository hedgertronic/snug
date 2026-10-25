import AppKit
import ImageIO
import OSLog
import ScreenshotCore
import UniformTypeIdentifiers

let signposter = OSSignposter(subsystem: "com.hedgertronic.snug", category: "capture")
/// Times from the shortcut to the overlay: the capture, the first draw, and the window list.
let openLog = Logger(subsystem: "com.hedgertronic.snug", category: "open")

/// UserDefaults keys and their registered defaults.
enum Pref {
    static let snap = "SnugSnap"
    /// Whether output gets its shadow (Frame): a live window its real macOS shadow, a subject the synthetic window shadow, an area or
    /// element a padded card with a shadow. Replaces the "SnugStyle" string and the "SnugShadow" bool, which `register` removes.
    static let frame = "SnugFrame"
    /// The transparent padding around a framed area or element, in whole points from 0 to 64 (Settings > Appearance > Frame).
    static let framePadding = "SnugFramePadding"
    /// The frame's shadow: "default" (a live window its real macOS shadow, a subject the synthetic window shadow, an area or element the
    /// card's shadow scaled to the padding) or "custom" (live windows captured without their shadow, and every framed output drawn with
    /// the shadow below). The custom shadow: opacity 0 to 1, blur and distance in points, the angle it falls in degrees counterclockwise
    /// from the right (270 is straight down), and its color as hex. The defaults are `OutputFrame.windowShadow`'s.
    static let frameShadow = "SnugFrameShadow"
    static let frameShadowOpacity = "SnugFrameShadowOpacity"
    static let frameShadowBlur = "SnugFrameShadowBlur"
    static let frameShadowDistance = "SnugFrameShadowDistance"
    static let frameShadowAngle = "SnugFrameShadowAngle"
    static let frameShadowColor = "SnugFrameShadowColor"
    private static let legacyStyle = "SnugStyle"
    private static let legacyShadow = "SnugShadow"
    static let saveFolder = "SnugSaveFolder"
    static let hotKeyCode = "SnugHotKeyCode"
    static let hotKeyModifiers = "SnugHotKeyModifiers"
    static let loupe = "SnugLoupe"
    static let rulers = "SnugRulers"
    static let crosshair = "SnugCrosshair"
    static let guidesAnimation = "SnugGuidesAnimation"
    static let colorFormat = "SnugColorFormat"
    static let candidates = "SnugCandidateList"
    static let accessibilityAsked = "SnugAccessibilityAsked"
    /// Whether Text mode turns on a Chromium app's accessibility (until the app quits) when it opens over one of its windows, so the next
    /// capture reads that app's text exactly instead of by OCR (Settings > General > Text mode). Off, Snug never sets the attribute.
    static let chromiumText = "SnugChromiumText"
    /// Whether crops take the corner radius measured on screen (and their window's at shared corners); off, they are square unless
    /// edited with [ and ].
    static let roundCorners = "SnugRoundCorners"
    /// The highlight: a hex color ("" is the system accent), fill and background fade as opacities, and the hover glow as an intensity from 0 to 1.
    static let highlightColor = "SnugHighlightColor"
    static let highlightFill = "SnugHighlightFill"
    static let highlightFade = "SnugHighlightFade"
    static let highlightGlow = "SnugHighlightGlow"
    /// The overlay chrome's look: "system" follows macOS, "light" and "dark" force one.
    static let overlayAppearance = "SnugOverlayAppearance"
    /// Where the toast sits (bottomCenter, bottomRight, or topRight), and how many seconds it stays while the pointer is elsewhere
    /// (one of `Toast.lifetimes`: 0 shows no toast but failures, -1 keeps it until closed).
    static let toastPosition = "SnugToastPosition"
    static let toastLifetime = "SnugToastLifetime"
    /// Whether Snug plays its sounds on a capture and a recording's start and stop (Settings > General). Failures beep either way.
    static let playSounds = "SnugPlaySounds"
    /// Off unless set with `defaults write com.hedgertronic.snug SnugLogHover -bool true`: each hover lookup and the Dock's window rect append to
    /// ~/Library/Logs/Snug/hover.log, so live accessibility frames can be read back without Accessibility in a terminal.
    static let logHover = "SnugLogHover"
    /// Off unless set with `defaults write com.hedgertronic.snug SnugLogText -bool true`: each Text mode press, drag event and release appends
    /// Live Text's selection before and after Snug's fix to ~/Library/Logs/Snug/text.log.
    static let logText = "SnugLogText"
    /// Off unless set with `defaults write com.hedgertronic.snug SnugLogScroll -bool true`: each scrolling capture writes every frame it captures,
    /// numbered in order, to a folder named for its start under ~/Library/Logs/Snug/scroll/, so a bad stitch can be replayed in a test.
    static let logScroll = "SnugLogScroll"
    /// The modification date of the Snug binary whose `--warm-vision` child process warmed Vision's accurate OCR models.
    static let visionWarmedBuild = "SnugVisionWarmedBuild"
    /// The menu bar icon variant, "a" or "d" (see `SnugApp.menuBarIcon`). The status item redraws as soon as it changes, so
    /// `defaults write com.hedgertronic.snug SnugMenuBarIcon d` switches the icon live.
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

    /// The custom shadow when `frameShadow` is "custom"; nil for the default shadows.
    static func customShadow(in defaults: UserDefaults) -> OutputFrame.Shadow? {
        guard defaults.string(forKey: frameShadow) == "custom" else { return nil }
        let color = Highlight.color(hex: defaults.string(forKey: frameShadowColor)!)
        return OutputFrame.Shadow(opacity: defaults.double(forKey: frameShadowOpacity), blur: defaults.double(forKey: frameShadowBlur),
                                  distance: defaults.double(forKey: frameShadowDistance), angle: defaults.double(forKey: frameShadowAngle),
                                  color: SRGBColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent))
    }

    static func register(in defaults: UserDefaults) {
        if let style = defaults.string(forKey: legacyStyle) {
            defaults.set(style == "backdrop", forKey: frame)
            defaults.removeObject(forKey: legacyStyle)
        }
        // Shadow on (its default) with Frame off stays off: Frame keeps its own value, so only the key goes.
        defaults.removeObject(forKey: legacyShadow)
        defaults.register(defaults: [
            snap: true,
            frame: false,
            framePadding: 24,
            frameShadow: "default",
            frameShadowOpacity: OutputFrame.windowShadow.opacity,
            frameShadowBlur: OutputFrame.windowShadow.blur,
            frameShadowDistance: OutputFrame.windowShadow.offset,
            frameShadowAngle: 270,
            frameShadowColor: "#000000",
            saveFolder: NSHomeDirectory() + "/Desktop",
            hotKeyCode: 49,
            hotKeyModifiers: Int(NSEvent.ModifierFlags([.control, .shift]).rawValue),
            colorFormat: ColorFormat.hex.rawValue,
            highlightColor: "",
            highlightFill: 0.1,
            highlightFade: 0.5,
            highlightGlow: 0.2,
            overlayAppearance: "system",
            guidesAnimation: GuidesAnimation.fade.rawValue,
            toastPosition: "bottomCenter",
            toastLifetime: 4,
            playSounds: true,
            roundCorners: true,
            chromiumText: true,
            menuBarIcon: "a",
            cutoutCrop: false,
            recordCountIn: 3,
            recordCursor: true
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

    /// Renders the frame on `padding` points (or none when nil) with the card shadow or `shadow`, and encodes a PNG off the main thread.
    @concurrent
    static func encode(_ image: CGImage, crop: CGRect, padding: CGFloat?, scale: CGFloat, cornerRadii: CornerRadii = .zero,
                       shadow: OutputFrame.Shadow? = nil) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try OutputFrame.render(image, crop: crop, scale: scale, padding: padding, cornerRadii: cornerRadii, shadow: shadow)
        return (try await png(rendered), rendered.width, rendered.height)
    }

    /// Renders a cutout (`OutputFrame.renderCutout`) and encodes a PNG off the main thread.
    @concurrent
    static func encodeCutout(_ subject: CGImage, bounds: CGRect?, cornerRadii: CornerRadii, framed: Bool, scale: CGFloat,
                             shadow: OutputFrame.Shadow? = nil, padding: CGFloat = 0) async throws -> (png: Data, width: Int, height: Int) {
        let rendered = try OutputFrame.renderCutout(subject, bounds: bounds, cornerRadii: cornerRadii, framed: framed, scale: scale, shadow: shadow, padding: padding)
        return (try await png(rendered), rendered.width, rendered.height)
    }

    /// Encodes a crop, then copies it to the pasteboard or saves it, and shows a toast (see `publish`).
    @MainActor
    static func deliver(_ image: CGImage, crop: CGRect, padding: CGFloat?, scale: CGFloat, cornerRadii: CornerRadii = .zero, shadow: OutputFrame.Shadow? = nil,
                        copy: Bool, save: Bool, destination: URL? = nil, warning: String? = nil, pasteboard: NSPasteboard, defaults: UserDefaults) async throws {
        let id = signposter.beginInterval("encode")
        let output = try await encode(image, crop: crop, padding: padding, scale: scale, cornerRadii: cornerRadii, shadow: shadow)
        signposter.endInterval("encode", id)
        publish(png: output.png, detail: "\(output.width) x \(output.height)", copy: copy, save: save, destination: destination,
                warning: warning, pasteboard: pasteboard, defaults: defaults)
    }

    /// The usual file for a saved capture: the save folder and a timestamped name.
    static func defaultFile(defaults: UserDefaults) -> URL {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!).appending(path: "Snug \(format.string(from: .now)).png")
    }

    /// Copies a PNG to the pasteboard or saves it, and shows a toast; returns the toast's message and detail. `detail` is the toast's
    /// pixel size line, saved or not. A save goes to `destination` (Save As, which the panel already confirmed) or the usual file, which takes a
    /// numbered name when its own is taken. A write that fails (the pasteboard refusing the image, an unwritable folder) shows a red toast
    /// with its reason and keeps the capture in it: "Copy failed" or "Save failed"; a capture that lands plays the capture sound. Otherwise a `warning` (a capture that may be wrong)
    /// takes the detail line and an orange mark.
    @MainActor
    @discardableResult
    static func publish(png: Data, detail: String, copy: Bool, save: Bool, destination: URL? = nil, warning: String? = nil, pasteboard: NSPasteboard,
                        defaults: UserDefaults) -> (message: String, detail: String) {
        var copied = !copy
        if copy {
            let id = signposter.beginInterval("pasteboard")
            pasteboard.clearContents()
            copied = pasteboard.setData(png, forType: .png)
            signposter.endInterval("pasteboard", id)
        }
        var file: URL?
        var saveError: (any Error)?
        if save {
            do {
                if let destination {
                    try png.write(to: destination, options: .atomic)
                    file = destination
                } else {
                    file = try UniqueFile.write(png, to: defaultFile(defaults: defaults))
                }
            } catch {
                saveError = error
            }
        }
        let folder = (file?.deletingLastPathComponent() ?? URL(fileURLWithPath: defaults.string(forKey: Pref.saveFolder)!)).lastPathComponent
        let message = message(copy: copy, save: save, copied: copied, saved: saveError == nil, folder: folder)
        let failed = !copied || saveError != nil
        let reason = saveError.map { ($0 as NSError).localizedFailureReason ?? $0.localizedDescription } ?? "The pasteboard did not accept the image."
        let detail = failed ? reason : warning ?? detail
        Toast.show(png: png, message: message, detail: detail, file: file, color: failed ? .systemRed : warning.map { _ in .systemOrange },
                   defaults: defaults, pasteboard: pasteboard)
        if !failed { Sound.capture.play(defaults: defaults) }
        return (message, detail)
    }

    /// The toast's message for what was asked (`copy`, `save`) and what worked (`copied`, `saved`). Only a recording, already saved, is
    /// both copied and saved.
    static func message(copy: Bool, save: Bool, copied: Bool, saved: Bool, folder: String) -> String {
        switch (copy, save, copied, saved) {
        case (true, true, true, _): "Copied, saved to \(folder)"
        case (true, true, false, _): "Saved to \(folder), copy failed"
        case (true, false, true, _): "Copied"
        case (true, false, false, _): "Copy failed"
        case (false, _, _, true): "Saved to \(folder)"
        default: "Save failed"
        }
    }
}
