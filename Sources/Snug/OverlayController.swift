import AppKit
import ScreenshotCore

@MainActor
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

/// Owns the overlay window and one capture session: selection state, key dispatch, snap, and cancellation.
@MainActor
final class OverlayController {
    enum Mode { case area, text, element }

    private enum Interaction {
        case none
        case drawing(AreaDrag)
        case resizing(Handle)
        case moving(last: CGPoint, moved: Bool)
    }

    let window = OverlayWindow()
    let view = OverlayView()
    var pasteboard = NSPasteboard.general
    var defaults = UserDefaults.standard
    var mode = Mode.area
    /// Debug runs drive the window with synthesized events; it stays transparent, below other apps' windows' level, and never takes focus.
    var isHeadless = false

    var selection: AreaSelection?
    private(set) var snapPreview: CGRect?
    private(set) var image: CGImage?
    private(set) var scale: CGFloat = 1
    private(set) var displayID: CGDirectDisplayID?
    /// Milliseconds spent opening the window and committing its first frame, from the last `present`.
    private(set) var lastOpenMilliseconds = 0.0
    private(set) var lastFirstDrawMilliseconds = 0.0
    /// The running debounce/snap or on-demand fit computation, if any.
    private(set) var snapTask: Task<Void, any Error>?
    /// The running encode and pasteboard/save work after a commit.
    private(set) var commitTask: Task<Void, Never>?

    private let bar = StyleBar()
    var extent = CGRect.zero
    var windows: [CGRect] = []
    var hoverWindow: CGRect?
    /// The last pointer position in image pixels.
    var pointer = CGPoint.zero
    var session: SelectionSession?
    var elementTask: Task<Void, Never>?
    var elementCandidates: [Candidate] = []
    var previousApp: NSRunningApplication?
    let modeBar = ModeBar()
    let helpPanel = InfoPanel()
    let listPanel = InfoPanel()
    private var interaction = Interaction.none
    private var snapSuggestions: [CGRect] = []
    private var bypassSnap = false
    private var hadSelection = false
    private var spaceHeld = false

    private var snapEnabled: Bool { defaults.bool(forKey: Pref.snap) }
    var style: OutputStyle {
        get { defaults.string(forKey: Pref.style).flatMap(OutputStyle.init(rawValue:)) ?? .tight }
        set {
            defaults.set(newValue.rawValue, forKey: Pref.style)
            refresh()
        }
    }

    init() {
        view.controller = self
        window.contentView = view
        bar.isHidden = true
        view.addSubview(bar)
        for panel in [modeBar, helpPanel, listPanel] { view.addSubview(panel) }
        modeBar.onMode = { [unowned self] in setMode($0) }
        bar.onStyle = { [unowned self] in style = $0 }
        bar.onSave = { [unowned self] in save() }
        bar.onCopy = { [unowned self] in copy() }
    }

