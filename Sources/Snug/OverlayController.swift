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
    /// The capture shrunk by its point-to-pixel scale, built once per capture off main. Element detection analyzes this and
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
    /// Text mode: the drag, region, OCR result, and picked item; the running OCR; and how links open.
    var text = TextSession()
    var textTask: Task<Void, Never>?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The whole image's OCR, started the first time Text mode needs it and reused for the capture.
    var textPage: Task<TextResult, any Error>?
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
    var hoverWindow: CGRect?
    var windowNames: [String] = []
    var windowIDs: [CGWindowID] = []
    /// Per window: a Dock, menu bar, or menu target, cropped from the frozen image instead of captured as a window.
    var windowFrozen: [Bool] = []
    /// Option is held: a window click inverts the shadow preference.
    var optionHeld = false
    /// Corner radius in pixels of each snap fit, Tab fit, Element candidate, and hovered window, measured once per rectangle.
    /// A rectangle that is not here (an exact drag, a nudged or resized selection) has square corners.
    var radii: [CGRect: CGFloat] = [:]
    private var radiusTasks: [CGRect: Task<CGFloat, Never>] = [:]
    /// The last pointer position in image pixels.
    var pointer = CGPoint.zero
    var session: SelectionSession?
    var elementTask: Task<Void, Never>?
    var elementCandidates: [Candidate] = []
    /// Element mode: the pointer-down pixel until the press turns into a drag (Area) or a click (copy).
    var elementPress: CGPoint?
    /// The running accessibility lookup and when the last one started (throttle).
    var accessibilityTask: Task<Void, Never>?
    var accessibilityStarted: ContinuousClock.Instant?
    var previousApp: NSRunningApplication?
    /// N hides the Element candidate list; it shows in Element mode otherwise.
    var listHidden = false
    private var interaction = Interaction.none
    private var snapSuggestions: [CGRect] = []
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
            defaults.set(!defaults.bool(forKey: $0), forKey: $0)
            refresh()
        }
        chrome.bottomBar.onStyle = { [unowned self] in style = style.next }
        chrome.styleBar.onStyle = { [unowned self] in style = $0 }
        chrome.styleBar.onSave = { [unowned self] in save() }
        chrome.styleBar.onCopy = { [unowned self] in copy() }
    }

    /// Shows the frozen image in the reused window. `frame` is in screen points.
    func present(image: CGImage, frame: CGRect, displayID: CGDirectDisplayID?) {
        cancelWork()
        textPage?.cancel()
        textPage = nil
        smallImage = nil
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
    }

    /// Supplies window rectangles (image pixels, front to back) once they are built.
    func setWindows(_ rects: [CGRect], names: [String] = [], ids: [CGWindowID] = [], frozen: [Bool] = [], pointer: CGPoint) {
        windows = rects
        windowNames = names
        windowIDs = ids
        windowFrozen = frozen
        if mode == .element { merge(windowCandidates) }
        updateHover(pixel: CGPoint(x: (pointer.x - window.frame.minX) * scale, y: (window.frame.maxY - pointer.y) * scale))
    }

    /// Closes the overlay, cancels pending work, and releases the frozen image.
    func dismiss() {
        cancelWork()
        textPage?.cancel()
        textPage = nil
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
        hoverWindow = nil
        selection = nil
        interaction = .none
        spaceHeld = false
        resetExtras()
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
        optionHeld = event.modifierFlags.contains(.option)
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
        guard mode != .text else { return textMouseDown(event) }
        let point = view.pixelPoint(event)
        guard mode != .element else { elementPress = point; return }
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
        guard mode != .text else { return textMouseDragged(event) }
        let point = view.pixelPoint(event)
        pointer = point
        if let press = elementPress, hypot(point.x - press.x, point.y - press.y) >= 4 * scale {
            elementPress = nil
            setMode(.area)
            interaction = .drawing(AreaDrag(extent: extent, origin: press))
        }
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
        guard mode != .text else { return textMouseUp(event) }
        let point = view.pixelPoint(event)
        if elementPress != nil {
            elementPress = nil
            return copy()
        }
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
                if !hadSelection {
                    if let hoverWindow { clickWindow(hoverWindow, shadow: windowShadow(option: event.modifierFlags.contains(.option))) }
                    else { selection = AreaSelection(extent: extent, exact: extent) }
                }
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
            case .text: handled = handleTextKey(event)
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

    /// A click on a hovered window. A live capture takes the window itself like macOS does (rounded corners, shadow,
    /// transparent background); a frozen-image run, the Dock, the menu bar, and menus have no window to capture and crop the rectangle.
    private func clickWindow(_ rect: CGRect, shadow: Bool) {
        let index = windows.firstIndex(of: rect)!
        guard displayID != nil, !windowFrozen.indices.contains(index) || !windowFrozen[index] else { return finish(crop: rect, copy: true, save: afterCaptureSaves) }
        let id = windowIDs[index]
        dismiss()
        commitTask = Task { [pasteboard, defaults, afterCaptureSaves] in
            do {
                let image = try await DisplayCapture.image(ofWindow: id, shadow: shadow)
                let png = try await Output.png(image)
                try Output.publish(png: png, detail: "\(image.width) x \(image.height)  window", copy: true, save: afterCaptureSaves,
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
    private func finish(crop: CGRect, copy: Bool, save: Bool) {
        guard let image else { return }
        let style = style, scale = scale
        let known = radii[crop], measuring = radiusTasks[crop]
        if let displayID {
            let area = [Double(displayID)] + [crop.minX, crop.minY, crop.width, crop.height].map { Double($0 / scale) }
            defaults.set(area, forKey: Pref.lastArea)
        }
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let radius = if let known { known } else { await measuring?.value ?? 0 }
                try await Output.deliver(image, crop: crop, style: style, scale: scale, cornerRadius: radius, copy: copy, save: save,
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
        guard mode != .text else { return refreshText() }
        view.textOverlay.layer.isHidden = true
        var overlays = OverlayView.Overlays()
        if case .drawing(let drag) = interaction, drag.rect.width > 0 || drag.rect.height > 0 { overlays.ghost = drag.rect }
        overlays.preview = snapPreview
        overlays.selection = selection?.rect
        overlays.showsHandles = selection != nil && mode != .element
        if selection == nil, case .none = interaction { overlays.hover = hoverWindow }
        let fit = mode == .element ? session?.selected?.bounds : selection.flatMap { $0.rect == $0.exact ? nil : $0.rect }
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
