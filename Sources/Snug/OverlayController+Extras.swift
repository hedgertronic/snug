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
        let toggles = ["l": Pref.loupe, "r": Pref.rulers, "x": Pref.crosshair, "n": Pref.candidates]
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
        accessibilityPixel = nil
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

    /// Copies `color`, or the pointer's color or the selection's average, in the chosen format, and closes the overlay.
    func copyColor(_ color: SRGBColor? = nil) {
        guard let color = color ?? pickedColor else { return }
        let text = colorFormat.string(for: color)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        dismiss()
        Toast.show(message: "Copied", detail: text, color: swatch(color))
    }

    /// U on a selection, or on the hovered element (the rectangle Return would copy): the menu under the Colors button, with the area's
    /// average (what C copies) and its five main colors, each copied by its row or its 1-6 key. The colors are worked out off main,
    /// since they take over 5 ms on a large selection.
    func showColorsMenu() {
        guard let rect = selection?.rect ?? hoverRect, let image else { return }
        Task {
            let (average, palette) = await Task.detached { (ColorFormat.average(of: image, in: rect), ColorFormat.palette(of: image, in: rect)) }.value
            guard (selection?.rect ?? hoverRect) == rect else { return }
            let rows = [average] + palette
            let items = rows.enumerated().map { index, color in
                RatioMenu.Item(title: colorFormat.string(for: color), on: false, swatch: swatch(color), cap: "\(index + 1)") { [self] in copyColor(color) }
            }
            let button = chrome.colors
            chrome.colorMenu.open(Array(items.prefix(1)) + [RatioMenu.Item(title: "", on: false) {}] + items.dropFirst(), under: view.convert(button.bounds, from: button))
            refresh()
        }
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

    /// While the capture is live and Accessibility is allowed, asks the window under `pixel` for the elements there and for the hovered
    /// element's peers (Left and Right step among them), off main, at most about every 150 ms. A request the throttle drops comes
    /// again once it ends, at the pointer, unless the pointer is on the pixel the last lookup used. Nothing happens without
    /// permission, in debug runs, or when the lookup finds nothing.
    func requestAccessibility(at pixel: CGPoint) {
        guard displayID != nil, !isHeadless, AXIsProcessTrusted(),
              let index = windows.firstIndex(where: { $0.contains(pixel) }), windowIDs.indices.contains(index),
              AccessibilityBounds.looksUp(inWindowNamed: windowNames[index], frozen: windowFrozen[index]) else { return }
        guard accessibilityTask == nil, accessibilityStarted.map({ $0.duration(to: .now) >= .milliseconds(150) }) ?? true else {
            accessibilityRetry?.cancel()
            accessibilityRetry = Task {
                try await Task.sleep(for: .milliseconds(160))
                if mode == .capture, session != nil, pointerPixel != accessibilityPixel { requestAccessibility(at: pointer) }
            }
            return
        }
        accessibilityStarted = .now
        accessibilityPixel = CGPoint(x: pixel.x.rounded(.down), y: pixel.y.rounded(.down))
        let id = windowIDs[index]
        let primaryHeight = NSScreen.screens[0].frame.height
        let origin = CGPoint(x: window.frame.minX, y: primaryHeight - window.frame.maxY)
        let point = AccessibilityBounds.point(forPixel: pixel, displayOrigin: origin, scale: scale)
        let (scale, extent, image, windows) = (scale, extent, image!, windows)
        accessibilityTask = Task {
            defer { accessibilityTask = nil }
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            guard let pid = info?.first?[kCGWindowOwnerPID as String] as? Int32 else { return }
            let began = ContinuousClock.now
            let (frames, peers) = await Accessibility.framesAndPeers(at: point, pid: pid)
            let lookup = began.duration(to: .now)
            guard !Task.isCancelled, mode == .capture else { return }
            let found = StageManager.visibleThumbnails(try await AccessibilityBounds.candidates(frames: AccessibilityBounds.hoverLevel(frames), displayOrigin: origin,
                                                                                                scale: scale, extent: extent), frames: frames, in: image, scale: scale)
            // A peer nobody hit can sit under another window: only those whose center is in this window's visible part count.
            let peerFound = StageManager.visibleThumbnails(try await AccessibilityBounds.peerCandidates(peers, displayOrigin: origin, scale: scale, extent: extent),
                                                           frames: frames, in: image, scale: scale)
                .filter { peer in windows.firstIndex { $0.contains(CGPoint(x: peer.bounds.midX, y: peer.bounds.midY)) } == index }
            Pref.logHoverLine("hover \(point) scale \(scale) frames " + frames.map { "\($0.role) '\($0.roleDescription)' '\($0.title)' \($0.rect)" }.joined(separator: " | ")
                + " -> " + found.map { "\($0.label) \($0.bounds)" }.joined(separator: " | ") + " | lookup with \(peers.count) peers \(lookup), \(peerFound.count) candidates")
            guard !found.isEmpty else { return }
            let grown = await Task.detached { (found + peerFound).map { $0.grownToBorder(in: image) } }.value
            guard !Task.isCancelled, session != nil else { return }
            // The hit element's chain covers its own candidates; a peer's AX data comes from a hit test at copy time.
            for candidate in grown.prefix(found.count) { accessibilityObservations[candidate.bounds] = (frames, .now) }
            merge(grown)
        }
    }

    // MARK: Drawing

    func refreshExtras() {
        refreshChrome()
        updateGuides()
    }

    func updateGuides() {
        let guides = view.guides
        // Armed recording shows no guides, and brings them back when it ends.
        let armed = armedRecording != nil
        guides.crosshair.isHidden = armed || !defaults.bool(forKey: Pref.crosshair)
        let animation = GuidesAnimation(rawValue: defaults.string(forKey: Pref.guidesAnimation)!)!
        let animated = !isHeadless && animation != GuidesAnimation.none
        guides.setShown(guides.rulers, !armed && defaults.bool(forKey: Pref.rulers), from: animation == .slide ? Guides.rulersHiddenTransform : CATransform3DIdentity, animated: animated)
        guides.setShown(guides.loupe, !armed && defaults.bool(forKey: Pref.loupe), from: Guides.loupeHiddenTransform, animated: animated)
        guides.slidesPlacement = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Hovering with nothing selected or dragged, the pointer cluster `[x 123  y 456] [Snap S]` sits 16 pt below and right of the pointer, or
        // centered under the loupe's readout, clamped into the view.
        defer {
            let (tag, coordinates) = (chrome.snapTag, chrome.coordinates)
            let hovering = mode == .capture && selection == nil && draggedRect == nil && scrollArea == nil && armedRecording == nil && cutout == nil && image != nil
            coordinates.isHidden = !hovering
            if hovering {
                tag.setTitle("Snap")
                tag.lit = snapEnabled
                let text = "x \(Int(pointerPixel.x))  y \(Int(pointerPixel.y))"
                coordinates.show(text) { [NSTextField(text, size: 12, mono: true, color: .chromeText)] }
                let width = coordinates.frame.width + Guides.clusterGap + tag.frame.width
                let point = CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale)
                let below = guides.readout.isHidden ? CGPoint(x: point.x + 16, y: point.y - 16 - tag.frame.height)
                    : CGPoint(x: guides.readout.frame.midX - width / 2, y: guides.readout.frame.minY - Guides.clusterGap - tag.frame.height)
                let origin = CGPoint(x: min(max(below.x, 8), view.bounds.width - width - 8),
                                     y: min(max(below.y, 8), view.bounds.height - topInset - tag.frame.height - 4))
                coordinates.frame.origin = origin
                tag.frame.origin = CGPoint(x: origin.x + coordinates.frame.width + Guides.clusterGap, y: origin.y)
                tag.isHidden = false
            }
        }
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
                      avoiding: [chrome.topBar, chrome.strip, chrome.list, chrome.hover, chrome.size, chrome.snap, chrome.ratio, chrome.radius, chrome.status,
                                 chrome.reading, chrome.legend, chrome.colorMenu, chrome.ratioMenu].filter { !$0.isHidden }.map(\.frame))
    }
}
