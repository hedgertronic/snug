import AppKit
import ServiceManagement
import ScreenshotCore
import SwiftUI

/// The hot key's display string and menu key equivalent, derived from the stored key code and modifiers.
enum Shortcut {
    /// Function keys F1-F12 by key code, with the `NSF1FunctionKey`-based character a menu key equivalent needs.
    static let functionKeys: [Int: (name: String, character: Int)] = [
        122: ("F1", NSF1FunctionKey), 120: ("F2", NSF2FunctionKey), 99: ("F3", NSF3FunctionKey), 118: ("F4", NSF4FunctionKey),
        96: ("F5", NSF5FunctionKey), 97: ("F6", NSF6FunctionKey), 98: ("F7", NSF7FunctionKey), 100: ("F8", NSF8FunctionKey),
        101: ("F9", NSF9FunctionKey), 109: ("F10", NSF10FunctionKey), 103: ("F11", NSF11FunctionKey), 111: ("F12", NSF12FunctionKey)
    ]

    /// US-layout key names for the other keys the recorder accepts: letters, digits, punctuation, and space.
    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "space", 50: "`"
    ]

    static func label(code: Int, modifiers: Int) -> String {
        guard code >= 0 else { return "None" }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "\u{2303}" : "") + (flags.contains(.option) ? "\u{2325}" : "")
            + (flags.contains(.shift) ? "\u{21E7}" : "") + (flags.contains(.command) ? "\u{2318}" : "") + (functionKeys[code]?.name ?? keyNames[code]!)
    }

    static func label(from defaults: UserDefaults) -> String {
        label(code: defaults.integer(forKey: Pref.hotKeyCode), modifiers: defaults.integer(forKey: Pref.hotKeyModifiers))
    }
}

/// The Settings window's toolbar tabs. The window title stays "Settings" on every tab.
@MainActor
enum SettingsTabs {
    static let width: CGFloat = 400
    /// The Appearance and Keys panes' height; both scroll what is taller, so the two tabs are the same size.
    static let tallHeight: CGFloat = 641
    static let panes: [(title: String, symbol: String, view: AnyView)] = [
        ("General", "gearshape", AnyView(GeneralPane())),
        ("Appearance", "paintpalette", AnyView(AppearancePane())),
        ("Keys", "keyboard", AnyView(KeysPane())),
        ("Agent", "sparkles", AnyView(AgentPane()))
    ]

    /// AppKit gives the window the selected tab's label as its title; this puts "Settings" back.
    private final class Controller: NSTabViewController {
        override var title: String! {
            get { "Settings" }
            set {}
        }
    }

    static func makeController() -> NSTabViewController {
        let controller = Controller()
        controller.tabStyle = .toolbar
        for pane in panes {
            let host = NSHostingController(rootView: pane.view)
            host.sizingOptions = .preferredContentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            controller.addTabViewItem(item)
        }
        return controller
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeController())
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }
}

/// A pane's content: 20 pt side insets, 14 pt between blocks.
private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.init(top: 18, leading: 20, bottom: 20, trailing: 20))
            .frame(width: SettingsTabs.width, alignment: .leading)
    }
}

/// A row's label at the leading edge and its control at the trailing edge.
private struct RowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// Rows on a rounded card, separated by hairlines. Each row is at least `rowHeight` tall with 12 pt side insets.
private struct Card<Content: View>: View {
    var rowHeight: CGFloat = 38
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    rows[index].padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    if index < rows.count - 1 { Divider() }
                }
            }
        }
        .labeledContentStyle(RowStyle())
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
    }
}

/// A row title with a smaller secondary line under it.
private func detailed(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
}

