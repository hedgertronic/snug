import AppKit
import ScreenshotCore

/// A small non-activating confirmation: a pill with the message and size, and, when the preview is on, a separate rounded card with a
/// thumbnail of the capture a gap away (above the pill, or below it at the top right). Each piece has its own shadow. It goes away after
/// the lifetime setting (4 s unless changed) while the pointer is elsewhere, and stays while it is over the toast; leaving starts the
/// full lifetime again. A lifetime of 0 shows only failure toasts (red), for 4 s; Forever keeps the toast until it is closed or replaced.
/// Over it, a close button sits on the top-left corner and, when it holds a capture, icon buttons replace the pill's text: Share, Trash (a saved file), Save (an unsaved capture), and Open (Preview, or QuickTime Player for a recording). Drag it to drop the image; a saved toast reveals the file when clicked.
/// The capture is held only while the toast is visible: `dismiss` releases it.
@MainActor
final class Toast: NSPanel, NSDraggingSource {
    private static var current: Toast?
    /// Debug runs set this so scripted copies never put a toast on screen or open Preview.
    static var isSuppressed = false
    /// Transparent margin around the pieces, so the close button can hang off a corner.
    private static let margin: CGFloat = 10
    /// The space between the pill and the preview card.
    private static let gap: CGFloat = 8
    /// The lifetime setting's choices, in seconds: 0 is no toast but failures, and -1 is Forever.
    static let lifetimes = [0, 2, 4, 6, 10, -1]
    private(set) var png: Data?
    private(set) var file: URL?
    private var reveals: Bool
    private(set) var dismissal: Task<Void, any Error>?
    private var dragStart: NSPoint?
    private var sharing = false
    /// How long the toast stays while the pointer is elsewhere; nil is until it is closed.
    let lifetime: Duration?
    private(set) var preview: NSView?
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let screenArea: CGRect
    private let position: String
    /// The pill.
    let card: NSVisualEffectView
    private let row: NSStackView
    /// The checkmark, or a color toast's swatch.
    let mark: NSView
    let message: NSTextField
    private let detail: NSTextField
    let closeButton: NSButton
    private let actions: NSStackView?
    let shareButton: NSButton
    let trashButton: NSButton
    let saveButton: NSButton
    let openInPreview: NSButton

    /// A color toast passes `color` instead of a PNG and shows a swatch in place of the thumbnail. `pasteboard` is where Trash looks for the capture.
    static func show(png: Data? = nil, message: String, detail: String = "", file: URL? = nil, color: NSColor? = nil, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        guard !isSuppressed, defaults.integer(forKey: Pref.toastLifetime) != 0 || color == .systemRed else { return }
        current?.dismiss()
        let toast = Toast(png: png, message: message, detail: detail, file: file, color: color, defaults: defaults, pasteboard: pasteboard)
        current = toast
        toast.orderFrontRegardless()
        toast.scheduleDismissal()
    }

    func scheduleDismissal() {
        dismissal?.cancel()
        guard let lifetime else { return }
        dismissal = Task {
            try await Task.sleep(for: lifetime)
            dismiss()
        }
    }

    /// Hides the toast and releases the capture and its thumbnail.
    func dismiss() {
        dismissal?.cancel()
        orderOut(nil)
        if Toast.current === self { Toast.current = nil }
        png = nil
        preview?.layer!.contents = nil
        preview = nil
    }

    init(png: Data?, message messageText: String, detail detailText: String, file: URL?, color: NSColor?, defaults: UserDefaults, pasteboard: NSPasteboard = .general) {
        self.png = png
        self.file = file
        self.defaults = defaults
        self.pasteboard = pasteboard
        reveals = file != nil
        let thumbnail = png.flatMap { defaults.bool(forKey: Pref.toastPreview) ? NSImage(data: $0) : nil }
        let seconds = defaults.integer(forKey: Pref.toastLifetime)
        lifetime = seconds < 0 ? nil : .seconds(seconds == 0 ? 4 : seconds)
        let fit = thumbnail.map { min(1, 240 / $0.size.width, 160 / $0.size.height) } ?? 1
        let previewSize = thumbnail.map { CGSize(width: ($0.size.width * fit).rounded(), height: ($0.size.height * fit).rounded()) } ?? .zero
        preview = thumbnail.map {
            let view = NSView(frame: CGRect(origin: .zero, size: previewSize))
            view.wantsLayer = true
            view.layer!.contents = $0
            view.layer!.contentsGravity = .resizeAspect
            view.layer!.masksToBounds = true
            view.layer!.cornerRadius = 12
            view.layer!.borderWidth = 1
            view.layer!.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            return view
        }
        position = defaults.string(forKey: Pref.toastPosition)!
        screenArea = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!).visibleFrame

