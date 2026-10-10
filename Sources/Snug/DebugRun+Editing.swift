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

        // The key map: hints and the help table list the new keys.
        open()
        require(texts(in: overlay.chrome.hints).contains("edit"), "the hover hint row offers E")
        let helpKeys = HelpSheet.columns.flatMap(\.rows).map(\.keys)
        require(["Cmd-Shift-S", "E / Shift-click", "Option-arrow", "Shift-click", "Shift-drag handle", "Shift-move", "P", "M", "=", "O"].allSatisfy(helpKeys.contains), "the help table lists the new keys")
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
        require(["resize", "scroll"].allSatisfy(texts(in: overlay.chrome.hints).contains) && !["frame", "corners"].contains(where: texts(in: overlay.chrome.hints).contains),
                "the selection hint row offers resize and scroll, and no frame or corners hint")

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
        require(overlay.radiusReadout == "r \(Int((before.topLeft + moved) / scale))", "the size badge reads the radius: \(overlay.radiusReadout ?? "nil")")
        let all = radii()
        drag(from: dot(.bottomRight), by: CGPoint(x: -step, y: -step), .option)
        require(near(radii().bottomRight, all.bottomRight + moved) && near(radii().topLeft, all.topLeft) && near(radii().topRight, all.topRight)
                && near(radii().bottomLeft, all.bottomLeft), "Option-dragging a dot changes only that corner")
        require(overlay.radiusReadout?.split(separator: " ").count == 5, "unequal corners read as four values: \(overlay.radiusReadout ?? "nil")")
        require(overlay.lastEditedCorner == .bottomRight, "the dragged corner is the last edited one")

        // Per-corner apply: hovering a dot shows its "All corners" chip outside that corner; = and the chip copy the hovered corner to all four.
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
        require(texts(in: overlay.cornerChip).contains("All corners") && overlay.cornerChip.frame.maxX <= box.minX, "the top-left chip reads All corners, outside the selection's left edge")
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

        // O toggles rounding; with it off, a hovered window is square, and E keeps it square until edited.
        open()
        defaults.set(true, forKey: Pref.roundCorners)
        require(overlay.view.overlays.hoverRadii == CornerRadii(radius), "hovering a window shows its radius")
        key(31, "o")
        require(!defaults.bool(forKey: Pref.roundCorners) && overlay.view.overlays.hoverRadii == .zero, "O turns rounding off and squares the hover")
        key(14, "e")
        try await waitFor("E with rounding off carries square corners") { overlay.editedRadii[a] == CornerRadii.zero }
        key(31, "o")
        require(defaults.bool(forKey: Pref.roundCorners) && overlay.view.overlays.radii == .zero, "O turns rounding on; the edited square corners stay")
        overlay.dismiss()

        // Shift-click with no selection opens the element without copying it.
        open()
        pasteboard.clearContents()
        click(insideA, .shift)
        require(overlay.selection?.rect == a && pasteboard.data(forType: .png) == nil, "Shift-click opens the hovered element instead of copying it")
        try await waitFor("Shift-click carries the radii") { overlay.editedRadii[a] == CornerRadii(radius) }

        // With a selection open, Shift outlines the element under the pointer and Shift-click grows to the union.
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

        // P cycles the ratio lock: Free, 1:1, 4:3, 3:2, 16:9, then Free; it lasts one capture and shows in the status line.
        open()
        func lock() -> String { overlay.ratioLock?.label ?? "free" }
        var cycle: [String] = []
        for _ in 0..<5 { key(35, "p"); cycle.append(lock()) }
        require(cycle == ["1:1", "4:3", "3:2", "16:9", "free"], "P cycles the ratio lock: \(cycle)")
        key(35, "p"); key(35, "p")
        func same(_ rect: CGRect?, _ expected: CGRect) -> Bool {
            guard let rect else { return false }
            return near(rect.minX, expected.minX) && near(rect.minY, expected.minY) && near(rect.width, expected.width) && near(rect.height, expected.height)
        }
        func ratio() -> CGFloat { overlay.selection!.rect.width / overlay.selection!.rect.height }
        mouse(.leftMouseDown, CGPoint(x: 1000, y: 600))
        mouse(.leftMouseDragged, CGPoint(x: 1800, y: 900))
        require(same(overlay.view.overlays.ghost, CGRect(x: 1000, y: 600, width: 800, height: 600)), "the ghost of a fresh drag keeps the lock while dragging: \(String(describing: overlay.view.overlays.ghost))")
        mouse(.leftMouseUp, CGPoint(x: 1800, y: 900))
        require(same(overlay.selection?.rect, CGRect(x: 1000, y: 600, width: 800, height: 600)), "a fresh drag with 4:3 locked is 4:3: \(String(describing: overlay.selection?.rect))")
        require(texts(in: overlay.chrome.status).contains("Exact, Ratio 4:3"), "the status line reads Ratio 4:3: \(texts(in: overlay.chrome.status))")
        require(overlay.selection?.fits.count == 1, "a locked ratio takes no snap fits")
        drag(from: CGPoint(x: 300, y: 1200), by: CGPoint(x: 300, y: 800))
        require(same(overlay.selection?.rect, CGRect(x: 300, y: 1200, width: 300, height: 400)), "a taller fresh drag, cut off by the extent, is 3:4: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 1000, y: 600), by: CGPoint(x: 800, y: 300))
        drag(from: CGPoint(x: 1800, y: 1200), by: CGPoint(x: 200, y: 0))
        require(same(overlay.selection?.rect, CGRect(x: 1000, y: 600, width: 1000, height: 750)), "a corner handle drag keeps the locked ratio, the opposite corner fixed: \(String(describing: overlay.selection?.rect))")
        drag(from: CGPoint(x: 2000, y: 975), by: CGPoint(x: -400, y: 0))
        require(same(overlay.selection?.rect, CGRect(x: 1000, y: 750, width: 600, height: 450)), "a side handle drag keeps the ratio, growing the other side about the center: \(String(describing: overlay.selection?.rect))")
        key(35, "p"); key(35, "p"); key(35, "p")
        require(lock() == "free" && !texts(in: overlay.chrome.status).contains { $0.contains("Ratio") }, "P back to Free drops the status text")
        overlay.dismiss()
        require(overlay.ratioLock == nil, "the lock does not outlive the capture")

        // hasOtherFits: Tab has a fit (a snap or the exact drag) that differs from the selection by more than 1 pt.
        open()
        overlay.selection = AreaSelection(extent: overlay.extent, exact: a, suggestions: [a.insetBy(dx: -4, dy: -4)], takingFirst: true)
        require(overlay.hasOtherFits, "a released snap has the exact drag as another fit")
        overlay.selection = AreaSelection(extent: overlay.extent, exact: a.insetBy(dx: -5, dy: -5), suggestions: [a.insetBy(dx: -4, dy: -4)], takingFirst: true)
        require(!overlay.hasOtherFits, "an exact drag within 1 pt of the snap does not count")
        overlay.selection = AreaSelection(extent: overlay.extent, exact: a, suggestions: [a.insetBy(dx: 1, dy: 1)])
        require(!overlay.hasOtherFits, "a snap within 1 pt of the selection does not count")
        overlay.dismiss()

        // P conforms an open selection at once: the largest rectangle of the lock's ratio inside the rectangle from before this run of
        // P presses, on its center, in whole pixels. Free leaves the rectangle alone.
        open()
        key(14, "e")
        require(overlay.ratioReadout == "2.00", "a free 2:1 selection reads its live ratio: \(overlay.ratioReadout)")
        key(35, "p")
        require(overlay.selection?.rect == CGRect(x: 400, y: 300, width: 200, height: 200), "P to 1:1 conforms the selection about its center: \(String(describing: overlay.selection?.rect))")
        require(overlay.ratioReadout == "1:1 locked", "a lock reads as the lock: \(overlay.ratioReadout)")
        key(35, "p")
        require(overlay.selection?.rect == CGRect(x: 367, y: 300, width: 267, height: 200), "P to 4:3 fits the rectangle from before the P presses, not the square: \(String(describing: overlay.selection?.rect))")
        key(35, "p")
        require(overlay.selection?.rect == CGRect(x: 350, y: 300, width: 300, height: 200), "P to 3:2 conforms: \(String(describing: overlay.selection?.rect))")
        key(35, "p")
        let sixteenNine = CGRect(x: 322, y: 300, width: 356, height: 200)
        require(overlay.selection?.rect == sixteenNine, "P to 16:9 conforms: \(String(describing: overlay.selection?.rect))")
        key(35, "p")
        require(overlay.ratioLock == nil && overlay.selection?.rect == sixteenNine, "P to Free leaves the rectangle alone")
        require(overlay.ratioReadout == "1.78 ≈ 16:9", "356 x 200 px reads as near 16:9: \(overlay.ratioReadout)")
        key(right)
        key(35, "p")
        require(overlay.selection?.rect == CGRect(x: 401, y: 300, width: 200, height: 200), "after a nudge, P conforms the nudged rectangle: \(String(describing: overlay.selection?.rect))")
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
        overlay.chooseSaveURL = { _ in nil }
        try FileManager.default.removeItem(at: chosen)
        open()
        key(1, "S", [.command, .shift])
        await overlay.commitTask?.value
        require(!FileManager.default.fileExists(atPath: chosen.path) && !overlay.window.isVisible, "cancelling the save panel writes nothing")
        return passed
    }
}