/// The app icon and name once, then shortcut, save folder, open at login, recording, the Text mode switch, and the permissions; then About the
/// developer: the headshot, name, a link to hedgertronic.com, a short bio, and the Ko-fi button.
private struct GeneralPane: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @AppStorage(Pref.saveFolder) private var saveFolder = ""
    @AppStorage(Pref.chromiumText) private var chromiumText = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Pane {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snug").font(.system(size: 28, weight: .heavy, design: .rounded))
                        Text("\(hotKeyCode < 0 ? "Set a shortcut to capture." : "Press \(Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)) to capture.")\nPress ? in the overlay for every key.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Card {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(code: hotKeyCode, modifiers: hotKeyModifiers).fixedSize()
                        // Removing both keys falls back to the registered default shortcut.
                        Button("Reset") {
                            UserDefaults.standard.removeObject(forKey: Pref.hotKeyCode)
                            UserDefaults.standard.removeObject(forKey: Pref.hotKeyModifiers)
                        }
                    }
                    LabeledContent("Save to") {
                        Button(URL(fileURLWithPath: saveFolder).lastPathComponent) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.directoryURL = URL(fileURLWithPath: saveFolder)
                            if panel.runModal() == .OK { saveFolder = panel.url!.path }
                        }
                    }
                    LabeledContent("Open at login") {
                        Toggle("Open at login", isOn: $opensAtLogin).labelsHidden().toggleStyle(.switch)
                    }
                    .onChange(of: opensAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSApp.presentError(error)
                            opensAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                }
                caption("Text mode")
                Card {
                    LabeledContent {
                        Toggle("Read text from Chromium apps", isOn: $chromiumText).labelsHidden().toggleStyle(.switch)
                    } label: {
                        detailed("Read text from Chromium apps", "Turns on the app's accessibility until it quits.")
                    }
                    .padding(.vertical, 4)
                }
                caption("Permissions")
                // macOS sends no notification when a permission changes, so the rows re-read both every second.
                Card {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        permission("Screen Recording", detail: "Required", granted: CGPreflightScreenCaptureAccess()) {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        permission("Accessibility", detail: "Recommended, highlights parts of apps", granted: AXIsProcessTrusted()) { Accessibility.requestTrust() }
                    }
                }
                caption("About the developer")
                Card {
                    // The 200 px headshot drawn at 44 pt stays sharp at 2x.
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: NSImage(data: headshotJPEG)!).resizable().interpolation(.high).frame(width: 44, height: 44).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Josh Hejka").font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                MakerButton()
                            }
                            Text("Professional pitcher and R&D analyst at Driveline Baseball. Snug is one of my side projects.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    SupportButton().frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permission(_ name: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: allow).buttonStyle(.borderedProminent)
            }
        } label: {
            detailed(name, detail)
        }
        .padding(.vertical, 4)
    }
}

/// The Ko-fi link: a sunflower and the line on a sunflower-yellow capsule, dark ink in either appearance.
private struct SupportButton: View {
    private static let ink = Color(red: 0x24 / 255, green: 0x22 / 255, blue: 0x1C / 255)

    var body: some View {
        Link(destination: URL(string: "https://ko-fi.com/hedgertronic")!) {
            HStack(spacing: 5) {
                Image(systemName: "camera.macro").font(.system(size: 11, weight: .semibold))
                Text("Buy me a bag of sunflower seeds").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Self.ink)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color(red: 1, green: 0.83, blue: 0.23)))
        }
        .buttonStyle(.plain)
        .help("Support Snug on Ko-fi")
    }
}