        let mark: NSView
        if let color {
            mark = NSView()
            mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
            mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
            mark.wantsLayer = true
            mark.layer!.backgroundColor = color.cgColor
            mark.layer!.cornerRadius = 5
            mark.layer!.borderWidth = 1
            mark.layer!.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        } else {
            // The highlight color, as the overlay resolves it, with the check in white or black by its luminance.
            let tint = Highlight.color(hex: defaults.string(forKey: Pref.highlightColor)!)
            let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
            check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold).applying(.init(paletteColors: [Chrome.text(on: tint), tint]))
            check.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            mark = check
        }
        message = NSTextField(messageText, size: 13, weight: .semibold)
        detail = NSTextField(detailText, size: 12, mono: true, color: .secondaryLabelColor)
        detail.isHidden = detailText.isEmpty
        self.mark = mark
        row = NSStackView(views: [mark, message, detail])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 16)

        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: nil, action: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0.2, alpha: 0.9)]))
        closeButton.isBordered = false
        closeButton.frame.size = CGSize(width: 22, height: 22)
        closeButton.isHidden = true
        let isMovie = file?.pathExtension == "mov"
        shareButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: nil, action: nil)
        trashButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")!, target: nil, action: nil)
        saveButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")!, target: nil, action: nil)
        openInPreview = NSButton(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: isMovie ? "Open in QuickTime Player" : "Open in Preview")!, target: nil, action: nil)
        for (button, tip) in [(shareButton, "Share"), (trashButton, "Move to Trash"), (saveButton, "Save"), (openInPreview, isMovie ? "Open in QuickTime Player" : "Open in Preview")] {
            button.isBordered = false
            button.toolTip = tip
            button.contentTintColor = .labelColor
            button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        saveButton.isHidden = file != nil
        trashButton.isHidden = file == nil
        actions = png == nil ? nil : NSStackView(views: [shareButton, trashButton, saveButton, openInPreview])
        actions?.spacing = 6
        actions?.isHidden = true

        // The pill is a blur clipped to a capsule: NSVisualEffectView ignores its layer's corner mask for the blur, so `maskImage` (set in
        // `layoutCard`) rounds the blur and with it the window's shadow. The preview card is a plain layer clipped by its corner radius.
        card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer!.masksToBounds = true
        card.layer!.borderWidth = 1
        card.layer!.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        card.addSubview(row)
        if let actions { card.addSubview(actions) }
        let root = NSView()
        root.addSubview(card)
        if let preview { root.addSubview(preview) }
        root.addSubview(closeButton)

        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        root.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        contentView = root
        for (button, action) in [(closeButton, #selector(closeClicked)), (shareButton, #selector(shareClicked)), (trashButton, #selector(trashClicked)),
                                 (saveButton, #selector(saveClicked)), (openInPreview, #selector(openClicked))] {
            button.target = self
            button.action = action
        }
        layoutCard()
    }

    /// Sizes the pieces to their content and puts the window where the position setting says; run again after the text changes. The preview
    /// card sits above the pill, or below it at the top right.
    private func layoutCard() {
        let margin = Toast.margin
        row.frame.size = row.fittingSize
        let actionsSize = actions?.fittingSize ?? .zero
        let pill = CGSize(width: max(row.frame.width, actionsSize.width + 16), height: row.frame.height)
        let previewSize = preview?.frame.size ?? .zero
        let stacked = preview == nil ? 0 : previewSize.height + Toast.gap
        let size = CGSize(width: max(pill.width, previewSize.width), height: pill.height + stacked)
        let below = position == "topRight"
        card.frame = CGRect(origin: CGPoint(x: margin + ((size.width - pill.width) / 2).rounded(), y: margin + (below ? stacked : 0)), size: pill)
        card.layer!.cornerRadius = pill.height / 2
        card.maskImage = NSImage(size: pill, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return true
        }
        row.frame.origin = CGPoint(x: ((pill.width - row.frame.width) / 2).rounded(), y: 0)
        actions?.frame = CGRect(origin: CGPoint(x: ((pill.width - actionsSize.width) / 2).rounded(), y: ((pill.height - actionsSize.height) / 2).rounded()), size: actionsSize)
        preview?.frame.origin = CGPoint(x: margin + ((size.width - previewSize.width) / 2).rounded(), y: margin + (below ? 0 : pill.height + Toast.gap))
        let top = below ? card.frame : preview?.frame ?? card.frame
        closeButton.frame.origin = CGPoint(x: top.minX - closeButton.frame.width / 2 + 4, y: top.maxY - closeButton.frame.height / 2 - 4)
        let origin = switch position {
        case "bottomRight": NSPoint(x: screenArea.maxX - size.width - 20, y: screenArea.minY + 48)
        case "topRight": NSPoint(x: screenArea.maxX - size.width - 20, y: screenArea.maxY - size.height - 20)
        default: NSPoint(x: screenArea.midX - size.width / 2, y: screenArea.minY + 48)
        }
        setFrame(CGRect(x: origin.x - margin, y: origin.y - margin, width: size.width + 2 * margin, height: size.height + 2 * margin), display: true)
        invalidateShadow()
    }

    private func setHovering(_ hovering: Bool) {
        closeButton.isHidden = !hovering
        actions?.isHidden = !hovering
        if actions != nil { row.isHidden = hovering }
        invalidateShadow()
    }

    @objc private func closeClicked() { dismiss() }

    /// The saved file, or the capture written to a temporary one.
    private func fileOnDisk() -> URL {
        if file == nil {
            file = FileManager.default.temporaryDirectory.appending(path: "Snug.png")
            try! png!.write(to: file!)
        }
        return file!
    }

    /// Opens the file in Preview, or in QuickTime Player for a recording.
    @objc private func openClicked() {
        let url = fileOnDisk()
        guard !Toast.isSuppressed else { return }
        let app = url.pathExtension == "mov" ? "com.apple.QuickTimePlayerX" : "com.apple.Preview"
        NSWorkspace.shared.open([url], withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)!, configuration: NSWorkspace.OpenConfiguration())
        dismiss()
    }

    /// Shows the share menu from the button. The toast stays up while it is open, and closes once a service is chosen.
    @objc private func shareClicked() {
        let url = fileOnDisk()
        guard !Toast.isSuppressed else { return }
        sharing = true
        dismissal?.cancel()
        let picker = NSSharingServicePicker(items: [url])
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

    /// Saves to the save location as Cmd-S does (under a numbered name when the usual one is taken), then shows the saved state. A save
    /// that fails shows its reason in the toast and keeps the Save button.
    @objc private func saveClicked() {
        let url: URL
        do {
            url = try UniqueFile.write(png!, to: Output.defaultFile(defaults: defaults))
        } catch {
            message.stringValue = "Save failed"
            detail.stringValue = (error as NSError).localizedFailureReason ?? error.localizedDescription
            detail.isHidden = false
            message.sizeToFit()
            detail.sizeToFit()
            layoutCard()
            return
        }
        file = url
        reveals = true
        message.stringValue = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        detail.stringValue = url.lastPathComponent
        detail.isHidden = false
        message.sizeToFit()
        detail.sizeToFit()
        saveButton.isHidden = true
        trashButton.isHidden = false
        layoutCard()
    }

    override func mouseEntered(with event: NSEvent) {
        dismissal?.cancel()
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !sharing else { return }
        scheduleDismissal()
        setHovering(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        if reveals, let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let png, let start = dragStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        dragStart = nil
        reveals = false
        dismissal?.cancel()
        let item = NSDraggingItem(pasteboardWriter: fileOnDisk() as NSURL)
        item.setDraggingFrame((preview ?? card).frame, contents: NSImage(data: png))
        contentView!.beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dismiss() }
    }
}

extension Toast: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let chosen = service != nil
        MainActor.assumeIsolated {
            sharing = false
            if chosen { dismiss() } else { scheduleDismissal() }
        }
    }
}
