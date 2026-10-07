import AppKit
import ScreenshotCore

/// Mode switching, view toggles, color picking, the help sheet, and Element mode.
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
        let toggles = ["b": Pref.modeBar, "l": Pref.loupe, "r": Pref.rulers, "x": Pref.crosshair]
        let character = event.charactersIgnoringModifiers ?? ""
        if let key = toggles[character] {
            defaults.set(!defaults.bool(forKey: key), forKey: key)
            return true
        }
        switch character {
        case "a": setMode(.area)
        case "e" where defaults.bool(forKey: Pref.elementMode): setMode(.element)
        case "t": setMode(.text)
        case "c": copyColor()
        case "C": cycleColorFormat()
        case "?": chrome.help.isHidden.toggle()
        case "n" where mode == .element: listHidden.toggle()
        default: return false
        }
        return true
    }

    /// Changing mode cancels in-flight work and clears the selection.
    func setMode(_ new: Mode) {
        guard new != mode else { return }
        cancelWork()
        elementTask?.cancel()
        elementTask = nil
        session = nil
        selection = nil
        hoverWindow = nil
        listHidden = false
        elementCandidates = []
        mode = new
        if new == .element {
            guard let image else { return }
            buildSession()
            elementTask = Task {
                do {
                    elementCandidates = try await GeometryDetector().detect(in: image)
                    try Task.checkCancellation()
                    buildSession()
                    elementCandidates += try await VisionDetector().detectText(in: image)
                    try Task.checkCancellation()
                    buildSession()
                } catch {
                    report(error)
                }
            }
        }
        refresh()
    }

    /// Back to the state every capture opens in: Area mode, no help, focus returned to the previous app.
    func resetExtras() {
        elementTask?.cancel()
        elementTask = nil
        session = nil
        elementCandidates = []
        mode = .area
        chrome.help.isHidden = true
        listHidden = false
        if !isHeadless { previousApp?.activate() }
        previousApp = nil
    }

    // MARK: Color

    private var pickedColor: SRGBColor? {
        guard let image else { return nil }
        return ColorFormat.average(of: image, in: selection?.rect ?? CGRect(origin: pointerPixel, size: CGSize(width: 1, height: 1)))
    }

    private func swatch(_ color: SRGBColor) -> NSColor { NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1) }

    private func copyColor() {
        guard let color = pickedColor else { return }
        let text = colorFormat.string(for: color)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        dismiss()
        Toast.show(message: "Copied", detail: text, color: swatch(color))
    }

    private func cycleColorFormat() {
        guard let color = pickedColor else { return }
        let next = colorFormat.next
        defaults.set(next.rawValue, forKey: Pref.colorFormat)
        Toast.show(message: next.label, detail: next.string(for: color), color: swatch(color))
    }

    // MARK: Element mode

    /// Window rectangles join the detected candidates; the session starts at the pointer.
    func buildSession() {
        let windowCandidates = windows.enumerated().map {
            Candidate(id: "window-\($0.offset)", label: "Window", bounds: $0.element, score: -Double($0.offset), kind: .window)
        }
        session = SelectionSession(candidates: elementCandidates + windowCandidates, extent: extent, anchor: pointer)
        syncSelection()
    }

    /// Hover selects until the user draws, nudges, or locks the session with a key.
    func elementHover(pixel: CGPoint) {
        guard var session, selection == nil || selection!.rect == session.selected?.bounds else { return }
        session.hover(at: pixel)
        self.session = session
        syncSelection()
    }

    private func syncSelection() {
        selection = session?.selected.map { AreaSelection(extent: extent, exact: $0.bounds) }
        refresh()
    }

    func handleElementKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let character = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, command, character) {
        case (126, _, _): session?.expand()
        case (125, _, _): session?.shrink()
        case (_, false, "1"..."5"): session?.pick(Int(character)! - 1)
        default: return handleAreaKey(event)
        }
        syncSelection()
        return true
    }

    // MARK: Drawing

    func refreshExtras() {
        refreshChrome()
        updateGuides()
    }

    func updateGuides() {
        let guides = view.guides
        guides.crosshair.isHidden = !defaults.bool(forKey: Pref.crosshair)
        guides.rulers.isHidden = !defaults.bool(forKey: Pref.rulers)
        guides.loupe.isHidden = !defaults.bool(forKey: Pref.loupe)
        guard !(guides.crosshair.isHidden && guides.rulers.isHidden && guides.loupe.isHidden) else { return }
        guides.update(point: CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale), pixel: pointerPixel,
                      image: image, bounds: view.bounds, scale: scale, topInset: topInset,
                      span: (selection?.rect ?? text.rect).map(view.viewRect))
    }
}