/// The developer's credit: the hedgertronic camera and the site's name, linking to it.
private struct MakerButton: View {
    var body: some View {
        Link(destination: URL(string: "https://hedgertronic.com/")!) {
            HStack(spacing: 5) {
                Image(nsImage: NSImage(data: makerCameraPNG)!).resizable().interpolation(.high).frame(width: 14, height: 14)
                Text("hedgertronic.com").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Visit hedgertronic.com")
    }
}

/// The overlay's appearance, the highlight (live preview, color menu, fill, fade, glow), the toast, and the frame (live preview, padding, shadow).
private struct AppearancePane: View {
    @AppStorage(Pref.overlayAppearance) private var overlayAppearance = "system"
    @AppStorage(Pref.highlightColor) private var highlightColor = ""
    @AppStorage(Pref.highlightFill) private var highlightFill = 0.1
    @AppStorage(Pref.highlightFade) private var highlightFade = 0.5
    @AppStorage(Pref.highlightGlow) private var highlightGlow = 0.2
    @AppStorage(Pref.toastPosition) private var toastPosition = "bottomCenter"
    @AppStorage(Pref.toastLifetime) private var toastLifetime = 4
    @AppStorage(Pref.framePadding) private var framePadding = 24
    @AppStorage(Pref.frameShadow) private var frameShadow = "default"
    @AppStorage(Pref.frameShadowOpacity) private var shadowOpacity = OutputFrame.windowShadow.opacity
    @AppStorage(Pref.frameShadowBlur) private var shadowBlur = OutputFrame.windowShadow.blur
    @AppStorage(Pref.frameShadowDistance) private var shadowDistance = OutputFrame.windowShadow.offset
    @AppStorage(Pref.frameShadowAngle) private var shadowAngle = 270.0
    @AppStorage(Pref.frameShadowColor) private var shadowColor = "#000000"

    private static let positions: [(tag: String, title: String, alignment: Alignment)] = [
        ("bottomCenter", "Bottom center", .bottom), ("bottomRight", "Bottom right", .bottomTrailing), ("topRight", "Top right", .topTrailing)
    ]

    var body: some View {
        ScrollView {
            Pane {
                caption("Overlay")
                Card {
                    LabeledContent("Appearance") {
                        Picker("Appearance", selection: $overlayAppearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                caption("Highlight")
                OverlayPreview(appearance: overlayAppearance, color: Highlight.color(hex: highlightColor), fill: highlightFill, fade: highlightFade, glow: highlightGlow)
                Card {
                    LabeledContent("Color") { ColorMenu(hex: $highlightColor).fixedSize() }
                    slider("Fill", value: $highlightFill, range: 0...0.3)
                    slider("Background fade", value: $highlightFade, range: 0...0.6)
                    slider("Glow", value: $highlightGlow, range: 0...1)
                }
                caption("Toast")
                Card {
                    LabeledContent("Toast duration") {
                        Picker("Toast duration", selection: $toastLifetime) {
                            ForEach(Toast.lifetimes, id: \.self) { Text($0 < 0 ? "Forever" : "\($0) s").tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Toast position")
                        HStack(spacing: 8) {
                            ForEach(Self.positions, id: \.tag) { position in
                                let selected = toastPosition == position.tag
                                Button { toastPosition = position.tag } label: {
                                    VStack(spacing: 5) {
                                        ZStack(alignment: position.alignment) {
                                            RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(red: 0.72, green: 0.77, blue: 0.82), Color(red: 0.87, green: 0.89, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : Color(white: 0.16, opacity: 0.85)).frame(width: 22, height: 9).padding(5)
                                        }
                                        .frame(height: 46)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                                        Text(position.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Color.accentColor : .secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                    caption("Frame")
                FramePreview(padding: CGFloat(framePadding), shadow: Pref.customShadow(in: .standard))
                Card {
                    VStack(spacing: 4) {
                        LabeledContent("Padding") {
                            Text(([16: "Small  ", 24: "Medium  ", 40: "Large  "][framePadding] ?? "") + "\(framePadding) pt")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding { Double(framePadding) } set: { framePadding = Int($0.rounded()) }, in: 0...64) {
                            Text("Padding")
                        } ticks: {
                            SliderTick(16)
                            SliderTick(24)
                            SliderTick(40)
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 8)
                    LabeledContent {
                        Picker("Shadow", selection: $frameShadow) {
                            Text("Default").tag("default")
                            Text("Custom").tag("custom")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        detailed("Shadow", frameShadow == "custom" ? "Every capture, windows too" : "Windows: the macOS shadow")
                    }
                    .padding(.vertical, 6)
                    if frameShadow == "custom" {
                        pointSlider("Opacity", value: Binding { shadowOpacity * 100 } set: { shadowOpacity = $0 / 100 }, range: 0...100, unit: "%")
                        pointSlider("Size", value: $shadowBlur, range: 0...100, unit: " pt")
                        pointSlider("Distance", value: $shadowDistance, range: 0...64, unit: " pt")
                        pointSlider("Angle", detail: "90\u{00B0} up, 270\u{00B0} down", value: $shadowAngle, range: 0...360, unit: "\u{00B0}")
                        LabeledContent("Color") { ColorSwatch(hex: $shadowColor).fixedSize() }
                    }
                }
            }
        }
        .frame(width: SettingsTabs.width, height: SettingsTabs.tallHeight)
    }

    /// A slider that keeps whole values, with its value and `unit`, and an optional detail line under its title.
    private func pointSlider(_ title: String, detail: String? = nil, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding { value.wrappedValue } set: { value.wrappedValue = $0.rounded() }, in: range).frame(width: 130)
                Text("\(value.wrappedValue.formatted())\(unit)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            }
        } label: {
            if let detail { detailed(title, detail) } else { Text(title) }
        }
    }

    /// A slider with its value as a percentage.
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range).frame(width: 150)
                Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/// A sample window card framed exactly as an area is: `OutputFrame.render` at 2x on `padding` points with the card shadow or `shadow`,
/// the output's transparent canvas as a checkerboard on a gray backdrop, shown at its size or scaled down to fit.
struct FramePreview: View {
    let padding: CGFloat
    let shadow: OutputFrame.Shadow?

    /// A 100 x 60 pt window at 2x: a white body under a gray title bar with the three window buttons.
    private static let card: CGImage = {
        let context = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 92, width: 200, height: 28))
        for (index, color) in [CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                               CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: 14 + index * 20, y: 100, width: 12, height: 12))
        }
        return context.makeImage()!
    }()

    var body: some View {
        let output = try! OutputFrame.render(Self.card, crop: CGRect(x: 0, y: 0, width: Self.card.width, height: Self.card.height), scale: 2, padding: padding, shadow: shadow)
        Image(decorative: output, scale: 2).resizable().scaledToFit()
            .background(Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.97)))
                for row in 0..<Int(size.height / 6) + 1 {
                    for column in 0..<Int(size.width / 6) + 1 where (row + column) % 2 == 0 {
                        context.fill(Path(CGRect(x: column * 6, y: row * 6, width: 6, height: 6)), with: .color(Color(white: 0.88)))
                    }
                }
            })
            .frame(maxWidth: CGFloat(output.width) / 2, maxHeight: CGFloat(output.height) / 2)
            .padding(10)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(white: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 0.5))
    }
}

/// The highlight color as a pop-up: the system accent, the eight macOS accents with a color dot each, then "Custom..." for the color panel.
private struct ColorMenu: NSViewRepresentable {
    @Binding var hex: String

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.pick)
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.hex = $hex
        popUp.removeAllItems()
        for preset in Highlight.presets {
            popUp.addItem(withTitle: preset.name)
            popUp.lastItem!.image = Self.dot(Highlight.color(hex: preset.hex))
            popUp.lastItem!.representedObject = preset.hex
        }
        popUp.addItem(withTitle: "Custom...")
        let selected = popUp.indexOfItem(withRepresentedObject: hex)
        if selected >= 0 {
            popUp.selectItem(at: selected)
        } else {
            popUp.lastItem!.image = Self.dot(Highlight.color(hex: hex))
            popUp.selectItem(at: popUp.numberOfItems - 1)
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            circle.stroke()
            return true
        }
    }

    final class Coordinator: ColorPanelTarget {
        @objc func pick(_ popUp: NSPopUpButton) {
            if let preset = popUp.selectedItem!.representedObject as? String {
                hex.wrappedValue = preset
                return
            }
            // Until a color is picked, the menu keeps showing the current choice.
            let current = popUp.indexOfItem(withRepresentedObject: hex.wrappedValue)
            if current >= 0 { popUp.selectItem(at: current) }
            take()
            NSColorPanel.shared.orderFront(nil)
        }
    }
}

/// The shared color panel's client: `take` makes this the panel's target and its only writer, so a color picked in the panel changes
/// the setting of whichever control opened it last (the highlight menu or the shadow swatch) and never the other's.
@MainActor
class ColorPanelTarget: NSObject {
    private static weak var owner: ColorPanelTarget?
    var hex: Binding<String>

    init(hex: Binding<String>) { self.hex = hex }

    /// Becomes the panel's owner before setting its color, so a change the previous target hears is ignored.
    func take() {
        Self.owner = self
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = Highlight.color(hex: hex.wrappedValue)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged))
    }

    @objc func colorChanged(_ panel: NSColorPanel) {
        guard Self.owner === self else { return }
        let picked = panel.color.usingColorSpace(.sRGB)!
        hex.wrappedValue = ColorFormat.hex.string(for: SRGBColor(red: picked.redComponent, green: picked.greenComponent, blue: picked.blueComponent))
    }
}

/// A color swatch button that opens the shared color panel for `hex`.
struct ColorSwatch: NSViewRepresentable {
    @Binding var hex: String

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.isBordered = false
        button.setAccessibilityLabel("Color")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.hex = $hex
        let color = Highlight.color(hex: hex)
        button.image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            let swatch = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            color.setFill()
            swatch.fill()
            NSColor.separatorColor.setStroke()
            swatch.stroke()
            return true
        }
    }

