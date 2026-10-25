import AppKit
import ScreenshotCore
import UniformTypeIdentifiers

/// A small non-activating confirmation: one capsule on the chrome surface with a lead tile, the message, and a detail line. The lead is
/// the capture's thumbnail (44 x 28 pt, aspect fill), the swatch for a color, a text glyph for copied text, or a mark (red for a failure
/// with no capture). The capsule is 40 pt tall (taller for a two-line warning or failure) and up to 360 pt wide, and it keeps that size
/// and place for its whole life: its text box is as wide as the wider of the resting text and the actions, and on hover the text
/// cross-fades to the actions in the same box, both centered in it. The close button fades in on the top-left corner. Copy puts the
/// capture (or the recording's file, or the text) on the pasteboard again; Save As (an unsaved capture: a save panel, and the toast closes
/// once it is saved) or Trash (a saved file), Open
/// (in the default app for the file, named in its tooltip), Show in Finder (a saved file) and Share act on the capture; copied text has
/// Open (in the default app for plain text, from a temporary file) and Share. The toast takes no keys.
/// Pointing at the thumbnail grows the capture out of it in its own panel, a margin above the capsule (below it at the top right); the
/// pointer can cross to it without either closing. Drag the thumbnail or the preview to drop the image, or click either to open it as
/// Open does; a click elsewhere closes the toast. It goes away after the lifetime setting (4 s unless changed) while the pointer is elsewhere, and
/// stays while it is over the toast or its preview; leaving starts the full lifetime again. A lifetime of 0 shows only failure toasts
/// (red), for 4 s; Forever keeps the toast until it is closed or drops off the stack.
/// Toasts stack, each on its own timer: the newest at the anchor and the older ones a gap further from it (up from a bottom anchor, down
/// from the top right). Closing one settles the ones past it back toward the anchor; a new one that makes the stack taller than a third of
/// the screen's visible height closes the oldest.
/// The capture is held only while the toast is visible: `dismiss` releases it.
@MainActor
final class Toast: NSPanel, NSDraggingSource {
    /// The toasts on screen, oldest first.
    private(set) static var shown: [Toast] = []
    /// The space between stacked capsules.
    static let gap: CGFloat = 8
    /// Debug runs set this so scripted copies never put a toast on screen or open an app; an action that would open one records it in `opened`.
    static var isSuppressed = false
    /// The file and the bundle id of the app the last suppressed Open or Show in Finder would have opened.
    private(set) static var opened: (file: URL, app: String)?
    /// Save As: the file to write, given the usual name in the save folder; nil cancels. Debug runs answer without a panel.
    static var chooseSaveURL: (URL) -> URL? = { suggested in
        NSApp.activate()
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Transparent margin around the capsule, so the close button can hang off a corner; it is also the gap to the preview.
    private static let margin: CGFloat = 10
    /// The lifetime setting's choices, in seconds: 0 is no toast but failures, and -1 is Forever.
    static let lifetimes = [0, 2, 4, 6, 10, -1]
    /// A warning's and a failure's detail, darker on the light surface so it reads.
    private static let warningText = NSColor.look(dark: NSColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 1), light: NSColor(srgbRed: 0.64, green: 0.32, blue: 0, alpha: 1))
    private static let failureText = NSColor.look(dark: NSColor(srgbRed: 1, green: 0.41, blue: 0.38, alpha: 1), light: NSColor(srgbRed: 0.77, green: 0.13, blue: 0.1, alpha: 1))
    private(set) var png: Data?
    private(set) var file: URL?
    /// What Copy puts on the pasteboard for a toast without a capture: the copied text or color value.
    private let text: String?
    private(set) var dismissal: Task<Void, any Error>?
    private(set) var dragStart: NSPoint?
    /// The share menu or the Save As panel is open, so the toast stays.
    private var holding = false
    /// How long the toast stays while the pointer is elsewhere; nil is until it is closed.
    let lifetime: Duration?
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    /// The capsule, on the chrome surface with its hairline in the look the toast opens in.
    let card = NSView()
    /// The thumbnail, swatch, text glyph, or mark.
    let lead: NSView
    /// The message and detail; on hover the actions take its place.
    let textBox = NSView()
    let message: NSTextField
    let detail: NSTextField
    let actions: NSStackView
    let closeButton: NSButton
    let copyButton: NSButton
    let saveButton: NSButton
    let trashButton: NSButton
    let openButton: NSButton
    let revealButton: NSButton
    let shareButton: NSButton
    /// The capture at up to 240 x 160 pt, in a panel of its own so showing it never moves the capsule.
    private(set) var preview: ToastPreview?
    private(set) var isHovering = false
    private(set) var isPeeking = false
    private var overCapsule = false
    private var overThumbnail = false
    private var overPreview = false
    private var thumbnailArea: NSTrackingArea?
    private var previewArea: NSTrackingArea?
    /// The preview's frame, and the thumbnail-sized frame at its edge by the capsule that it grows from, relative to the toast's origin.
    private var previewOffsets = (from: CGRect.zero, to: CGRect.zero)
    /// The toast's origin at the anchor, whether the stack grows down from it (the top right), and the visible screen it is on.
    private var anchor = NSPoint.zero
    private var fromTop = false
    private var screenArea = CGRect.zero
    private var settle: Task<Void, any Error>?
    /// The ends of the hover fade and of the preview's shrink: hiding the faded side, and ordering out the preview.
    private var fade: Task<Void, any Error>?
    private var peekFade: Task<Void, any Error>?

