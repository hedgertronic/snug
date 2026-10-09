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
}

/// Owns the overlay window and one capture session: selection state, key dispatch, snap, and cancellation.
@MainActor
final class OverlayController {
    enum Mode { case capture, text }

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
    var mode = Mode.capture
    /// Debug runs drive the window with synthesized events; it stays transparent, below other apps' windows' level, and never takes focus.
    var isHeadless = false

    var selection: AreaSelection?
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
    /// Corner radius in pixels of each snap fit, Tab fit, and hovered rectangle, measured once per rectangle.
    /// A rectangle that is not here (an exact drag, a nudged or resized selection) has square corners.
    var radii: [CGRect: CGFloat] = [:]
    private var radiusTasks: [CGRect: Task<CGFloat, Never>] = [:]
    /// The last pointer position in image pixels.
    var pointer = CGPoint.zero
    /// Capture mode: what the pointer is over (accessibility elements, pixel geometry, windows, the display), and the running geometry analysis.
    var session: SelectionSession?
    var detectionTask: Task<Void, Never>?
    var detected: [Candidate] = []
    /// The running accessibility lookup and when the last one started (throttle).
    var accessibilityTask: Task<Void, Error>?
    var accessibilityStarted: ContinuousClock.Instant?
    var previousApp: NSRunningApplication?
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