    final class Coordinator: ColorPanelTarget {
        @objc func open() {
            take()
            NSColorPanel.shared.orderFront(nil)
        }
    }
}

/// A read-only guide to the overlay keys, built from the same table as the ? sheet: the action, then its key caps.
private struct KeysPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Every overlay key, grouped like the ? sheet. Rebinding is planned.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(HelpSheet.columns, id: \.title) { column in
                    caption(column.title)
                    Card(rowHeight: 30) {
                        ForEach(column.rows, id: \.action) { row in
                            LabeledContent {
                                HStack(spacing: 4) {
                                    ForEach(Self.caps(row.keys), id: \.self) { KeyCapView(text: $0).fixedSize() }
                                }
                            } label: {
                                Text(row.action).font(.system(size: 12.5))
                            }
                        }
                    }
                }
            }
            .padding(.init(top: 10, leading: 20, bottom: 20, trailing: 20))
        }
        .frame(width: SettingsTabs.width, height: SettingsTabs.tallHeight)
    }

    /// The caps for a row's keys: alternatives split on " / ", modifier words as their symbols.
    private static func caps(_ keys: String) -> [String] {
        keys.components(separatedBy: " / ").map {
            $0.replacingOccurrences(of: "Option-", with: "\u{2325}").replacingOccurrences(of: "Cmd-", with: "\u{2318}").replacingOccurrences(of: "Shift-", with: "\u{21E7}")
        }
    }
}

