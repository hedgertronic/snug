import AppKit
import ScreenshotCore

/// Mode switching, view toggles, color picking, the help sheet, and Capture mode's hover.
extension OverlayController {
    private var colorFormat: ColorFormat { ColorFormat(rawValue: defaults.string(forKey: Pref.colorFormat)!)! }

    /// The pointer pixel clamped into the image.
    private var pointerPixel: CGPoint {
        CGPoint(x: min(max(pointer.x.rounded(.down), 0), extent.width - 1), y: min(max(pointer.y.rounded(.down), 0), extent.height - 1))
    }

    /// Keys shared by every mode. Returns false for anything else.
    func handleExtrasKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        if event.keyCode == 53, !chrome.help.isHidden {
            chrome.help.isHidden = true
            return true
        }
        let toggles = ["b": Pref.modeBar, "l": Pref.loupe, "r": Pref.rulers, "x": Pref.crosshair, "n": Pref.candidates]
        let character = event.charactersIgnoringModifiers ?? ""
        if let key = toggles[character] {
            defaults.set(!defaults.bool(forKey: key), forKey: key)
            return true
        }
        switch character {
        case "a": setMode(.capture)
        case "t": setMode(.text)
        case "c": copyColor()
        case "C": cycleColorFormat()
        case "?": chrome.help.isHidden.toggle()
        default: return false
        }
        return true
    }

    /// Changing mode cancels in-flight work, clears the selection, and takes keyboard focus back to the overlay.
    func setMode(_ new: Mode) {
        guard new != mode else { return }
        cancelWork()
        detectionTask?.cancel()
        detectionTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
        session = nil
        selection = nil
        mode = new
        view.liveText.resetSelection()
        // A click in Live Text leaves focus there; hiding it would hand focus to the window, out of reach of the overlay's keys.
        window.makeFirstResponder(view)
        if image != nil { if new == .capture { startHover() } else { startLiveText() } }
        refresh()
    }

    /// Back to the state every capture opens in: Capture mode, no help, no cap lit, focus returned to the previous app.
    func resetExtras() {
        detectionTask?.cancel()
        detectionTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
        accessibilityStarted = nil
        session = nil
        detected = []
        dockTiles = []
        mode = .capture
        view.guides.loupeOffset = nil
        chrome.help.isHidden = true
        chrome.pressed = []
        if !isHeadless { previousApp?.activate() }
        previousApp = nil
    }

    // MARK: Color

    private var pickedColor: SRGBColor? {
        guard let image else { return nil }
        return ColorFormat.average(of: image, in: selection?.rect ?? CGRect(origin: pointerPixel, size: CGSize(width: 1, height: 1)))
    }

    private func swatch(_ color: SRGBColor) -> NSColor { NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }

    func copyColor() {
        guard let color = pickedColor else { return }
        let text = colorFormat.string(for: color)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        dismiss()
        Toast.show(message: "Copied", detail: text, color: swatch(color))
    }

    func cycleColorFormat() {
        guard let color = pickedColor else { return }
        let next = colorFormat.next
        defaults.set(next.rawValue, forKey: Pref.colorFormat)
        Toast.show(message: next.label, detail: next.string(for: color), color: swatch(color))
    }

    // MARK: Capture hover

    var windowCandidates: [Candidate] {
        windows.enumerated().map {
            Candidate(id: "window-\($0.offset)", label: "Window", bounds: $0.element, score: -Double($0.offset), kind: .window)
        }
    }

    /// A new hover session over the windows and the geometry found so far. Pixel geometry runs off main, once per capture, and joins
    /// the session when it finishes; it never reads text, which belongs to Text mode.
    func startHover() {
        buildSession()
        if detected.isEmpty {
            let (small, factor) = (small(), CGFloat(Int(scale)))
            detectionTask = Task {
                do {
                    let found = try await GeometryDetector().detect(in: await small.value).map { $0.scaled(by: factor) }
                    try Task.checkCancellation()
                    detected = found
                    merge(found)
                } catch {
                    report(error)
                }
            }
        }
        let small = small()
        fillsTask = Task {
            let built = await Task.detached { FlatFills(await small.value) }.value
            guard !Task.isCancelled else { return }
            fills = built
        }
        requestAccessibility(at: pointer)
    }

    /// Adds the small uniform fill under `pixel` (a pill, chip or input the geometry pass skips for its size) to the session unless a candidate already has its rect (within 4 pt).
    func addFill(at pixel: CGPoint) {
        let factor = CGFloat(Int(scale))
        guard let fill = fills?.region(at: CGPoint(x: pixel.x / factor, y: pixel.y / factor))?.scaled(by: factor).grownToBorder(in: image!),
              !session!.candidates.contains(where: { $0.bounds.isNear(fill.bounds, within: 4 * factor) }) else { return }
        session!.merge([fill])
    }

    func buildSession() {
        session = SelectionSession(candidates: detected + dockTiles + windowCandidates, extent: extent, anchor: pointer)
    }

    /// Late results (geometry, accessibility) join the pool; a level picked with a key and the list order stay as they are.
    func merge(_ added: [Candidate]) {
        session!.merge(added)
        refresh()
    }

    /// While the capture is live and Accessibility is allowed, asks the window under `pixel` for the elements there, off main,
    /// at most about every 150 ms. Nothing happens without permission, in debug runs, or when the lookup finds nothing.
    func requestAccessibility(at pixel: CGPoint) {
        guard displayID != nil, !isHeadless, AXIsProcessTrusted(), accessibilityTask == nil,
              accessibilityStarted.map({ $0.duration(to: .now) >= .milliseconds(150) }) ?? true,
              let index = windows.firstIndex(where: { $0.contains(pixel) }), windowIDs.indices.contains(index),
              AccessibilityBounds.looksUp(inWindowNamed: windowNames[index], frozen: windowFrozen[index]) else { return }
        accessibilityStarted = .now
        let id = windowIDs[index]
        let primaryHeight = NSScreen.screens[0].frame.height
        let origin = CGPoint(x: window.frame.minX, y: primaryHeight - window.frame.maxY)
        let point = AccessibilityBounds.point(forPixel: pixel, displayOrigin: origin, scale: scale)
        let (scale, extent, image) = (scale, extent, image!)
        accessibilityTask = Task {
            defer { accessibilityTask = nil }
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            guard let pid = info?.first?[kCGWindowOwnerPID as String] as? Int32 else { return }
            let frames = await Accessibility.frames(at: point, pid: pid)
            guard !Task.isCancelled, mode == .capture else { return }
            let found = StageManager.visibleThumbnails(try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(frames), displayOrigin: origin,
                                                                                                scale: scale, extent: extent), frames: frames, in: image, scale: scale)
            Pref.logHoverLine("hover \(point) scale \(scale) frames " + frames.map { "\($0.role) '\($0.roleDescription)' '\($0.title)' \($0.rect)" }.joined(separator: " | ")
                + " -> " + found.map { "\($0.label) \($0.bounds)" }.joined(separator: " | "))
            if !found.isEmpty { merge(found.map { $0.grownToBorder(in: image) }) }
        }
    }

    // MARK: Drawing

    func refreshExtras() {
        refreshChrome()
        updateGuides()
    }

    func updateGuides() {
        let guides = view.guides
        guides.crosshair.isHidden = !defaults.bool(forKey: Pref.crosshair)
        let animation = GuidesAnimation(rawValue: defaults.string(forKey: Pref.guidesAnimation)!)!
        let animated = !isHeadless && animation != GuidesAnimation.none
        guides.setShown(guides.rulers, defaults.bool(forKey: Pref.rulers), from: animation == .slide ? Guides.rulersHiddenTransform : CATransform3DIdentity, animated: animated)
        guides.setShown(guides.loupe, defaults.bool(forKey: Pref.loupe), from: Guides.loupeHiddenTransform, animated: animated)
        guides.slidesPlacement = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !(guides.crosshair.isHidden && guides.rulers.isHidden && guides.loupe.isHidden) else { return }
        // While a drag carries a max side with the pointer, the loupe centers on the last pixel inside the crop, whose max sides round up,
        // so the outline keeps to the center cell's far side as the pointer crosses pixel boundaries.
        var pixel = pointerPixel
        if let dragged = draggedRect {
            if pointer.x == dragged.maxX { pixel.x = min(max(pointer.x.rounded(.up) - 1, 0), extent.width - 1) }
            if pointer.y == dragged.maxY { pixel.y = min(max(pointer.y.rounded(.up) - 1, 0), extent.height - 1) }
        }
        guides.update(point: CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale), pixel: pixel,
                      image: image, bounds: view.bounds, scale: scale, topInset: topInset,
                      selected: draggedRect ?? selection?.rect, dragging: draggedRect != nil,
                      avoiding: [chrome.topBar, chrome.strip, chrome.hints, chrome.list].filter { !$0.isHidden }.map(\.frame))
    }
}
