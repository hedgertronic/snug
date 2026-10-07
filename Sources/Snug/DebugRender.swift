import AppKit
import SwiftUI
import ScreenshotCore

extension DebugRun {
    /// `--render-states DIR`: renders the overlay offscreen to one PNG per state with `cacheDisplay`.
    static func renderStates(into directory: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = overlay.defaults

        func require(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<10000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            guard condition() else { throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(message)"]) }
        }
        func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) {
            let point = CGPoint(x: pixel.x / overlay.scale, y: overlay.view.bounds.height - pixel.y / overlay.scale)
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
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
        func open() { overlay.present(image: image, frame: frame, displayID: nil) }
        func drag(_ rect: CGRect, release: Bool) {
            mouse(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY))
            mouse(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY))
            if release { mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY)) }
        }
        func snapshot(_ name: String) throws {
            let view = overlay.view
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
            print(directory.appending(path: "\(name).png").path)
        }
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        let cart = CGRect(x: 1645, y: 384, width: 582, height: 557)

        open()
        mouse(.mouseMoved, CGPoint(x: 1200, y: 1000))
        try snapshot("area-idle")
        overlay.dismiss()

        open()
        drag(rough, release: false)
        try await waitFor("a snap preview") { overlay.snapPreview != nil }
        try snapshot("area-drag-snap")
        mouse(.leftMouseUp, CGPoint(x: rough.maxX, y: rough.maxY))
        try snapshot("area-released")
        key(0, "2", .command)
        try snapshot("area-margin")
        key(0, "3", .command)
        try snapshot("area-backdrop")
        overlay.dismiss()
        defaults.set(OutputStyle.tight.rawValue, forKey: Pref.style)

        open()
        overlay.setWindows([CGRect(x: 300, y: 300, width: 1300, height: 1000)], names: ["Form test - Browser"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        mouse(.mouseMoved, CGPoint(x: 900, y: 700))
        try snapshot("window-hover")
        overlay.dismiss()

        open()
        let rounded = CGRect(x: 1100, y: 250, width: 1000, height: 700)
        overlay.setWindows([rounded], names: ["Rounded window"], pointer: CGPoint(x: frame.minX, y: frame.maxY))
        overlay.radii[rounded] = 40
        mouse(.mouseMoved, CGPoint(x: 1600, y: 600))
        try snapshot("window-hover-rounded")
        overlay.dismiss()

        open()
        key(17, "t")
        mouse(.leftMouseDown, CGPoint(x: cart.minX, y: cart.minY))
        mouse(.leftMouseDragged, CGPoint(x: cart.maxX, y: cart.maxY))
        mouse(.leftMouseUp, CGPoint(x: cart.maxX, y: cart.maxY))
        try snapshot("text-reading")
        try await waitFor("OCR") { overlay.text.result != nil }
        try snapshot("text")
        overlay.dismiss()

        open()
        key(14, "e")
        try await overlay.elementTask?.value
        mouse(.mouseMoved, CGPoint(x: 422, y: 585))
        try snapshot("element")
        overlay.dismiss()

        open()
        key(44, "?", .shift)
        try snapshot("help")
        overlay.dismiss()

        open()
        drag(rough, release: true)
        key(37, "l")
        key(15, "r")
        mouse(.mouseMoved, CGPoint(x: 1500, y: 700))
        try snapshot("loupe-rulers")
        overlay.dismiss()

        open()
        overlay.topInset = 38
        defaults.set(true, forKey: Pref.rulers)
        defaults.set(true, forKey: Pref.loupe)
        mouse(.mouseMoved, CGPoint(x: 1200, y: 90))
        try snapshot("area-idle-notch")
        overlay.dismiss()

        let toast = Toast(png: nil, message: "Copied", detail: "1824 x 768  backdrop", file: nil, color: nil).contentView!
        let rep = toast.bitmapImageRepForCachingDisplay(in: toast.bounds)!
        toast.cacheDisplay(in: toast.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "toast.png"))
        print(directory.appending(path: "toast.png").path)

        func render(_ name: String, _ content: some View) throws {
            let renderer = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "\(name).png"))
            print(directory.appending(path: "\(name).png").path)
        }
        let firstRun = NSHostingView(rootView: FirstRunView())
        try render("first-run", FirstRunView())
        require(firstRun.fittingSize.width == 500, "the first-run window is 500 pt wide")
        try render("settings", SettingsView())

        let menu = SnugApp.makeMenu(defaults: defaults)
        let capture = menu.items[0]
        require(menu.items.map(\.title) == ["Capture", "Copy Text", "Repeat Last Area", "Open Image...", "", "Settings...", "Quit"], "menu items: \(menu.items.map(\.title))")
        require(capture.keyEquivalent == " " && capture.keyEquivalentModifierMask == [.control, .shift], "Capture shows the shortcut as a key equivalent")
        require(menu.items[5].keyEquivalent == "," && menu.items[6].keyEquivalent == "q", "Settings and Quit carry their command keys")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{21E7}Space", "the default shortcut displays as glyphs: \(Shortcut.label(from: defaults))")
        defaults.set(40, forKey: Pref.hotKeyCode)
        defaults.set(Int(NSEvent.ModifierFlags([.control, .option]).rawValue), forKey: Pref.hotKeyModifiers)
        capture.setShortcut(from: defaults)
        require(capture.keyEquivalent == "k" && capture.keyEquivalentModifierMask == [.control, .option], "a recorded letter shortcut updates the key equivalent")
        require(Shortcut.label(from: defaults) == "\u{2303}\u{2325}K", "the recorded shortcut displays from code and modifiers: \(Shortcut.label(from: defaults))")
        let hintFill = overlay.chrome.hints.layer!.backgroundColor.flatMap(NSColor.init(cgColor:))!
        require(hintFill.alphaComponent >= 0.9, "the hint strip is nearly opaque: \(hintFill.alphaComponent)")
        exit(EXIT_SUCCESS)
    }
}
