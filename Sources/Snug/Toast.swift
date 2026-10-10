import AppKit

/// A small non-activating confirmation, with a thumbnail of the capture joined to the top of it when the preview is on. It goes away after 2 s
/// (4 s with a thumbnail) while the pointer is elsewhere, and stays while it is over the toast. Over it, a close button sits on the top-left
/// corner and, when it holds a capture, "Open in Preview" and "Save" appear. Drag it to drop the image; a saved toast reveals the file when clicked.
/// The capture is held only while the toast is visible: `dismiss` releases it.
@MainActor
final class Toast: NSPanel, NSDraggingSource {
    private static var current: Toast?
    /// Debug runs set this so scripted copies never put a toast on screen or open Preview.
    static var isSuppressed = false
    /// Transparent margin around the card, so the close button can hang off its corner.
    private static let margin: CGFloat = 10
    private(set) var png: Data?
    private(set) var file: URL?
    private var reveals: Bool
    private(set) var dismissal: Task<Void, any Error>?
    private var dragStart: NSPoint?
    let lifetime: Duration
    private var preview: NSView?
    private let defaults: UserDefaults
    private let screenArea: CGRect
    private let position: String
    let card: NSVisualEffectView
    private let row: NSStackView
    let message: NSTextField
    private let detail: NSTextField
    let closeButton: NSButton
    private let actions: NSStackView?
    let saveButton: NSButton
    let openInPreview: NSButton

    /// A color toast passes `color` instead of a PNG and shows a swatch in place of the thumbnail.
    static func show(png: Data? = nil, message: String, detail: String = "", file: URL? = nil, color: NSColor? = nil, defaults: UserDefaults = .standard) {
        guard !isSuppressed else { return }
        current?.dismiss()
        let toast = Toast(png: png, message: message, detail: detail, file: file, color: color, defaults: defaults)
        current = toast
        toast.orderFrontRegardless()
        toast.scheduleDismissal()
    }

    func scheduleDismissal() {
        dismissal?.cancel()
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

    init(png: Data?, message messageText: String, detail detailText: String, file: URL?, color: NSColor?, defaults: UserDefaults) {
        self.png = png
        self.file = file
        self.defaults = defaults
        reveals = file != nil
        let thumbnail = png.flatMap { defaults.bool(forKey: Pref.toastPreview) ? NSImage(data: $0) : nil }
        lifetime = thumbnail == nil ? .seconds(2) : .seconds(4)
        let fit = thumbnail.map { min(1, 240 / $0.size.width, 160 / $0.size.height) } ?? 1
        let previewSize = thumbnail.map { CGSize(width: ($0.size.width * fit).rounded(), height: ($0.size.height * fit).rounded()) } ?? .zero
        preview = thumbnail.map {
            let view = NSView(frame: CGRect(origin: .zero, size: previewSize))
            view.wantsLayer = true
            view.layer!.contents = $0
            view.layer!.contentsGravity = .resizeAspect
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
            let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
            check.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
            check.contentTintColor = .controlAccentColor
            check.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            mark = check
        }
        message = NSTextField(messageText, size: 13, weight: .semibold)
        detail = NSTextField(detailText, size: 12, mono: true, color: .secondaryLabelColor)
        detail.isHidden = detailText.isEmpty
        row = NSStackView(views: [mark, message, detail])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 16)

        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: nil, action: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0.2, alpha: 0.9)]))
        closeButton.isBordered = false
        closeButton.frame.size = CGSize(width: 22, height: 22)
        closeButton.isHidden = true
        openInPreview = NSButton(title: "Open in Preview", target: nil, action: nil)
        saveButton = NSButton(title: "Save", target: nil, action: nil)
        for button in [openInPreview, saveButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        saveButton.isHidden = file != nil
        actions = png == nil ? nil : NSStackView(views: [openInPreview, saveButton])
        actions?.spacing = 8
        if preview != nil {
            // A scrim keeps the buttons legible over the thumbnail.
            actions?.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            actions?.wantsLayer = true
            actions?.layer!.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            actions?.layer!.cornerRadius = 10
        }
        actions?.isHidden = true

        // One card: the thumbnail sits flush on top of the pill, and a single rounded, outlined clip gives the thumbnail its top corners and
        // the pill its bottom corners (a pill alone is fully rounded). NSVisualEffectView ignores its layer's corner mask for the blur, so
        // `maskImage` (set in `layoutCard`) rounds the blur and with it the window's shadow.
        card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer!.masksToBounds = true
        card.layer!.borderWidth = 1
        card.layer!.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        card.addSubview(row)
        if let preview { card.addSubview(preview) }
        if let actions { card.addSubview(actions) }
        let root = NSView()
        root.addSubview(card)
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
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        openInPreview.target = self
        openInPreview.action = #selector(openInPreviewClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        layoutCard()
    }

    /// Sizes the card to its content and puts the window where the position setting says; run again after the text changes.
    private func layoutCard() {
        let margin = Toast.margin
        row.frame.size = row.fittingSize
        let pill = row.frame.size
        let previewSize = preview?.frame.size ?? .zero
        let actionsSize = actions?.fittingSize ?? .zero
        let size = CGSize(width: max(pill.width, previewSize.width, actionsSize.width == 0 ? 0 : actionsSize.width + 16), height: pill.height + previewSize.height)
        card.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: size)
        card.layer!.cornerRadius = min(20, size.height / 2)
        card.maskImage = NSImage(size: size, flipped: false) { rect in
            let radius = min(20, rect.height / 2)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        row.frame.origin = CGPoint(x: ((size.width - pill.width) / 2).rounded(), y: 0)
        preview?.frame.origin = CGPoint(x: ((size.width - previewSize.width) / 2).rounded(), y: pill.height)
        // Over a thumbnail the actions float near its bottom edge; on a pill they replace the text while the pointer is over it.
        actions?.frame = CGRect(origin: CGPoint(x: ((size.width - actionsSize.width) / 2).rounded(), y: preview == nil ? ((pill.height - actionsSize.height) / 2).rounded() : pill.height + 8),
                                size: actionsSize)
        closeButton.frame.origin = CGPoint(x: margin - closeButton.frame.width / 2 + 4, y: margin + size.height - closeButton.frame.height / 2 - 4)
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
        if preview == nil, actions != nil { row.isHidden = hovering }
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

    @objc private func openInPreviewClicked() {
        let url = fileOnDisk()
        guard !Toast.isSuppressed else { return }
        NSWorkspace.shared.open([url], withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")!, configuration: NSWorkspace.OpenConfiguration())
        dismiss()
    }

    /// Saves to the save location as Cmd-S does, then shows the saved state.
    @objc private func saveClicked() {
        let url = Output.defaultFile(defaults: defaults)
        try! png!.write(to: url)
        file = url
        reveals = true
        message.stringValue = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        detail.stringValue = url.lastPathComponent
        detail.isHidden = false
        message.sizeToFit()
        detail.sizeToFit()
        saveButton.isHidden = true
        layoutCard()
    }

    override func mouseEntered(with event: NSEvent) {
        dismissal?.cancel()
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
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
        item.setDraggingFrame(preview.map { card.convert($0.frame, to: contentView!) } ?? card.frame, contents: NSImage(data: png))
        contentView!.beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dismiss() }
    }
}