    /// Shows the frozen image in the reused window. `frame` is in screen points.
    func present(image: CGImage, frame: CGRect, displayID: CGDirectDisplayID?) {
        cancelWork()
        let start = ContinuousClock.now
        let shown = signposter.beginInterval("overlay shown")
        self.image = image
        self.displayID = displayID
        scale = CGFloat(image.width) / frame.width
        extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        windows = []
        previousApp = displayID == nil || isHeadless ? nil : NSWorkspace.shared.frontmostApplication
        pointer = CGPoint(x: (NSEvent.mouseLocation.x - frame.minX) * scale, y: (frame.maxY - NSEvent.mouseLocation.y) * scale)
        view.scale = scale
        view.image = image
        window.setFrame(frame, display: false)
        if isHeadless {
            window.level = .normal
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        window.makeFirstResponder(view)
        signposter.endInterval("overlay shown", shown)
        let opened = ContinuousClock.now
        let draw = signposter.beginInterval("first draw")
        refresh()
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        signposter.endInterval("first draw", draw)
        lastOpenMilliseconds = start.duration(to: opened).milliseconds
        lastFirstDrawMilliseconds = opened.duration(to: .now).milliseconds
    }

    /// Supplies window rectangles (image pixels, front to back) once they are built.
    func setWindows(_ rects: [CGRect], pointer: CGPoint) {
        windows = rects
        if mode == .element { buildSession() }
        updateHover(pixel: CGPoint(x: (pointer.x - window.frame.minX) * scale, y: (window.frame.maxY - pointer.y) * scale))
    }

    /// Closes the overlay, cancels pending work, and releases the frozen image.
    func dismiss() {
        cancelWork()
        window.orderOut(nil)
        view.image = nil
        image = nil
        windows = []
        hoverWindow = nil
        selection = nil
        interaction = .none
        spaceHeld = false
        resetExtras()
        refresh()
    }

    func cancelWork() {
        snapTask?.cancel()
        snapTask = nil
        snapPreview = nil
        snapSuggestions = []
    }

    // MARK: Pointer

    func mouseMoved(_ event: NSEvent) {
        pointer = view.pixelPoint(event)
        updateHover(pixel: pointer)
        updateGuides()
    }

    private func updateHover(pixel: CGPoint) {
        if mode == .element { return elementHover(pixel: pixel) }
        guard selection == nil, case .none = interaction else { return }
        hoverWindow = windows.first { $0.contains(pixel) }
        refresh()
    }

    func mouseDown(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        hadSelection = selection != nil
        if let selection {
            if let handle = selection.handle(at: point, tolerance: 8 * scale) {
                interaction = .resizing(handle)
                return
            }
            if selection.rect.contains(point) {
                interaction = .moving(last: point, moved: false)
                return
            }
        }
        selection = nil
        cancelWork()
        bypassSnap = event.modifierFlags.contains(.option)
        interaction = .drawing(AreaDrag(extent: extent, origin: point))
        refresh()
    }

    func mouseDragged(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        pointer = point
        switch interaction {
        case .none:
            break
        case .drawing(var drag):
            drag.update(to: point, moving: spaceHeld)
            interaction = .drawing(drag)
            scheduleSnap(for: drag.rect)
        case .resizing(let handle):
            selection?.resize(handle, to: point)
        case .moving(let last, _):
            selection?.move(by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            interaction = .moving(last: point, moved: true)
        }
        refresh()
    }

    func mouseUp(_ event: NSEvent) {
        let point = view.pixelPoint(event)
        let finished = interaction
        interaction = .none
        switch finished {
        case .none, .resizing:
            break
        case .moving(_, let moved):
            if !moved { copy() }
        case .drawing(var drag):
            drag.update(to: point, moving: false)
            let rect = drag.rect
            if rect.width < AreaSelection.minimumSize || rect.height < AreaSelection.minimumSize {
                cancelWork()
                if !hadSelection, let hoverWindow { finish(crop: hoverWindow, copy: true, save: afterCaptureSaves) }
            } else {
                release(rect)
            }
        }
        refresh()
    }

    private func release(_ rect: CGRect) {
        snapTask?.cancel()
        let suggestions = snapPreview == nil ? [] : snapSuggestions
        selection = AreaSelection(extent: extent, exact: rect, suggestions: suggestions, takingFirst: !suggestions.isEmpty)
        snapPreview = nil
        snapSuggestions = []
    }

    // MARK: Snap

    /// Waits for a pause, then previews the snap. Keeps the previous preview while the drag stays in its search band.
    private func scheduleSnap(for rough: CGRect) {
        snapTask?.cancel()
        guard snapEnabled, !bypassSnap, let image else { return }
        if let snapPreview, !AreaSelection.preview(snapPreview, stillFits: rough) {
            self.snapPreview = nil
            snapSuggestions = []
        }
        snapTask = Task {
            try await Task.sleep(for: .milliseconds(80))
            let id = signposter.beginInterval("snap")
            let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)
            signposter.endInterval("snap", id)
            try Task.checkCancellation()
            snapSuggestions = suggestions.map(\.bounds)
            snapPreview = snapSuggestions.first
            refresh()
        }
    }

    /// Tab: the next fit. After a quick drag with no suggestions, computes them for the current rectangle first.
    private func cycleFit(backward: Bool) {
        guard var current = selection, let image else { return }
        guard current.fits.count == 1 else {
            current.cycle(backward: backward)
            selection = current
            return
        }
        let rough = current.rect
        snapTask?.cancel()
        snapTask = Task {
            let suggestions = try await SmartSnap().suggest(in: image, roughBounds: rough)
            try Task.checkCancellation()
            guard selection?.rect == rough else { return }
            selection?.setSuggestions(suggestions.map(\.bounds))
            selection?.cycle(backward: backward)
            refresh()
        }
    }

    // MARK: Keys

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    /// The single key dispatch point; each mode routes its own keys.
    func handleKey(_ event: NSEvent) -> Bool {
        var handled = handleExtrasKey(event)
        if !handled {
            switch mode {
            case .area: handled = handleAreaKey(event)
            case .text: handled = false
            case .element: handled = handleElementKey(event)
            }
        }
        refresh()
        return handled
    }

    func handleAreaKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch (event.keyCode, command, event.charactersIgnoringModifiers ?? "") {
        case (53, _, _): dismiss()
        case (36, _, _), (76, _, _): copy()
        case (48, _, _): cycleFit(backward: event.modifierFlags.contains(.shift))
        case (49, _, _): spaceHeld = true
        case (123, _, _): selection?.move(by: CGPoint(x: -step * scale, y: 0))
        case (124, _, _): selection?.move(by: CGPoint(x: step * scale, y: 0))
        case (125, _, _): selection?.move(by: CGPoint(x: 0, y: step * scale))
        case (126, _, _): selection?.move(by: CGPoint(x: 0, y: -step * scale))
        case (_, true, "s"): save()
        case (_, true, "1"): style = .tight
        case (_, true, "2"): style = .margin
        case (_, true, "3"): style = .backdrop
        case (_, false, "m"): style = style.next
        case (_, false, "s"): defaults.set(!snapEnabled, forKey: Pref.snap)
        case (_, false, "f"):
            cancelWork()
            selection = AreaSelection(extent: extent, exact: extent)
        default: return false
        }
        return true
    }

