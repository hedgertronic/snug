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
        require(["Cmd-Shift-S", "E / Shift-click", "Option-arrow", "Shift-click", "Corner dot", "=", "O"].allSatisfy(helpKeys.contains), "the help table lists the new keys")

        // E opens the hovered window as a selection that keeps its radii, even after a nudge (the measured radius is by rectangle).
        require(overlay.view.overlays.hover == a, "the pointer hovers window A")
        key(14, "e")
        require(overlay.selection?.rect == a, "E opens the hovered element as a selection")
        try await waitFor("E carries the hovered corner radii as edited ones") { overlay.editedRadii[a] == CornerRadii(radius) }
        require(overlay.view.overlays.showsHandles && overlay.view.overlays.radii == CornerRadii(radius), "the selection shows handles and the carried radii")
        key(right, "", .shift)
        require(overlay.selection?.rect == a.offsetBy(dx: 10 * scale, dy: 0) && overlay.view.overlays.radii == CornerRadii(radius), "a nudged E selection keeps its radii")
        key(left, "", .shift)
        require(texts(in: overlay.chrome.hints).contains("edge") && texts(in: overlay.chrome.hints).contains("corners"), "the selection hint row offers edge nudges and corners")

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

        // Apply to all: the chip and =.
        require(!overlay.applyChip.isHidden && texts(in: overlay.chrome.size).count == 1, "unequal corners show the Apply to all chip")
        key(24, "=")
        require(equal(radii(), CornerRadii(all.bottomRight + moved)) && overlay.applyChip.isHidden, "= copies the last-edited corner's radius to all four and hides the chip")
        drag(from: dot(.topRight), by: CGPoint(x: -step, y: step), .option)
        require(!overlay.applyChip.isHidden, "an Option-drag brings the chip back")
        overlay.applyChip.onClick()
        require(overlay.applyChip.isHidden && Set(CornerRadii.corners.map { radii()[$0] }).count == 1, "clicking the chip applies one radius to all four corners")
        drag(from: dot(.topLeft), by: CGPoint(x: 1000 * scale, y: 1000 * scale))
        require(equal(radii(), CornerRadii(a.height / 2)), "a dot drag clamps to half the shorter side")
        drag(from: dot(.topLeft), by: CGPoint(x: -1000 * scale, y: -1000 * scale))
        require(equal(radii(), .zero) && near(dot(.topLeft).x, a.minX + 8 * scale / 2.0.squareRoot()), "dragging out reaches 0 and the dot rests 8 pt along the diagonal")
        // A square corner still resizes from its handle: the corner itself is not a dot.
        mouse(.mouseMoved, CGPoint(x: a.minX, y: a.minY))
        require(overlay.view.cursor === OverlayController.resizeCursors[.topLeft], "a square corner's handle keeps its resize cursor")

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

        // Option-arrow grows one side; Option-Command-arrow shrinks it; Shift is 10 pt; the extent and the minimum size hold.
        open()
        click(insideA, .shift)
        key(right, "", .option)
        require(overlay.selection?.rect == CGRect(x: a.minX, y: a.minY, width: a.width + scale, height: a.height), "Option-Right grows the right side 1 pt")
        key(left, "", .option)
        require(overlay.selection?.rect == CGRect(x: a.minX - scale, y: a.minY, width: a.width + 2 * scale, height: a.height), "Option-Left grows the left side 1 pt")
        key(up, "", [.option, .shift])
        require(overlay.selection?.rect.minY == a.minY - 10 * scale, "Shift-Option-Up grows the top side 10 pt")
        key(down, "", [.option, .command])
        key(down, "", [.option, .command])
        require(overlay.selection?.rect.maxY == a.maxY - 2 * scale, "Option-Command-Down shrinks the bottom side 1 pt each press")
        key(left, "", [.option, .command, .shift])
        require(overlay.selection?.rect.minX == a.minX - scale + 10 * scale, "Shift-Option-Command-Left shrinks the left side 10 pt")
        for _ in 0..<200 { key(right, "", [.option, .command, .shift]) }
        require(overlay.selection!.rect.width == AreaSelection.minimumSize, "shrinking stops at the minimum size")
        key(3, "f")
        key(right, "", .option)
        require(overlay.selection?.rect == overlay.extent, "growing stops at the extent")
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
        require(pngSize(try? Data(contentsOf: chosen)) == CGSize(width: a.width + scale, height: a.height), "Save As on a selection writes the selection")
        overlay.chooseSaveURL = { _ in nil }
        try FileManager.default.removeItem(at: chosen)
        open()
        key(1, "S", [.command, .shift])
        await overlay.commitTask?.value
        require(!FileManager.default.fileExists(atPath: chosen.path) && !overlay.window.isVisible, "cancelling the save panel writes nothing")
        return passed
    }
}
