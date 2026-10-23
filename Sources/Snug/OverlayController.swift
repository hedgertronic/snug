import AppKit
import ScreenshotCore
import Translation

/// A nonactivating panel: it becomes key, taking the keyboard, without making Snug the active app. Activating Snug on open could
/// wait about 0.5 s on the app being left, and the overlay reached the screen only after it, so `present` activates Snug once the
/// overlay is drawn: until then the app being left keeps the cursor (Finder holds it at the arrow).
@MainActor
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Text mode: where the current press landed and the word (or, after a double or triple click, the word or line) it anchors.
    var textPress: (point: CGPoint, anchor: Range<String.Index>?)?

    /// Text mode: a press is down that began on a chrome button, or one that began elsewhere (Live Text's).
    var buttonPress = false
    var textDragging = false

    override func sendEvent(_ event: NSEvent) {
        let view = contentView as! OverlayView
        guard !view.liveText.isHidden, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return super.sendEvent(event) }
        // A press that begins on a chrome button goes to the button, so it never clears or changes the text selection it acts on.
        if event.type == .leftMouseDown { buttonPress = view.hitTest(event.locationInWindow) is BarButton }
        guard !buttonPress else { return super.sendEvent(event) }
        // While Live Text's press is down the Text strip stays hidden, so it never lands under the pointer mid-drag.
        textDragging = event.type != .leftMouseUp
        sendTextMouse(event)
        if event.type == .leftMouseUp { view.controller!.refresh() }
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
    /// Points at the bottom of the screen a Dock there takes (0 when it is hidden or on a side); the settings bar sits above it.
    var bottomInset: CGFloat = 0
    var extent = CGRect.zero
    var windows: [CGRect] = []
    var windowNames: [String] = []
    var windowIDs: [CGWindowID] = []
    /// Per window: a Dock, menu bar, or menu target, cropped from the frozen image instead of captured as a window.
    var windowFrozen: [Bool] = []
    /// Option is held: a click on the hovered object inverts Frame for that capture.
    var optionHeld = false
    /// Command is held: the hint key caps for it fill with the accent.
    var commandHeld = false
    /// Control is held: with Option, the arrow legend reads edge out or edge in, and the Control caps fill with the accent.
    var controlHeld = false
    /// Corner radius in pixels of each snap fit, settled selection, and hovered rectangle, measured once per rectangle.
    /// A rectangle that is not here (one being resized, or still being measured) has square corners.
    var radii: [CGRect: CGFloat] = [:]
    /// The arc each corner of a measured rectangle follows (0 where none): a corner takes its own arc where the corners agree on no
    /// radius, and inside a window's corner, ahead of the window's arc.
    var arcs: [CGRect: CornerRadii] = [:]
    var radiusTasks: [CGRect: Task<(radius: CGFloat, arcs: CornerRadii), Never>] = [:]
    /// Per-corner radii set with `[`, `]`, the corner dots, and E, by rectangle; they replace the measured ones.
    var editedRadii: [CGRect: CornerRadii] = [:]
    /// Cmd-Z and Cmd-Shift-Z: the selection states before each edit since the selection was made, and those undone; the last key
    /// that edited it and when, for coalescing.
    var undoStack: [SelectionState] = []
    var redoStack: [SelectionState] = []
    var lastEdit: (key: String, at: ContinuousClock.Instant)?
    /// The corner a dot drag last changed; `=` copies its radius to the other corners.
    var lastEditedCorner: Handle?
    /// The corner whose dot the pointer is on (or whose chip it is heading to).
    var hoveredCorner: Handle?
    /// The corner Tab stepped to with a selection open: its dot lights, the corner group shows at it ahead of a hovered dot's, and `[`
    /// and `]` change only it. Nil is all four. A pointer moving onto another dot takes over, and a new capture clears it.
    var focusedCorner: Handle?
    /// The corner group's chip, at the focused or hovered corner: the target of `[` and `]` ("All corners", or the focused corner's
    /// name) with its radius, and `=`, which a click presses.
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
    /// The windows have arrived since the overlay opened, so the hover target is known (see `Overlays.dimResolved`).
    private var dimResolved = false
    /// The ratio of the rectangle being dragged or selected, with the nearest standard (see `RatioLock.readout`); empty with neither.
    var ratioReadout: String {
        (draggedRect ?? selection?.rect).map { RatioLock.readout(for: $0.size) } ?? ""
    }
    /// Shift is down: with a selection open, once the pointer moves outside the selection, the element under it is outlined for a union.
    var shiftHeld = false
    /// The pointer moved (or clicked) since Shift went down.
    private var movedWithShift = false
    /// With a selection open, Shift held, and the pointer moved since then and outside the selection, the hover outlines the element
    /// under the pointer for a union.
    private var unionHover: Bool { shiftHeld && movedWithShift && selection.map { !$0.rect.contains(pointer) } ?? false }
    /// Save As: the file to write, given the usual name in the save folder; nil cancels. Debug runs answer without a panel.
    var chooseSaveURL: (URL) -> URL? = { suggested in
        NSApp.activate()
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// The last pointer position in image pixels.
    var pointer = CGPoint.zero
    /// Capture mode: what the pointer is over (accessibility elements, pixel geometry, windows, the display), and the running geometry analysis.
    var session: SelectionSession?
    /// A fresh key press (not a repeat) is being handled; a hover change it makes is a jump.
    var keyJump = false
    /// This refresh moves the hover outline to another candidate after a key jump with motion on: the outline and its chrome animate.
    var jumping = false
    var detectionTask: Task<Void, Never>?
    var detected: [Candidate] = []
    /// Small uniform fills read from the 1x capture (built off main), and the task building them; hover adds the one under the pointer.
    var fills: FlatFills?
    var fillsTask: Task<Void, Never>?
    /// The Dock's icon tiles read from the frozen image, labeled by the Dock's item titles.
    var dockTiles: [Candidate] = []
    /// The running accessibility lookup and when the last one started (throttle), the pixel it looked up, and the repeat of a request
    /// the throttle dropped.
    var accessibilityTask: Task<Void, Error>?
    var accessibilityStarted: ContinuousClock.Instant?
    var accessibilityPixel: CGPoint?
    var accessibilityRetry: Task<Void, Error>?
    /// The frames each accessibility candidate came from (its element and ancestors, innermost first) and when they were read, by its
    /// rectangle; Copy for Agent reads them.
    var accessibilityObservations: [CGRect: (frames: [AXFrame], observedAt: Date)] = [:]
    /// When `present` froze the pixels.
    var frozenAt = Date.now
    var previousApp: NSRunningApplication?
    /// Esc as a global hot key while the overlay is up (never in debug runs): Snug is not the active app (see `OverlayWindow`), and when
    /// the shortcut opened the overlay over another app's open menu a plain Esc would go to that app. A press reaches the overlay as its Esc key.
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
    /// The selection state when the current press began, for its undo step.
    private var pressState: SelectionState?
    var spaceHeld = false
    /// Scrolling capture (G): the area in image pixels, the stitched height so far, the stitcher, and the loop capturing the area.
    /// Debug runs replace the live frame source.
    var scrollArea: CGRect?
    var scrollHeight = 0
    /// The stitched image so far, scaled to fit beside the area (see `Minimap`).
    var scrollThumbnail: CGImage?
    var stitcher: ScrollStitcher?
    var scrollTask: Task<Void, Never>?
    var scrollFrames: ((CGRect) async throws -> CGImage)?
    /// The scroll-wheel and drag events sent to other apps since scrolling capture started, and the monitor that collects them.
    var scrollInput: [NSEvent] = []
    var scrollMonitor: Any?
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
        // Bottom to top: the hint caps, the chips, the strip and settings bar with their menus, the keys sheet, then the loupe.
        chrome.all.forEach(view.addSubview)
        cornerChip.isHidden = true
        view.addSubview(cornerChip, positioned: .below, relativeTo: chrome.topBar)
        view.addSubview(view.guides.host)
        wireChrome()
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
        dimResolved = false
        detectionTask?.cancel()
        detected = []
        fillsTask?.cancel()
        fills = nil
        dockTiles = []
        accessibilityTask?.cancel()
        accessibilityObservations = [:]
        frozenAt = .now
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
        let screen = NSScreen.screens.first { $0.frame == frame }
        topInset = screen?.safeAreaInsets.top ?? 0
        bottomInset = screen.map { $0.visibleFrame.minY - $0.frame.minY } ?? 0
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
            window.orderFrontRegardless()
            window.makeKey()
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
        if !isHeadless { NSApp.activate() }
    }

    /// Supplies window rectangles (image pixels, front to back) once they are built.
    func setWindows(_ rects: [CGRect], names: [String] = [], ids: [CGWindowID] = [], frozen: [Bool] = [], pointer: CGPoint) {
        windows = rects
        windowNames = names
        windowIDs = ids
        windowFrozen = frozen
        if mode == .capture { buildSession() }
        // The dim waits for the windows: a hover before them would find nothing, dim everything, then fade to the window under the pointer.
        dimResolved = true
        updateHover(pixel: CGPoint(x: (pointer.x - window.frame.minX) * scale, y: (window.frame.maxY - pointer.y) * scale))
    }

    /// Closes the overlay, cancels pending work, and releases the frozen image.
    func dismiss() {
        cancelWork()
        disarmRecording()
        scrollTask?.cancel()
        scrollTask = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollInput = []
        scrollArea = nil
        scrollHeight = 0
        scrollThumbnail = nil
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
        undoStack = []
        redoStack = []
        lastEditedCorner = nil
        hoveredCorner = nil
        focusedCorner = nil
        lockedRatio = nil
        ratioBase = nil
        ratioPortrait = nil
        chrome.ratioMenu.isHidden = true
        chrome.colorMenu.isHidden = true
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
        controlHeld = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        if shift != shiftHeld, image != nil {
            shiftHeld = shift
            movedWithShift = false
            // On the top bar or the strip the hover holds, so Shift relabels the strip under the pointer instead of picking anew.
            if !holdsHover(at: CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale)) { updateHover(pixel: pointer) }
        }
        refresh()
    }

    func mouseMoved(_ event: NSEvent) {
        // The Colors menu is anchored to the hovered element's strip: while it is open the hover stays where it was.
        guard image != nil, armedRecording == nil, chrome.colorMenu.isHidden else { return }
        optionHeld = event.modifierFlags.contains(.option)
        commandHeld = event.modifierFlags.contains(.command)
        controlHeld = event.modifierFlags.contains(.control)
        shiftHeld = event.modifierFlags.contains(.shift)
        movedWithShift = shiftHeld
        let wasOnSelection = pointerOnSelection
        pointer = view.pixelPoint(event)
        // On the top bar, or crossing from the hovered element to its chips or strip, the hover holds so their buttons can be clicked;
        // the guides, loupe and crosshair still follow the pointer.
        if holdsHover(at: view.convert(event.locationInWindow, from: nil)) {
            updateGuides()
            updateToolTip()
            return updateCursor()
        }
        // The edge keys show while the pointer is inside a released selection.
        if pointerOnSelection != wasOnSelection { refresh() }
        updateHoveredCorner()
        updateHover(pixel: pointer)
        updateGuides()
        updateToolTip()
        updateCursor()
    }

    /// The crosshair over a button of the chrome or a row of its menus, inside the selection too; resize cursors on handles and edges,
    /// an open hand inside the selection, a closed hand while moving, the I-beam over text in Text mode, the crosshair elsewhere. The
    /// panel does not activate, so cursor rects alone are unreliable: the choice is also set on each pointer move. Headless runs record
    /// the choice on the view but leave the system cursor alone.
    func updateCursor() {
        guard window.isVisible else { return }
        let cursor: NSCursor
        switch interaction {
        case .none where overClickableChrome: cursor = .crosshair
        case .resizing(let handle, _): cursor = Self.resizeCursors[handle]!
        case .moving: cursor = .closedHand
        case .rounding: cursor = .pointingHand
        case .drawing: cursor = .crosshair
        case .none where mode == .text:
            // Live Text takes points from the top-left corner (measured), not the view's bottom-left.
            cursor = view.liveText.hasText(at: CGPoint(x: pointer.x / scale, y: pointer.y / scale)) ? .iBeam : .crosshair
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
        guard selection == nil || unionHover else {
            if view.overlays.hover != nil { refresh() }
            return
        }
        if mode == .capture, session != nil {
            requestAccessibility(at: pixel)
            addFill(at: pixel)
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
        pressState = selectionState
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
                // A Shift-click counts as a move: it outlines and takes the element under the pointer.
                movedWithShift = true
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
                let band = SmartSnap.band(scale: scale)
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
        // A handle drag, move, corner drag or Shift-click union is one undo step; a fresh drag starts the history over in `release`. A
        // button click's release reaches here without its press, so only a press on the overlay itself counts.
        if case .drawing = finished {} else if let pressState { recordEdit(from: pressState) }
        pressState = nil
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
                if !hadSelection { clickHover(framed: framed != event.modifierFlags.contains(.option), copy: true, save: afterCaptureSaves) }
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
        undoStack = []
        redoStack = []
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
        flash(event)
        text.notice = nil
        keyJump = !event.isARepeat
        defer { keyJump = false }
        if scrollArea != nil { return handleScrollKey(event) }
        if armedRecording != nil { return handleRecordingKey(event) }
        if cutout != nil { return handleCutoutKey(event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift])
        // After Esc dropped the selection, the undo stack holds it, so Cmd-Z brings it back.
        if mode == .capture, selection != nil || !undoStack.isEmpty, flags.isSuperset(of: .command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoEdit(redo: flags.contains(.shift))
            if selection == nil { updateHover(pixel: pointer) }
            refresh()
            return true
        }
        // Esc with a corner focused returns to all four corners first.
        if event.keyCode == 53, focusedCorner != nil, mode == .capture, selection != nil, chrome.help.isHidden {
            focusedCorner = nil
            refresh()
            return true
        }
        // Esc, or E (the lit Edit button), with a released selection drops it back to hover, as an undo step.
        let leavesEdit = event.keyCode == 53 || flags.isEmpty && event.charactersIgnoringModifiers == "e"
        if leavesEdit, mode == .capture, selection != nil, chrome.help.isHidden, case .none = interaction {
            undoStack.append(selectionState)
            redoStack = []
            lastEdit = nil
            cancelWork()
            selection = nil
            focusedCorner = nil
            lockedRatio = nil
            ratioBase = nil
            ratioPortrait = nil
            updateHover(pixel: pointer)
            refresh()
            return true
        }
        let before = selectionState
        var handled = handleExtrasKey(event)
        if !handled {
            switch mode {
            case .capture: handled = handleCaptureKey(event)
            case .text: handled = handleTextKey(event)
            }
        }
        // Arrow nudges, and presses of one key, coalesce into one undo step.
        let nudge = (123...126).contains(event.keyCode) && !flags.contains(.command) && !flags.contains(.option)
        recordEdit(from: before, key: nudge ? "nudge" : "\(event.keyCode) \(event.charactersIgnoringModifiers ?? "") \(flags.rawValue)")
        refresh()
        return handled
    }

    func handleCaptureKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let control = event.modifierFlags.contains(.control)
        // Arrow steps are device pixels: selections are in the capture's pixels, one per device pixel.
        let step: CGFloat = shift ? 10 : 1
        let character = event.charactersIgnoringModifiers ?? ""
        let hovering = selection == nil
        // Control only changes the arrows (edge in and out); any other key with Control does nothing.
        if control && !(123...126).contains(event.keyCode) { return false }
        switch (event.keyCode, command, character) {
        case (53, _, _): dismiss()
        case (36, true, _) where !shift && !option, (76, true, _) where !shift && !option: copyForAgent()
        case (36, _, _) where hovering && !shift && !option, (76, _, _) where hovering && !shift && !option: clickHover(framed: framed, copy: true, save: afterCaptureSaves, takeDisplay: true)
        case (_, true, _) where shift && character.lowercased() == "s":
            if hovering { clickHover(framed: framed, copy: false, save: true, takeDisplay: true, saveAs: true) } else { save(saveAs: true) }
        case (_, false, "e") where hovering && hoverRect != nil: openAsSelection(hoverRect!)
        case (_, false, "w") where hovering:
            // The frontmost window under the pointer, whatever element inside it is hovered, taken as Return takes a hovered window.
            guard let index = windows.firstIndex(where: { $0.contains(pointer) }) else { return false }
            clickWindow(index, crop: windows[index], framed: framed, copy: true, save: afterCaptureSaves)
        case (_, false, "k"): cutOut()
        case (_, false, "u"): showColorsMenu()
        case (_, false, "o"): defaults.set(!defaults.bool(forKey: Pref.roundCorners), forKey: Pref.roundCorners)
        case (_, false, _) where shift && !hovering && character.lowercased() == "p": toggleRatioLock()
        case (_, false, "p") where !hovering: showRatioMenu()
        case (_, false, "="): applyRadiusToAll()
        case (_, false, "+") where !hovering: growSides(by: option ? 10 : 1)
        case (_, false, "-") where !hovering: growSides(by: option ? -10 : -1)
        // On a selection: Option-arrow grows a side, Option-Command-arrow shrinks it; with Control they move it to the next edge out or
        // in, and Shift does nothing. Command-arrow without Option is unbound.
        case (123...126, _, _) where control && option && !hovering: moveSideToEdge(keyCode: event.keyCode, outward: !command)
        case (123...126, _, _) where option && !hovering: nudgeSide(keyCode: event.keyCode, outward: !command, by: step)
        case (123...126, true, _) where !hovering: return false
        case (_, true, "s") where hovering: clickHover(framed: framed, copy: false, save: true, takeDisplay: true)
        case (36, _, _) where shift || option, (76, _, _) where shift || option: copySelectionText(translating: option)
        case (36, _, _), (76, _, _): copy()
        case (48, _, _) where hovering, (126, _, _) where hovering || unionHover, (125, _, _) where hovering || unionHover:
            if event.keyCode == 125 || event.keyCode == 48 && shift { session?.shrink() } else { session?.expand() }
            walkedLevel = true
        case (48, _, _) where !command:
            // Tab with a selection open cycles top-left, top-right, bottom-right, bottom-left, and Shift-Tab goes back; from all
            // corners Tab picks top-left and Shift-Tab bottom-left. Only Esc returns to all corners.
            let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
            focusedCorner = focusedCorner.map { order[(order.firstIndex(of: $0)! + (shift ? 3 : 1)) % 4] } ?? (shift ? .bottomLeft : .topLeft)
        case (123, false, _) where hovering && !option, (124, false, _) where hovering && !option:
            // The element beside the hovered one; it holds like an Up or Down pick.
            guard session?.step(right: event.keyCode == 124) == true else { beep(); break }
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
        // F with nothing selected takes the display at once, as W takes the window; on a selection F grows it to the display and W to
        // the frontmost window holding the selection's center.
        case (_, false, "f") where hovering: finish(crop: extent, copy: true, save: afterCaptureSaves)
        case (_, false, "f"), (_, false, "w"):
            let target = character == "f" ? extent : windows.first { $0.contains(CGPoint(x: selection!.rect.midX, y: selection!.rect.midY)) }
            guard let target else { return false }
            cancelWork()
            selection = AreaSelection(extent: extent, exact: target)
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
        if let index = window(matching: rect) {
            return clickWindow(index, crop: rect, framed: framed, copy: true, save: afterCaptureSaves)
        }
        finish(crop: rect, copy: true, save: afterCaptureSaves)
    }

    /// The window whose frame `rect` matches within 3 pt on every side: copying it captures the real window shape, not a crop.
    func window(matching rect: CGRect) -> Int? {
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
    private func clickHover(framed: Bool, copy: Bool, save: Bool, takeDisplay: Bool = false, saveAs: Bool = false) {
        guard let hovered = session?.selected else { return }
        switch hovered.kind {
        case .window: clickWindow(Int(hovered.id.dropFirst("window-".count))!, crop: hovered.bounds, framed: framed, copy: copy, save: save, saveAs: saveAs)
        case .display where !takeDisplay: selection = AreaSelection(extent: extent, exact: extent)
        default:
            if let index = window(matching: hovered.bounds) {
                return clickWindow(index, crop: hovered.bounds, framed: framed, copy: copy, save: save, saveAs: saveAs)
            }
            finish(crop: hovered.bounds, framed: framed, copy: copy, save: save, saveAs: saveAs)
        }
    }

    /// A live capture takes the window itself like macOS does (rounded corners, shadow, transparent background); a frozen-image run,
    /// the Dock, the menu bar, and menus have no window to capture and crop `crop`.
    private func clickWindow(_ index: Int, crop rect: CGRect, framed: Bool, copy: Bool, save: Bool, saveAs: Bool = false) {
        guard displayID != nil, !windowFrozen.indices.contains(index) || !windowFrozen[index] else { return finish(crop: rect, framed: framed, copy: copy, save: save, saveAs: saveAs) }
        let id = windowIDs[index]
        // A capture that comes back square takes the radius measured on the frozen screen around the window; a shaped one keeps its outline.
        let radius = radii[windows[index]] ?? image.map { windowCornerRadius(in: $0, rect: windows[index]) } ?? 0
        // The frozen display shows the window as it looked (ScreenCaptureKit drops what a translucent window shows through) unless a
        // window in front overlaps it; then the capture's own pixels stand.
        let overlap = windows[..<index].map { $0.intersection(windows[index]) }.reduce(0) { $0 + ($1.isNull ? 0 : $1.width * $1.height) }
        let interior = overlap == 0 ? image?.cropping(to: windows[index]) : nil
        Pref.logHoverLine("window \(id) rect \(windows[index]) overlap in front \(overlap) -> " + (interior == nil ? "captured pixels" : "frozen interior"))
        let destination = saveAs ? askSaveURL() : nil
        guard !saveAs || destination != nil else { return }
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let image = roundingWindowCorners(try await DisplayCapture.image(ofWindow: id, shadow: framed, interior: interior), radius: radius)
                let png = try await Output.png(image)
                Output.publish(png: png, detail: "\(image.width) x \(image.height)  window", copy: copy, save: save, destination: destination,
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

    /// `]` / `[`: every corner of the selection (or the hovered rectangle), or only the focused corner, grows or shrinks by `points`, from its current radii.
    private func adjustRadii(by points: CGFloat) {
        guard let rect = selection?.rect ?? hoverRect else { return }
        let radii = cornerRadii(of: rect)
        editedRadii[rect] = radii.moving(focusedCorner ?? .topLeft, by: points * scale, alone: focusedCorner != nil, in: rect.size)
    }

    /// Asks where Save As writes, with the overlay still up: canceling the panel leaves the overlay and its selection as they were, and
    /// only a chosen file closes it. While the panel runs, the overlay drops from the screen saver level to floating, under the modal
    /// panel whatever level the panel keeps, and the Esc hot key is let go, so Esc cancels the panel, not the overlay.
    private func askSaveURL() -> URL? {
        escape?.unregister()
        let level = window.level
        window.level = .floating
        let url = chooseSaveURL(Output.defaultFile(defaults: defaults))
        window.level = level
        if url == nil, !isHeadless {
            try! escape!.register(keyCode: 53, modifiers: [])
            window.makeKeyAndOrderFront(nil)
        }
        return url
    }

    /// Asks for the Save As file when asked to, then closes the overlay, encodes off main and delivers.
    func finish(crop: CGRect, framed: Bool? = nil, copy: Bool, save: Bool, saveAs: Bool = false) {
        guard let image else { return }
        let destination = saveAs ? askSaveURL() : nil
        guard !saveAs || destination != nil else { return }
        let framed = framed ?? self.framed, scale = scale
        let container = container(of: crop)
        let edited = editedRadii[crop], rounds = defaults.bool(forKey: Pref.roundCorners)
        let (known, measuring) = (radii[crop].map { (radius: $0, arcs: arcs[crop] ?? .zero) }, radiusTasks[crop])
        let (windowKnown, windowMeasuring) = (container.flatMap { radii[$0] }, container.flatMap { radiusTasks[$0] })
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let measured = if let known { known } else { await measuring?.value ?? (0, .zero) }
                var radii = measured.radius > 0 ? CornerRadii(measured.radius) : measured.arcs
                if let container {
                    let windowRadius = if let windowKnown { windowKnown } else { await windowMeasuring?.value.radius ?? 0 }
                    radii = radii.replacingCorners(sharedWith: container, in: crop, with: windowRadius, arcs: measured.arcs)
                }
                try await Output.deliver(image, crop: crop, framed: framed, scale: scale, cornerRadii: edited ?? (rounds ? radii : .zero), copy: copy, save: save,
                                         destination: destination, pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }

    /// Shows a failure unless its task was cancelled (Vision reports cancellation with its own error, not
    /// `CancellationError`) as a red toast with a short reason, the way a failed recording shows (an alert may never show for an
    /// accessory app). Closes the overlay first. Debug runs print it and exit instead.
    func report(_ error: any Error) {
        guard !Task.isCancelled else { return }
        if isHeadless {
            FileHandle.standardError.write(Data("Debug run failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        dismiss()
        Toast.show(message: "Snug could not finish", detail: (error as NSError).localizedFailureReason ?? error.localizedDescription, color: .systemRed)
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
        // Armed to record, the red outline replaces both, so the view never receives them.
        overlays.showsHandles = selection != nil && armedRecording == nil
        overlays.showsOutline = armedRecording == nil
        overlays.focusedCorner = selection == nil ? nil : focusedCorner
        if selection == nil || unionHover, case .none = interaction { overlays.hover = hoverRect }
        if mode == .text, let picked = text.picked { overlays.hover = text.items![picked].bounds }
        // While hovering, faint outlines show what Up and Down would select, unless that is nothing, the display, or within 4 pt of the hover.
        if mode == .capture, selection == nil, let hover = overlays.hover, let session {
            let level = { (candidate: Candidate?) in candidate.flatMap { $0.kind == .display || $0.bounds.isNear(hover, within: 4 * self.scale) ? nil : $0.bounds } }
            overlays.upHint = level(session.parents.first)
            overlays.downHint = level(session.child)
        }
        if let scrollArea { overlays.selection = scrollArea; overlays.showsHandles = false; overlays.hover = nil }
        if let cutout { overlays.selection = cutout.frame; overlays.showsHandles = false; overlays.hover = nil }
        overlays.dimResolved = dimResolved
        overlays.dimsAll = dimResolved && mode == .capture && overlays.selection == nil && overlays.preview == nil && overlays.ghost == nil && overlays.hover == nil
        // The selection is measured once it settles; a dragged handle makes a new rectangle on every event.
        let settled: CGRect? = if case .none = interaction { selection?.rect } else { nil }
        let shown = selection?.rect ?? snapPreview
        let hints = [overlays.upHint, overlays.downHint]
        for rect in [snapPreview, settled, overlays.hover] + hints { measureRadius(rect) }
        for rect in [shown, overlays.hover] + hints { measureRadius(rect.flatMap(container)) }
        overlays.radii = cutout?.frameRadii ?? shown.map(cornerRadii) ?? .zero
        overlays.hoverRadii = overlays.hover.map(cornerRadii) ?? .zero
        overlays.upHintRadii = overlays.upHint.map(cornerRadii) ?? .zero
        overlays.downHintRadii = overlays.downHint.map(cornerRadii) ?? .zero
        // The padded card of an area or element; a live window's real shadow has no card to preview.
        if let rect = selection?.rect, framed, !capturesLiveWindow(rect) { overlays.styleFrame = OutputFrame.rect(around: rect, scale: scale, framed: true) }
        jumping = keyJump && !isHeadless && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && selection == nil
            && overlays.hover != nil && view.overlays.hover != nil && overlays.hover != view.overlays.hover
        view.overlays = overlays
        refreshExtras()
        jumping = false
        refreshRecording()
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
