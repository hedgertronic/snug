import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--verify-agent-ui DIR`: the Copy for Agent checks alone, writing their bundles into DIR and leaving them there.
    static func verifyAgent(into folder: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        overlay.defaults.set(folder.path, forKey: Pref.agentFolder)
        var passed: [String] = []
        try await verifyAgentHandoff(image: image, frame: frame, overlay: overlay) { condition, message in
            guard condition else {
                FileHandle.standardError.write(Data("Agent UI verification failed: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
            passed.append(message)
        }
        requireBackground(overlay)
        print("Agent UI verification passed (\(passed.count) checks)")
        passed.forEach { print("  ok: \($0)") }
        exit(EXIT_SUCCESS)
    }

    /// Copy for Agent on the frozen image, with Frame and Rounded on: Cmd-Return on a hovered geometry element, again with synthetic
    /// accessibility frames whose row is larger than the element (a web page's, with details), then a Command-click on the strip's Copy
    /// (reading Agent) on a selection whose accessibility frames the hover had read. Each writes a bundle with a valid manifest to the agent folder
    /// (each replaces the one before) and one item with the PNG (its manifest in the text chunk), the reference line and the manifest to the run's private pasteboard.
    static func verifyAgentHandoff(image: CGImage, frame: CGRect, overlay: OverlayController, require: (Bool, String) -> Void) async throws {
        let pasteboard = overlay.pasteboard
        let defaults = overlay.defaults
        let store = HandoffStore(defaults: defaults)
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                overlay.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!)
            }
        }
        func flags(_ held: NSEvent.ModifierFlags) {
            overlay.window.sendEvent(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!)
        }
        let copyButton = overlay.chrome.copy
        /// Holding Command turns the strip's Copy into Agent, its Command cap lit; releasing it brings Copy back.
        func checkAgentLabel(_ name: String) {
            flags(.command)
            let command = copyButton.caps.first { $0.text == "\u{2318}" }
            require(texts(in: copyButton) == ["Agent", "\u{2318}", "\u{21A9}"] && copyButton.key == "\u{2318}\u{21A9}" && command?.pressed == true,
                    "\(name): with Command held the strip's Copy reads Agent, its Command cap lit: \(texts(in: copyButton))")
            flags([])
            require(texts(in: copyButton) == ["Copy", "\u{21A9}"] && copyButton.key == "\u{21A9}",
                    "\(name): releasing Command restores Copy with Return alone: \(texts(in: copyButton))")
        }
        /// The copied item's manifest, after checking the bundle, the clipboard item and the toast against it and the frozen pixels at `crop`.
        func copied(_ crop: CGRect, _ name: String) async throws -> HandoffManifest {
            await overlay.commitTask?.value
            require(!overlay.window.isVisible, "\(name): the overlay closes")
            let items = pasteboard.pasteboardItems ?? []
            require(items.count == 1, "\(name): one clipboard item (\(items.count))")
            let types = items[0].types.map(\.rawValue)
            require(["public.png", "public.utf8-plain-text", "local.snug.capture-json"].allSatisfy(types.contains), "\(name): the item has the PNG, text and manifest types: \(types)")
            let json = items[0].data(forType: .snugCapture)!
            let manifest = try HandoffManifest(json: json)
            let bundle = store.root.appending(path: manifest.captureId)
            require(try HandoffManifest(json: Data(contentsOf: bundle.appending(path: "manifest.json"))) == manifest,
                    "\(name): the bundle \(bundle.path) holds the same manifest")
            let png = items[0].data(forType: .png)!
            require(try Data(contentsOf: bundle.appending(path: "capture.png")) == png && HandoffManifest.embedded(in: png) == json,
                    "\(name): the bundle's capture.png is the clipboard PNG, with the manifest in its Snug.Manifest text chunk")
            let decoded = NSBitmapImageRep(data: png)!
            let frozen = NSBitmapImageRep(cgImage: image.cropping(to: crop)!)
            require(decoded.pixelsWide == Int(crop.width) && decoded.pixelsHigh == Int(crop.height)
                        && manifest.image.width == Int(crop.width) && manifest.image.height == Int(crop.height),
                    "\(name): the image is the crop at full resolution, with no Frame padding: \(decoded.pixelsWide) x \(decoded.pixelsHigh), crop \(crop)")
            let corners = [(0, 0), (decoded.pixelsWide - 1, 0), (0, decoded.pixelsHigh - 1), (decoded.pixelsWide - 1, decoded.pixelsHigh - 1), (decoded.pixelsWide / 2, decoded.pixelsHigh / 2)]
            require(corners.allSatisfy { decoded.colorAt(x: $0.0, y: $0.1) == frozen.colorAt(x: $0.0, y: $0.1) && decoded.colorAt(x: $0.0, y: $0.1)!.alphaComponent == 1 },
                    "\(name): its corners are the frozen pixels, opaque, with no rounded mask")
            require(manifest.geometry.cropPixels == .init(crop) && manifest.image.scale == Double(overlay.scale)
                        && manifest.geometry.cropGlobal.width == Double(crop.width / overlay.scale), "\(name): the geometry is the crop in pixels and points")
            let reference = items[0].string(forType: .string)!
            require(reference == manifest.reference && reference.allSatisfy(\.isASCII) && reference.hasPrefix("[Snug capture \(manifest.captureId): "),
                    "\(name): the text is the ASCII reference line: \(reference)")
            require(OverlayController.lastAgentToast! == ("Copied for agent", manifest.captureId), "\(name): the toast says Copied for agent with the id")
            print("\(name) reference: \(reference)")
            print("\(name) manifest: \(String(decoding: json, as: UTF8.self))")
            return manifest
        }
        defaults.set(true, forKey: Pref.frame)
        defaults.set(true, forKey: Pref.roundCorners)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        // Cmd-Return on a hovered geometry element.
        overlay.present(image: image, frame: frame, displayID: nil)
        await overlay.detectionTask?.value
        let target = overlay.detected.filter { $0.bounds.width < extent.width / 4 && $0.bounds.height < extent.height / 4 && $0.bounds.width > 40 }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }!
        mouse(.mouseMoved, CGPoint(x: target.bounds.midX, y: target.bounds.midY))
        let hovered = overlay.session!.selected!
        require(hovered.kind != .window && hovered.kind != .display && !overlay.chrome.strip.isHidden, "a hovered element shows the strip")
        checkAgentLabel("the hover strip")
        pasteboard.clearContents()
        key(36, "\r", .command)
        let element = try await copied(hovered.bounds.integral, "Cmd-Return on a hovered element")
        require(element.target.kind == (hovered.id.hasPrefix("fill-") ? .fill : .element) && element.target.provenance == .geometry && element.target.role == nil
                    && element.target.frame == nil && element.target.label == hovered.label,
                "the hovered geometry element is the target, with no accessibility fields when nothing was read: \(element.target)")
        require(element.warnings == [.accessibilityUnavailable, .sourceUnavailable] && element.source == nil,
                "an imported image warns that accessibility and the source are unavailable: \(element.warnings)")

        // Cmd-Return on the same element with synthetic frames from the hover: a row inside a web page, larger than the element by more
        // than the tolerance on every side, holding a smaller link. The row is the target, its frame beside the crop; kind and provenance stay.
        let scale = overlay.scale
        let origin = CGPoint(x: overlay.window.frame.minX, y: NSScreen.screens[0].frame.height - overlay.window.frame.maxY)
        func global(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX / scale, y: origin.y + rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
        }
        overlay.present(image: image, frame: frame, displayID: nil)
        await overlay.detectionTask?.value
        mouse(.mouseMoved, CGPoint(x: target.bounds.midX, y: target.bounds.midY))
        let again = overlay.session!.selected!
        let crop = global(again.bounds.integral)
        let page = global(extent)
        let rowFrames = [AXFrame(roleDescription: "link", rect: CGRect(x: crop.midX - 10, y: crop.midY - 5, width: 20, height: 10), role: "AXLink", title: "Docs",
                                 details: .init(url: "https://example.com/docs", domId: "docs-link", domClasses: ["nav-link"])),
                         AXFrame(roleDescription: "row", rect: crop.insetBy(dx: -8, dy: -8), role: "AXRow",
                                 details: .init(help: "Open the docs", domClasses: ["nav-row", "flex"], enabled: true, selected: true,
                                                children: [.init(role: "AXLink", name: "Docs")], siblings: [.init(role: "AXRow", name: "Blog")])),
                         AXFrame(roleDescription: "HTML content", rect: page, role: "AXWebArea", title: "Example"),
                         AXFrame(roleDescription: "standard window", rect: page, role: "AXWindow", title: "Example")]
        overlay.accessibilityObservations[again.bounds] = (rowFrames, overlay.frozenAt.addingTimeInterval(1))
        pasteboard.clearContents()
        key(36, "\r", .command)
        let row = try await copied(again.bounds.integral, "Cmd-Return on a hovered element inside a larger accessibility row")
        require(row.target.kind == element.target.kind && row.target.provenance == .geometry && row.target.role == "AXRow" && row.target.frame == .init(rowFrames[1].rect)
                    && row.target.ancestors?.map(\.role) == ["AXWebArea", "AXWindow"] && row.target.observedAt != nil,
                "the row holding the element is the target, with its frame, while kind and provenance stay: \(row.target)")
        require(row.target.help == "Open the docs" && row.target.selected == true && row.target.children?.first?.name == "Docs"
                    && row.target.siblings?.first?.name == "Blog" && row.target.selector == "row.nav-row.flex",
                "the row carries its details and a selector from the web area: \(row.target.selector ?? "none")")
        require(row.reference.contains(": \(row.target.label.lowercased()), "), "the reference names the element's label, not the row: \(row.reference)")
        require(!row.warnings.contains(.accessibilityStale), "a read 1 s after the freeze is not stale: \(row.warnings)")

        // The strip's Agent button on a selection the hover had read accessibility frames for.
        overlay.present(image: image, frame: frame, displayID: nil)
        overlay.detectionTask?.cancel()
        let rect = CGRect(x: 350, y: 458, width: 580, height: 64)
        overlay.selection = AreaSelection(extent: extent, exact: rect)
        overlay.refresh()
        checkAgentLabel("the selection strip")
        let field = global(rect)
        let frames = [AXFrame(roleDescription: "text field", rect: field.insetBy(dx: 1, dy: 1), role: "AXTextField", title: "Email",
                              identifier: "email", elementDescription: "Email address"),
                      AXFrame(roleDescription: "group", rect: field.insetBy(dx: -40, dy: -40), role: "AXGroup"),
                      AXFrame(roleDescription: "standard window", rect: field.insetBy(dx: -200, dy: -200), role: "AXWindow", title: "Form test")]
        overlay.accessibilityObservations[rect] = (frames, overlay.frozenAt.addingTimeInterval(6))
        pasteboard.clearContents()
        // A Command-click on the strip's Copy, which reads Agent while Command is held, copies for the agent.
        flags(.command)
        let center = copyButton.convert(CGPoint(x: copyButton.bounds.midX, y: copyButton.bounds.midY), to: overlay.view)
        let pixel = CGPoint(x: center.x * overlay.scale, y: (overlay.view.bounds.height - center.y) * overlay.scale)
        require(overlay.view.hitTest(center) === copyButton && texts(in: copyButton).first == "Agent", "with Command held a click at Copy reaches it, reading Agent")
        mouse(.leftMouseDown, pixel, .command)
        mouse(.leftMouseUp, pixel, .command)
        flags([])
        let selected = try await copied(rect, "A Command-click on the strip's Copy (Agent) on a selection")
        require(selected.target.kind == .area && selected.target.provenance == .accessibility && selected.target.role == "AXTextField" && selected.target.title == "Email"
                    && selected.target.identifier == "email" && selected.target.description == "Email address" && selected.target.subrole == nil,
                "a selection takes the accessibility fields of the element the hover read for it: \(selected.target)")
        require(selected.target.ancestors?.map(\.role) == ["AXGroup", "AXWindow"] && selected.warnings.contains(.accessibilityStale),
                "its ancestors follow innermost first, and a read 6 s after the freeze is stale: \(selected.warnings)")
        require(try store.current() == selected && FileManager.default.contentsOfDirectory(atPath: store.root.path) == [selected.captureId],
                "the last copy replaced the others: the store holds only bundle \(selected.captureId), not \(row.captureId)")
        print("replaced captures: \(element.captureId), \(row.captureId)")
        defaults.set(false, forKey: Pref.frame)
    }
}
