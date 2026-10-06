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
    static func show(png: Data? = nil, message: String, file: URL? = nil, color: NSColor? = nil) {
        guard !isSuppressed else { return }
        current?.orderOut(nil)
        let toast = Toast(png: png, message: message, file: file, color: color)
        current = toast
        toast.orderFrontRegardless()
        toast.dismissal = Task {
            try await Task.sleep(for: .seconds(2))
            toast.orderOut(nil)
            if current === toast { current = nil }
        }
    }

    private init(png: Data?, message: String, file: URL?, color: NSColor?) {
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

        let thumbnail: NSView
        if let color {
            thumbnail = NSView(frame: NSRect(x: 10, y: 8, width: 40, height: 40))
            thumbnail.wantsLayer = true
            thumbnail.layer!.backgroundColor = color.cgColor
            thumbnail.layer!.cornerRadius = 8
            thumbnail.layer!.borderWidth = 1
            thumbnail.layer!.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        } else {
            let image = NSImageView(image: NSImage(data: png!)!)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.frame = NSRect(x: 10, y: 8, width: 56, height: 40)
            thumbnail = image
        }
        let label = NSTextField(labelWithString: message)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: thumbnail.frame.maxX + 10, y: (56 - label.frame.height) / 2)
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: thumbnail.frame.maxX + 10 + label.frame.width + 14, height: 56))
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.addSubview(thumbnail)
        content.addSubview(label)
        contentView = content
        setContentSize(content.frame.size)
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
