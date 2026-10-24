import AppKit
import ScreenshotCore

/// Positions and fills the on-screen chrome: the top bar, the chip row above the object and the action strip below it, the keys
/// line, the candidate list, and the keys sheet.
extension OverlayController {
    /// A click on a button presses its key, so it does what the key does in the current state.
    func wireChrome() {
        for button in chrome.buttons + [cornerChip] {
            button.onClick = { [unowned self, unowned button] in _ = handleKey(KeyCap.event(for: button.key!)) }
        }
        cornerChip.surface = true
        for menu in [chrome.ratioMenu, chrome.colorMenu] {
            menu.onClose = { [unowned self] in
                refresh()
                updateCursor()
            }
            menu.onMove = { [unowned self] in updateCursor() }
            menu.onKey = { [unowned self] in flash($0) }
        }
    }

    /// The motion of chrome changes (seconds), ease out, and of a key's jump between hover candidates, which the outline and its chrome share.
    static let motionDuration = 0.14, jumpDuration = 0.1

    /// Runs `changes` in the one chrome animation: with `on`, frames and layers they set animate over `duration`, ease out.
    func animate(_ on: Bool, duration: TimeInterval = motionDuration, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = on
            changes()
        }
    }

    /// Lights the caps of a key just pressed, for 150 ms.
    func flash(_ event: NSEvent) {
        chrome.pressed = KeyCap.pressed(by: event)
        chrome.pressTask?.cancel()
        chrome.pressTask = Task {
            try await Task.sleep(for: .milliseconds(150))
            chrome.pressed = []
            lightCaps()
        }
        lightCaps()
    }

    /// Whether `point` (view points) is on the top bar, or between the hovered element and its strip: there the hover holds, so the
    /// strip's buttons can be reached. The chips are labels that clicks and hover pass through, so they never hold it.
    func holdsHover(at point: CGPoint) -> Bool {
        guard selection == nil, let hover = view.overlays.hover else { return false }
        let box = view.viewRect(hover)
        // The strip and the bridge across the gap between it and the box, as wide as both.
        let attached = [chrome.strip].filter { !$0.isHidden }.flatMap { item in
            let left = max(box.minX, item.frame.minX), right = min(box.maxX, item.frame.maxX)
            let span = item.frame.union(box)
            return [item.frame] + (right > left ? [CGRect(x: left, y: span.minY, width: right - left, height: span.height)] : [])
        }
        return !box.contains(point) && attached.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
            || !chrome.topBar.isHidden && chrome.topBar.frame.contains(point)
    }

    /// Whether the pointer is on clickable chrome: a button of the top bar, strip or chips, or a row of an open menu (which covers the
    /// rest). The chips that pass clicks through are not.
    var overClickableChrome: Bool {
        if let menu = [chrome.ratioMenu, chrome.colorMenu].first(where: { !$0.isHidden }) { return menu.overRow }
        let point = CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale)
        return view.hitTest(view.convert(point, to: view.superview)) is BarButton
    }

    /// The tool button under the pointer: its name shows in the tool tip chip under it after 0.5 s, as a macOS tooltip does.
    func updateToolTip() {
        let point = CGPoint(x: pointer.x / scale, y: view.bounds.height - pointer.y / scale)
        let hit = view.hitTest(view.convert(point, to: view.superview))
        let tool: BarButton? = [chrome.scroll, chrome.record, chrome.cutout, chrome.colors].first { $0 === hit }
        guard tool !== chrome.tipButton else { return }
        chrome.tipButton = tool
        chrome.tipDue = false
        chrome.tipTask?.cancel()
        refreshExtras()
        guard tool != nil else { return }
        chrome.tipTask = Task {
            try await Task.sleep(for: .milliseconds(500))
            chrome.tipDue = true
            refreshExtras()
        }
    }

    /// The glyphs of the modifiers held now; each one's cap is lit.
    private var heldGlyphs: Set<Character> {
        Set([(optionHeld, "\u{2325}"), (commandHeld, "\u{2318}"), (shiftHeld, "\u{21E7}")].compactMap { $0.0 ? Character($0.1) : nil })
    }

    /// Every cap is pressed while its chord flashes, and a modifier's cap while its key is held;
    /// with `restyle` (a new tint), every button and cap redraws in the current tint.
    private func lightCaps(restyle: Bool = false) {
        let held = heldGlyphs.union(controlHeld ? ["\u{2303}"] : [])
        func light(_ view: NSView) {
            if let cap = view as? KeyCap { cap.pressed = chrome.pressed.contains(cap.chord) || cap.text.count == 1 && held.contains(cap.text.first!) }
            if restyle {
                (view as? BarButton)?.apply()
                (view as? KeyCap)?.apply()
            }
            view.subviews.forEach(light)
        }
        (chrome.all + [cornerChip, view.guides.readout] + chrome.buttons).forEach(light)
    }

    /// What the arrow keys do on a selection with the modifiers held now, as one label with its chord; nil while Command is held
    /// without Option (Command-arrow is unbound). Control matters only with Option, and Shift not with Control.
    private var arrowLegend: (keys: [String], label: String)? {
        switch (optionHeld, controlHeld, commandHeld) {
        case (true, true, false): (["\u{2303}\u{2325}"], "edge out")
        case (true, true, true): (["\u{2303}\u{2325}\u{2318}"], "edge in")
        case (true, false, false): shiftHeld ? (["\u{2325}\u{21E7}"], "grow 10 px") : (["\u{2325}"], "grow")
        case (true, false, true): shiftHeld ? (["\u{2325}\u{21E7}\u{2318}"], "shrink 10 px") : (["\u{2325}\u{2318}"], "shrink")
        case (false, _, true): nil
        case (false, _, false): shiftHeld ? (["\u{21E7}"], "move 10 px") : ([], "move")
        }
    }

    /// "r 12", or each corner when they differ: "r 12 / 0 / 0 / 12" (top-left, top-right, bottom-left, bottom-right), in points.
    private func radiusText(_ rect: CGRect) -> String {
        let radii = cornerRadii(of: rect)
        let points = CornerRadii.corners.map { Int((radii[$0] / scale).rounded()) }
        return "r " + (Set(points).count == 1 ? "\(points[0])" : points.map(String.init).joined(separator: " / "))
    }

    /// Whether a copy of `rect` captures a live window (with its real shadow, whose size macOS decides, under the default shadow) rather
    /// than cropping the frozen screen.
    func capturesLiveWindow(_ rect: CGRect) -> Bool {
        window(matching: rect).map { displayID != nil && !(windowFrozen.indices.contains($0) && windowFrozen[$0]) } ?? false
    }

    /// What the output of `rect` adds when Frame is on (flipped by `option`, Option on a hovered object): "  + frame W x H" in output
    /// pixels, the padded card's for an area or element and the window shadow's canvas for a subject; and "  + frame" alone when a
    /// click takes `rect` as a live window with its real shadow, whose size macOS decides per window (a 400 x 523 pt Settings window at
    /// 2x measured 94 x 123 px, against a subject's 208 x 210). Under a custom shadow every target adds its known canvas.
    private func additions(_ rect: CGRect, option: Bool = false) -> String {
        guard framed != option else { return "" }
        let shadow = frameShadow
        if cutout != nil, shadow == nil {
            let padding = OutputFrame.shadowPadding(scale: scale)
            return "  + frame \(2 * padding.sides) x \(padding.top + padding.bottom)"
        }
        if capturesLiveWindow(rect), shadow == nil { return "  + frame" }
        let crop = rect.integral, output = OutputFrame.rect(around: crop, scale: scale, padding: framePadding, shadow: shadow).integral
        return "  + frame \(Int(output.width - crop.width)) x \(Int(output.height - crop.height))"
    }

    /// Whether the pointer is inside the released selection or on its handles and edge band, the zone the resize cursors use (pixels).
    var pointerOnSelection: Bool {
        selection.map { $0.rect.contains(pointer) || $0.handle(at: pointer, tolerance: 8 * scale) != nil } == true
    }

    func refreshChrome() {
        let c = chrome
        let bounds = view.bounds
        // With Rulers on, chrome keeps clear of the top and left rulers' bands as it does of the menu bar and screen edges.
        let ruler = defaults.bool(forKey: Pref.rulers) ? Guides.rulerThickness : 0
        let topEdge = bounds.height - topInset - ruler, leftEdge = 8 + ruler
        let overlays = view.overlays
        let released = mode == .capture && selection != nil
        let editing = released && armedRecording == nil
        let tint = view.highlight?.color ?? .controlAccentColor
        let restyle = tint.cgColor != c.drawnTint
        c.drawnTint = tint.cgColor
        Chrome.tint = tint
        let look = Chrome.appearance(defaults)
        // The keys sheet keeps its own dark material.
        if c.topBar.appearance?.name != look?.name {
            for item in c.all + [cornerChip, view.guides.readout] where item !== c.help { item.appearance = look }
        }
        // Chrome motion, off in debug runs and with Reduce Motion: the strip's buttons cross-fade their labels and caps and animate their
        // widths, the strip moves and resizes, the settings bar slides, and the chips and strip fade in and out, 140 ms, ease out.
        // Everything else, the hover outline and the selection among it, changes at once. Frames take their final values at once; the
        // layers animate to them.
        let motion = animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A key's jump to another hover candidate moves the chrome on the outline's own 100 ms animation, so nothing trails it.
        let duration = jumping ? Self.jumpDuration : Self.motionDuration
        // The chrome on the hover outline and where each piece showed, which a jump moves from there to its new place.
        let attached: [NSView] = [c.hover, c.size, c.snap, c.snapTag, c.ratio, c.radius, c.legend, c.reading, c.status, c.list] + c.sideHints
        let attachedBefore = jumping ? attached.filter { !$0.isHidden }.map { ($0, $0.frame.origin) } : []
        let fading: [NSView] = [c.hover, c.size, c.snap, c.ratio, c.radius, c.reading, c.status, c.strip, c.toolTip]
        let wasShown = fading.map { !$0.isHidden }
        // The strip moves only from where it showed, against the same outline (checked once it is placed), and not while a drag moves the
        // selection under it. Its views and their frames now, and each one's subviews (a button's caps), to animate from once it is laid out.
        let stripMoves = motion && !c.strip.isHidden && draggedRect == nil
        func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
        let stripBefore = stripMoves ? tree(c.strip).map { ($0, $0.frame, $0.subviews) } : []
        let buttonsBefore = stripMoves ? c.strip.groups.flatMap(\.subviews) : []
        for item in [c.hover, c.size, c.snap, c.snapTag, c.ratio, c.radius, c.legend, c.reading, c.status, c.strip, c.minimap] { item.isHidden = true }
        c.help.frame = bounds
        c.help.layoutPanel()

        // The settings bar: the modes (not in cut out), view, style (not in Text), and the keys sheet's button; hidden while scrolling or
        // armed to record. On a screen too narrow for it, the keys sheet's button alone.
        if scrollArea != nil || armedRecording != nil {
            c.topBar.isHidden = true
        } else {
            let modes = cutout == nil ? [[c.modeButtons[.capture]!, c.modeButtons[.text]!]] : []
            c.topBar.show(modes + [c.viewToggles.map(\.1)] + (mode == .text ? [] : [c.styleToggles.map(\.1)]) + [[c.keys]])
            if c.topBar.frame.width > bounds.width - 16 { c.topBar.show([[c.keys]]) }
        }
        for (current, button) in c.modeButtons { button.primary = current == mode }
        for (key, button) in c.viewToggles + c.styleToggles { button.lit = defaults.bool(forKey: key) }

        // The object's chips and strip, filled before the keys line, which leaves out what the strip shows, and attached to the object
        // once the bar and keys line are placed.
        var attachment: (box: CGRect, strip: Bool, left: [NSView], right: [NSView])?
        c.stripSlack = 0
        func sizeChip(_ rect: CGRect, drag: String = "") -> Pill {
            let text = (rect == extent ? "Full screen  " : "") + "\(Int(rect.width)) x \(Int(rect.height))" + (armedRecording == nil ? additions(rect) : "") + drag
            c.size.show(text) { [NSTextField(text, size: 12, mono: true, color: .chromeText)] }
            return c.size
        }
        /// A session's hint in the status chip, in the chip row after the size chip; a notice takes the chip instead.
        func statusChip(_ keys: [String], _ label: String) -> [NSView] {
            guard text.notice == nil else { return [] }
            c.status.show(label + keys.joined()) { [Pill.hint(keys, label)] }
            return [c.status]
        }
        func radiusChip(_ rect: CGRect) -> Pill {
            let text = radiusText(rect)
            c.radius.show(text) { [NSTextField(text, size: 12, mono: true, color: .chromeText), KeyCap("["), KeyCap("]")] }
            return c.radius
        }
        /// The capture strip: Edit in its own pill, lit once there is a selection, then Copy and Save, then Scroll and Record (each
        /// left out when it cannot run on `area`), Subject, and Colors. The modifiers held relabel Copy (Command: Agent, Shift: Text,
        /// Option: Translate, each alone) and Save (Shift: Save As), whose clicks press the chord shown; at rest each shows only its own
        /// key, and a modifier's cap appears while it is held. A combination with no meaning dims the button, and any modifier dims Edit
        /// and the tools.
        func captureStrip(_ area: CGRect) {
            let scrolls = (scrollFrames != nil || displayID != nil) && area != extent && windows.contains { $0.insetBy(dx: -2, dy: -2).contains(area) }
            // Control has no strip action, so with it held every relabel misses and Copy and Save dim.
            let held = heldGlyphs.union(controlHeld ? ["\u{2303}"] : [])
            c.edit.lit = selection != nil
            let copy: (title: String, key: String)? = switch held {
            case []: ("Copy", "\u{21A9}")
            case ["\u{2318}"]: ("Agent", "\u{2318}\u{21A9}")
            case ["\u{21E7}"]: ("Text", "\u{21E7}\u{21A9}")
            case ["\u{2325}"]: ("Translate", "\u{2325}\u{21A9}")
            default: nil
            }
            c.copy.setTitle(copy?.title ?? "Copy")
            c.copy.setKeys(copy?.key ?? "\u{21A9}")
            c.save.setTitle(shiftHeld && !optionHeld ? "Save As" : "Save")
            c.save.setKeys(shiftHeld && !optionHeld ? "\u{21E7}\u{2318}S" : "\u{2318}S")
            // A modifier dims what it changes, and releasing it brings that back, in the strip's motion.
            animate(stripMoves, duration: duration) {
                c.copy.isEnabled = copy != nil
                c.save.isEnabled = !optionHeld && !controlHeld
                for button in [c.edit, c.scroll, c.record, c.cutout, c.colors] { button.isEnabled = held.isEmpty }
            }
            c.stripSlack = Chrome.widest.copy - c.copy.frame.width + Chrome.widest.save - c.save.frame.width
            c.strip.show([[c.edit], [c.copy, c.save], (scrolls ? [c.scroll] : []) + (displayID != nil ? [c.record] : []) + [c.cutout, c.colors]])
        }

        /// The Text strip: Copy, whose label the modifiers held change (Shift alone: Rows, Option alone: Translate) and which at rest
        /// shows only Return; any other combination dims it.
        func textStrip() {
            let copy: (title: String, key: String)? = switch heldGlyphs {
            case []: ("Copy", "\u{21A9}")
            case ["\u{21E7}"]: ("Rows", "\u{21E7}\u{21A9}")
            case ["\u{2325}"]: ("Translate", "\u{2325}\u{21A9}")
            default: nil
            }
            c.copy.setTitle(copy?.title ?? "Copy")
            c.copy.setKeys(copy?.key ?? "\u{21A9}")
            animate(stripMoves, duration: duration) { c.copy.isEnabled = copy != nil }
            c.stripSlack = Chrome.widest.text - c.copy.frame.width
            c.strip.show([[c.copy]])
        }

        if mode == .text {
            if let rect = selection?.rect {
                // The box: the Text strip, and once its lines are read the count of them in the size chip.
                textStrip()
                var left: [NSView] = []
                if text.box?.rect == rect, let lines = text.box?.lines {
                    let count = "\(lines.count) \(lines.count == 1 ? "line" : "lines")"
                    c.size.show(count) { [NSTextField(count, size: 12, mono: true, color: .chromeText)] }
                    left = [c.size]
                }
                attachment = (view.viewRect(rect), true, left, [])
            } else if !window.textDragging, let box = screenSelectionBox ?? textSelectionBox {
                textStrip()
                attachment = (box, true, [], [])
            }
        } else if let cutout {
            let subjects = cutout.subjects.count > 1 ? [c.subject] : []
            c.subject.setTitle(cutout.label)
            c.crop.lit = cutout.cropped
            c.copy.setTitle("Copy")
            c.copy.setKeys("\u{21A9}")
            c.save.setTitle("Save")
            c.save.setKeys("\u{2318}S")
            for button in [c.copy, c.save] { button.isEnabled = true }
            c.strip.show([subjects + [c.crop], [c.save, c.copy]])
            attachment = (view.viewRect(cutout.frame), true, [sizeChip(cutout.frame)] + statusChip(["K", "esc"], "back"), [])
        } else if let scrollArea {
            let height = scrollHeight >= ScrollStitcher.maximumHeight ? "\(ScrollStitcher.maximumHeight) px, the limit" : "\(scrollHeight) px"
            c.scrolled.setTitle("Scrolling \(height)")
            c.strip.show([[c.scrolled], [c.cancel, c.done]])
            attachment = (view.viewRect(scrollArea), true, statusChip([], "Scroll the app under the outline"), [])
        } else if let armed = armedRecording, let rect = selection?.rect {
            let countIn = defaults.integer(forKey: Pref.recordCountIn)
            c.cursor.lit = defaults.bool(forKey: Pref.recordCursor)
            c.audio.lit = defaults.bool(forKey: Pref.recordAudio)
            c.countIn.setTitle(countIn > 0 ? "\(countIn)-second count" : "Count-in")
            c.countIn.lit = countIn > 0
            c.strip.show(armed.remaining == nil ? [[c.cursor, c.audio, c.countIn], [c.cancel, c.start]] : [[c.cancel]])
            // Counting in, the chip counts down; before, Start and Cancel on the strip carry the keys.
            attachment = (view.viewRect(rect), true, [sizeChip(rect)] + (armed.remaining.map { statusChip([], "Recording in \($0)") } ?? []), [])
        } else if mode == .capture, let rect = overlays.selection ?? overlays.preview ?? overlays.ghost {
            // A drag shows its size, then Snapped when the snap preview is showing and Exact when it is not. A selection shows its size
            // and Snap, which reads Snapped or Exact, then the ratio and radius.
            let snapped = selection.map { $0.fits.count > 1 && $0.rect != $0.exact }
            c.snap.setTitle(snapped.map { $0 ? "Snapped" : "Exact" } ?? "Snap")
            c.snap.lit = snapped ?? false
            var right: [NSView] = []
            if editing {
                c.ratioButton.setTitle(ratioReadout)
                c.lock.lit = ratioLocked
                c.ratio.show(ratioReadout) { [c.ratioButton, c.ratioDivider, c.lock] }
                right = [c.ratio, radiusChip(rect)]
                captureStrip(rect)
            }
            attachment = (view.viewRect(rect), editing, selection == nil ? [sizeChip(rect, drag: overlays.preview == nil ? "  Exact" : "  Snapped")] : [sizeChip(rect), c.snap], right)
        } else if mode == .capture, let rect = overlays.hover {
            // Hovering: the element's name and size; the radius once `[` or `]` changed it.
            let hovered = session!.selected!
            let isWindow = hovered.kind == .window
            let index = isWindow ? Int(hovered.id.dropFirst("window-".count))! : 0
            let name = switch hovered.kind {
            case .window: windowNames.indices.contains(index) ? windowNames[index] : "Window"
            case .display: "Full screen"
            default: hovered.label
            }
            let size = "\(Int(rect.width)) x \(Int(rect.height))" + additions(rect, option: optionHeld)
            c.hover.show("\(name)|\(size)") {
                [NSTextField(name, size: 12, weight: .semibold, color: .chromeText), NSTextField(size, size: 12, mono: true, color: NSColor.chromeText.withAlphaComponent(0.65))]
            }
            captureStrip(rect)
            attachment = (view.viewRect(rect), true, [c.hover] + (editedRadii[rect] == nil ? [] : [radiusChip(rect)]), [])
        }

        // The settings bar sits 8 pt above the bottom edge, or above a Dock there. It moves under the menu bar or notch while a drag, preview, or selection is
        // within 24 pt of it there and not there.
        let objects = [overlays.ghost, overlays.preview, overlays.selection].compactMap { $0 }.map(view.viewRect)
        let barSize = c.topBar.frame.size
        func barFrame(atTop: Bool) -> CGRect {
            CGRect(x: ((bounds.width - barSize.width) / 2).rounded(), y: atTop ? topEdge - 8 - barSize.height : bottomInset + 8, width: barSize.width, height: barSize.height)
        }
        let barAtTop = !c.topBar.isHidden && objects.contains {
            $0.intersects(barFrame(atTop: false).insetBy(dx: -24, dy: -24)) && !$0.intersects(barFrame(atTop: true).insetBy(dx: -24, dy: -24))
        }
        // Chrome attached to an object keeps between `floor` and `top`, clear of the bar.
        var top = topEdge, floor: CGFloat = 8
        var frames: [(NSView, CGRect)] = []
        if !c.topBar.isHidden {
            let frame = barFrame(atTop: barAtTop)
            frames.append((c.topBar, frame))
            if barAtTop { top = frame.minY } else { floor = frame.maxY + 8 }
        }
        animate(motion && (barAtTop != c.barAtTop || ruler != c.ruler), duration: duration) {
            for (item, frame) in frames { item.frame = frame }
        }
        c.ruler = ruler
        c.barAtTop = barAtTop

        /// Attaches the strip below `box` (above when the bottom has no room, else inside), then the chip row above it (above the strip
        /// when that is above, else inside the top): `left` from the box's left edge, `right` ending at its right edge, or after `left`
        /// when they would meet, or a row higher (lower, inside) when the screen ends first, unless inside a box too narrow to hold the row, where it stays in the row. Only the box's edges place them. Outside, chrome
        /// sits 8 pt off the outline; inside, 8 pt in from it on every side. A box wholly above the bar's lower edge with the bar at the
        /// top, or above the top ruler's lower edge, has no room there: the strip hangs from that edge and the chip row stacks under it. With
        /// the bar at the bottom, a box that ends below the bar's upper edge gets its strip and chips standing on that edge.
        func attach(to box: CGRect, strip: Bool, left: [NSView], right: [NSView] = []) {
            var over = max(box.maxY + 8, floor)
            let capped = box.minY > top
            if strip {
                let size = c.strip.frame.size
                let below = min(box.minY, top) - 8 - size.height
                let outside = below >= floor || over + size.height <= top - 8
                let y = below >= floor ? below : over + size.height <= top - 8 ? over : max(box.minY + 8, floor)
                c.strip.frame.origin = CGPoint(x: min(max(box.minX + (outside ? 0 : 8), leftEdge), bounds.width - size.width - c.stripSlack - 8), y: y)
                if y == over { over = c.strip.frame.maxY + 8 }
            }
            guard let height = (left + right).first?.frame.height else { return }
            for chip in left + right { chip.isHidden = false }
            // A box too short to hold the chip row inside above its strip (a menu bar item at the top edge) stacks it under the strip.
            let stacked = capped || strip && over + height > top - 8 && c.strip.frame.maxY <= box.minY && min(box.maxY, top) - 14 - height < c.strip.frame.maxY
            let inside = stacked || over + height > top - 8
            let inset: CGFloat = inside && !stacked ? 8 : 0
            var y = stacked ? (strip ? c.strip.frame.minY : top - 8) - 6 - height : inside ? min(box.maxY, top) - 8 - height : over
            var x = min(max(box.minX + inset, leftEdge), bounds.width - 8 - left.reduce(-6) { $0 + $1.frame.width + 6 })
            for chip in left {
                chip.frame.origin = CGPoint(x: x, y: y)
                x += chip.frame.width + 6
            }
            let width = right.reduce(-6) { $0 + $1.frame.width + 6 }
            var start = min(max(box.maxX - inset - width, x), bounds.width - 8 - width)
            if start < x - 0.5 || inside && start + width > box.maxX - inset + 0.5 && width <= box.width - 2 * inset {
                start = min(max(box.maxX - inset - width, leftEdge, box.minX + inset), bounds.width - 8 - width)
                y += inside ? -(height + 6) : height + 6
                // A row dropped inside the top, onto a strip standing just under a short box, goes under the strip instead.
                if strip, inside, c.strip.frame.intersects(CGRect(x: start, y: y, width: width, height: height)) { y = c.strip.frame.minY - 6 - height }
            }
            for chip in right {
                chip.frame.origin = CGPoint(x: start, y: y)
                start += chip.frame.width + 6
            }
        }
        if let attachment { attach(to: attachment.box, strip: attachment.strip, left: attachment.left, right: attachment.right) }

        // One placement pass, in priority order, on the screen under the menu bar and clear of the rulers' bands. The bar and `attach` place the first four, each clear of those before it; from the fifth,
        // each item takes the first of its spots that is on the screen and clear of every item placed before it, and hides when none is:
        // 1. the settings bar: at the bottom, or at the top while an object is near the bottom (placed above);
        // 2. the strip: below the object, above it, or inside its bottom (`attach`);
        // 3. the size chip row (size and Snap, the hover chip, or the status chip): above the object, inside its top, or under the strip (`attach`);
        // 4. the radius chip row (ratio and radius): ending at the object's right edge, or a row past the size chips (`attach`); while a corner shows, the row waits
        //    for item 7 and then takes its place or the nearest spot past the chrome;
        // 5. the tool tip, which names the strip's button under the pointer: under the strip, then over it;
        // 6. the notice (a message the user must read): centered above the bar, then centered under the menu bar, then centered just
        //    below or above each item placed so far, nearest first;
        // 7. the corner chip of the focused or hovered corner with its keys stacked under it (over it at the bottom corners):
        //    outside the corner beside the selection's side, inside the corner, inside along the selection's top or bottom edge, then just
        //    below or above each item placed so far, nearest first, so a focused corner always shows;
        // 8. the legend with the arrow keys around it like a D-pad, as one group under every modifier: centered in the selection when it
        //    fits, else wholly outside it on the nearest free side (below, above, right, left), else just below or above an item placed so far;
        // 9. the hint caps: inside the top-left corner of their outlines, then inside the bottom-left;
        // 10. the reading chip: centered in the text region, then above it, then below it, then just below or above an item placed so far;
        // 11. the candidate list: beside the hovered outline on its right, then its left, then inside its top right and top left;
        // 12. the scroll minimap, centered beside the scroll area: on its right, then its left, then inside its right edge;
        // 13. the pointer cluster and the loupe, placed last in `updateGuides` against every frame placed here and moved clear of all of
        //     them: the loupe follows the pointer on its lower or upper side, sliding up or down past a bar or chip it would cover, and
        //     its readout and the cluster hang under it.
        let screen = CGRect(x: 4 + ruler, y: 4, width: bounds.width - 8 - ruler, height: topEdge - 8)
        var placed = [c.topBar, c.strip].filter { !$0.isHidden }.map(\.frame)
        /// Moves `group` as one so its first view's origin takes the first free spot, or hides it.
        func settle(_ group: [NSView], _ spots: [CGPoint]) {
            let start = group[0].frame.origin
            let spot = spots.first { spot in
                group.allSatisfy { item in
                    let frame = item.frame.offsetBy(dx: spot.x - start.x, dy: spot.y - start.y)
                    return screen.contains(frame) && !placed.contains { $0.intersects(frame) }
                }
            }
            for item in group {
                item.isHidden = spot == nil
                if let spot { item.frame.origin = CGPoint(x: item.frame.minX + spot.x - start.x, y: item.frame.minY + spot.y - start.y) }
            }
            if spot != nil { placed += group.map(\.frame) }
        }
        /// `x` clamped so a frame of `size` starting there is on the screen, and likewise `y`.
        func onScreenX(_ x: CGFloat, _ size: CGSize) -> CGFloat { min(max(x, screen.minX), max(screen.maxX - size.width, screen.minX)) }
        func onScreenY(_ y: CGFloat, _ size: CGSize) -> CGFloat { min(max(y, screen.minY), max(screen.maxY - size.height, screen.minY)) }
        /// Spots for a `size` frame at `x` (kept on the screen): just below and just above each item placed so far, nearest to `y` first.
        func past(x: CGFloat, _ size: CGSize, near y: CGFloat) -> [CGPoint] {
            placed.flatMap { [CGPoint(x: onScreenX(x, size), y: $0.minY - 6 - size.height), CGPoint(x: onScreenX(x, size), y: $0.maxY + 6)] }.sorted { abs($0.y - y) < abs($1.y - y) }
        }
        // `attach` already kept the chip rows clear of the bar and strip and as far on the screen as it could. While a corner shows, the
        // ratio and radius row waits: the corner's chip and keys are placed first and the row moves if they take its place.
        let cornerShown = (hoveredCorner ?? focusedCorner) != nil && selection != nil && scrollArea == nil && mode == .capture
        let row = cornerShown ? attachment?.right ?? [] : []
        let rowHome = row.first?.frame.origin
        if let attachment { placed += (attachment.left + attachment.right.filter { !row.contains($0) }).map(\.frame) }

        // The tool tip, once its delay has passed and while the pointer is on the button and the button takes clicks (not dimmed, not under
        // an open menu).
        let point = CGPoint(x: pointer.x / scale, y: bounds.height - pointer.y / scale)
        c.toolTip.isHidden = true
        if c.tipDue, let tool = c.tipButton, !c.strip.isHidden, view.hitTest(view.convert(point, to: view.superview)) === tool {
            let name = tool.accessibilityLabel()!
            c.toolTip.show(name) { [NSTextField(name, size: 12, weight: .semibold, color: .chromeText)] }
            let button = view.convert(tool.bounds, from: tool), size = c.toolTip.frame.size
            let x = min(max((button.midX - size.width / 2).rounded(), 8), bounds.width - size.width - 8)
            settle([c.toolTip], [CGPoint(x: x, y: c.strip.frame.minY - 4 - size.height), CGPoint(x: x, y: c.strip.frame.maxY + 4)])
        }

        if let notice = text.notice {
            c.status.show(notice) { [NSTextField(notice, size: 12, color: .chromeText)] }
            let size = c.status.frame.size, x = ((bounds.width - size.width) / 2).rounded()
            settle([c.status], [CGPoint(x: x, y: floor), CGPoint(x: x, y: top - 8 - size.height)] + past(x: x, size, near: floor))
        }

        cornerChip.isHidden = true
        c.cornerKeys.isHidden = true
        if cornerShown, let corner = focusedCorner ?? hoveredCorner, let rect = selection?.rect {
            // One group for a hovered dot and a focused corner: the chip names what [ and ] change, with its radius in points (all
            // corners' as a range when they differ), and the same rows follow, esc only while a corner is focused.
            let names: [Handle: String] = [.topLeft: "Top left", .topRight: "Top right", .bottomRight: "Bottom right", .bottomLeft: "Bottom left"]
            let points = (focusedCorner.map { [$0] } ?? CornerRadii.corners).map { Int((cornerRadii(of: rect)[$0] / scale).rounded()) }
            let range = points.min()! == points.max()! ? "\(points[0])" : "\(points.min()!)-\(points.max()!)"
            cornerChip.setTitle((focusedCorner.map { names[$0]! } ?? "All corners") + "  r " + range)
            c.cornerKeys.show(focusedCorner == nil ? "all corners" : "one corner") {
                [Pill.hint(["[", "]"], "radius"), Pill.hint(["tab"], focusedCorner == nil ? "one corner" : "next corner")]
                    + (focusedCorner == nil ? [] : [Pill.hint(["esc"], "all corners")])
            }
            let box = view.viewRect(rect), chip = cornerChip.frame.size, keys = c.cornerKeys.frame.size
            let y = corner.movesTop ? box.maxY - chip.height : box.minY
            cornerChip.frame.origin = CGPoint(x: corner.movesLeft ? box.minX - 6 - chip.width : box.maxX + 6, y: y)
            c.cornerKeys.frame.origin = CGPoint(x: corner.movesLeft ? cornerChip.frame.maxX - keys.width : cornerChip.frame.minX,
                                                y: corner.movesTop ? y - 4 - keys.height : y + chip.height + 4)
            let group = cornerChip.frame.union(c.cornerKeys.frame), toGroup = CGPoint(x: group.minX - cornerChip.frame.minX, y: group.minY - cornerChip.frame.minY)
            let edgeY = corner.movesTop ? box.maxY - 8 - chip.height : box.minY + 8
            settle([cornerChip, c.cornerKeys],
                   [cornerChip.frame.origin, CGPoint(x: corner.movesLeft ? box.minX + 14 : box.maxX - 14 - chip.width, y: y), CGPoint(x: (box.midX - chip.width / 2).rounded(), y: edgeY)]
                    + past(x: group.minX, group.size, near: group.minY).map { CGPoint(x: $0.x - toGroup.x, y: $0.y - toGroup.y) })
        }
        if let rowHome {
            let size = row.reduce(CGSize.zero) { CGSize(width: $0.width + $1.frame.width + 6, height: $1.frame.height) }
            settle(row, [rowHome] + past(x: rowHome.x, size, near: rowHome.y))
        }

        // While the pointer rests inside a released selection or on its handles (pixels, as the handle cursors read them), or Option is held, the legend in the middle says what the arrows do.
        let resting = draggedRect == nil && pointerOnSelection
        let legend = arrowLegend
        let showsEdgeKeys = editing && legend != nil && (optionHeld || resting)
        for (index, pill) in c.sideHints.enumerated() {
            let arrow = ["\u{2190}", "\u{2192}", "\u{2191}", "\u{2193}"][index]
            pill.isHidden = !showsEdgeKeys
            if showsEdgeKeys { pill.show(arrow) { [KeyCap(arrow)] } }
        }
        if showsEdgeKeys, let legend, let rect = overlays.selection {
            c.legend.show(legend.label + legend.keys.joined()) { [Pill.hint(legend.keys, legend.label)] }
            let box = view.viewRect(rect), gap: CGFloat = 6
            let (left, right, up, down) = (c.sideHints[0].frame.size, c.sideHints[1].frame.size, c.sideHints[2].frame.size, c.sideHints[3].frame.size)
            let size = c.legend.frame.size
            let group = CGSize(width: left.width + gap + size.width + gap + right.width, height: up.height + gap + size.height + gap + down.height)
            // The group is laid out centered in the selection and moves as one to its spot, given as the group's lower-left corner.
            let centered = CGPoint(x: (box.midX - group.width / 2).rounded(), y: (box.midY - group.height / 2).rounded())
            let center = CGPoint(x: centered.x + left.width + gap + size.width / 2, y: centered.y + down.height + gap + size.height / 2)
            c.legend.frame.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            c.sideHints[0].frame.origin = CGPoint(x: c.legend.frame.minX - gap - left.width, y: center.y - left.height / 2)
            c.sideHints[1].frame.origin = CGPoint(x: c.legend.frame.maxX + gap, y: center.y - right.height / 2)
            c.sideHints[2].frame.origin = CGPoint(x: center.x - up.width / 2, y: c.legend.frame.maxY + gap)
            c.sideHints[3].frame.origin = CGPoint(x: center.x - down.width / 2, y: c.legend.frame.minY - gap - down.height)
            let fits = box.contains(CGRect(origin: centered, size: group))
            let outside = [CGPoint(x: onScreenX(centered.x, group), y: box.minY - 8 - group.height), CGPoint(x: onScreenX(centered.x, group), y: box.maxY + 8),
                           CGPoint(x: box.maxX + 8, y: onScreenY(centered.y, group)), CGPoint(x: box.minX - 8 - group.width, y: onScreenY(centered.y, group))]
            // The down cap is the group's lowest view, so its origin moves by the group's.
            let lowest = c.sideHints[3]
            // With no side free the group goes past the chrome.
            settle([lowest, c.legend] + c.sideHints.prefix(3), ((fits ? [centered] : outside) + past(x: centered.x, group, near: centered.y)).map { CGPoint(x: lowest.frame.minX + $0.x - centered.x, y: lowest.frame.minY + $0.y - centered.y) })
        }

        // The key caps of the faint outlines. At a jump they move at once and fade in with their outlines.
        for (cap, rect) in [(c.upHint, overlays.upHint), (c.downHint, overlays.downHint)] {
            cap.isHidden = rect == nil
            if let rect {
                let box = view.viewRect(rect)
                cap.frame.origin = CGPoint(x: box.minX + 4, y: box.maxY - cap.frame.height - 4)
                settle([cap], [cap.frame.origin, CGPoint(x: box.minX + 4, y: box.minY + 4)])
                if jumping { cap.layer!.add(view.levelHintLayer.animation(forKey: "opacity")!, forKey: "opacity") }
            }
        }

        if let rect = text.reading {
            c.reading.show("reading") { [NSTextField("Reading text...", size: 12, color: .chromeText)] }
            let box = view.viewRect(rect), size = c.reading.frame.size, x = onScreenX((box.midX - size.width / 2).rounded(), size)
            settle([c.reading], [CGPoint(x: x, y: onScreenY((box.midY - size.height / 2).rounded(), size)), CGPoint(x: x, y: box.maxY + 8), CGPoint(x: x, y: box.minY - 8 - size.height)] + past(x: x, size, near: box.midY))
        }

        c.list.isHidden = !(overlays.hover != nil && selection == nil && defaults.bool(forKey: Pref.candidates))
        if !c.list.isHidden, let session {
            let allow = displayID != nil && !isHeadless && !AXIsProcessTrusted()
            c.list.update(session.shortlist, parents: session.parents, current: session.selected?.id, onAllowAccessibility: allow ? { Accessibility.requestTrust() } : nil)
            let box = view.viewRect(overlays.hover!), size = c.list.frame.size
            let y = onScreenY(box.maxY - size.height, size)
            settle([c.list], [CGPoint(x: box.maxX + 12, y: y), CGPoint(x: box.minX - 12 - size.width, y: y), CGPoint(x: box.maxX - 12 - size.width, y: y), CGPoint(x: box.minX + 12, y: y)])
        }
        if let scrollArea, let thumbnail = scrollThumbnail {
            let box = view.viewRect(scrollArea)
            c.minimapThumb.show(thumbnail, size: CGSize(width: CGFloat(thumbnail.width) / scale, height: CGFloat(thumbnail.height) / scale),
                                shown: CGFloat(scrollArea.height) / CGFloat(scrollHeight), tint: tint)
            c.minimap.show("minimap \(thumbnail.width) x \(thumbnail.height)") { [c.minimapThumb] }
            let size = c.minimap.frame.size, y = (box.midY - size.height / 2).rounded()
            settle([c.minimap], [CGPoint(x: box.maxX + 8, y: y), CGPoint(x: box.minX - 8 - size.width, y: y), CGPoint(x: box.maxX - 8 - size.width, y: y)])
        }
        // Against the same outline, the strip's views that stayed in it animate from their old frames to the new ones, and a button whose
        // caps were replaced cross-fades its old title and caps into the new ones. A new outline (a hover change, an arrow nudge) moves
        // the strip and every chip with it at once. The views are built and laid out outside the animation: a new text field, not yet
        // in a layer tree, would otherwise grow its frame from zero.
        if !c.strip.isHidden, attachment?.box == c.anchor || jumping {
            let moved = stripBefore.filter { $0.0.frame != $0.1 && ($0.0 === c.strip || $0.0.isDescendant(of: c.strip)) }
            let relabeled = stripBefore.filter { $0.0 is BarButton && $0.0.subviews != $0.2 }.map(\.0)
            // A session strip whose buttons changed (the scroll, recording or subject strip taking the capture strip's place) cross-fades whole.
            let reshaped = !buttonsBefore.isEmpty && buttonsBefore != c.strip.groups.flatMap(\.subviews)
            let targets = moved.map(\.0.frame)
            for (item, frame, _) in moved { item.frame = frame }
            animate(true, duration: duration) {
                for ((item, _, _), target) in zip(moved, targets) { item.animator().frame = target }
                let fade = CATransition()
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for button in relabeled { button.layer!.add(fade, forKey: kCATransition) }
                if reshaped { c.strip.layer!.add(fade, forKey: kCATransition) }
            }
        }
        c.anchor = attachment?.box
        for (item, origin) in attachedBefore where !item.isHidden && item.frame.origin != origin {
            let target = item.frame.origin
            item.frame.origin = origin
            animate(true, duration: duration) { item.animator().setFrameOrigin(target) }
        }
        // A chip or the strip that appeared or went away fades: its hidden state is set again inside the animation.
        for (item, shown) in zip(fading, wasShown) where motion && item.isHidden == shown {
            item.isHidden = !shown
            animate(true, duration: duration) { item.isHidden = shown }
        }
        lightCaps(restyle: restyle)
    }
}
