import AppKit
import ScreenshotCore

/// Mode switching, view toggles, color picking, the help sheet, and Element mode.
extension OverlayController {
    static let help: [(keys: String, action: String, modes: [Mode])] = [
        ("A / E / T", "Area / Element / Text mode", [.area, .element, .text]),
        ("drag", "select a region", [.area, .text]),
        ("click", "copy the window under the pointer", [.area, .element]),
        ("Option-drag", "exact rectangle, no snap", [.area]),
        ("F", "full screen", [.area, .element]),
        ("S", "snap on / off", [.area, .element]),
        ("Tab / Shift-Tab", "other fits", [.area, .element]),
        ("arrows", "nudge (Shift: 10 pt)", [.area]),
        ("Up / Down", "grow / shrink the element", [.element]),
        ("1-5", "pick a candidate", [.element]),
        ("N", "candidate list", [.element]),
        ("Cmd-1/2/3, M", "tight / margin / backdrop", [.area, .element]),
        ("Return", "copy", [.area, .element, .text]),
        ("Cmd-S", "save", [.area, .element]),
        ("Tab", "step through found items", [.text]),
        ("Shift-Return", "copy as a table", [.text]),
        ("Cmd-Return", "open the picked link", [.text]),
        ("C / Shift-C", "copy color / cycle HEX RGB HSL Swift", [.area, .element, .text]),
        ("L / R / X", "loupe / rulers / crosshair", [.area, .element, .text]),
        ("B", "mode bar", [.area, .element, .text]),
        ("?", "this help", [.area, .element, .text]),
        ("Esc", "cancel", [.area, .element, .text])
    ]

    private var colorFormat: ColorFormat { ColorFormat(rawValue: defaults.string(forKey: Pref.colorFormat)!)! }

    /// The pointer pixel clamped into the image.
    private var pointerPixel: CGPoint {
        CGPoint(x: min(max(pointer.x.rounded(.down), 0), extent.width - 1), y: min(max(pointer.y.rounded(.down), 0), extent.height - 1))
    }

    /// Keys shared by every mode. Returns false for anything else.
    func handleExtrasKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
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
        case "?": helpPanel.isHidden.toggle()
        case "n" where mode == .element: listPanel.isHidden.toggle()
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
        listPanel.isHidden = true
        mode = new
        if new == .element {
            guard let image else { return }
            buildSession()
            elementTask = Task {
                do {
                    let report = try await Detection.run(.geometry, image: image)
                    try Task.checkCancellation()
                    elementCandidates = report.candidates
                    buildSession()
                } catch is CancellationError {
                } catch {
                    NSApp.presentError(error)
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
        helpPanel.isHidden = true
        listPanel.isHidden = true
        previousApp?.activate()
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
        Toast.show(message: "Copied \(text)", color: swatch(color))
    }

    private func cycleColorFormat() {
        guard let color = pickedColor else { return }
        let next = colorFormat.next
        defaults.set(next.rawValue, forKey: Pref.colorFormat)
        Toast.show(message: "\(next.label): \(next.string(for: color))", color: swatch(color))
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
        modeBar.isHidden = !defaults.bool(forKey: Pref.modeBar)
        modeBar.update(mode: mode, elementEnabled: defaults.bool(forKey: Pref.elementMode))
        modeBar.frame.origin = CGPoint(x: (view.bounds.width - modeBar.frame.width) / 2, y: view.bounds.height - modeBar.frame.height - 12)
        if !helpPanel.isHidden {
            helpPanel.text = "Keys: \(String(describing: mode).capitalized)\n\n"
                + Self.help.filter { $0.modes.contains(mode) }.map { "\($0.keys)\t\($0.action)" }.joined(separator: "\n")
            helpPanel.frame.origin = CGPoint(x: (view.bounds.width - helpPanel.frame.width) / 2, y: (view.bounds.height - helpPanel.frame.height) / 2)
        }
        if !listPanel.isHidden, let session {
            listPanel.text = session.shortlist.enumerated().map { index, candidate in
                "\(candidate.id == session.selected?.id ? ">" : " ") \(index + 1)  \(candidate.kind.rawValue.capitalized)\t\(Int(candidate.bounds.width)) x \(Int(candidate.bounds.height)) px"
            }.joined(separator: "\n")
            listPanel.frame.origin = CGPoint(x: 12, y: view.bounds.height - listPanel.frame.height - modeBar.frame.height - 24)
        }
        updateGuides()
    }

    func updateGuides() {
        let guides = view.guides
        guides.crosshair.isHidden = !defaults.bool(forKey: Pref.crosshair)
        guides.rulers.isHidden = !defaults.bool(forKey: Pref.rulers)
        guides.loupe.isHidden = !defaults.bool(forKey: Pref.loupe)
        guard !(guides.crosshair.isHidden && guides.rulers.isHidden && guides.loupe.isHidden) else { return }
        guides.update(point: CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale), pixel: pointerPixel,
                      image: image, bounds: view.bounds, scale: scale)
    }
}