/// The overlay's key cap in SwiftUI.
private struct KeyCapView: NSViewRepresentable {
    let text: String

    /// `KeyCap` reports its frame as its size, and SwiftUI resizes the frame, so the size it was built with is kept here.
    final class Coordinator { var size = CGSize.zero }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyCap {
        let cap = KeyCap(text)
        context.coordinator.size = cap.frame.size
        return cap
    }

    func updateNSView(_ cap: KeyCap, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView cap: KeyCap, context: Context) -> CGSize? { context.coordinator.size }
}

/// The overlay's chrome in the look the appearance setting picks: a frozen-screen mock with the dim, the highlight, a chip, and a top-bar
/// pill with one lit toggle. "system" shows the light look and the dark one on either side of a diagonal. The chrome is the overlay's own
/// `Pill`, `BarButton`, and `KeyCap`, each sample forced to one appearance.
struct OverlayPreview: View {
    let appearance: String
    let color: NSColor
    let fill: Double
    let fade: Double
    let glow: Double

    var body: some View {
        ZStack {
            if appearance != "dark" { Sample(dark: false, color: color, fill: fill, fade: fade, glow: glow) }
            if appearance == "dark" { Sample(dark: true, color: color, fill: fill, fade: fade, glow: glow) }
            if appearance == "system" {
                Sample(dark: true, color: color, fill: fill, fade: fade, glow: glow).mask(Diagonal())
                Diagonal(edge: true).stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .frame(height: 140)
    }

    /// The lower-right half of a rectangle, cut on the diagonal from its bottom-left to its top-right corner; `edge` is the cut alone.
    private struct Diagonal: Shape {
        var edge = false

        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                if !edge {
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.closeSubpath()
                }
            }
        }
    }

