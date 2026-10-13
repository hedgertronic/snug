import AppKit
import ScreenshotCore
import Translation

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

    /// Text mode: where the current press landed and the word (or, after a double or triple click, the word or line) it anchors.
    var textPress: (point: CGPoint, anchor: Range<String.Index>?)?

    override func sendEvent(_ event: NSEvent) {
        guard !(contentView as! OverlayView).liveText.isHidden, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else {
            return super.sendEvent(event)
        }
        sendTextMouse(event)
    }
}

/// Owns the overlay window and one capture session: selection state, key dispatch, snap, and cancellation.
@MainActor
final class OverlayController {
    enum Mode { case capture, text }

    private enum Interaction {
        case none
        case drawing(AreaDrag)
        case resizing(Handle, start: CGRect)
        case moving(last: CGPoint, origin: CGPoint, moved: Bool)
        case rounding(Handle, start: CGPoint, from: CornerRadii)
    }

    let window = OverlayWindow()
    let view = OverlayView()
    var pasteboard = NSPasteboard.general
    var defaults = UserDefaults.standard
    var mode = Mode.capture
    /// Debug runs drive the window with synthesized events; it stays transparent, below other apps' windows' level, and never takes focus.
    var isHeadless = false

    /// The system alert for a key that can't act here; silent in debug runs, which hit these paths on purpose.
    func beep() { if !isHeadless { NSSound.beep() } }

    var selection: AreaSelection?
    /// The rectangle a drag is changing right now: the one being drawn, or the selection being resized or moved.
    var draggedRect: CGRect? {
        switch interaction {
        case .drawing(let drag) where drag.rect.width > 0 || drag.rect.height > 0: drag.rect
        case .resizing, .moving: selection?.rect
        default: nil
        }
    }
    private(set) var snapPreview: CGRect?
    private(set) var image: CGImage?
    private(set) var scale: CGFloat = 1
    /// The capture shrunk by its point-to-pixel scale, built once per capture off main. Hover geometry analysis uses this and
    /// multiplies results by `scale`, which maps them back to full-resolution pixels. Corner radii stay at full resolution:
    /// measured on the half-size copy they disagreed with the full-size value by more than 2 px for 23 of 85 rects.
    private var smallImage: Task<CGImage, Never>?
    private(set) var displayID: CGDirectDisplayID?
    /// Milliseconds spent opening the window and committing its first frame, from the last `present`.
    private(set) var lastOpenMilliseconds = 0.0
    private(set) var lastFirstDrawMilliseconds = 0.0
    /// The running debounce/snap or on-demand fit computation, if any.
    private(set) var snapTask: Task<Void, any Error>?
    /// The running encode and pasteboard/save work after a commit.
    var commitTask: Task<Void, Never>?
    /// The reading pill and notice, and the running text analysis, OCR, or translation.
    var text = TextSession()
    var textTask: Task<Void, Never>?
    /// Milliseconds the last Live Text analysis took, from the start of the analysis to the result.
    var lastLiveTextMilliseconds = 0.0
    /// Option-Return: the language to translate into, the installed-pair check, and the translation; debug runs replace them.
    var targetLanguage = Locale.current.language
    var translationStatus: (Locale.Language, Locale.Language) async -> LanguageAvailability.Status = { await LanguageAvailability().status(from: $0, to: $1) }
    var translate: (String, Locale.Language, Locale.Language) async throws -> String = {
        try await TranslationSession(installedSource: $1, target: $2).translate($0).targetText
    }
    /// Text mode's Cmd-Return on a picked item; debug runs record the URL instead.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    let chrome = Chrome()
    /// Points at the top of the screen the camera housing covers; chrome stays below it.
    var topInset: CGFloat = 0
    var extent = CGRect.zero
    var windows: [CGRect] = []
    var windowNames: [String] = []
    var windowIDs: [CGWindowID] = []
    /// Per window: a Dock, menu bar, or menu target, cropped from the frozen image instead of captured as a window.
    var windowFrozen: [Bool] = []
    /// Option is held: a window click inverts the shadow preference.
    var optionHeld = false
    /// Command is held: the hint key caps for it fill with the accent.
    var commandHeld = false
    /// Corner radius in pixels of each snap fit, settled selection, and hovered rectangle, measured once per rectangle.
    /// A rectangle that is not here (one being resized, or still being measured) has square corners.
    var radii: [CGRect: CGFloat] = [:]
    /// The arc each corner of a measured rectangle follows (0 where none): a corner takes its own arc where the corners agree on no
    /// radius, and inside a window's corner, ahead of the window's arc.
    var arcs: [CGRect: CornerRadii] = [:]
    var radiusTasks: [CGRect: Task<(radius: CGFloat, arcs: CornerRadii), Never>] = [:]
    /// Per-corner radii set with `[`, `]`, the corner dots, and E, by rectangle; they replace the measured ones.
    var editedRadii: [CGRect: CornerRadii] = [:]
    /// The size pill's text while a radius edit is fresh, e.g. "r 12".
    var radiusReadout: String?
    /// The corner a dot drag last changed; `=` copies its radius to the other corners.
    var lastEditedCorner: Handle?
    /// The corner whose dot the pointer is on (or whose chip it is heading to), and its "All corners" chip.
    var hoveredCorner: Handle?
    let cornerChip = BarButton("All corners", key: "=", height: 23, size: 11)
    /// The selection's locked aspect ratio, width over height, set with Shift-P or a preset from P's menu; nil is free. Handle drags,
    /// grow and shrink keep it. A fresh drag or closing the overlay drops it.
    var lockedRatio: CGFloat?
    /// Whether the selection's ratio is locked, for the ratio chip's lock icon.
    var ratioLocked: Bool { lockedRatio != nil }
    /// The selection before the first pick from P's menu and the rectangle the last pick conformed it to: each pick conforms the
    /// rectangle from before the first, so picking 1:1 does not shrink the 16:9 that follows.
    var ratioBase: (base: CGRect, conformed: CGRect)?
    /// The menu's Portrait item: tall presets. Nil follows the selection's shape.
    var ratioPortrait: Bool?
    /// The hovered level was walked to with Up, Down or Tab (not picked from the list); it lets go after 4 pt of pointer travel.
    private var walkedLevel = false
    /// The ratio of the rectangle being dragged or selected, with the nearest standard (see `RatioLock.readout`); empty with neither.
    var ratioReadout: String {
        (draggedRect ?? selection?.rect).map { RatioLock.readout(for: $0.size) } ?? ""
    }
    /// Shift is down: with a selection open, the element under the pointer is outlined for a union.
    var shiftHeld = false
    /// Save As: the file to write, given the usual name in the save folder; nil cancels. Debug runs answer without a panel.
    var chooseSaveURL: (URL) -> URL? = { suggested in
        NSApp.activate()
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }
    var radiusReadoutTask: Task<Void, Error>?
    /// The last pointer position in image pixels.
    var pointer = CGPoint.zero
    /// Capture mode: what the pointer is over (accessibility elements, pixel geometry, windows, the display), and the running geometry analysis.
    var session: SelectionSession?
    var detectionTask: Task<Void, Never>?
    var detected: [Candidate] = []
    /// The Dock's icon tiles read from the frozen image, labeled by the Dock's item titles.
    var dockTiles: [Candidate] = []
    /// The running accessibility lookup and when the last one started (throttle).
    var accessibilityTask: Task<Void, Error>?
    var accessibilityStarted: ContinuousClock.Instant?
    var previousApp: NSRunningApplication?
    /// Esc as a global hot key while the overlay is up (never in debug runs): Snug may not be active, as when the shortcut opened the
    /// overlay over another app's open menu, and then a plain Esc would go to that app. A press reaches the overlay as its Esc key.
    private var escape: HotKey?
    private var interaction = Interaction.none
    private var snapSuggestions: [CGRect] = []
    /// Debug runs replace the accessibility lookup behind snap fits and edges with synthetic frames (image pixels).
    var snapFrameSource: ((CGRect) async -> [CGRect])?
    /// While a side drags: accessibility frames around the selection, the lookup filling them, and the sides snapped to
    /// (zero-width or zero-height rectangles, image pixels).
    private var edgeFrames: [CGRect] = []
    private var edgeFramesTask: Task<Void, Error>?
    private var snappedEdges: [CGRect] = []
    var bypassSnap = false
    private var hadSelection = false
    var spaceHeld = false
    /// Scrolling capture (G): the area in image pixels, the stitched height so far, the stitcher, and the loop capturing the area.
    /// Debug runs replace the live frame source.
    var scrollArea: CGRect?
    var scrollHeight = 0
    var stitcher: ScrollStitcher?
    var scrollTask: Task<Void, Never>?
    var scrollFrames: ((CGRect) async throws -> CGImage)?
    /// V armed recording of the selection (see `OverlayController+Recording.swift`).
    var armedRecording: ArmedRecording?
    /// K's cut-out preview while it is open.
    var cutout: CutoutPreview?