    /// A color toast passes the swatch `color` (red is a failure, orange a warning); a text toast passes the copied `text`, and a color
    /// toast its value to copy again. `pasteboard` is where Copy writes and Trash looks for the capture. A failure beeps.
    static func show(png: Data? = nil, message: String, detail: String = "", file: URL? = nil, color: NSColor? = nil, text: String? = nil,
                     defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        guard !isSuppressed, defaults.integer(forKey: Pref.toastLifetime) != 0 || color == .systemRed else { return }
        if color == .systemRed { NSSound.beep() }
        let toast = Toast(png: png, message: message, detail: detail, file: file, color: color, text: text, defaults: defaults, pasteboard: pasteboard)
        stack(toast)
        toast.orderFrontRegardless()
        toast.scheduleDismissal()
    }

    /// Adds a toast at the anchor and moves the others away from it, closing the oldest while the stack is taller than a third of the screen.
    static func stack(_ toast: Toast) {
        shown.append(toast)
        while shown.count > 1 && shown.reduce(-gap, { $0 + $1.card.frame.height + gap }) > toast.screenArea.height / 3 { shown[0].dismiss() }
        layout()
    }

    /// Places the toasts from the newest at its anchor, each a gap past the one after it, with each preview by its own toast. A toast on
    /// screen slides to its place over 0.2 s (at once under Reduce Motion); one off screen is put there.
    private static func layout() {
        var offset: CGFloat = 0
        for toast in shown.reversed() {
            let place = CGRect(origin: CGPoint(x: toast.anchor.x, y: toast.anchor.y + (toast.fromTop ? -offset : offset)), size: toast.frame.size)
            offset += toast.card.frame.height + gap
            // A preview shrinking away keeps shrinking toward the thumbnail.
            let peek = (toast.preview?.isVisible == true && !toast.isPeeking ? toast.previewOffsets.from : toast.previewOffsets.to).offsetBy(dx: place.minX, dy: place.minY)
            if toast.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    toast.animator().setFrame(place, display: true)
                    toast.preview?.animator().setFrame(peek, display: true)
                }
            } else {
                toast.setFrame(place, display: false)
                toast.preview?.setFrame(peek, display: false)
            }
        }
    }

    func scheduleDismissal() {
        dismissal?.cancel()
        guard let lifetime else { return }
        dismissal = Task {
            try await Task.sleep(for: lifetime)
            dismiss()
        }
    }

    /// Hides the toast and its preview and releases the capture and its images.
    func dismiss() {
        dismissal?.cancel()
        settle?.cancel()
        orderOut(nil)
        preview?.orderOut(nil)
        if let index = Toast.shown.firstIndex(where: { $0 === self }) {
            Toast.shown.remove(at: index)
            Toast.layout()
        }
        png = nil
        lead.layer?.contents = nil
        preview?.contentView!.layer!.contents = nil
        preview = nil
    }

    init(png: Data?, message messageText: String, detail detailText: String, file: URL?, color: NSColor?, text: String? = nil, defaults: UserDefaults,
         pasteboard: NSPasteboard = .general) {
        self.png = png
        self.file = file
        self.text = text
        self.defaults = defaults
        self.pasteboard = pasteboard
        let seconds = defaults.integer(forKey: Pref.toastLifetime)
        lifetime = seconds < 0 ? nil : .seconds(seconds == 0 ? 4 : seconds)
        let image = png.flatMap(NSImage.init(data:))
        let tone = color == .systemRed ? Toast.failureText : color == .systemOrange ? Toast.warningText : nil
        let swatch = tone == nil ? color : nil
        let copiedText = swatch == nil ? text : nil

        if let image {
            lead = NSView(frame: CGRect(x: 0, y: 0, width: 44, height: 28))
            lead.wantsLayer = true
            lead.layer!.contents = image
            lead.layer!.contentsRect = Toast.crop(image.size, to: lead.frame.size)
            lead.layer!.contentsGravity = .resizeAspectFill
            lead.layer!.cornerRadius = 7
            lead.layer!.masksToBounds = true
            lead.layer!.borderWidth = 1
            lead.layer!.borderColor = NSColor(white: 0.5, alpha: 0.3).cgColor
        } else if let swatch {
            let box = NSBox(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
            box.boxType = .custom
            box.fillColor = swatch
            box.borderColor = .swatchEdge
            box.borderWidth = 1
            box.cornerRadius = 7
            lead = box
        } else {
            // A text glyph or a mark in the highlight color (as the overlay resolves it) or the failure's or warning's color, with its
            // glyph in white or black by luminance.
            let fill = copiedText == nil && color != nil ? color! : Highlight.color(hex: defaults.string(forKey: Pref.highlightColor)!)
            let symbol = copiedText != nil ? "t.square.fill" : color == .systemRed ? "xmark.circle.fill" : color == .systemOrange ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            let mark = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: copiedText == nil ? 22 : 27, weight: .regular).applying(.init(paletteColors: [Chrome.text(on: fill), fill]))
            mark.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            lead = mark
        }

        message = NSTextField(messageText, size: 13, weight: .semibold)
        message.lineBreakMode = .byTruncatingTail
        // Copied text shows its first non-empty line in quotes; a warning or failure is in its color and may take two lines.
        let firstLine = copiedText.map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "" }
        detail = if let tone { NSTextField(detailText, size: 12, color: tone) } else if let firstLine { NSTextField("\"\(firstLine)\"", size: 12, mono: true) }
            else { NSTextField(detailText, size: 12, mono: true, color: .secondaryLabelColor) }
        detail.lineBreakMode = detailText == file?.lastPathComponent ? .byTruncatingMiddle : .byTruncatingTail
        detail.toolTip = copiedText == nil && !detailText.isEmpty ? detailText : nil
        detail.isHidden = detail.stringValue.isEmpty

        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: nil, action: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0.2, alpha: 0.9)]))
        closeButton.isBordered = false
        closeButton.frame.size = CGSize(width: 22, height: 22)
        closeButton.toolTip = "Close"
        closeButton.isHidden = true
        // Open names the default app for plain text, or for the file's type (a PNG until the capture is saved).
        let openTip = "Open in \(Toast.appName(toOpen: copiedText != nil ? .plainText : file.map { UTType(filenameExtension: $0.pathExtension)! } ?? .png))"
        func button(_ symbol: String, _ tip: String) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
            button.isBordered = false
            button.toolTip = tip
            button.contentTintColor = .labelColor
            button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }
        copyButton = button("doc.on.doc", "Copy")
        saveButton = button("square.and.arrow.down", "Save As...")
        trashButton = button("trash", "Move to Trash")
        openButton = button(copiedText != nil ? "doc.text" : "arrow.up.forward.app", openTip)
        revealButton = button("folder", "Show in Finder")
        shareButton = button("square.and.arrow.up", "Share")
        copyButton.isHidden = png == nil && text == nil
        saveButton.isHidden = png == nil || file != nil
        trashButton.isHidden = file == nil
        openButton.isHidden = png == nil && copiedText == nil
        revealButton.isHidden = file == nil
        shareButton.isHidden = png == nil && copiedText == nil
        actions = NSStackView(views: [copyButton, saveButton, trashButton, openButton, revealButton, shareButton])
        actions.spacing = 4
        actions.isHidden = true

        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        for (button, action) in [(closeButton, #selector(closeClicked)), (copyButton, #selector(copyClicked)), (saveButton, #selector(saveClicked)),
                                 (trashButton, #selector(trashClicked)), (openButton, #selector(openClicked)), (revealButton, #selector(revealClicked)),
                                 (shareButton, #selector(shareClicked))] {
            button.target = self
            button.action = action
        }

        // The size, fixed here: the text box is the wider of the resting text (the message up to 200 pt) and the actions, within 360 pt
        // for the whole capsule. A warning or failure too long for one line wraps to two and makes the capsule taller.
        let margin = Toast.margin
        let messageWidth = min(message.frame.width, 200)
        let resting = messageWidth + (detail.isHidden ? 0 : 8 + detail.frame.width)
        let widest = 360 - 6 - lead.frame.width - 10 - 12
        let boxWidth = min(max(resting, actions.arrangedSubviews.contains { !$0.isHidden } ? actions.fittingSize.width : 0), widest).rounded(.up)
        if tone != nil && resting > widest {
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 2
            detail.cell!.truncatesLastVisibleLine = true
        }
        let detailHeight = detail.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: boxWidth - messageWidth - 8, height: 100)).height
        let size = CGSize(width: 6 + lead.frame.width + 10 + boxWidth + 12, height: max(40, (detailHeight + 12).rounded(.up)))
        card.wantsLayer = true
        card.layer!.cornerRadius = 20
        card.layer!.borderWidth = 0.5
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer!.backgroundColor = NSColor.chromeSurface.cgColor
            card.layer!.borderColor = NSColor.chromeHairline.cgColor
        }
        card.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: size)
        lead.frame.origin = CGPoint(x: 6, y: ((size.height - lead.frame.height) / 2).rounded())
        textBox.frame = CGRect(x: lead.frame.maxX + 10, y: 0, width: boxWidth, height: size.height)
        textBox.addSubview(message)
        textBox.addSubview(detail)
        layoutText()
        actions.frame.size = actions.fittingSize
        actions.frame.origin = CGPoint(x: textBox.frame.minX + ((boxWidth - actions.frame.width) / 2).rounded(), y: ((size.height - actions.frame.height) / 2).rounded())
        for view in [lead, textBox, actions] { card.addSubview(view) }
        closeButton.frame.origin = CGPoint(x: card.frame.minX - closeButton.frame.width / 2 + 4, y: card.frame.maxY - closeButton.frame.height / 2 - 4)
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(card)
        root.addSubview(closeButton)
        contentView = root
        screenArea = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!).visibleFrame
        let position = defaults.string(forKey: Pref.toastPosition)!
        let origin = switch position {
        case "bottomRight": NSPoint(x: screenArea.maxX - size.width - 20, y: screenArea.minY + 48)
        case "topRight": NSPoint(x: screenArea.maxX - size.width - 20, y: screenArea.maxY - size.height - 20)
        default: NSPoint(x: (screenArea.midX - size.width / 2).rounded(), y: screenArea.minY + 48)
        }
        setFrame(CGRect(x: origin.x - margin, y: origin.y - margin, width: size.width + 2 * margin, height: size.height + 2 * margin), display: false)
        anchor = frame.origin
        fromTop = position == "topRight"
        root.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        guard let image else { return }

        // The preview: the whole capture aspect-fit inside 240 x 160 pt (never enlarged), each side at least 72 pt with the image cropped
        // as the thumbnail is. It starts at the thumbnail's left edge, kept on screen, a margin above the capsule (below it at the top right).
        let fit = min(1, 240 / image.size.width, 160 / image.size.height)
        let previewSize = CGSize(width: max(72, (image.size.width * fit).rounded()), height: max(72, (image.size.height * fit).rounded()))
        let thumbnail = lead.convert(lead.bounds, to: nil)
        let previewFrame = CGRect(x: min(frame.minX + thumbnail.minX, screenArea.maxX - 20 - previewSize.width), y: fromTop ? frame.minY - previewSize.height : frame.maxY,
                                  width: previewSize.width, height: previewSize.height)
        let panel = ToastPreview(contentRect: previewFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = collectionBehavior
        panel.nextResponder = self
        let picture = NSView(frame: CGRect(origin: .zero, size: previewSize))
        picture.wantsLayer = true
        picture.layer!.contents = image
        picture.layer!.contentsRect = Toast.crop(image.size, to: previewSize)
        picture.layer!.contentsGravity = .resizeAspectFill
        picture.layer!.cornerRadius = 12
        picture.layer!.masksToBounds = true
        picture.layer!.borderWidth = 1
        picture.layer!.borderColor = NSColor(white: 0.5, alpha: 0.3).cgColor
        // The pixel size in the bottom-right corner, left out under 110 pt wide.
        if previewSize.width >= 110, let pixels = image.representations.first {
            let label = NSTextField("\(pixels.pixelsWide) x \(pixels.pixelsHigh)", size: 10, weight: .semibold, mono: true, color: .white)
            let badge = NSView(frame: CGRect(x: 0, y: 0, width: label.frame.width + 10, height: label.frame.height + 4))
            badge.wantsLayer = true
            badge.layer!.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
            badge.layer!.cornerRadius = 5
            label.frame.origin = CGPoint(x: 5, y: 2)
            badge.addSubview(label)
            badge.frame.origin = CGPoint(x: previewSize.width - badge.frame.width - 5, y: 5)
            badge.autoresizingMask = [.minXMargin, .maxYMargin]
            picture.addSubview(badge)
        }
        panel.contentView = picture
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        picture.addTrackingArea(area)
        previewArea = area
        preview = panel
        previewOffsets = (CGRect(x: thumbnail.minX, y: fromTop ? -thumbnail.height : frame.height, width: thumbnail.width, height: thumbnail.height),
                          previewFrame.offsetBy(dx: -frame.minX, dy: -frame.minY))
        let thumbnailRect = NSTrackingArea(rect: thumbnail, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        root.addTrackingArea(thumbnailRect)
        thumbnailArea = thumbnailRect
    }

    /// The name of the default app for files of `type`, from its bundle.
    static func appName(toOpen type: UTType) -> String {
        let app = Bundle(url: NSWorkspace.shared.urlForApplication(toOpen: type)!)!
        return (app.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? app.object(forInfoDictionaryKey: "CFBundleName")) as! String
    }

    /// The part of an image of `size` that fills `box`: a tall image keeps its top, a wide one its middle.
    static func crop(_ size: CGSize, to box: CGSize) -> CGRect {
        let ratio = box.width / box.height / (size.width / size.height)
        return ratio > 1 ? CGRect(x: 0, y: 1 - 1 / ratio, width: 1, height: 1 / ratio) : CGRect(x: (1 - ratio) / 2, y: 0, width: ratio, height: 1)
    }

    /// Centers the message and detail in the text box, whose size never changes: the detail gives way first, then the message.
    private func layoutText() {
        message.sizeToFit()
        let box = textBox.bounds.size
        let messageWidth = min(message.frame.width, 200, box.width)
        // The detail at its one-line width, cut (or wrapped) to the room left, and as tall as that makes it.
        let width = detail.isHidden ? 0 : min(detail.cell!.cellSize.width, max(0, box.width - messageWidth - 8))
        let detailSize = CGSize(width: width, height: detail.isHidden ? 0 : min(detail.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: box.height)).height, box.height))
        let x = ((box.width - messageWidth - (detail.isHidden ? 0 : 8 + detailSize.width)) / 2).rounded()
        message.frame = CGRect(x: x, y: ((box.height - message.frame.height) / 2).rounded(), width: messageWidth, height: message.frame.height)
        detail.frame = CGRect(x: x + messageWidth + 8, y: ((box.height - detailSize.height) / 2).rounded(), width: detailSize.width, height: detailSize.height)
    }

    /// Cross-fades the text and the actions (when there are any) and fades the close button, over 0.15 s; nothing moves or resizes.
    /// The side fading out is hidden once the fade ends, so it takes no clicks.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        let swaps = actions.arrangedSubviews.contains { !$0.isHidden }
        let shown: [NSView] = swaps ? [closeButton, actions] : [closeButton], faded: [NSView] = swaps ? [textBox] : []
        let (incoming, outgoing) = hovering ? (shown, faded) : (faded, shown)
        for view in incoming where view.isHidden {
            view.alphaValue = 0
            view.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            for view in incoming { view.animator().alphaValue = 1 }
            for view in outgoing { view.animator().alphaValue = 0 }
        }
        fade?.cancel()
        fade = Task {
            try await Task.sleep(for: .milliseconds(150))
            for view in outgoing { view.isHidden = true }
            invalidateShadow()
        }
    }

    /// Shows the preview, grown out of the thumbnail with a fade over 0.18 s, or shrinks it back. Only a toast on screen puts it on screen.
    func setPeeking(_ peeking: Bool) {
        guard let preview, peeking != isPeeking else { return }
        isPeeking = peeking
        guard isVisible else { return }
        let (from, to) = (previewOffsets.from.offsetBy(dx: frame.minX, dy: frame.minY), previewOffsets.to.offsetBy(dx: frame.minX, dy: frame.minY))
        if peeking && !preview.isVisible {
            preview.setFrame(from, display: false)
            preview.alphaValue = 0
            preview.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            preview.animator().setFrame(peeking ? to : from, display: true)
            preview.animator().alphaValue = peeking ? 1 : 0
        }
        peekFade?.cancel()
        guard !peeking else { return }
        peekFade = Task {
            try await Task.sleep(for: .milliseconds(180))
            preview.orderOut(nil)
        }
    }

    @objc private func closeClicked() { dismiss() }

    /// The saved file, or the capture written to a temporary one, or the copied text written as UTF-8 to a temporary file of its own.
    private func fileOnDisk() -> URL {
        if file == nil, let png {
            file = FileManager.default.temporaryDirectory.appending(path: "Snug.png")
            try! png.write(to: file!)
        } else if file == nil {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Snug")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd HH.mm.ss"
            file = try! UniqueFile.write(Data(text!.utf8), to: folder.appending(path: "Snug Text \(format.string(from: .now)).txt"))
        }
        return file!
    }

    /// Puts the capture on the pasteboard again (a recording as its file, as delivered), or the copied text or color value, and closes.
    @objc private func copyClicked() {
        pasteboard.clearContents()
        if let file, file.pathExtension == "mov" {
            pasteboard.writeObjects([file as NSURL])
        } else if let png {
            pasteboard.setData(png, forType: .png)
        } else {
            pasteboard.setString(text!, forType: .string)
        }
        dismiss()
    }

    /// Opens the file (the capture, the recording, or the copied text's temporary file) in its default app and closes the toast.
    @objc private func openClicked() {
        let url = fileOnDisk()
        guard !Toast.isSuppressed else {
            Toast.opened = (url, Bundle(url: NSWorkspace.shared.urlForApplication(toOpen: url)!)!.bundleIdentifier!)
            return
        }
        NSWorkspace.shared.open(url)
        dismiss()
    }

    /// Selects the saved file in a Finder window and closes the toast.
    @objc private func revealClicked() {
        guard !Toast.isSuppressed else {
            Toast.opened = (file!, "com.apple.finder")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file!])
        dismiss()
    }

    /// Shows the share menu from the button for the capture's file or the copied text. The toast stays up while it is open, and closes once
    /// a service is chosen.
    @objc private func shareClicked() {
        let item: Any = png == nil ? text! : fileOnDisk()
        guard !Toast.isSuppressed else { return }
        holding = true
        dismissal?.cancel()
        let picker = NSSharingServicePicker(items: [item])
        picker.delegate = self
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    /// Moves the saved file to the Trash, clears the pasteboard if it still holds this capture, and closes the toast.
    @objc private func trashClicked() {
        let holdsCapture = pasteboard.data(forType: .png) == png || (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first == file
        if holdsCapture { pasteboard.clearContents() }
        try! FileManager.default.trashItem(at: file!, resultingItemURL: nil)
        dismiss()
    }

    /// Asks where to save with the Save As panel (the toast holds while it is open, dropped with its preview from the screen saver level to
    /// floating, under the modal panel), writes the capture there and closes the toast.
    /// Canceling keeps the toast and restarts its timer; a write that fails shows its reason in the toast, in red, and keeps the button.
    @objc private func saveClicked() {
        dismissal?.cancel()
        holding = true
        let level = self.level
        self.level = .floating
        preview?.level = .floating
        let chosen = Toast.chooseSaveURL(Output.defaultFile(defaults: defaults))
        self.level = level
        preview?.level = level
        holding = false
        guard let chosen else { return scheduleDismissal() }
        do {
            try png!.write(to: chosen, options: .atomic)
        } catch {
            message.stringValue = "Save failed"
            detail.stringValue = (error as NSError).localizedFailureReason ?? error.localizedDescription
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = Toast.failureText
            detail.lineBreakMode = .byTruncatingTail
            detail.toolTip = detail.stringValue
            detail.isHidden = false
            layoutText()
            scheduleDismissal()
            return
        }
        dismiss()
    }

    override func mouseEntered(with event: NSEvent) { track(event, inside: true) }

    override func mouseExited(with event: NSEvent) { track(event, inside: false) }

    /// Follows the pointer over the capsule, the thumbnail and the preview: over the capsule or the preview the toast is hovered and
    /// stays; over the thumbnail or the preview the preview shows. Leaving settles after 0.15 s, so the pointer can cross the margin
    /// between the thumbnail and the preview without either closing.
    private func track(_ event: NSEvent, inside: Bool) {
        if event.trackingArea === thumbnailArea {
            overThumbnail = inside
        } else if event.trackingArea === previewArea {
            overPreview = inside
        } else {
            overCapsule = inside
        }
        settle?.cancel()
        if overCapsule || overPreview {
            dismissal?.cancel()
            setHovering(true)
        }
        if overThumbnail || overPreview { setPeeking(true) }
        settle = Task {
            try await Task.sleep(for: .milliseconds(150))
            if !overThumbnail && !overPreview { setPeeking(false) }
            guard !overCapsule && !overPreview && !holding else { return }
            setHovering(false)
            scheduleDismissal()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A drag starts on the thumbnail or the preview, whose mouse events come here too.
    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        dragStart = event.window === preview || (png != nil && lead.convert(lead.bounds, to: nil).contains(point)) ? point : nil
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { return openClicked() }
        dismiss()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let png, let start = dragStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        dragStart = nil
        dismissal?.cancel()
        let view = event.window!.contentView!
        let item = NSDraggingItem(pasteboardWriter: fileOnDisk() as NSURL)
        item.setDraggingFrame(event.window === preview ? view.bounds : view.convert(lead.bounds, from: lead), contents: NSImage(data: png))
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dismiss() }
    }
}

/// The toast's preview panel. It takes no keys; its mouse events go to the toast.
final class ToastPreview: NSPanel {}

extension Toast: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chosen = service != nil
        MainActor.assumeIsolated {
            holding = false
            if chosen { dismiss() } else { scheduleDismissal() }
        }
    }
}