    var snapEnabled: Bool { defaults.bool(forKey: Pref.snap) }
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
        chrome.all.forEach(view.addSubview)
        chrome.bottomBar.onMode = { [unowned self] in setMode($0) }
        chrome.bottomBar.onToggle = { [unowned self] in
            if $0 == Pref.snap { return toggleSnap() }
            defaults.set(!defaults.bool(forKey: $0), forKey: $0)
            refresh()
        }
        chrome.bottomBar.onStyle = { [unowned self] in style = style.next }
        chrome.styleBar.onStyle = { [unowned self] in style = $0 }
        chrome.styleBar.onSave = { [unowned self] in save() }
        chrome.styleBar.onCopy = { [unowned self] in copy() }
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
        view.liveText.analysis = nil
        smallImage = nil
        window.orderOut(nil)
        view.image = nil
        image = nil
        windows = []
        windowNames = []
        windowIDs = []
        windowFrozen = []
        radii = [:]
        radiusTasks = [:]
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
        snapTask?.cancel()
        snapTask = nil
        snapPreview = nil
        snapSuggestions = []
    }

    // MARK: Pointer

    func flagsChanged(_ event: NSEvent) {
        optionHeld = event.modifierFlags.contains(.option)
        refresh()
    }

    func mouseMoved(_ event: NSEvent) {
        guard image != nil else { return }
        optionHeld = event.modifierFlags.contains(.option)
        pointer = view.pixelPoint(event)
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
        case .resizing(let handle): cursor = Self.resizeCursors[handle]!
        case .moving: cursor = .closedHand
        case .drawing: cursor = .crosshair
        case .none where mode == .text:
            // Live Text takes points from the top-left corner (measured), not the view's bottom-left.
            cursor = view.liveText.hasText(at: CGPoint(x: pointer.x / scale, y: pointer.y / scale)) ? .iBeam : .arrow
        case .none:
            if let selection {
                cursor = selection.handle(at: pointer, tolerance: 8 * scale).map { Self.resizeCursors[$0]! }
                    ?? (selection.rect.contains(pointer) ? .openHand : .crosshair)
            } else {
                cursor = .crosshair
            }
        }
        view.cursor = cursor
        if !isHeadless { cursor.set() }
    }

    /// Capture mode: the pointer picks the element, window, or display under it. A level picked with a key holds until the pointer leaves it.
    private func updateHover(pixel: CGPoint) {
        guard selection == nil, case .none = interaction else { return }
        if mode == .capture, session != nil {
            requestAccessibility(at: pixel)
            if session!.isLocked, !session!.holds(at: pixel) { session!.toggleLock() }
            session!.hover(at: pixel)
        }
        refresh()
    }

    /// The rectangle a click would capture. The full display shows once a key has walked out to it or the pointer is at the screen edge.
    private var hoverRect: CGRect? {
        guard mode == .capture, let session, let selected = session.selected,
              selected.kind != .display || session.isLocked || session.anchorAtEdge else { return nil }
        return selected.bounds
    }

    func mouseDown(_ event: NSEvent) {
        guard mode == .capture else { return }
        let point = view.pixelPoint(event)
        pointer = point
        hadSelection = selection != nil
        if let selection {
            if let handle = selection.handle(at: point, tolerance: 8 * scale) {
                interaction = .resizing(handle)
                edgeFrames = []
                edgeFramesTask?.cancel()
                edgeFramesTask = Task { edgeFrames = try await snapFrames(around: selection.rect) }
                return updateCursor()
            }
            if selection.rect.contains(point) {
                interaction = .moving(last: point, moved: false)
                return updateCursor()
            }
        }
        selection = nil
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
            drag.update(to: point, moving: spaceHeld)
            interaction = .drawing(drag)
            scheduleSnap(for: drag.rect)
        case .resizing(let handle):
            snapResize(handle, to: point, exact: event.modifierFlags.contains(.option))
        case .moving(let last, _):
            selection?.move(by: CGPoint(x: point.x - last.x, y: point.y - last.y))
            interaction = .moving(last: point, moved: true)
        }
        updateCursor()
        refresh()
    }

    /// Moves the sides a handle controls to the pointer. Each snaps to the nearest pixel edge or accessibility edge
    /// within the band, unless snap is off or Option is held.
    private func snapResize(_ handle: Handle, to point: CGPoint, exact: Bool) {
        guard let image, let rect = selection?.rect else { return }
        var target = point
        var snapped = (x: false, y: false)
        if snapEnabled, !exact {
            for vertical in [true, false] where vertical ? handle.movesLeft || handle.movesRight : handle.movesTop || handle.movesBottom {
                let value = vertical ? point.x : point.y
                let band = SmartSnap.band(side: vertical ? rect.width : rect.height, scale: scale)
                // Cancellation is the only error here and a drag event is never cancelled.
                let pixel = try! SmartSnap().edges(in: image, of: rect, vertical: vertical, near: value, band: band)
                guard let edge = SnapFits.edge(near: value, band: CGFloat(band), frames: edgeFrames, pixel: pixel, vertical: vertical) else { continue }
                if vertical { target.x = edge; snapped.x = true } else { target.y = edge; snapped.y = true }
            }
        }
        selection?.resize(handle, to: target)
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
        case .none, .resizing:
            break
        case .moving(_, let moved):
            if !moved { copy() }
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
        } else if var current = selection, !current.isEdited {
            if !snapEnabled {
                current.selectExact()
                selection = current
            } else if current.fits.count > 1 {
                current.selectBest()
                selection = current
            } else {
                cycleFit(backward: false, toBest: true)
            }
        }
        refresh()
    }

    /// Tab: the next fit. After a quick drag with no suggestions, computes them for the current rectangle first;
    /// `toBest` then takes the best fit instead of stepping.
    private func cycleFit(backward: Bool, toBest: Bool = false) {
        guard var current = selection, let image else { return }
        guard current.fits.count == 1 else {
            current.cycle(backward: backward)
            selection = current
            return
        }
        let rough = current.rect
        snapTask?.cancel()
        snapTask = Task {
            let suggestions = try await fits(for: rough, in: image)
            try Task.checkCancellation()
            guard selection?.rect == rough else { return }
            selection?.setSuggestions(suggestions)
            if toBest { selection?.selectBest() } else { selection?.cycle(backward: backward) }
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
        let step: CGFloat = shift ? 10 : 1
        let character = event.charactersIgnoringModifiers ?? ""
        let hovering = selection == nil
        switch (event.keyCode, command, character) {
        case (53, _, _): dismiss()
        case (36, _, _) where hovering, (76, _, _) where hovering: clickHover(shadow: windowShadow(option: false), copy: true, save: afterCaptureSaves, takeDisplay: true)
        case (_, true, "s") where hovering: clickHover(shadow: windowShadow(option: false), copy: false, save: true, takeDisplay: true)
        case (36, _, _) where shift || option, (76, _, _) where shift || option: copySelectionText(translating: option)
        case (36, _, _), (76, _, _): copy()
        case (48, _, _) where hovering: if shift { session?.shrink() } else { session?.expand() }
        case (126, _, _) where hovering: session?.expand()
        case (125, _, _) where hovering: session?.shrink()
        case (_, false, "1"..."5") where hovering && defaults.bool(forKey: Pref.candidates): session?.pick(Int(character)! - 1)
        case (48, _, _): cycleFit(backward: shift)
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
        case (_, false, "s"): toggleSnap()
        case (_, false, "f"):
            cancelWork()
            selection = AreaSelection(extent: extent, exact: extent)
        default: return false
        }
        return true
    }

    // MARK: Output

    var afterCaptureSaves: Bool { defaults.string(forKey: Pref.afterCapture) == "copyAndSave" }

    func copy() {
        guard let rect = selection?.rect else { return }
        if style == .tight, let index = window(matching: rect) {
            return clickWindow(index, crop: rect, shadow: windowShadow(option: false), copy: true, save: afterCaptureSaves)
        }
        finish(crop: rect, copy: true, save: afterCaptureSaves)
    }

    /// The window whose frame `rect` matches within 3 pt on every side: copying it captures the real window shape, not a crop.
    private func window(matching rect: CGRect) -> Int? {
        windows.firstIndex { abs($0.minX - rect.minX) <= 3 * scale && abs($0.minY - rect.minY) <= 3 * scale
            && abs($0.maxX - rect.maxX) <= 3 * scale && abs($0.maxY - rect.maxY) <= 3 * scale }
    }

    func save() {
        guard let rect = selection?.rect else { return }
        finish(crop: rect, copy: false, save: true)
    }

    /// A click (or Return / Cmd-S) on the hovered rectangle. A window, or anything matching a window's frame, is captured as a window;
    /// the full display becomes a selection on click and is taken directly with `takeDisplay`; anything else is cropped from the
    /// frozen image with its measured corner radius.
    private func clickHover(shadow: Bool, copy: Bool, save: Bool, takeDisplay: Bool = false) {
        guard let hovered = session?.selected else { return }
        switch hovered.kind {
        case .window: clickWindow(Int(hovered.id.dropFirst("window-".count))!, crop: hovered.bounds, shadow: shadow, copy: copy, save: save)
        case .display where !takeDisplay: selection = AreaSelection(extent: extent, exact: extent)
        default:
            if style == .tight, let index = window(matching: hovered.bounds) {
                return clickWindow(index, crop: hovered.bounds, shadow: shadow, copy: copy, save: save)
            }
            finish(crop: hovered.bounds, copy: copy, save: save)
        }
    }

    /// A live capture takes the window itself like macOS does (rounded corners, shadow, transparent background); a frozen-image run,
    /// the Dock, the menu bar, and menus have no window to capture and crop `crop`.
    private func clickWindow(_ index: Int, crop rect: CGRect, shadow: Bool, copy: Bool, save: Bool) {
        guard displayID != nil, !windowFrozen.indices.contains(index) || !windowFrozen[index] else { return finish(crop: rect, copy: copy, save: save) }
        let id = windowIDs[index]
        // macOS 26 window captures come back with square corners; the radius is measured on the frozen screen around the window.
        let radius = radii[windows[index]] ?? image.map { cornerRadius(in: $0, rect: windows[index]) } ?? 0
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let image = roundingWindowCorners(try await DisplayCapture.image(ofWindow: id, shadow: shadow), radius: radius)
                let png = try await Output.png(image)
                try Output.publish(png: png, detail: "\(image.width) x \(image.height)  window", copy: copy, save: save,
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

    /// Measures a fit's corner radius off the main thread, once, and redraws when it arrives.
    private func measureRadius(_ rect: CGRect?) {
        guard let rect, let image, radii[rect] == nil, radiusTasks[rect] == nil else { return }
        radiusTasks[rect] = Task {
            let radius = await Task.detached { cornerRadius(in: image, rect: rect) }.value
            if self.image === image {
                radii[rect] = radius
                refresh()
            }
            return radius
        }
    }

    /// Closes the overlay first, then encodes off main and delivers.
    func finish(crop: CGRect, copy: Bool, save: Bool) {
        guard let image else { return }
        let style = style, scale = scale
        let known = radii[crop], measuring = radiusTasks[crop]
        // The frontmost window holding the crop: its measured radius clears the crop's corners that sit on the window's corners.
        let container = windows.first { $0.insetBy(dx: -2, dy: -2).contains(crop) }
        let containerRadius = container.flatMap { radii[$0] }
        if let displayID {
            let area = [Double(displayID)] + [crop.minX, crop.minY, crop.width, crop.height].map { Double($0 / scale) }
            defaults.set(area, forKey: Pref.lastArea)
        }
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let radius = if let known { known } else { await measuring?.value ?? 0 }
                var window: (rect: CGRect, radius: CGFloat)?
                if let container {
                    let measured = containerRadius == nil ? await Task.detached { cornerRadius(in: image, rect: container) }.value : 0
                    window = (container, containerRadius ?? measured)
                }
                try await Output.deliver(image, crop: crop, style: style, scale: scale, cornerRadius: radius, window: window, copy: copy, save: save,
                                         pasteboard: pasteboard, defaults: defaults)
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
        var overlays = OverlayView.Overlays()
        if case .drawing(let drag) = interaction, drag.rect.width > 0 || drag.rect.height > 0 { overlays.ghost = drag.rect }
        overlays.preview = snapPreview
        overlays.selection = selection?.rect
        overlays.snappedEdges = snappedEdges
        overlays.showsHandles = selection != nil
        if selection == nil, case .none = interaction { overlays.hover = hoverRect }
        let fit = selection.flatMap { $0.rect == $0.exact ? nil : $0.rect }
        for rect in [snapPreview, fit, overlays.hover] { measureRadius(rect) }
        overlays.radius = radii[selection?.rect ?? snapPreview ?? .null] ?? 0
        overlays.hoverRadius = radii[overlays.hover ?? .null] ?? 0
        if let rect = selection?.rect, style != .tight { overlays.styleFrame = style.frame(around: rect, in: extent, scale: scale) }
        view.overlays = overlays
        refreshExtras()
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
