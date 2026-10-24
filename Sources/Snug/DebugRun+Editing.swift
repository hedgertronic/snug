import AppKit
import ScreenshotCore

extension DebugRun {
    /// Selection editing through synthesized events: E and Shift-click, the union, corner dots, Apply to all, O, edge nudges, Save As.
    /// Returns the checks that passed; a failure prints and exits.
    static func verifyEditing(image: CGImage, frame: CGRect, overlay: OverlayController, folder: URL) async throws -> [String] {
        let pasteboard = overlay.pasteboard
        let defaults = overlay.defaults
        var passed: [String] = []

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("Editing verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<9000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            require(condition(), message)
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        func click(_ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            mouse(.leftMouseDown, pixel, flags)
            mouse(.leftMouseUp, pixel, flags)
        }
        func drag(from start: CGPoint, by delta: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            mouse(.leftMouseDown, start, flags)
            mouse(.leftMouseDragged, CGPoint(x: start.x + delta.x / 2, y: start.y + delta.y / 2), flags)
            mouse(.leftMouseDragged, CGPoint(x: start.x + delta.x, y: start.y + delta.y), flags)
            mouse(.leftMouseUp, CGPoint(x: start.x + delta.x, y: start.y + delta.y), flags)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
        func equal(_ a: CornerRadii, _ b: CornerRadii) -> Bool { CornerRadii.corners.allSatisfy { near(a[$0], b[$0]) } }

        let returnKey: UInt16 = 36
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        let scale = overlay.scale
        let a = CGRect(x: 300, y: 300, width: 400, height: 200)
        let b = CGRect(x: 800, y: 300, width: 200, height: 150)
        let insideA = CGPoint(x: 350, y: 350), insideB = CGPoint(x: 900, y: 350)
        let radius = 20 * scale
        let step = 5 * scale
        func open() {
            overlay.dismiss()
            overlay.present(image: image, frame: frame, displayID: nil)
            overlay.detectionTask?.cancel()
            overlay.setWindows([a, b], pointer: CGPoint(x: frame.minX + 10, y: frame.maxY - 10))
            overlay.radii[a] = radius
            overlay.radii[b] = radius
            mouse(.mouseMoved, insideA)
        }
        func dot(_ corner: Handle) -> CGPoint {
            let rect = overlay.selection!.rect
            return overlay.cornerRadii(of: rect).dot(of: corner, in: rect, minimumInset: 8 * scale)
        }
        func radii() -> CornerRadii { overlay.cornerRadii(of: overlay.selection!.rect) }

        // The key map: the help table lists the new keys, and every key the keys line used to show.
        open()
        let helpKeys = HelpSheet.columns.flatMap(\.rows).map(\.keys)
        let keysLineKeys = ["drag", "\u{2325} click", "F", "W", "tab", "C", "+ / -", "\u{2191} / \u{2193}", "\u{2190} \u{2192}", "\u{2325} arrow", "\u{2325} \u{2318} arrow",
                            "\u{2303} \u{2325} arrow", "\u{2303} \u{2325} \u{2318} arrow", "\u{2318} Z", "Text: drag", "Text: \u{21A9}", "Text: \u{21E7} \u{21A9}", "Text: tab", "Text: \u{2325} \u{21A9}",
                            "Menus: \u{2191} / \u{2193}", "Subject: K / esc", "?"]
        require(keysLineKeys.allSatisfy(helpKeys.contains) && !helpKeys.contains("B"),
                "the help table lists every key the keys line showed, and no B: missing \(keysLineKeys.filter { !helpKeys.contains($0) })")
        require(["\u{21E7} \u{2318} S", "E / \u{21E7} click", "\u{2325} arrow", "\u{21E7} click", "\u{21E7} drag", "P", "M", "=", "O"].allSatisfy(helpKeys.contains), "the help table lists the new keys")
        require(!["Cmd-1/2", "Corner dot"].contains(where: helpKeys.contains) && HelpSheet.columns.flatMap(\.rows).contains { $0.keys == "O" && $0.action == "Rounded corners" },
                "the help table has no Cmd-1/2 or Corner dot row, and O reads Rounded corners")

        // E opens the hovered window as a selection that keeps its radii, even after a nudge (the measured radius is by rectangle).
        require(overlay.view.overlays.hover == a, "the pointer hovers window A")
        key(14, "e")
        require(overlay.selection?.rect == a, "E opens the hovered element as a selection")
        try await waitFor("E carries the hovered corner radii as edited ones") { overlay.editedRadii[a] == CornerRadii(radius) }
        require(overlay.view.overlays.showsHandles && overlay.view.overlays.radii == CornerRadii(radius), "the selection shows handles and the carried radii")
        key(right, "", .shift)
        require(overlay.selection?.rect == a.offsetBy(dx: 10, dy: 0) && overlay.view.overlays.radii == CornerRadii(radius), "Shift-Right moves 10 px, and a nudged E selection keeps its radii")
        key(left, "", .shift)
        key(down)
        require(overlay.selection?.rect == a.offsetBy(dx: 0, dy: 1), "an arrow moves the selection 1 device pixel, not 1 pt")
        key(up)
        require(overlay.chrome.cutout.window != nil && !overlay.chrome.strip.isHidden, "the strip offers Subject")

        // Corner dots: cursor, drag all, Option-drag one, clamp.
        mouse(.mouseMoved, dot(.topLeft))
        require(overlay.view.cursor === NSCursor.pointingHand, "the pointer over a corner dot shows a pointing hand")
        let before = radii()
        let along = CGPoint(x: step, y: step)
        let moved = 5 * scale * 2.0.squareRoot()
        drag(from: dot(.topLeft), by: along)
        require(overlay.selection?.rect == a, "dragging a dot does not move or resize the selection")
        require(equal(radii(), before.offset(by: moved, in: a.size)) && overlay.editedRadii[a].map({ equal($0, radii()) }) == true,
                "dragging a dot changes all four corners by the drag along the diagonal")
        require(texts(in: overlay.chrome.radius).first == "r \(Int(((before.topLeft + moved) / scale).rounded()))", "the radius chip reads the radius: \(texts(in: overlay.chrome.radius))")
        let all = radii()
        drag(from: dot(.bottomRight), by: CGPoint(x: -step, y: -step), .option)
        require(near(radii().bottomRight, all.bottomRight + moved) && near(radii().topLeft, all.topLeft) && near(radii().topRight, all.topRight)
                && near(radii().bottomLeft, all.bottomLeft), "Option-dragging a dot changes only that corner")
        require(texts(in: overlay.chrome.radius).first?.split(separator: "/").count == 4, "unequal corners read as four values: \(texts(in: overlay.chrome.radius))")
        require(overlay.lastEditedCorner == .bottomRight, "the dragged corner is the last edited one")

        // Per-corner apply: hovering a dot shows its corner chip ("All corners" and the radius) outside that corner; = and the chip copy the
        // hovered corner to all four.
        mouse(.mouseMoved, CGPoint(x: a.midX, y: a.midY))
        require(overlay.cornerChip.isHidden && overlay.hoveredCorner == nil, "no corner dot hovered: no chip")
        key(24, "=")
        require(equal(radii(), CornerRadii(all.bottomRight + moved)), "= with no corner hovered copies the last-edited corner's radius to all four")
        drag(from: dot(.topRight), by: CGPoint(x: -step, y: step), .option)
        require(Set(CornerRadii.corners.map { radii()[$0] }).count > 1, "an Option-drag makes the corners unequal")
        func chipCenter() -> CGPoint { CGPoint(x: overlay.cornerChip.frame.midX * scale, y: (overlay.view.bounds.height - overlay.cornerChip.frame.midY) * scale) }
        let box = overlay.view.viewRect(a)
        mouse(.mouseMoved, dot(.topLeft))
        require(overlay.hoveredCorner == .topLeft && !overlay.cornerChip.isHidden, "hovering a corner dot shows its chip")
        // The 152 pt chip is wider than the 140 pt left of the selection, so it takes its next spot, inside the corner.
        let shown = CornerRadii.corners.map { Int((radii()[$0] / scale).rounded()) }
        require(texts(in: overlay.cornerChip) == ["All corners  r \(shown.min()!)-\(shown.max()!)", "="]
                    && overlay.cornerChip.frame.maxY == box.maxY && overlay.cornerChip.frame.minX == box.minX + 14,
                "the top-left chip reads All corners with the radius range, at the top-left corner: \(texts(in: overlay.cornerChip)) \(overlay.cornerChip.frame) \(box)")
        let topLeftRadius = radii().topLeft
        mouse(.mouseMoved, dot(.bottomRight))
        require(overlay.hoveredCorner == .bottomRight && overlay.cornerChip.frame.minX >= box.maxX, "the bottom-right chip sits outside the right edge")
        mouse(.mouseMoved, dot(.topLeft))
        mouse(.mouseMoved, CGPoint(x: (dot(.topLeft).x + chipCenter().x) / 2, y: (dot(.topLeft).y + chipCenter().y) / 2))
        require(overlay.hoveredCorner == .topLeft, "the chip stays while the pointer travels from the dot to it")
        mouse(.mouseMoved, CGPoint(x: a.midX, y: a.midY))
        require(overlay.cornerChip.isHidden, "moving off the dot and the chip hides it")
        mouse(.mouseMoved, dot(.topLeft))
        key(24, "=")
        require(equal(radii(), CornerRadii(topLeftRadius)), "= applies the hovered corner's radius, not the last-edited corner's")
        drag(from: dot(.topRight), by: CGPoint(x: -step, y: step), .option)
        mouse(.mouseMoved, dot(.bottomLeft))
        let bottomLeftRadius = radii().bottomLeft
        mouse(.mouseMoved, chipCenter())
        click(chipCenter())
        require(equal(radii(), CornerRadii(bottomLeftRadius)), "clicking a corner's chip applies that corner's radius to all four")
        drag(from: dot(.topLeft), by: CGPoint(x: 1000 * scale, y: 1000 * scale))
        require(equal(radii(), CornerRadii(a.height / 2)), "a dot drag clamps to half the shorter side")
        drag(from: dot(.topLeft), by: CGPoint(x: -1000 * scale, y: -1000 * scale))
        require(equal(radii(), .zero) && near(dot(.topLeft).x, a.minX + 8 * scale / 2.0.squareRoot()), "dragging out reaches 0 and the dot rests 8 pt along the diagonal")
        // A square corner still resizes from its handle: the corner itself is not a dot.
        mouse(.mouseMoved, CGPoint(x: a.minX, y: a.minY))
        require(overlay.view.cursor === OverlayController.resizeCursors[.topLeft], "a square corner's handle keeps its resize cursor")

        // A dot drag snaps the radius to the one detected under that corner (window A's 20 pt) within 3 pt, unless Snap is off.
        func dragInward(_ corner: Handle, _ points: CGFloat, _ flags: NSEvent.ModifierFlags = []) {
            let along = points * scale / 2.0.squareRoot()
            drag(from: dot(corner), by: CGPoint(x: corner.movesLeft ? along : -along, y: corner.movesTop ? along : -along), flags)
        }
        overlay.editedRadii[a] = CornerRadii(radius - 8 * scale)
        dragInward(.topLeft, 2)
        require(near(radii().topLeft, radius - 6 * scale), "a dot drag ending 6 pt from the detected radius does not snap: \(radii().topLeft / scale) pt")
        dragInward(.topLeft, 3.5)
        require(equal(radii(), CornerRadii(radius)), "a dot drag ending within 3 pt of the detected radius snaps to it: \(radii().topLeft / scale) pt")
        overlay.editedRadii[a] = CornerRadii(radius - 8 * scale)
        dragInward(.bottomRight, 6, .option)
        require(near(radii().bottomRight, radius) && near(radii().topLeft, radius - 8 * scale), "an Option dot drag snaps only its corner")
        defaults.set(false, forKey: Pref.snap)
        overlay.editedRadii[a] = CornerRadii(radius - 8 * scale)
        dragInward(.topLeft, 6)
        require(equal(radii(), CornerRadii(radius - 2 * scale)), "with Snap off a dot drag does not snap: \(radii().topLeft / scale) pt")
        defaults.set(true, forKey: Pref.snap)

        // Corner dots and copies: the PNG follows the edited radii.
        drag(from: dot(.topLeft), by: CGPoint(x: 20 * scale, y: 20 * scale))
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        let copied = NSBitmapImageRep(data: pasteboard.data(forType: .png)!)!
        require(copied.colorAt(x: 0, y: 0)!.alphaComponent == 0 && copied.colorAt(x: copied.pixelsWide / 2, y: 0)!.alphaComponent == 1,
                "the copy rounds its corners with the dot-edited radii")

        // O toggles rounding everywhere: with it off a hovered window, its selection and edited corners are all square; on again, they
        // come back.
        open()
        defaults.set(true, forKey: Pref.roundCorners)
        require(overlay.view.overlays.hoverRadii == CornerRadii(radius), "hovering a window shows its radius")
        key(31, "o")
        require(!defaults.bool(forKey: Pref.roundCorners) && overlay.view.overlays.hoverRadii == .zero, "O turns rounding off and squares the hover")
        key(14, "e")
        require(overlay.editedRadii[a] == nil && overlay.view.overlays.radii == .zero, "E with rounding off opens a square selection")
        key(31, "o")
        require(defaults.bool(forKey: Pref.roundCorners) && overlay.view.overlays.radii == CornerRadii(radius), "O turns rounding on and the selection takes the window's radius")
        key(30, "]")
        let edited = overlay.view.overlays.radii
        require(edited != CornerRadii(radius), "] edits the selection's corners")
        key(31, "o")
        require(overlay.view.overlays.radii == .zero, "O turns rounding off and squares the edited selection")
        key(53, "\u{1B}")
        require(overlay.view.overlays.hoverRadii == .zero, "back in hover with rounding off, the hover stays square")
        key(14, "e")
        key(30, "]")
        require(defaults.bool(forKey: Pref.roundCorners), "editing a radius with rounding off turns rounding on")
        overlay.dismiss()

        // Shift-click with no selection opens the element without copying it.
        open()
        pasteboard.clearContents()
        click(insideA, .shift)
        require(overlay.selection?.rect == a && pasteboard.data(forType: .png) == nil, "Shift-click opens the hovered element instead of copying it")
        try await waitFor("Shift-click carries the radii") { overlay.editedRadii[a] == CornerRadii(radius) }

        // With a selection open, Shift outlines the element under the pointer only once the pointer moves outside the selection: not for a
        // Shift-arrow with the pointer inside, nor for Shift going down outside until the pointer moves.
        func shift(_ down: Bool) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        }
        let unionStart = overlay.selection!.rect
        mouse(.mouseMoved, CGPoint(x: unionStart.midX, y: unionStart.midY))
        shift(true)
        key(right, "", .shift)
        let insideOutline = overlay.view.overlays.hover
        key(left, "", .shift)
        shift(false)
        mouse(.mouseMoved, insideB)
        shift(true)
        let unmovedOutline = overlay.view.overlays.hover
        mouse(.mouseMoved, CGPoint(x: insideB.x + 4, y: insideB.y), .shift)
        let movedOutline = overlay.view.overlays.hover
        shift(false)
        require(insideOutline == nil && unmovedOutline == nil && movedOutline == b && overlay.selection?.rect == unionStart,
                "Shift draws no union outline inside the selection or before the pointer moves, and does once it moves outside: \(String(describing: movedOutline))")
        mouse(.mouseMoved, insideB)
        require(overlay.view.overlays.hover == nil, "without Shift an open selection draws no hover")
        mouse(.mouseMoved, insideB, .shift)
        require(overlay.view.overlays.hover == b && overlay.view.overlays.upHint == nil, "Shift with a selection outlines the element under the pointer")
        overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        require(overlay.view.overlays.hover == nil, "releasing Shift drops the outline")
        mouse(.mouseMoved, insideB, .shift)
        click(insideB, .shift)
        require(overlay.selection?.rect == a.union(b), "Shift-click grows the selection to the union")
        require(overlay.editedRadii[a.union(b)] == CornerRadii(radius), "the union keeps the selection's edited corners")
        overlay.dismiss()

        // Option-arrow grows one side; Option-Command-arrow shrinks it; 1 px a press, Shift 10 px; the extent and the minimum size hold.
        open()
        click(insideA, .shift)
        key(right, "", .option)
        require(overlay.selection?.rect == CGRect(x: a.minX, y: a.minY, width: a.width + 1, height: a.height), "Option-Right grows the right side 1 px")
        key(left, "", .option)
        require(overlay.selection?.rect == CGRect(x: a.minX - 1, y: a.minY, width: a.width + 2, height: a.height), "Option-Left grows the left side 1 px")
        key(up, "", [.option, .shift])
        require(overlay.selection?.rect.minY == a.minY - 10, "Shift-Option-Up grows the top side 10 px")
        key(down, "", [.option, .command])
        key(down, "", [.option, .command])
        require(overlay.selection?.rect.maxY == a.maxY - 2, "Option-Command-Down shrinks the bottom side 1 px each press")
        key(left, "", [.option, .command, .shift])
        require(overlay.selection?.rect.minX == a.minX - 1 + 10, "Shift-Option-Command-Left shrinks the left side 10 px")
        for _ in 0..<400 { key(right, "", [.option, .command, .shift]) }
        require(overlay.selection!.rect.width == AreaSelection.minimumSize, "shrinking stops at the minimum size")
        key(3, "f")
        key(right, "", .option)
        require(overlay.selection?.rect == overlay.extent, "growing stops at the extent")
        overlay.dismiss()

        // Shift-P locks the selection's ratio as it is, or unlocks it, without moving an edge. While it is locked, handle drags, grow and
        // shrink keep that ratio within 1 px in whole pixels and Tab takes no other fit; a fresh drag or closing the overlay drops the lock.
        open()
        func same(_ rect: CGRect?, _ expected: CGRect) -> Bool {
            guard let rect else { return false }
            return near(rect.minX, expected.minX) && near(rect.minY, expected.minY) && near(rect.width, expected.width) && near(rect.height, expected.height)
        }
        let odd = CGRect(x: 1000, y: 600, width: 400, height: 237)
        overlay.selection = AreaSelection(extent: overlay.extent, exact: odd, suggestions: [odd.insetBy(dx: -40, dy: -40)])
        key(35, "P", .shift)
        require(overlay.ratioLocked && overlay.selection?.rect == odd, "Shift-P locks the ratio and moves no edge: \(String(describing: overlay.selection?.rect))")
        key(35, "P", .shift)
        require(!overlay.ratioLocked && overlay.selection?.rect == odd, "Shift-P again unlocks and moves no edge: \(String(describing: overlay.selection?.rect))")
        key(35, "P", .shift)
        let locked = odd.width / odd.height
        func keepsRatio(_ message: String) {
            let rect = overlay.selection!.rect
            require(abs(rect.height - rect.width / locked) <= 1 && rect.integral == rect, "\(message) keeps the locked ratio within 1 px, in whole pixels: \(rect)")
        }
        drag(from: CGPoint(x: odd.maxX, y: odd.maxY), by: CGPoint(x: 200, y: 13))
        require(overlay.selection!.rect.width == 600, "a locked corner drag resizes: \(overlay.selection!.rect)")
        keepsRatio("a corner handle drag")
        var rect = overlay.selection!.rect
        drag(from: CGPoint(x: rect.maxX, y: rect.midY), by: CGPoint(x: -150, y: 0))
        keepsRatio("a side handle drag")
        rect = overlay.selection!.rect
        drag(from: CGPoint(x: rect.midX, y: rect.minY), by: CGPoint(x: 0, y: -77))
        keepsRatio("a top handle drag")
        for _ in 0..<3 { key(right, "", .option) }
        keepsRatio("Option-Right grow")
        key(up, "", [.option, .shift])
        keepsRatio("Shift-Option-Up grow")
        key(left, "", [.option, .command])
        keepsRatio("Option-Command-Left shrink")
        rect = overlay.selection!.rect
        key(right)
        key(down, "", .shift)
        require(overlay.selection!.rect == rect.offsetBy(dx: 1, dy: 10), "an arrow nudge moves the locked selection without resizing it")
        key(35, "P", .shift)
        rect = overlay.selection!.rect
        drag(from: CGPoint(x: rect.maxX, y: rect.midY), by: CGPoint(x: 50, y: 0), .option)
        require(overlay.selection!.rect.height == rect.height && overlay.selection!.rect.width == rect.width + 50, "unlocked, a side handle drag changes only its side")
        key(35, "P", .shift)
        drag(from: CGPoint(x: 300, y: 1200), by: CGPoint(x: 300, y: 200))
        require(!overlay.ratioLocked, "a fresh drag drops the lock")
        key(35, "P", .shift)
        mouse(.mouseMoved, insideB, .shift)
        click(insideB, .shift)
        require(overlay.selection?.rect.contains(b) == true && !overlay.ratioLocked, "a Shift-click union drops the lock")
        key(35, "P", .shift)
        key(3, "f")
        require(overlay.selection?.rect == overlay.extent && !overlay.ratioLocked, "F's full-screen selection drops the lock")
        key(35, "P", .shift)
        overlay.dismiss()
        require(!overlay.ratioLocked, "the lock does not outlive the capture")

        // P opens the ratio menu. A preset conforms the selection once and locks: the largest rectangle of its ratio inside the selection
        // from before the first pick (so picks do not compound), on its center, in whole pixels. Free unlocks and leaves the rectangle
        // alone; Original takes the ratio at release; Portrait flips the presets and the lock.
        open()
        key(35, "p")
        require(overlay.chrome.ratioMenu.isHidden, "P with no selection opens no menu")
        key(14, "e")
        require(overlay.ratioReadout == "2.00", "a free 2:1 selection reads its live ratio: \(overlay.ratioReadout)")
        key(35, "p")
        let menu = overlay.chrome.ratioMenu
        require(!menu.isHidden && menu.items.map(\.title) == ["Free", "Original", "1:1", "4:3", "3:2", "16:10", "16:9", "21:9", "", "Portrait"],
                "P opens the presets: \(menu.items.map(\.title))")
        let widest = menu.rows.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.frame.maxX }.max()!
        let capLeft = menu.rows.flatMap(\.subviews).compactMap { ($0 as? KeyCap)?.frame.minX }.min()!
        require(menu.panel.frame.width <= 124 && widest + 12 <= capLeft && capLeft + menu.rows[0].frame.minX < menu.panel.frame.width - 8,
                "the menu is as wide as its longest title and a cap: panel \(menu.panel.frame.width), title ends at \(widest), caps start at \(capLeft)")
        func pick(_ title: String) {
            if menu.isHidden { key(35, "p") }
            menu.pick(menu.items.firstIndex { $0.title == title }!)
        }
        pick("1:1")
        require(overlay.ratioLocked && overlay.selection?.rect == CGRect(x: 400, y: 300, width: 200, height: 200),
                "1:1 conforms the selection about its center and locks: \(String(describing: overlay.selection?.rect))")
        require(overlay.ratioReadout == "1:1", "the readout shows the live ratio: \(overlay.ratioReadout)")
        pick("4:3")
        require(overlay.selection?.rect == CGRect(x: 367, y: 300, width: 267, height: 200),
                "a second pick conforms the selection from before the first pick, not the square: \(String(describing: overlay.selection?.rect))")
        pick("16:9")
        let sixteenNine = CGRect(x: 322, y: 300, width: 356, height: 200)
        require(overlay.selection?.rect == sixteenNine, "16:9 conforms: \(String(describing: overlay.selection?.rect))")
        require(overlay.ratioReadout == "1.78 ≈ 16:9", "356 x 200 px reads as near 16:9: \(overlay.ratioReadout)")
        key(35, "p")
        require(menu.items.filter(\.on).map(\.title) == ["16:9"], "the menu checks the lock it applied")
        pick("Free")
        require(!overlay.ratioLocked && overlay.selection?.rect == sixteenNine, "Free unlocks and leaves the rectangle alone")
        pick("21:9")
        require(overlay.selection?.rect == CGRect(x: 300, y: 315, width: 400, height: 171),
                "after Free a pick still starts from the selection before the first pick: \(String(describing: overlay.selection?.rect))")
        pick("Original")
        require(overlay.selection?.rect == a, "Original takes the ratio at release: \(String(describing: overlay.selection?.rect))")
        pick("16:10")
        require(overlay.selection?.rect == CGRect(x: 340, y: 300, width: 320, height: 200), "16:10 conforms: \(String(describing: overlay.selection?.rect))")
        pick("Portrait")
        require(overlay.selection?.rect == CGRect(x: 438, y: 300, width: 125, height: 200),
                "Portrait flips the lock to 10:16 from the same selection: \(String(describing: overlay.selection?.rect))")
        require(!menu.isHidden, "Portrait keeps the menu open for the next pick")
        require(["3:4", "2:3", "10:16", "9:16", "9:21"].allSatisfy { title in menu.items.contains { $0.title == title } }
                && menu.items.last?.title == "Portrait" && menu.items.last?.on == true, "with Portrait on the presets read tall")
        pick("Portrait")
        require(overlay.selection?.rect == CGRect(x: 340, y: 300, width: 320, height: 200) && !menu.isHidden,
                "Portrait off flips the lock back and keeps the menu open: \(String(describing: overlay.selection?.rect))")
        key(right)
        pick("1:1")
        require(overlay.selection?.rect == CGRect(x: 401, y: 300, width: 200, height: 200), "after a nudge, a pick conforms the nudged rectangle: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 601, y: 500), by: CGPoint(x: 100, y: 0))
        require(overlay.selection?.rect.size == CGSize(width: 300, height: 300), "a preset's lock holds on a corner handle drag: \(String(describing: overlay.selection?.rect))")
        overlay.dismiss()

        // Shift on a handle keeps the ratio the selection had when the drag started.
        open()
        key(14, "e")
        let corner = CGPoint(x: a.maxX, y: a.maxY)
        drag(from: corner, by: CGPoint(x: 100, y: 0), .shift)
        require(same(overlay.selection?.rect, CGRect(x: a.minX, y: a.minY, width: 500, height: 250)), "Shift on a corner handle keeps the start ratio: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 800, y: 550), by: CGPoint(x: 0, y: 100), .shift)
        require(same(overlay.selection?.rect, CGRect(x: a.minX, y: a.minY, width: 700, height: 350)), "a vertical Shift drag of a corner keeps the ratio: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 1000, y: 475), by: CGPoint(x: 100, y: 0), .option)
        require(overlay.selection?.rect.width == 800 && overlay.selection?.rect.height == 350, "without Shift a side handle changes only its side")
        overlay.dismiss()

        // Shift while moving locks the move to the axis with the larger travel; Space-drag too.
        open()
        key(14, "e")
        drag(from: insideA, by: CGPoint(x: 60, y: 20), .shift)
        require(overlay.selection?.rect == a.offsetBy(dx: 60, dy: 0), "Shift-moving mostly right moves horizontally only: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 400, y: 400), by: CGPoint(x: 20, y: 60), .shift)
        require(overlay.selection?.rect == a.offsetBy(dx: 60, dy: 60), "Shift-moving mostly down moves vertically only: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 400, y: 460), by: CGPoint(x: 20, y: 60))
        require(overlay.selection?.rect == a.offsetBy(dx: 80, dy: 120), "without Shift the move is free")
        overlay.dismiss()
        open()
        mouse(.leftMouseDown, CGPoint(x: 1000, y: 600))
        mouse(.leftMouseDragged, CGPoint(x: 1200, y: 800))
        overlay.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
        mouse(.leftMouseDragged, CGPoint(x: 1300, y: 830), .shift)
        mouse(.leftMouseUp, CGPoint(x: 1300, y: 800), .shift)
        overlay.window.sendEvent(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: overlay.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
        require(overlay.selection?.rect == CGRect(x: 1100, y: 600, width: 200, height: 200), "Shift Space-drag moves the drawn rectangle along one axis: \(String(describing: overlay.selection?.rect))")
        overlay.dismiss()

        // Option-Command-arrow shrinks one side of a released drag selection.
        open()
        drag(from: CGPoint(x: 1000, y: 600), by: CGPoint(x: 400, y: 300))
        let drawn = overlay.selection!.rect
        key(right, "", [.option, .command])
        require(overlay.selection?.rect == CGRect(x: drawn.minX, y: drawn.minY, width: drawn.width - 1, height: drawn.height), "Option-Command-Right shrinks a drawn selection's right side")
        overlay.dismiss()

        // Control-Option-arrow moves that side out to the next edge, then the next, then the extent; Control-Option-Command-arrow moves it
        // back in, and stops short of the minimum size; Shift changes neither. Command-arrow alone does nothing. The fixture is a 1200 x 800
        // white image with a gray panel (200-1000, 150-650) holding a dark one (400-800, 300-500).
        let panels = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (gray, rect) in [(1.0, CGRect(x: 0, y: 0, width: 1200, height: 800)), (0.63, CGRect(x: 200, y: 150, width: 800, height: 500)),
                             (0.24, CGRect(x: 400, y: 300, width: 400, height: 200))] {
            panels.setFillColor(CGColor(gray: gray, alpha: 1))
            panels.fill(rect)
        }
        overlay.dismiss()
        overlay.present(image: panels.makeImage()!, frame: CGRect(x: frame.minX, y: frame.minY, width: 600, height: 400), displayID: nil)
        overlay.detectionTask?.cancel()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: CGRect(x: 450, y: 350, width: 300, height: 100))
        let edge: NSEvent.ModifierFlags = [.control, .option], edgeIn: NSEvent.ModifierFlags = [.control, .option, .command]
        let unmoved = overlay.selection!.rect
        for code in [left, right, up, down] { key(code, "", .command) }
        require(overlay.selection?.rect == unmoved, "Command-arrow alone leaves the selection as it was: \(String(describing: overlay.selection?.rect))")
        var rights: [CGFloat] = []
        for _ in 0..<4 {
            key(right, "", edge)
            rights.append(overlay.selection!.rect.maxX)
        }
        require(rights == [800, 1000, 1200, 1200], "Control-Option-Right takes the right side to the dark panel's edge, the gray panel's, then the extent, then stays: \(rights)")
        for _ in 0..<3 {
            key(right, "", rights.count == 4 ? edgeIn : edgeIn.union(.shift))
            rights.append(overlay.selection!.rect.maxX)
        }
        require(rights.suffix(3) == [1000, 800, 800], "Control-Option-Command-Right (Shift or not) takes it back in edge by edge and stops before the minimum size: \(rights)")
        key(left, "", edge)
        key(down, "", edge.union(.shift))
        var tops: [CGFloat] = []
        for _ in 0..<3 {
            key(up, "", edge)
            tops.append(overlay.selection!.rect.minY)
        }
        rect = overlay.selection!.rect
        require(tops == [300, 150, 0] && rect == CGRect(x: 400, y: 0, width: 400, height: 500),
                "Control-Option-Left, -Down (with Shift, which changes nothing) and -Up move the other sides to their next edges: \(tops) \(rect)")
        overlay.dismiss()
        // On the page: Control-Option-Command-Right on a selection wider than the cart panel takes the right side in to the panel's right
        // border (the 2 px run at 2214-2215, counted at its middle), then to its left border (1656-1657), then stays at the minimum size's limit.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: CGRect(x: 1600, y: 450, width: 800, height: 400))
        var inward: [CGFloat] = []
        for _ in 0..<3 {
            key(right, "", edgeIn)
            inward.append(overlay.selection!.rect.maxX)
        }
        require(inward == [2215, 1657, 1657], "Control-Option-Command-Right on the page steps the right side in to the cart panel's right edge, then its left: \(inward)")
        overlay.dismiss()
        // One press's cost on the page: a tall selection whose search reaches across most of the screen.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: CGRect(x: 20, y: 100, width: 40, height: 1400))
        let pressed = ContinuousClock.now
        key(right, "", edge)
        print("Control-Option-Right on a 40 x 1400 px selection: \(String(format: "%.1f", pressed.duration(to: .now).milliseconds)) ms, right side to \(overlay.selection!.rect.maxX)")
        overlay.dismiss()

        // + and - move every side out or in by 1 px, Option 10 px, within the extent and the minimum size.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: a)
        var sides: [CGRect] = []
        for (character, flags) in [("+", NSEvent.ModifierFlags.shift), ("+", [.shift, .option]), ("-", []), ("-", .option)] {
            key(character == "+" ? 24 : 27, character, flags)
            sides.append(overlay.selection!.rect)
        }
        require(sides == [a.insetBy(dx: -1, dy: -1), a.insetBy(dx: -11, dy: -11), a.insetBy(dx: -10, dy: -10), a],
                "+ and - grow and shrink all four sides by 1 px, Option 10 px: \(sides)")
        for _ in 0..<30 { key(27, "-", .option) }
        require(overlay.selection!.rect.height == AreaSelection.minimumSize, "- stops at the minimum size: \(overlay.selection!.rect)")
        key(3, "f")
        key(24, "+", .shift)
        require(overlay.selection?.rect == overlay.extent, "+ stops at the extent")
        overlay.dismiss()

        // Cmd-Z undoes one edit at a time back to the released drag, then beeps and stays; Cmd-Shift-Z redoes them. Quick nudges are one step.
        open()
        drag(from: CGPoint(x: 1000, y: 600), by: CGPoint(x: 400, y: 300))
        let released = overlay.selection!.rect
        for _ in 0..<3 { key(right) }
        let nudged = overlay.selection!.rect
        drag(from: CGPoint(x: nudged.maxX, y: nudged.midY), by: CGPoint(x: 60, y: 0))
        let resized = overlay.selection!.rect
        key(30, "]")
        let rounded = overlay.editedRadii[resized]
        require(nudged == released.offsetBy(dx: 3, dy: 0) && resized.width > nudged.width && rounded != nil && overlay.undoStack.count == 3,
                "a drag, three quick nudges, a handle drag and ] make three undo steps: \(released) \(nudged) \(resized) \(overlay.undoStack.count)")
        var undone: [(CGRect, CornerRadii?)] = []
        for _ in 0..<4 {
            key(6, "z", .command)
            undone.append((overlay.selection!.rect, overlay.editedRadii[overlay.selection!.rect]))
        }
        require(undone.map(\.0) == [resized, nudged, released, released] && undone[0].1 == nil,
                "Cmd-Z steps back through ], the handle drag and the nudges, then stays on the released drag: \(undone.map(\.0))")
        var redone: [(CGRect, CornerRadii?)] = []
        for _ in 0..<3 {
            key(6, "Z", [.command, .shift])
            redone.append((overlay.selection!.rect, overlay.editedRadii[overlay.selection!.rect]))
        }
        require(redone.map(\.0) == [nudged, resized, resized] && redone[2].1 == rounded && overlay.redoStack.isEmpty,
                "Cmd-Shift-Z comes back step by step to the rounded, resized selection: \(redone.map(\.0))")
        drag(from: CGPoint(x: 200, y: 200), by: CGPoint(x: 300, y: 300))
        require(overlay.undoStack.isEmpty && overlay.redoStack.isEmpty, "a fresh drag starts the history over")
        // A real click on a chip button is one step too; its release, which reaches the overlay, leaves the history alone.
        key(right)
        let lockChip = overlay.chrome.lock
        let lockPoint = lockChip.convert(CGPoint(x: lockChip.bounds.midX, y: lockChip.bounds.midY), to: overlay.view)
        let lockPixel = CGPoint(x: lockPoint.x * scale, y: (overlay.view.bounds.height - lockPoint.y) * scale)
        mouse(.leftMouseDown, lockPixel)
        mouse(.leftMouseUp, lockPixel)
        require(overlay.ratioLocked && overlay.undoStack.count == 2, "clicking the lock chip locks the ratio as one more undo step: \(overlay.undoStack.count)")
        key(6, "z", .command)
        require(!overlay.ratioLocked && overlay.undoStack.count == 1, "Cmd-Z undoes the lock click")
        overlay.dismiss()

        // With Frame on, the size chip adds what the delivered image adds around the selection.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: a)
        defaults.set(true, forKey: Pref.frame)
        overlay.refresh()
        let framedChip = texts(in: overlay.chrome.size)
        pasteboard.clearContents()
        key(returnKey, "\r")
        await overlay.commitTask?.value
        let framedOutput = pngSize(pasteboard.data(forType: .png))!
        defaults.set(false, forKey: Pref.frame)
        require(framedChip == ["400 x 200  + frame \(Int(framedOutput.width) - 400) x \(Int(framedOutput.height) - 200)"],
                "the size chip adds the frame the copy gets: \(framedChip), copied \(framedOutput)")

        // Cmd-Shift-S: Save As writes where the panel (here the seam) says, with the usual name offered, and closes the overlay.
        var offered: URL?
        overlay.chooseSaveURL = { suggested in
            offered = suggested
            return folder.appending(path: "chosen name.png")
        }
        open()
        pasteboard.clearContents()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).count
        key(1, "S", [.command, .shift])
        await overlay.commitTask?.value
        require(!overlay.window.isVisible, "Cmd-Shift-S closes the overlay")
        let chosen = folder.appending(path: "chosen name.png")
        require(pngSize(try? Data(contentsOf: chosen)) == a.size, "Save As on a hover writes the element to the chosen file")
        require(offered?.deletingLastPathComponent().path == folder.path && offered?.lastPathComponent.hasPrefix("Snug ") == true, "the panel is offered the save folder and the usual name")
        require(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == filesBefore + 1 && pasteboard.data(forType: .png) == nil,
                "Save As writes only the chosen file and leaves the pasteboard alone")
        open()
        click(insideA, .shift)
        key(right, "", .option)
        try FileManager.default.removeItem(at: chosen)
        key(1, "S", [.command, .shift])
        await overlay.commitTask?.value
        require(pngSize(try? Data(contentsOf: chosen)) == CGSize(width: a.width + 1, height: a.height), "Save As on a selection writes the selection")
        // Canceling the panel comes back to the overlay as it was: the hover, or the same selection, with nothing written or copied.
        var asked = 0
        overlay.chooseSaveURL = { _ in asked += 1; return nil }
        try FileManager.default.removeItem(at: chosen)
        open()
        let task = overlay.commitTask
        let hovered = overlay.session?.selected?.bounds
        key(1, "S", [.command, .shift])
        require(asked == 1 && overlay.window.isVisible && overlay.commitTask == task && overlay.session?.selected?.bounds == hovered && hovered != nil,
                "cancelling Save As on a hover leaves the overlay open on the same element")
        open()
        click(insideA, .shift)
        key(right, "", .option)
        let selected = overlay.selection?.rect
        pasteboard.clearContents()
        key(1, "S", [.command, .shift])
        require(asked == 2 && overlay.window.isVisible && overlay.commitTask == task && selected != nil && overlay.selection?.rect == selected,
                "cancelling Save As on a selection leaves the overlay open with the same selection")
        let folderBefore = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        key(1, "s", [.command])
        await overlay.commitTask?.value
        let added = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)).subtracting(folderBefore)
        require(!FileManager.default.fileExists(atPath: chosen.path) && pasteboard.data(forType: .png) == nil, "cancelling Save As writes nothing and copies nothing")
        require(added.count == 1 && pngSize(try? Data(contentsOf: folder.appending(path: added.first!))) == selected!.size, "Cmd-S still saves the kept selection after a cancel: \(added)")

        // Output integrity: the usual name never overwrites, and a failed write is named in a red toast's message instead of "Copied".
        let outputFolder = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defaults.set(outputFolder.path, forKey: Pref.saveFolder)
        let taken = Output.defaultFile(defaults: defaults)
        try Data("taken".utf8).write(to: taken)
        for text in ["first", "second", "third"] {
            Output.publish(png: Data(text.utf8), detail: "", copy: false, save: true, pasteboard: pasteboard, defaults: defaults)
        }
        let saved = try FileManager.default.contentsOfDirectory(atPath: outputFolder.path)
        let contents = try Set(saved.map { try String(contentsOf: outputFolder.appending(path: $0), encoding: .utf8) })
        require(saved.count == 4 && contents == ["taken", "first", "second", "third"], "saves in one second keep every capture: \(saved)")
        require(saved.contains { $0.hasSuffix(" 2.png") }, "a taken default name gets \" 2\" before the extension: \(saved)")
        let savedToast = Output.publish(png: Data("fourth".utf8), detail: "1 x 1", copy: true, save: true, pasteboard: pasteboard, defaults: defaults)
        require(savedToast.detail == "1 x 1", "a saved capture's toast keeps the pixel size as its detail, not the file name: \(savedToast)")

        let blocked = folder.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defaults.set(blocked.path, forKey: Pref.saveFolder)
        pasteboard.clearContents()
        let partial = Output.publish(png: Data("kept".utf8), detail: "1 x 1", copy: true, save: true, pasteboard: pasteboard, defaults: defaults)
        require(partial.message == "Copied, save failed" && !partial.detail.isEmpty && pasteboard.data(forType: .png) == Data("kept".utf8),
                "Copy and Save on an unwritable folder copies and reports \"Copied, save failed\" with a reason: \(partial)")
        let saveOnly = Output.publish(png: Data("kept".utf8), detail: "1 x 1", copy: false, save: true, pasteboard: pasteboard, defaults: defaults)
        require(saveOnly.message == "Save failed" && saveOnly.detail == partial.detail, "Save alone on an unwritable folder reports \"Save failed\": \(saveOnly)")
        let copyOnly = Output.publish(png: Data("kept".utf8), detail: "1 x 1", copy: true, save: false, pasteboard: pasteboard, defaults: defaults)
        require(copyOnly.message == "Copied" && copyOnly.detail == "1 x 1", "a plain copy still says Copied: \(copyOnly)")
        let messages = [(true, true, true, true), (true, true, true, false), (true, true, false, true), (true, true, false, false),
                        (true, false, true, true), (true, false, false, true), (false, true, true, true), (false, true, true, false)]
            .map { Output.message(copy: $0.0, save: $0.1, copied: $0.2, saved: $0.3, folder: "F") }
        require(messages == ["Copied, saved to F", "Copied, save failed", "Saved to F, copy failed", "Copy and save failed",
                             "Copied", "Copy failed", "Saved to F", "Save failed"], "the toast names what worked and what failed: \(messages)")
        let toast = Toast(png: Data("kept".utf8), message: "Copied, save failed", detail: "reason", file: nil, color: .systemRed, defaults: defaults)
        toast.saveButton.performClick(nil)
        require(toast.message.stringValue == "Save failed" && toast.file == nil, "the toast's Save on an unwritable folder reports instead of crashing")
        toast.dismiss()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        defaults.set(folder.path, forKey: Pref.saveFolder)
        return passed
    }
}