    private struct Sample: NSViewRepresentable {
        let dark: Bool
        let color: NSColor
        let fill: Double
        let fade: Double
        let glow: Double

        func makeNSView(context: Context) -> SampleView { SampleView(dark: dark) }

        func updateNSView(_ view: SampleView, context: Context) {
            Chrome.tint = color
            view.color = color
            view.fill = fill
            view.fade = fade
            view.glow = glow
        }
    }

    private final class SampleView: NSView {
        var color = NSColor.controlAccentColor { didSet { loupe.apply(); rulers.apply(); needsDisplay = true } }
        var fill = 0.0 { didSet { needsDisplay = true } }
        var fade = 0.0 { didSet { needsDisplay = true } }
        var glow = 0.0 { didSet { needsDisplay = true } }
        private let dark: Bool
        private let chip = Pill.chip()
        private let bar = Bar()
        private let loupe = BarButton("Loupe", key: "L")
        private let rulers = BarButton("Rulers", key: nil)
        private var sample: CGRect { CGRect(x: 24, y: 10, width: bounds.width - 48, height: 50) }

        init(dark: Bool) {
            self.dark = dark
            super.init(frame: .zero)
            appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            wantsLayer = true
            layer!.cornerRadius = 6
            layer!.masksToBounds = true
            layer!.borderWidth = 0.5
            layer!.borderColor = NSColor.separatorColor.cgColor
            loupe.lit = true
            bar.show([[loupe, rulers]])
            chip.show("chip") { [NSTextField("Window 640 x 400", size: 12, mono: true, color: .chromeText)] }
            addSubview(chip)
            addSubview(bar)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            chip.frame.origin = CGPoint(x: sample.minX, y: sample.maxY + 6)
            bar.frame.origin = CGPoint(x: ((bounds.width - bar.frame.width) / 2).rounded(), y: bounds.height - 8 - bar.frame.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            bounds.fill()
            (dark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.78, alpha: 1)).setFill()
            for row in 0..<2 { CGRect(x: 8, y: 12 + CGFloat(row) * 12, width: bounds.width - 16, height: 5).fill() }
            let shape = NSBezierPath(roundedRect: sample, xRadius: 10, yRadius: 10)
            let dim = NSBezierPath(rect: bounds)
            dim.append(shape)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(fade).setFill()
            dim.fill()
            color.withAlphaComponent(fill).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(min(1, 1.6 * glow))
            shadow.shadowBlurRadius = 4 + 14 * glow
            shadow.set()
            color.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let ring = NSBezierPath(roundedRect: sample.insetBy(dx: -2.25, dy: -2.25), xRadius: 12.25, yRadius: 12.25)
            ring.lineWidth = 3
            color.withAlphaComponent(0.28).setStroke()
            ring.stroke()
        }
    }
}

/// A field that records a shortcut: click, then press one with at least one of Control, Option, or Command (or a function key).
/// It shows the shortcut as key caps with a clear button that starts recording, and while recording an accent ring around a "Type shortcut"
/// placeholder. Recording that ends without a new shortcut (Esc, a click anywhere else, or the window losing key) keeps the one it had.
struct ShortcutRecorder: NSViewRepresentable {
    let code: Int
    let modifiers: Int

    func makeNSView(context: Context) -> Field { Field() }
    func updateNSView(_ field: Field, context: Context) { field.show(code: code, modifiers: modifiers, recording: false) }

