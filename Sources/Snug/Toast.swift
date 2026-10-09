import AppKit

/// A small non-activating confirmation, with a thumbnail of the capture above it when the preview is on. It goes away after 2 s
/// (4 s with a thumbnail) while the pointer is elsewhere, and stays while it is over the toast.
/// Drag it to drop the image; a "Saved" toast reveals the file when clicked.
@MainActor
final class Toast: NSPanel, NSDraggingSource {
    private static var current: Toast?
    /// Debug runs set this so scripted copies never put a toast on screen.
    static var isSuppressed = false
    private let png: Data?
    private var file: URL?
    private var reveals: Bool
    private(set) var dismissal: Task<Void, any Error>?
    private var dragStart: NSPoint?
    let lifetime: Duration
    private let preview: NSView?

    /// A color toast passes `color` instead of a PNG and shows a swatch in place of the thumbnail.
    static func show(png: Data? = nil, message: String, detail: String = "", file: URL? = nil, color: NSColor? = nil, defaults: UserDefaults = .standard) {
        guard !isSuppressed else { return }
        current?.orderOut(nil)
        let toast = Toast(png: png, message: message, detail: detail, file: file, color: color, defaults: defaults)
        current = toast
        toast.orderFrontRegardless()
        toast.scheduleDismissal()
    }

    func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task {
            try await Task.sleep(for: lifetime)
            orderOut(nil)
            if Toast.current === self { Toast.current = nil }
        }
    }

    init(png: Data?, message: String, detail: String, file: URL?, color: NSColor?, defaults: UserDefaults) {
        self.png = png
        self.file = file
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
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

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
        let texts = [NSTextField(message, size: 13, weight: .semibold)]
            + (detail.isEmpty ? [] : [NSTextField(detail, size: 12, mono: true, color: .secondaryLabelColor)])
        let row = NSStackView(views: [mark] + texts)
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 16)
        row.frame.size = row.fittingSize
        let content = NSVisualEffectView(frame: row.frame)
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer!.cornerRadius = 20
        content.layer!.masksToBounds = true
        content.addSubview(row)
        // The capture's thumbnail sits above the pill; its own transparent corners give it the capture's rounding.
        let gap: CGFloat = preview == nil ? 0 : 8
        let size = CGSize(width: max(content.frame.width, previewSize.width), height: content.frame.height + gap + previewSize.height)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        content.frame.origin = CGPoint(x: ((size.width - content.frame.width) / 2).rounded(), y: 0)
        container.addSubview(content)
        if let preview {
            preview.frame.origin = CGPoint(x: ((size.width - previewSize.width) / 2).rounded(), y: content.frame.height + gap)
            container.addSubview(preview)
        }
        container.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        contentView = container
        setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let origin = switch defaults.string(forKey: Pref.toastPosition)! {
        case "bottomRight": NSPoint(x: visible.maxX - frame.width - 20, y: visible.minY + 48)
        case "topRight": NSPoint(x: visible.maxX - frame.width - 20, y: visible.maxY - frame.height - 20)
        default: NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 48)
        }
        setFrameOrigin(origin)
    }

    override func mouseEntered(with event: NSEvent) { dismissal?.cancel() }
    override func mouseExited(with event: NSEvent) { scheduleDismissal() }

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
        if file == nil {
            file = FileManager.default.temporaryDirectory.appending(path: "Snug.png")
            try! png.write(to: file!)
        }
        let item = NSDraggingItem(pasteboardWriter: file! as NSURL)
        item.setDraggingFrame(preview?.frame ?? contentView!.bounds, contents: NSImage(data: png))
        contentView!.beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { orderOut(nil) }
    }
}