    // MARK: Output

    private var afterCaptureSaves: Bool { defaults.string(forKey: Pref.afterCapture) == "copyAndSave" }

    func copy() {
        guard let rect = selection?.rect else { return }
        finish(crop: rect, copy: true, save: afterCaptureSaves)
    }

    func save() {
        guard let rect = selection?.rect else { return }
        finish(crop: rect, copy: false, save: true)
    }

    /// Closes the overlay first, then encodes off main and delivers.
    private func finish(crop: CGRect, copy: Bool, save: Bool) {
        guard let image else { return }
        let style = style, scale = scale
        if let displayID {
            let area = [Double(displayID)] + [crop.minX, crop.minY, crop.width, crop.height].map { Double($0 / scale) }
            defaults.set(area, forKey: Pref.lastArea)
        }
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                try await Output.deliver(image, crop: crop, style: style, scale: scale, copy: copy, save: save,
                                         pasteboard: pasteboard, defaults: defaults)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    // MARK: Drawing

    func refresh() {
        var overlays = OverlayView.Overlays()
        if case .drawing(let drag) = interaction, drag.rect.width > 0 || drag.rect.height > 0 { overlays.ghost = drag.rect }
        overlays.preview = snapPreview
        overlays.selection = selection?.rect
        overlays.showsHandles = selection != nil
        if selection == nil, case .none = interaction { overlays.hover = hoverWindow }
        if let rect = selection?.rect, style != .tight { overlays.styleFrame = style.frame(around: rect, in: extent, scale: scale) }
        view.overlays = overlays
        refreshExtras()

        bar.isHidden = selection == nil
        guard let rect = selection?.rect else { return }
        bar.style = style
        let box = view.viewRect(rect)
        let x = min(max(box.midX - bar.frame.width / 2, 8), view.bounds.width - bar.frame.width - 8)
        let below = box.minY - bar.frame.height - 10
        bar.frame.origin = CGPoint(x: x, y: below >= 8 ? below : min(box.maxY + 10, view.bounds.height - bar.frame.height - 8))
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