    var snapEnabled: Bool { defaults.bool(forKey: Pref.snap) }
    var framed: Bool { defaults.bool(forKey: Pref.frame) }

    init() {
        view.controller = self
        view.liveText.delegate = self
        window.contentView = view
        chrome.all.forEach(view.addSubview)
        cornerChip.isHidden = true
        cornerChip.style(fill: NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.86), text: .white)
        cornerChip.onClick = { [unowned self] in applyRadiusToAll() }
        view.addSubview(cornerChip)
        chrome.bottomBar.onMode = { [unowned self] in setMode($0) }
        chrome.bottomBar.onToggle = { [unowned self] in
            if $0 == Pref.snap { return toggleSnap() }
            defaults.set(!defaults.bool(forKey: $0), forKey: $0)
            refresh()
        }
        chrome.actionBar.onFrame = { [unowned self] in toggleFrame() }
        chrome.actionBar.onSnap = { [unowned self] in toggleSnap() }
        chrome.actionBar.roundedButton.onClick = { [unowned self] in chrome.bottomBar.onToggle(Pref.roundCorners) }
        chrome.actionBar.shadowButton.onClick = { [unowned self] in chrome.bottomBar.onToggle(Pref.shadow) }
        chrome.textButton.button.onClick = { [unowned self] in copySelectionText(translating: false) }
        chrome.actionBar.onSave = { [unowned self] in save() }
        chrome.actionBar.onCopy = { [unowned self] in copy() }
        chrome.actionBar.record.onClick = { [unowned self] in armRecording() }
        chrome.actionBar.scroll.onClick = { [unowned self] in startScroll() }
        chrome.actionBar.cutout.onClick = { [unowned self] in cutOut() }
    }

    static let resizeCursors: [Handle: NSCursor] = [
        .topLeft: .frameResize(position: .topLeft, directions: .all), .top: .frameResize(position: .top, directions: .all),
        .topRight: .frameResize(position: .topRight, directions: .all), .right: .frameResize(position: .right, directions: .all),
        .bottomRight: .frameResize(position: .bottomRight, directions: .all), .bottom: .frameResize(position: .bottom, directions: .all),
        .bottomLeft: .frameResize(position: .bottomLeft, directions: .all), .left: .frameResize(position: .left, directions: .all)
    ]

    /// Shows the frozen image in the reused window. `frame` is in screen points.
    func present(image: CGImage, frame: CGRect, displayID: CGDirectDisplayID?) {
        cancelWork()
        view.liveText.analysis = nil
        smallImage = nil
        detectionTask?.cancel()
        detected = []
        dockTiles = []
        accessibilityTask?.cancel()
        let start = ContinuousClock.now
        let shown = signposter.beginInterval("overlay shown")
        self.image = image
        self.displayID = displayID
        scale = CGFloat(image.width) / frame.width
        extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        windows = []
        windowNames = []
        windowIDs = []
        windowFrozen = []
        topInset = NSScreen.screens.first { $0.frame == frame }?.safeAreaInsets.top ?? 0
        previousApp = displayID == nil || isHeadless ? nil : NSWorkspace.shared.frontmostApplication
        pointer = CGPoint(x: (NSEvent.mouseLocation.x - frame.minX) * scale, y: (frame.maxY - NSEvent.mouseLocation.y) * scale)
        view.scale = scale
        view.highlight = Highlight(defaults: defaults)
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
            if escape == nil {
                escape = HotKey(id: 2) { [unowned self] in
                    window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                                      charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
                }
            }
            do {
                try escape!.register(keyCode: 53, modifiers: [])
            } catch {
                return report(error)
            }
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
        if mode == .capture { startHover() } else { startLiveText() }
    }

    /// Supplies window rectangles (image pixels, front to back) once they are built.
    func setWindows(_ rects: [CGRect], names: [String] = [], ids: [CGWindowID] = [], frozen: [Bool] = [], pointer: CGPoint) {
        windows = rects
        windowNames = names
        windowIDs = ids
        windowFrozen = frozen
        if mode == .capture { buildSession() }
        updateHover(pixel: CGPoint(x: (pointer.x - window.frame.minX) * scale, y: (window.frame.maxY - pointer.y) * scale))
    }

    /// Closes the overlay, cancels pending work, and releases the frozen image.
    func dismiss() {
        cancelWork()
        disarmRecording()
        scrollTask?.cancel()
        scrollTask = nil
        scrollArea = nil
        scrollHeight = 0
        stitcher = nil
        window.isOpaque = true
        window.backgroundColor = .black
        if !isHeadless { window.ignoresMouseEvents = false }
        view.liveText.analysis = nil
        smallImage = nil
        window.orderOut(nil)
        escape?.unregister()
        view.image = nil
        image = nil
        windows = []
        windowNames = []
        windowIDs = []
        windowFrozen = []
        radii = [:]
        arcs = [:]
        radiusTasks = [:]
        editedRadii = [:]
        radiusReadoutTask?.cancel()
        radiusReadout = nil
        lastEditedCorner = nil
        hoveredCorner = nil
        lockedRatio = nil
        ratioBase = nil
        ratioPortrait = nil
        chrome.ratioMenu.isHidden = true
        walkedLevel = false
        selection = nil
        interaction = .none
        spaceHeld = false
        resetExtras()
        snappedEdges = []
        edgeFramesTask?.cancel()
        view.cursor = .crosshair
        refresh()
    }

    func cancelWork() {
        textTask?.cancel()
        textTask = nil
        text = TextSession()
        closeCutout()
        snapTask?.cancel()
        snapTask = nil
        snapPreview = nil
        snapSuggestions = []
    }

    // MARK: Pointer

    func flagsChanged(_ event: NSEvent) {
        optionHeld = event.modifierFlags.contains(.option)
        commandHeld = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if shift != shiftHeld, image != nil {
            shiftHeld = shift
            updateHover(pixel: pointer)
        }
        refresh()
    }

    func mouseMoved(_ event: NSEvent) {
        guard image != nil, armedRecording == nil else { return }
        optionHeld = event.modifierFlags.contains(.option)
        commandHeld = event.modifierFlags.contains(.command)
        shiftHeld = event.modifierFlags.contains(.shift)
        let wasInside = selection?.rect.contains(pointer)
        pointer = view.pixelPoint(event)
        // The edge keys show while the pointer is inside a released selection.
        if selection?.rect.contains(pointer) != wasInside { refresh() }
        updateHoveredCorner()
        updateHover(pixel: pointer)
        updateGuides()
        updateCursor()
    }

    /// Resize cursors on handles and edges, an open hand inside the selection, a closed hand while moving, the crosshair elsewhere;
    /// in Text mode, the I-beam over text and the arrow elsewhere.
    /// Headless runs record the choice on the view but leave the system cursor alone.
    private func updateCursor() {
        guard window.isVisible else { return }
        let cursor: NSCursor
        switch interaction {
        case .resizing(let handle, _): cursor = Self.resizeCursors[handle]!
        case .moving: cursor = .closedHand
        case .rounding: cursor = .pointingHand
        case .drawing: cursor = .crosshair
        case .none where mode == .text:
            // Live Text takes points from the top-left corner (measured), not the view's bottom-left.
            cursor = view.liveText.hasText(at: CGPoint(x: pointer.x / scale, y: pointer.y / scale)) ? .iBeam : .arrow
        case .none:
            if let selection {
                cursor = cornerDot(at: pointer) != nil ? .pointingHand : selection.handle(at: pointer, tolerance: 8 * scale).map { Self.resizeCursors[$0]! }
                    ?? (selection.rect.contains(pointer) ? .openHand : .crosshair)
            } else {
                cursor = .crosshair
            }
        }
        view.cursor = cursor
        if !isHeadless { cursor.set() }
    }

    /// Capture mode: the pointer picks the element, window, or display under it. A level picked with a key holds until the pointer leaves
    /// it; one walked to with Up, Down or Tab also lets go once the pointer moves more than 4 pt from where the walk began (the session's
    /// anchor stops following the pointer while a level holds).
    private func updateHover(pixel: CGPoint) {
        guard case .none = interaction else { return }
        guard selection == nil || shiftHeld else {
            if view.overlays.hover != nil { refresh() }
            return
        }
        if mode == .capture, session != nil {
            requestAccessibility(at: pixel)
            let walkLetGo = walkedLevel && hypot(pixel.x - session!.anchor.x, pixel.y - session!.anchor.y) > 4 * scale
            if session!.isLocked, !session!.holds(at: pixel) || walkLetGo { session!.toggleLock() }
            if !session!.isLocked { walkedLevel = false }
            session!.hover(at: pixel)
        }
        refresh()
    }

    /// The rectangle a click would capture. The full display shows once a key has walked out to it or the pointer is at the screen edge.
    var hoverRect: CGRect? {
        guard mode == .capture, let session, let selected = session.selected,
              selected.kind != .display || session.isLocked || session.anchorAtEdge else { return nil }
        return selected.bounds
    }

    func mouseDown(_ event: NSEvent) {
        guard mode == .capture, armedRecording == nil else { return }
        let point = view.pixelPoint(event)
        pointer = point
        if cornerDot(at: point) == nil { hoveredCorner = nil }
        hadSelection = selection != nil
        shiftHeld = event.modifierFlags.contains(.shift)
        if let selection {
            if let corner = cornerDot(at: point) {
                interaction = .rounding(corner, start: point, from: cornerRadii(of: selection.rect))
                measureRadius(selection.rect)
                measureRadius(container(of: selection.rect))
                return updateCursor()
            }
            if let handle = selection.handle(at: point, tolerance: 8 * scale) {
                interaction = .resizing(handle, start: selection.rect)
                edgeFrames = []
                edgeFramesTask?.cancel()
                edgeFramesTask = Task { edgeFrames = try await snapFrames(around: selection.rect) }
                return updateCursor()
            }
            if shiftHeld {
                updateHover(pixel: point)
                if let hovered = hoverRect, !selection.rect.contains(point) { return growSelection(toInclude: hovered) }
            }
            if selection.rect.contains(point) {
                interaction = .moving(last: point, origin: point, moved: false)
                return updateCursor()
            }
        } else if shiftHeld {
            updateHover(pixel: point)
            if let hovered = hoverRect { return openAsSelection(hovered) }
        }
        selection = nil
        lockedRatio = nil
        ratioBase = nil
        ratioPortrait = nil
        cancelWork()
        bypassSnap = event.modifierFlags.contains(.option)
        interaction = .drawing(AreaDrag(extent: extent, origin: point))
        updateCursor()
        refresh()
    }

    func mouseDragged(_ event: NSEvent) {
        guard mode == .capture else { return }
        let point = view.pixelPoint(event)
        pointer = point
        switch interaction {
        case .none:
            break
        case .drawing(var drag):
            drag.update(to: point, moving: spaceHeld, axisLocked: event.modifierFlags.contains(.shift))
            interaction = .drawing(drag)
            scheduleSnap(for: drag.rect)
        case .resizing(let handle, let start):
            let old = selection!.rect
            let ratio = lockedRatio ?? (event.modifierFlags.contains(.shift) ? start.width / start.height : nil)
            snapResize(handle, to: point, exact: event.modifierFlags.contains(.option), ratio: ratio)
            carryRadii(from: old)
        case .moving(let last, let origin, _):
            let old = selection!.rect
            var target = point
            if event.modifierFlags.contains(.shift) {
                if abs(point.x - origin.x) >= abs(point.y - origin.y) { target.y = origin.y } else { target.x = origin.x }
            }
            selection?.move(by: CGPoint(x: target.x - last.x, y: target.y - last.y))
            carryRadii(from: old)
            interaction = .moving(last: target, origin: origin, moved: true)
        case .rounding(let corner, let start, let from):
            let rect = selection!.rect
            var delta = CornerRadii.inwardDistance(of: CGPoint(x: point.x - start.x, y: point.y - start.y), from: corner)
            // With Snap on, the dragged corner snaps to the radius detected under it when it ends within 3 pt of that radius.
            if snapEnabled, let detected = detectedRadius(corner, of: rect), abs(from[corner] + delta - detected) <= 3 * scale {
                delta = detected - from[corner]
            }
            let radii = from.moving(corner, by: delta, alone: event.modifierFlags.contains(.option), in: rect.size)
            editedRadii[rect] = radii
            lastEditedCorner = corner
            showRadiusReadout(radii)
        }
        updateCursor()
        refresh()
    }

    /// Moves the sides a handle controls to the pointer. Each snaps to the nearest pixel edge or accessibility edge
    /// within the band, unless snap is off, Option is held, or a `ratio` is kept (snapping fights a fixed ratio).
    private func snapResize(_ handle: Handle, to point: CGPoint, exact: Bool, ratio: CGFloat?) {
        guard let image, let rect = selection?.rect else { return }
        var target = point
        var snapped = (x: false, y: false)
        if snapEnabled, !exact, ratio == nil {
            for vertical in [true, false] where vertical ? handle.movesLeft || handle.movesRight : handle.movesTop || handle.movesBottom {
                let value = vertical ? point.x : point.y
                let band = SmartSnap.band(side: vertical ? rect.width : rect.height, scale: scale)
                // Cancellation is the only error here and a drag event is never cancelled.
                let pixel = try! SmartSnap().edges(in: image, of: rect, vertical: vertical, near: value, band: band)
                guard let edge = SnapFits.edge(near: value, band: CGFloat(band), frames: edgeFrames, pixel: pixel, vertical: vertical) else { continue }
                if vertical { target.x = edge; snapped.x = true } else { target.y = edge; snapped.y = true }
            }
        }
        selection?.resize(handle, to: target, ratio: ratio)
        let resized = selection!.rect
        snappedEdges = []
        if snapped.x {
            snappedEdges.append(CGRect(x: handle.movesLeft ? resized.minX : resized.maxX, y: resized.minY, width: 0, height: resized.height))
        }
        if snapped.y {
            snappedEdges.append(CGRect(x: resized.minX, y: handle.movesTop ? resized.minY : resized.maxY, width: resized.width, height: 0))
        }
    }

    func mouseUp(_ event: NSEvent) {
        guard mode == .capture else { return }
        let point = view.pixelPoint(event)
        pointer = point
        let finished = interaction
        interaction = .none
        snappedEdges = []
        edgeFramesTask?.cancel()
        switch finished {
        case .none, .resizing, .rounding:
            break
        case .moving(_, _, let moved):
            if !moved {
                // Shift-click inside the selection still grows it to the element under the pointer; Shift-drag there moves it.
                if event.modifierFlags.contains(.shift), let hovered = hoverRect { growSelection(toInclude: hovered) } else { copy() }
            }
        case .drawing(var drag):
            drag.update(to: point, moving: false)
            let rect = drag.rect
            if rect.width < AreaSelection.minimumSize || rect.height < AreaSelection.minimumSize {
                cancelWork()
                if !hadSelection { clickHover(shadow: windowShadow(option: event.modifierFlags.contains(.option)), copy: true, save: afterCaptureSaves) }
            } else {
                release(rect)
            }
        }
        updateCursor()
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
        guard snapEnabled, !bypassSnap, let image else {
            snapPreview = nil
            snapSuggestions = []
            return
        }
        if let snapPreview, !AreaSelection.preview(snapPreview, stillFits: rough, scale: scale) {
            self.snapPreview = nil
            snapSuggestions = []
        }
        snapTask = Task {
            try await Task.sleep(for: .milliseconds(80))
            let id = signposter.beginInterval("snap")
            let suggestions = try await fits(for: rough, in: image)
            signposter.endInterval("snap", id)
            try Task.checkCancellation()
            snapSuggestions = suggestions
            snapPreview = snapSuggestions.first
            refresh()
        }
    }

    /// Pixel fits for a rough drag, with accessibility frames that sit on its sides ranked first.
    private func fits(for rough: CGRect, in image: CGImage) async throws -> [CGRect] {
        async let frames = snapFrames(around: rough)
        let pixel = try await SmartSnap().suggest(in: image, roughBounds: rough, scale: scale).map(\.bounds)
        return SnapFits.merge(frames: try await frames, pixel: pixel, drag: rough, scale: scale)
    }

    /// S and the Snap button: flips the preference and applies it to what is on screen. While dragging, off clears the preview and on
    /// starts the analysis; on a released drag, off takes the exact drag and on the best fit (computed now if the drag had none).
    func toggleSnap() {
        defaults.set(!snapEnabled, forKey: Pref.snap)
        if case .drawing(let drag) = interaction {
            scheduleSnap(for: drag.rect)
        } else if var current = selection, !current.isEdited, lockedRatio == nil {
            if !snapEnabled {
                current.selectExact()
                selection = current
            } else if current.fits.count > 1 {
                current.selectBest()
                selection = current
            } else {
                selectBestFit()
            }
        }
        refresh()
    }

    /// After a quick drag with no suggestions, computes them for the current rectangle and takes the best fit. A locked ratio takes no other fit.
    private func selectBestFit() {
        guard lockedRatio == nil, let current = selection, let image else { return }
        let rough = current.rect
        snapTask?.cancel()
        snapTask = Task {
            let suggestions = try await fits(for: rough, in: image)
            try Task.checkCancellation()
            guard selection?.rect == rough else { return }
            selection?.setSuggestions(suggestions)
            selection?.selectBest()
            refresh()
        }
    }

    // MARK: Keys

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    /// The single key dispatch point; each mode routes its own keys.
    func handleKey(_ event: NSEvent) -> Bool {
        text.notice = nil
        if scrollArea != nil { return handleScrollKey(event) }
        if armedRecording != nil { return handleRecordingKey(event) }
        if cutout != nil { return handleCutoutKey(event) }
        var handled = handleExtrasKey(event)
        if !handled {
            switch mode {
            case .capture: handled = handleCaptureKey(event)
            case .text: handled = handleTextKey(event)
            }
        }
        refresh()
        return handled
    }

    func handleCaptureKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        // Arrow steps are device pixels: selections are in the capture's pixels, one per device pixel.
        let step: CGFloat = shift ? 10 : 1
        let character = event.charactersIgnoringModifiers ?? ""
        let hovering = selection == nil
        switch (event.keyCode, command, character) {
        case (53, _, _): dismiss()
        case (36, _, _) where hovering && !shift, (76, _, _) where hovering && !shift: clickHover(shadow: windowShadow(option: false), copy: true, save: afterCaptureSaves, takeDisplay: true)
        case (_, true, _) where shift && character.lowercased() == "s":
            if hovering { clickHover(shadow: windowShadow(option: false), copy: false, save: true, takeDisplay: true, saveAs: true) } else { save(saveAs: true) }
        case (_, false, "e") where hovering && hoverRect != nil: openAsSelection(hoverRect!)
        case (_, false, "w") where hovering:
            // The frontmost window under the pointer, whatever element inside it is hovered, taken as Return takes a hovered window.
            guard let index = windows.firstIndex(where: { $0.contains(pointer) }) else { return false }
            clickWindow(index, crop: windows[index], shadow: windowShadow(option: false), copy: true, save: afterCaptureSaves)
        case (_, false, "k"): cutOut()
        case (_, false, "o"): defaults.set(!defaults.bool(forKey: Pref.roundCorners), forKey: Pref.roundCorners)
        case (_, false, _) where shift && !hovering && character.lowercased() == "p": toggleRatioLock()
        case (_, false, "p") where !hovering: showRatioMenu()
        case (_, false, "="): applyRadiusToAll()
        case (123...126, _, _) where option && !hovering: nudgeSide(keyCode: event.keyCode, outward: !command, by: step)
        case (123...126, true, _) where !hovering: moveSideToEdge(keyCode: event.keyCode, outward: !shift)
        case (_, true, "s") where hovering: clickHover(shadow: windowShadow(option: false), copy: false, save: true, takeDisplay: true)
        case (36, _, _) where shift || option, (76, _, _) where shift || option: copySelectionText(translating: option)
        case (36, _, _), (76, _, _): copy()
        case (48, _, _) where hovering, (126, _, _) where hovering, (125, _, _) where hovering:
            if event.keyCode == 125 || event.keyCode == 48 && shift { session?.shrink() } else { session?.expand() }
            walkedLevel = true
        case (_, false, "1"..."5") where hovering && defaults.bool(forKey: Pref.candidates):
            session?.pick(Int(character)! - 1)
            walkedLevel = false
        case (49, _, _): spaceHeld = true
        case (123, _, _): nudge(CGPoint(x: -step, y: 0))
        case (124, _, _): nudge(CGPoint(x: step, y: 0))
        case (125, _, _): nudge(CGPoint(x: 0, y: step))
        case (126, _, _): nudge(CGPoint(x: 0, y: -step))
        case (_, true, "s"): save()
        case (_, false, "]"), (_, false, "}"): adjustRadii(by: shift ? 4 : 1)
        case (_, false, "["), (_, false, "{"): adjustRadii(by: shift ? -4 : -1)
        case (_, false, "m"): toggleFrame()
        case (_, false, "s"): toggleSnap()
        case (_, false, "g"): startScroll()
        case (_, false, "v"): armRecording()
        case (_, false, "f"):
            cancelWork()
            selection = AreaSelection(extent: extent, exact: extent)
            lockedRatio = nil
            ratioBase = nil
            ratioPortrait = nil
        default: return false
        }
        return true
    }

    // MARK: Output

    func toggleFrame() {
        defaults.set(!framed, forKey: Pref.frame)
        refresh()
    }

    var afterCaptureSaves: Bool { defaults.string(forKey: Pref.afterCapture) == "copyAndSave" }

    func copy() {
        guard let rect = selection?.rect else { return }
        if !framed, let index = window(matching: rect) {
            return clickWindow(index, crop: rect, shadow: windowShadow(option: false), copy: true, save: afterCaptureSaves)
        }
        finish(crop: rect, copy: true, save: afterCaptureSaves)
    }

    /// The window whose frame `rect` matches within 3 pt on every side: copying it captures the real window shape, not a crop.
    private func window(matching rect: CGRect) -> Int? {
        windows.firstIndex { abs($0.minX - rect.minX) <= 3 * scale && abs($0.minY - rect.minY) <= 3 * scale
            && abs($0.maxX - rect.maxX) <= 3 * scale && abs($0.maxY - rect.maxY) <= 3 * scale }
    }

    func save(saveAs: Bool = false) {
        guard let rect = selection?.rect else { return }
        finish(crop: rect, copy: false, save: true, saveAs: saveAs)
    }

    /// A click (or Return / Cmd-S) on the hovered rectangle. A window, or anything matching a window's frame, is captured as a window;
    /// the full display becomes a selection on click and is taken directly with `takeDisplay`; anything else is cropped from the
    /// frozen image with its measured corner radius.
    private func clickHover(shadow: Bool, copy: Bool, save: Bool, takeDisplay: Bool = false, saveAs: Bool = false) {
        guard let hovered = session?.selected else { return }
        switch hovered.kind {
        case .window: clickWindow(Int(hovered.id.dropFirst("window-".count))!, crop: hovered.bounds, shadow: shadow, copy: copy, save: save, saveAs: saveAs)
        case .display where !takeDisplay: selection = AreaSelection(extent: extent, exact: extent)
        default:
            if !framed, let index = window(matching: hovered.bounds) {
                return clickWindow(index, crop: hovered.bounds, shadow: shadow, copy: copy, save: save, saveAs: saveAs)
            }
            finish(crop: hovered.bounds, copy: copy, save: save, saveAs: saveAs)
        }
    }

    /// A live capture takes the window itself like macOS does (rounded corners, shadow, transparent background); a frozen-image run,
    /// the Dock, the menu bar, and menus have no window to capture and crop `crop`.
    private func clickWindow(_ index: Int, crop rect: CGRect, shadow: Bool, copy: Bool, save: Bool, saveAs: Bool = false) {
        guard displayID != nil, !windowFrozen.indices.contains(index) || !windowFrozen[index] else { return finish(crop: rect, copy: copy, save: save, saveAs: saveAs) }
        let id = windowIDs[index]
        // A capture that comes back square takes the radius measured on the frozen screen around the window; a shaped one keeps its outline.
        let radius = radii[windows[index]] ?? image.map { windowCornerRadius(in: $0, rect: windows[index]) } ?? 0
        // The frozen display shows the window as it looked (ScreenCaptureKit drops what a translucent window shows through) unless a
        // window in front overlaps it; then the capture's own pixels stand.
        let overlap = windows[..<index].map { $0.intersection(windows[index]) }.reduce(0) { $0 + ($1.isNull ? 0 : $1.width * $1.height) }
        let interior = overlap == 0 ? image?.cropping(to: windows[index]) : nil
        Pref.logHoverLine("window \(id) rect \(windows[index]) overlap in front \(overlap) -> " + (interior == nil ? "captured pixels" : "frozen interior"))
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let image = roundingWindowCorners(try await DisplayCapture.image(ofWindow: id, shadow: shadow, interior: interior), radius: radius)
                let png = try await Output.png(image)
                let destination = saveAs ? chooseSaveURL(Output.defaultFile(defaults: defaults)) : nil
                guard !saveAs || destination != nil else { return }
                try Output.publish(png: png, detail: "\(image.width) x \(image.height)  window", copy: copy, save: save, destination: destination,
                                   pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }

    /// The downsampled capture, started on first use.
    func small() -> Task<CGImage, Never> {
        if let smallImage { return smallImage }
        let (image, factor) = (image!, Int(scale))
        let task = Task.detached { Detection.downsampled(image, by: factor) }
        smallImage = task
        return task
    }

    /// Measures a rectangle's corner radius and corner arcs off the main thread, once, and redraws when they arrive. A window's radius is
    /// fitted to where its own color starts at each corner.
    private func measureRadius(_ rect: CGRect?) {
        guard let rect, let image, radii[rect] == nil, radiusTasks[rect] == nil else { return }
        // A frozen target (the Dock) is not a window with its own opaque color; its corners are fitted to its outline like any region's.
        let isWindow = windows.firstIndex(of: rect).map { !windowFrozen.indices.contains($0) || !windowFrozen[$0] } ?? false
        radiusTasks[rect] = Task {
            let measured = await Task.detached { () -> (radius: CGFloat, arcs: CornerRadii) in
                if isWindow { return (windowCornerRadius(in: image, rect: rect), .zero) }
                let arcs = cornerArcs(in: image, rect: rect)
                return (arcs.agreed, arcs)
            }.value
            if self.image === image {
                radii[rect] = measured.radius
                arcs[rect] = measured.arcs
                refresh()
            }
            return measured
        }
    }

    /// The frontmost window holding `rect`: its measured radius applies to the corners of `rect` that sit on the window's corners.
    func container(of rect: CGRect) -> CGRect? {
        windows.first { $0.insetBy(dx: -2, dy: -2).contains(rect) }
    }

    /// The corner radii of `rect`: the edited ones, else its measured radius on all four corners (each corner's own arc when they agree
    /// on none), with the corners that sit on its window's corners taking the window's radius.
    func cornerRadii(of rect: CGRect) -> CornerRadii {
        if let edited = editedRadii[rect] { return edited }
        guard defaults.bool(forKey: Pref.roundCorners) else { return .zero }
        let radius = radii[rect] ?? 0, arcs = arcs[rect] ?? .zero
        let measured = radius > 0 ? CornerRadii(radius) : arcs
        guard let window = container(of: rect) else { return measured }
        return measured.replacingCorners(sharedWith: window, in: rect, with: radii[window] ?? 0, arcs: arcs)
    }

    /// `]` / `[`: every corner of the selection (or the hovered rectangle) grows or shrinks by `points`, from its current radii.
    private func adjustRadii(by points: CGFloat) {
        guard let rect = selection?.rect ?? hoverRect else { return }
        let adjusted = cornerRadii(of: rect).offset(by: points * scale, in: rect.size)
        editedRadii[rect] = adjusted
        showRadiusReadout(adjusted)
    }

    /// Closes the overlay first, then encodes off main and delivers.
    func finish(crop: CGRect, copy: Bool, save: Bool, saveAs: Bool = false) {
        guard let image else { return }
        let framed = framed, scale = scale
        let container = container(of: crop)
        let edited = editedRadii[crop], rounds = defaults.bool(forKey: Pref.roundCorners)
        let (known, measuring) = (radii[crop].map { (radius: $0, arcs: arcs[crop] ?? .zero) }, radiusTasks[crop])
        let (windowKnown, windowMeasuring) = (container.flatMap { radii[$0] }, container.flatMap { radiusTasks[$0] })
        if let displayID {
            let area = [Double(displayID)] + [crop.minX, crop.minY, crop.width, crop.height].map { Double($0 / scale) }
            defaults.set(area, forKey: Pref.lastArea)
        }
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let measured = if let known { known } else { await measuring?.value ?? (0, .zero) }
                var radii = measured.radius > 0 ? CornerRadii(measured.radius) : measured.arcs
                if let container {
                    let windowRadius = if let windowKnown { windowKnown } else { await windowMeasuring?.value.radius ?? 0 }
                    radii = radii.replacingCorners(sharedWith: container, in: crop, with: windowRadius, arcs: measured.arcs)
                }
                let destination = saveAs ? chooseSaveURL(Output.defaultFile(defaults: defaults)) : nil
                guard !saveAs || destination != nil else { return }
                try await Output.deliver(image, crop: crop, framed: framed, scale: scale, cornerRadii: edited ?? (rounds ? radii : .zero), copy: copy, save: save,
                                         destination: destination, pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }

    /// Shows a failure unless its task was cancelled (Vision reports cancellation with its own error, not
    /// `CancellationError`). Closes the overlay first so the alert is not hidden under it.
    /// Debug runs print it and exit instead of opening an alert.
    func report(_ error: any Error) {
        guard !Task.isCancelled else { return }
        if isHeadless {
            FileHandle.standardError.write(Data("Debug run failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        dismiss()
        NSApp.presentError(error)
    }

    // MARK: Drawing

    func refresh() {
        view.liveText.isHidden = mode != .text
        showWarmUpNotice()
        var overlays = OverlayView.Overlays()
        if case .drawing(let drag) = interaction, drag.rect.width > 0 || drag.rect.height > 0 { overlays.ghost = drag.rect }
        overlays.preview = snapPreview
        overlays.selection = selection?.rect
        overlays.snappedEdges = snappedEdges
        overlays.showsHandles = selection != nil
        if selection == nil || shiftHeld, case .none = interaction { overlays.hover = hoverRect }
        if mode == .text, let picked = text.picked { overlays.hover = text.items![picked].bounds }
        // While hovering, faint outlines show what Up and Down would select, unless that is nothing, the display, or within 4 pt of the hover.
        if mode == .capture, selection == nil, let hover = overlays.hover, let session {
            let level = { (candidate: Candidate?) in candidate.flatMap { $0.kind == .display || $0.bounds.isNear(hover, within: 4 * self.scale) ? nil : $0.bounds } }
            overlays.upHint = level(session.parents.first)
            overlays.downHint = level(session.child)
        }
        if let scrollArea { overlays.selection = scrollArea; overlays.showsHandles = false; overlays.hover = nil }
        if let cutout { overlays.selection = cutout.frame; overlays.showsHandles = false; overlays.hover = nil }
        // The selection is measured once it settles; a dragged handle makes a new rectangle on every event.
        let settled: CGRect? = if case .none = interaction { selection?.rect } else { nil }
        let shown = selection?.rect ?? snapPreview
        for rect in [snapPreview, settled, overlays.hover, overlays.upHint, overlays.downHint] { measureRadius(rect) }
        for rect in [shown, overlays.hover, overlays.upHint, overlays.downHint] { measureRadius(rect.flatMap(container)) }
        overlays.radii = shown.map(cornerRadii) ?? .zero
        overlays.hoverRadii = overlays.hover.map(cornerRadii) ?? .zero
        layoutCornerChip()
        overlays.upHintRadii = overlays.upHint.map(cornerRadii) ?? .zero
        overlays.downHintRadii = overlays.downHint.map(cornerRadii) ?? .zero
        if let rect = selection?.rect, framed { overlays.styleFrame = OutputFrame.rect(around: rect, scale: scale, framed: true) }
        view.overlays = overlays
        refreshExtras()
        refreshRecording()
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
