import AppKit

/// A small non-activating confirmation that fades after about two seconds.
/// Drag it to drop the image; a "Saved" toast reveals the file when clicked.
@MainActor
final class Toast: NSPanel, NSDraggingSource {
    private static var current: Toast?
    /// Debug runs set this so scripted copies never put a toast on screen.
    static var isSuppressed = false
    private let png: Data?
    private var file: URL?
    private var reveals: Bool
    private var dismissal: Task<Void, any Error>?
    private var dragStart: NSPoint?

    /// A color toast passes `color` instead of a PNG and shows a swatch in place of the thumbnail.
    static func show(png: Data? = nil, message: String, detail: String = "", file: URL? = nil, color: NSColor? = nil) {
        guard !isSuppressed else { return }
        current?.orderOut(nil)
        let toast = Toast(png: png, message: message, detail: detail, file: file, color: color)
        current = toast
        toast.orderFrontRegardless()
        toast.dismissal = Task {
            try await Task.sleep(for: .seconds(2))
            toast.orderOut(nil)
            if current === toast { current = nil }
        }
    }

    init(png: Data?, message: String, detail: String, file: URL?, color: NSColor?) {
        self.png = png
        self.file = file
        reveals = file != nil
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
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        row.frame.size = row.fittingSize
        let content = NSVisualEffectView(frame: row.frame)
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer!.cornerRadius = 20
        content.layer!.masksToBounds = true
        content.addSubview(row)
        let size = content.frame.size
        contentView = content
        setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.minY + 48))
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
        if file == nil {
            file = FileManager.default.temporaryDirectory.appending(path: "Snug.png")
            try! png.write(to: file!)
        }
        let item = NSDraggingItem(pasteboardWriter: file! as NSURL)
        item.setDraggingFrame(contentView!.bounds, contents: NSImage(data: png))
        contentView!.beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { orderOut(nil) }
    }
}