    final class Field: NSView {
        static let height: CGFloat = 24
        private(set) var recording = false
        private var code = 0
        private var modifiers = 0
        private let caps = NSStackView()
        private let placeholder = NSTextField("Type shortcut", size: 12, weight: .regular, color: .secondaryLabelColor)
        private let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")!, target: nil, action: nil)
        private var clickMonitor: Any?
        private var resignKeyObserver: Any?
        override var acceptsFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer!.cornerRadius = 6
            layer!.shadowColor = NSColor.controlAccentColor.cgColor
            layer!.shadowOffset = .zero
            layer!.shadowRadius = 3
            caps.spacing = 3
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.toolTip = "Clear shortcut"
            clear.target = self
            clear.action = #selector(beginRecording)
            let row = NSStackView(views: [caps, placeholder, clear])
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 130), heightAnchor.constraint(equalToConstant: Self.height)
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The shortcut as one cap per modifier and one for the key, or the placeholder while `recording`. A negative `code` is no shortcut.
        func show(code: Int, modifiers: Int, recording: Bool) {
            self.code = code
            self.modifiers = modifiers
            self.recording = recording
            let label = Shortcut.label(code: code, modifiers: modifiers)
            let glyphs = code < 0 ? "" : String(label.prefix { "\u{2303}\u{2325}\u{21E7}\u{2318}".contains($0) })
            caps.setViews((code < 0 ? [] : glyphs.map(String.init) + [String(label.dropFirst(glyphs.count))]).map { KeyCap($0) }, in: .leading)
            caps.isHidden = recording
            placeholder.isHidden = !recording
            clear.isHidden = recording || code < 0
            layer!.borderWidth = recording ? 1.5 : 0.5
            layer!.shadowOpacity = recording ? 0.6 : 0
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer!.backgroundColor = NSColor.textBackgroundColor.cgColor
                layer!.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
                layer!.shadowColor = NSColor.controlAccentColor.cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() { show(code: code, modifiers: modifiers, recording: recording) }

        override func mouseDown(with event: NSEvent) { beginRecording() }

        @objc func beginRecording() {
            window?.makeFirstResponder(self)
            show(code: code, modifiers: modifiers, recording: true)
            // Clicking empty space in the window does not take first responder, so a click outside the field ends recording here.
            clickMonitor = clickMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.window?.makeFirstResponder(nil) }
                }
                return event
            }
            resignKeyObserver = resignKeyObserver ?? NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.window?.makeFirstResponder(nil) }
            }
        }

        override func resignFirstResponder() -> Bool {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            resignKeyObserver = nil
            show(code: code, modifiers: modifiers, recording: false)
            return super.resignFirstResponder()
        }

        /// While recording, command shortcuts reach `keyDown` instead of the menu.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard event.keyCode != 53 else { window?.makeFirstResponder(nil); return }
            let isFunctionKey = Shortcut.functionKeys[Int(event.keyCode)] != nil
            guard isFunctionKey || !modifiers.isDisjoint(with: [.control, .option, .command]) else { NSSound.beep(); return }
            guard isFunctionKey || Shortcut.keyNames[Int(event.keyCode)] != nil else { NSSound.beep(); return }
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Pref.hotKeyCode)
            defaults.set(Int(modifiers.rawValue), forKey: Pref.hotKeyModifiers)
            window?.makeFirstResponder(nil)
        }
    }
}

/// Copy for Agent: the last capture, with Clear, and the command that adds Snug's MCP server to Claude Code. Snug adds it nowhere by itself.
private struct AgentPane: View {
    @State private var captureId: String?
    private let store = HandoffStore(defaults: .standard)
    private let command = "claude mcp add snug -- " + { $0.contains(" ") ? "'\($0)'" : $0 }(Bundle.main.executablePath!) + " --mcp"

    var body: some View {
        Pane {
            Text("Cmd-Return in the overlay copies a capture for an agent, with the app, window and element it shows. Only the last capture is kept.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            Card {
                LabeledContent {
                    Button("Clear last capture") {
                        try! store.clear()
                        load()
                    }.disabled(captureId == nil)
                } label: {
                    detailed("Last agent capture", captureId ?? "None")
                }
                .padding(.vertical, 4)
            }
            caption("MCP server")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents read your captures through Snug's MCP server. To add it to Claude Code, run:")
                    HStack(spacing: 8) {
                        Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
    }

    private func load() {
        captureId = try! store.current()?.captureId
    }
}
