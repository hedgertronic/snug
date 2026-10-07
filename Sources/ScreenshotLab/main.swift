import AppKit
import CoreGraphics
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import os
import ScreenshotCore

private let pipelineSignposter = OSSignposter(subsystem: "local.smartscreenshot.lab", category: "pipeline")

@main
@MainActor
struct ScreenshotLabApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = LabApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class LabApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: LabWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = LabWindowController()
        self.controller = controller
        window = controller.window
        installMenu(for: controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.loadCommandLineImage()
    }

    private func installMenu(for controller: LabWindowController) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Smart Screenshot Lab")
        appMenu.addItem(withTitle: "Quit Smart Screenshot Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Image…", action: #selector(LabWindowController.openImagePanel), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Capture Screen", action: #selector(LabWindowController.captureScreen), keyEquivalent: "C")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.items.forEach { $0.target = controller }
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LabWindowController: NSWindowController {
    private let canvas = SelectionCanvas(frame: .zero)
    private let status = NSTextField(labelWithString: "Open an image or capture the active display")
    private let detectorPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dimensions = NSTextField(labelWithString: "")
    private var sourceImage: CGImage?
    private var session: SelectionSession?
    private var baseCandidates: [Candidate] = []
    private var report: DetectionReport?
    private var pendingReport: DetectionReport?
    private var activeAnalysis = UUID()
    private var activeSnapAnalysis = UUID()
    private var snapTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var manualRoughBounds: CGRect?
    private var snapAnalyzedBounds: CGRect?
    private var snapSuggestions: [SnapSuggestion] = []
    private var snapChoiceIndex = -1
    private var currentDetector: DetectorKind = .geometry
    private var currentURL: URL?
    private var overlayWindow: NSWindow?
    private var overlayCanvas: SelectionCanvas?
    private var labSnapshot: LabSnapshot?
    private var exitsAfterPreview = false

    private struct LabSnapshot {
        let sourceImage: CGImage?
        let session: SelectionSession?
        let report: DetectionReport?
        let pendingReport: DetectionReport?
        let currentURL: URL?
        let baseCandidates: [Candidate]
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Smart Screenshot Lab"
        window.minSize = NSSize(width: 700, height: 520)
        window.acceptsMouseMovedEvents = true
        window.center()
        super.init(window: window)
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { nil }

    func loadCommandLineImage() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--detector"), arguments.indices.contains(index + 1) {
            currentDetector = DetectorKind(rawValue: arguments[index + 1]) ?? .geometry
            detectorPicker.selectItem(withTitle: currentDetector == .geometry ? "Geometry" : "Apple Vision")
        }
        if let index = arguments.firstIndex(of: "--image"), arguments.indices.contains(index + 1) {
            openImage(at: URL(fileURLWithPath: arguments[index + 1]))
        } else if let demoURL = Bundle.main.url(forResource: "Demo", withExtension: "png") {
            openImage(at: demoURL)
        }
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
            let outputURL = URL(fileURLWithPath: arguments[index + 1])
            exitsAfterPreview = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.renderPreview(to: outputURL) }
        }
        if arguments.contains("--verify-snap-ui") {
            Task { [weak self] in await self?.verifySnapUI() }
        }
    }

    private func buildInterface(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let openButton = NSButton(title: "Open Image", target: self, action: #selector(openImagePanel))
        openButton.bezelStyle = .rounded
        let captureButton = NSButton(title: "Capture Screen", target: self, action: #selector(captureScreen))
        captureButton.bezelStyle = .rounded
        detectorPicker.addItems(withTitles: ["Geometry", "Apple Vision"])
        detectorPicker.target = self
        detectorPicker.action = #selector(detectorChanged)
        detectorPicker.selectItem(withTitle: "Geometry")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let toolbar = NSStackView(views: [openButton, captureButton, detectorPicker, status])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let canvasContainer = NSView()
        canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        canvasContainer.wantsLayer = true
        canvasContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        canvas.translatesAutoresizingMaskIntoConstraints = false
        configure(canvas)
        canvasContainer.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor)
        ])

        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [hintLabel(), dimensions])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(canvasContainer)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            canvasContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            canvasContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            canvasContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            canvasContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 22)
        ])
        canvasContainer.layer?.cornerRadius = 8
        canvasContainer.layer?.masksToBounds = true
    }

    private func hintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Hover · drag to snap · ⌥ drag exact · Tab snap choices · ↑ / ↓ resize · Return copy · ⌘S save · Esc clear")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(at: url)
    }

    private func openImage(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            showError("Could not open that image.")
            return
        }
        currentURL = url
        installImage(image)
    }

    private func configure(_ targetCanvas: SelectionCanvas) {
        targetCanvas.onHover = { [weak self] point in self?.hover(at: point) }
        targetCanvas.onBeginInteraction = { [weak self] in self?.lockSelectionForInteraction() }
        targetCanvas.onDragStart = { [weak self] in self?.invalidateSnap(clearAlternatives: true) }
        targetCanvas.onManual = { [weak self] rect, ended, bypassSnap in
            self?.setManual(rect, ended: ended, bypassSnap: bypassSnap)
        }
        targetCanvas.onCommit = { [weak self] in self?.copySelection() }
        targetCanvas.onSave = { [weak self] in self?.saveSelection() }
        targetCanvas.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    }

    private func installImage(_ image: CGImage, candidates: [Candidate] = [], anchor: CGPoint? = nil) {
        detectionTask?.cancel()
        detectionTask = nil
        invalidateSnap(clearAlternatives: true)
        sourceImage = image
        baseCandidates = candidates
        report = nil
        pendingReport = nil
        session = SelectionSession(candidates: candidates, extent: CGRect(x: 0, y: 0, width: image.width, height: image.height), anchor: anchor ?? CGPoint(x: image.width / 2, y: image.height / 2))
        canvas.image = image
        canvas.session = session
        canvas.needsDisplay = true
        canvas.window?.makeFirstResponder(canvas)
        overlayCanvas?.image = image
        overlayCanvas?.session = session
        overlayCanvas?.needsDisplay = true
        runDetection()
    }

    @objc private func detectorChanged() {
        detectionTask?.cancel()
        detectionTask = nil
        invalidateSnap(clearAlternatives: true)
        currentDetector = detectorPicker.indexOfSelectedItem == 1 ? .vision : .geometry
        if sourceImage != nil { runDetection() }
        window?.makeFirstResponder(canvas)
    }

    private func runDetection() {
        guard let image = sourceImage else { return }
        report = nil
        pendingReport = nil
        let token = UUID()
        activeAnalysis = token
        let detector = currentDetector
        status.stringValue = "Analyzing with \(detector == .geometry ? "Geometry" : "Apple Vision")…"
        detectionTask = Task { [weak self] in
            do {
                let analysis = Task.detached(priority: .userInitiated) {
                    try await Detection.run(detector, image: image)
                }
                let result = try await withTaskCancellationHandler {
                    try await analysis.value
                } onCancel: {
                    analysis.cancel()
                }
                guard let self, self.activeAnalysis == token, self.sourceImage === image else { return }
                self.report = result
                if self.session?.isLocked == true {
                    self.pendingReport = result
                    self.status.stringValue = "\(result.candidates.count) regions · \(result.elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms · cached until unlock"
                } else {
                    self.session = SelectionSession(candidates: self.baseCandidates + result.candidates, extent: CGRect(x: 0, y: 0, width: image.width, height: image.height), anchor: self.session?.anchor ?? CGPoint(x: image.width / 2, y: image.height / 2))
                    self.canvas.session = self.session
                    self.canvas.needsDisplay = true
                    self.overlayCanvas?.session = self.session
                    self.overlayCanvas?.needsDisplay = true
                    self.status.stringValue = "\(result.candidates.count) regions · \(result.elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
                }
                self.refreshDimensions()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeAnalysis == token else { return }
                self.report = nil
                self.status.stringValue = "Analysis failed · manual crop and full image remain available"
                self.showError("Detection failed: \(error.localizedDescription)")
            }
        }
    }

    private func hover(at point: CGPoint) {
        guard var session else { return }
        session.hover(at: point)
        self.session = session
        canvas.session = session
        overlayCanvas?.session = session
        canvas.needsDisplay = true
        overlayCanvas?.needsDisplay = true
        refreshDimensions()
    }

    private func lockSelectionForInteraction() {
        guard var session, !session.isLocked else { return }
        session.toggleLock()
        self.session = session
        canvas.session = session
        overlayCanvas?.session = session
        canvas.needsDisplay = true
        overlayCanvas?.needsDisplay = true
        refreshDimensions()
    }

    private func setManual(_ rectangle: CGRect, ended: Bool, bypassSnap: Bool) {
        guard var session else { return }
        session.setManual(rectangle)
        self.session = session
        manualRoughBounds = rectangle
        if bypassSnap {
            invalidateSnap(clearAlternatives: true)
            manualRoughBounds = rectangle
        } else if ended {
            snapTask?.cancel()
            snapTask = nil
            activeSnapAnalysis = UUID()
            if !snapSuggestions.isEmpty, let snapAnalyzedBounds, previewMatches(snapAnalyzedBounds, rectangle) {
                snapChoiceIndex = 1
                session.setManual(snapSuggestions[0].bounds)
                self.session = session
            } else {
                snapSuggestions = []
                snapAnalyzedBounds = nil
                snapChoiceIndex = 0
            }
        } else {
            snapChoiceIndex = 0
            scheduleSnapAnalysis(for: rectangle)
        }
        canvas.snapRoughBounds = rectangle
        canvas.snapPreviewBounds = !ended && !bypassSnap && !snapSuggestions.isEmpty ? snapSuggestions[0].bounds : nil
        overlayCanvas?.snapRoughBounds = rectangle
        overlayCanvas?.snapPreviewBounds = canvas.snapPreviewBounds
        canvas.session = self.session
        overlayCanvas?.session = self.session
        canvas.needsDisplay = true
        overlayCanvas?.needsDisplay = true
        refreshDimensions()
        refreshSnapStatus(isDragging: !ended && !bypassSnap)
    }

    private func analyzeManualBounds(_ bounds: CGRect, keyEvent: NSEvent) async {
        guard let image = sourceImage else { return }
        snapTask?.cancel()
        let analysis = Task.detached(priority: .userInitiated) {
            try await SmartSnap().suggest(in: image, roughBounds: bounds)
        }
        do {
            let suggestions = try await withTaskCancellationHandler {
                try await analysis.value
            } onCancel: {
                analysis.cancel()
            }
            guard sourceImage === image, session?.selected?.kind == .manual,
                  manualRoughBounds == bounds else { return }
            snapSuggestions = suggestions
            snapAnalyzedBounds = bounds
            snapChoiceIndex = 0
            if !suggestions.isEmpty { _ = handleKey(keyEvent) }
        } catch is CancellationError {
            return
        } catch {
            showError("Snap analysis failed: \(error.localizedDescription)")
        }
    }

    private func scheduleSnapAnalysis(for rectangle: CGRect) {
        snapTask?.cancel()
        let token = UUID()
        activeSnapAnalysis = token
        snapSuggestions = []
        snapAnalyzedBounds = nil
        canvas.snapPreviewBounds = nil
        overlayCanvas?.snapPreviewBounds = nil
        guard let image = sourceImage else { return }
        snapTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                let snapInterval = pipelineSignposter.beginInterval("Snap")
                let analysis = Task.detached(priority: .userInitiated) {
                    try await SmartSnap().suggest(in: image, roughBounds: rectangle)
                }
                let suggestions = try await withTaskCancellationHandler {
                    try await analysis.value
                } onCancel: {
                    analysis.cancel()
                }
                pipelineSignposter.endInterval("Snap", snapInterval)
                guard !Task.isCancelled, let self,
                      self.activeSnapAnalysis == token,
                      self.sourceImage === image,
                      self.manualRoughBounds == rectangle else { return }
                self.snapSuggestions = suggestions
                self.snapAnalyzedBounds = rectangle
                self.canvas.snapPreviewBounds = suggestions.first?.bounds
                self.overlayCanvas?.snapPreviewBounds = suggestions.first?.bounds
                self.canvas.needsDisplay = true
                self.overlayCanvas?.needsDisplay = true
                self.refreshSnapStatus(isDragging: true)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeSnapAnalysis == token else { return }
                self.snapSuggestions = []
                self.canvas.snapPreviewBounds = nil
                self.overlayCanvas?.snapPreviewBounds = nil
                self.canvas.needsDisplay = true
                self.overlayCanvas?.needsDisplay = true
            }
        }
    }

    private func invalidateSnap(clearAlternatives: Bool) {
        snapTask?.cancel()
        snapTask = nil
        activeSnapAnalysis = UUID()
        if clearAlternatives {
            snapSuggestions = []
            snapAnalyzedBounds = nil
            manualRoughBounds = nil
            snapChoiceIndex = 0
            canvas.snapRoughBounds = nil
            canvas.snapPreviewBounds = nil
            overlayCanvas?.snapRoughBounds = nil
            overlayCanvas?.snapPreviewBounds = nil
        }
        canvas.needsDisplay = true
        overlayCanvas?.needsDisplay = true
    }

    private func previewMatches(_ preview: CGRect, _ released: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(preview.minX - released.minX) <= tolerance
            && abs(preview.minY - released.minY) <= tolerance
            && abs(preview.width - released.width) <= tolerance
            && abs(preview.height - released.height) <= tolerance
    }

    private func refreshSnapStatus(isDragging: Bool) {
        guard !snapSuggestions.isEmpty else {
            if isDragging {
                status.stringValue = snapAnalyzedBounds == nil ? "Snap preview pending…" : "No nearby snap · release for manual crop"
            } else {
                status.stringValue = "Manual crop"
            }
            return
        }
        let suggestion = snapSuggestions[isDragging ? 0 : min(max(snapChoiceIndex - 1, 0), snapSuggestions.count - 1)]
        if !isDragging, snapChoiceIndex == 0 {
            status.stringValue = "Exact drag · Tab snap choices"
        } else {
            status.stringValue = "\(isDragging ? "Snap preview" : "Snap \(snapChoiceIndex)/\(snapSuggestions.count)") · \(suggestion.reason)"
        }
    }

    private func verifySnapUI() async {
        guard let image = sourceImage, session != nil else {
            failSnapUIVerification("No source image is loaded.")
        }
        let rough = CGRect(x: 350, y: 458, width: 580, height: 64)
        guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rough) else {
            failSnapUIVerification("The loaded image is too small for the verification crop.")
        }

        setManual(rough, ended: false, bypassSnap: false)
        guard await waitForSnapPreview() else {
            failSnapUIVerification("Snap analysis produced no preview for the verification crop.")
        }
        let preview = snapSuggestions[0].bounds
        setManual(rough, ended: true, bypassSnap: false)
        guard self.session?.selected?.bounds == preview else {
            failSnapUIVerification("Releasing a previewed crop did not accept the snap.")
        }

        let shiftTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window?.windowNumber ?? 0, context: nil,
                                        characters: "\t", charactersIgnoringModifiers: "\t",
                                        isARepeat: false, keyCode: 48)
        guard let shiftTab, handleKey(shiftTab), self.session?.selected?.bounds == rough else {
            failSnapUIVerification("Shift-Tab did not restore the original manual crop.")
        }

        setManual(rough, ended: false, bypassSnap: true)
        setManual(rough, ended: true, bypassSnap: true)
        guard self.session?.selected?.bounds == rough, snapSuggestions.isEmpty else {
            failSnapUIVerification("Option bypass did not keep the exact manual crop.")
        }

        setManual(rough, ended: false, bypassSnap: false)
        try? await Task.sleep(for: .milliseconds(15))
        setManual(rough, ended: true, bypassSnap: false)
        try? await Task.sleep(for: .milliseconds(350))
        guard self.session?.selected?.bounds == rough else {
            failSnapUIVerification("A cancelled pre-release analysis changed the selected crop later.")
        }

        setManual(rough, ended: false, bypassSnap: false)
        guard await waitForSnapPreview() else {
            failSnapUIVerification("Snap analysis produced no preview for changed-release verification.")
        }
        let changedRelease = rough.offsetBy(dx: 3, dy: 0)
        setManual(changedRelease, ended: true, bypassSnap: false)
        guard self.session?.selected?.bounds == changedRelease, snapSuggestions.isEmpty,
              canvas.snapPreviewBounds == nil else {
            failSnapUIVerification("A preview for different drag bounds was accepted on release.")
        }

        let quickDrag = rough.offsetBy(dx: 11, dy: -7)
        setManual(quickDrag, ended: false, bypassSnap: false)
        setManual(quickDrag, ended: true, bypassSnap: false)
        guard let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window?.windowNumber ?? 0, context: nil,
                                         characters: "\t", charactersIgnoringModifiers: "\t",
                                         isARepeat: false, keyCode: 48), handleKey(tab) else {
            failSnapUIVerification("Tab did not run for a quick manual drag.")
        }
        for _ in 0..<400 where snapAnalyzedBounds != quickDrag { try? await Task.sleep(for: .milliseconds(20)) }
        guard self.session?.selected?.kind == .manual,
              self.session?.selected?.bounds == quickDrag || snapSuggestions.contains(where: { $0.bounds == self.session?.selected?.bounds }),
              !(baseCandidates + (report?.candidates ?? [])).contains(where: { $0.bounds == self.session?.selected?.bounds }) else {
            failSnapUIVerification("Tab replaced a quick manual drag with a hover candidate.")
        }

        print("Snap UI verification passed: preview, release, Shift-Tab, Option bypass, cancellation, changed release, quick-drag Tab")
        Darwin.exit(EXIT_SUCCESS)
    }

    private func waitForSnapPreview() async -> Bool {
        for _ in 0..<400 {
            if canvas.snapPreviewBounds != nil { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func failSnapUIVerification(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Snap UI verification failed: \(message)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard var session else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" { saveSelection(); return true }
        if event.keyCode == 53 { clearSelection(); return true }
        if event.keyCode == 36 { copySelection(); return true }
        if event.keyCode == 48 {
            if session.selected?.kind == .manual, let roughBounds = manualRoughBounds, !snapSuggestions.isEmpty {
                let choices = snapSuggestions.count + 1
                snapChoiceIndex = (snapChoiceIndex + (modifiers.contains(.shift) ? -1 : 1) + choices) % choices
                let bounds = snapChoiceIndex == 0 ? roughBounds : snapSuggestions[snapChoiceIndex - 1].bounds
                session.setManual(bounds)
                refreshSnapStatus(isDragging: false)
            } else if session.selected?.kind == .manual {
                guard let roughBounds = manualRoughBounds else { return true }
                Task { await analyzeManualBounds(roughBounds, keyEvent: event) }
                return true
            } else {
                session.cycle(backward: modifiers.contains(.shift))
            }
        } else if event.keyCode == 126 {
            if session.selected?.kind == .manual { invalidateSnap(clearAlternatives: true); session.moveManual(dx: 0, dy: modifiers.contains(.shift) ? -10 : -1) }
            else { session.expand() }
        } else if event.keyCode == 125 {
            if session.selected?.kind == .manual { invalidateSnap(clearAlternatives: true); session.moveManual(dx: 0, dy: modifiers.contains(.shift) ? 10 : 1) }
            else { session.shrink() }
        } else if event.keyCode == 123, session.selected?.kind == .manual {
            invalidateSnap(clearAlternatives: true)
            session.moveManual(dx: modifiers.contains(.shift) ? -10 : -1, dy: 0)
        } else if event.keyCode == 124, session.selected?.kind == .manual {
            invalidateSnap(clearAlternatives: true)
            session.moveManual(dx: modifiers.contains(.shift) ? 10 : 1, dy: 0)
        } else if event.keyCode == 49 {
            session.toggleLock()
            if !session.isLocked {
                invalidateSnap(clearAlternatives: true)
                let candidates = baseCandidates + (pendingReport?.candidates ?? report?.candidates ?? [])
                session = SelectionSession(candidates: candidates, extent: session.extent, anchor: session.anchor)
                pendingReport = nil
                refreshAnalysisStatus()
            }
        } else if event.charactersIgnoringModifiers?.lowercased() == "f" {
            invalidateSnap(clearAlternatives: true)
            session.select(kind: .display)
        } else if event.charactersIgnoringModifiers?.lowercased() == "w" {
            invalidateSnap(clearAlternatives: true)
            session.select(kind: .window)
        } else {
            return false
        }
        self.session = session
        canvas.session = session
        overlayCanvas?.session = session
        canvas.needsDisplay = true
        overlayCanvas?.needsDisplay = true
        refreshDimensions()
        return true
    }

    private func refreshDimensions() {
        guard let candidate = session?.selected else { dimensions.stringValue = ""; return }
        dimensions.stringValue = "\(Int(candidate.bounds.width)) × \(Int(candidate.bounds.height)) px · \(candidate.label)\(session?.isLocked == true ? " · Locked" : "")"
    }

    private func refreshAnalysisStatus() {
        guard let report else { return }
        status.stringValue = "\(report.candidates.count) regions · \(report.elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private func copySelection() {
        guard let image = selectedCrop() else { return }
        let encodeInterval = pipelineSignposter.beginInterval("Encode")
        let data: Data
        do {
            data = try pngData(for: image)
        } catch {
            pipelineSignposter.endInterval("Encode", encodeInterval)
            showError("Could not copy selection: \(error.localizedDescription)")
            return
        }
        pipelineSignposter.endInterval("Encode", encodeInterval)
        do {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(data, forType: .png)
            NSPasteboard.general.clearContents()
            let pasteboardInterval = pipelineSignposter.beginInterval("Pasteboard")
            guard NSPasteboard.general.writeObjects([pasteboardItem]) else {
                pipelineSignposter.endInterval("Pasteboard", pasteboardInterval)
                throw CocoaError(.fileWriteUnknown)
            }
            pipelineSignposter.endInterval("Pasteboard", pasteboardInterval)
            status.stringValue = "Copied \(image.width) × \(image.height) px to clipboard"
            if overlayWindow != nil { finishCaptureOverlay(message: "Capture copied · lab image restored") }
        } catch {
            showError("Could not copy selection: \(error.localizedDescription)")
        }
    }

    private func saveSelection() {
        guard let image = selectedCrop() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot.png"
        panel.canCreateDirectories = true
        let overlayLevel = overlayWindow?.level
        overlayWindow?.level = .normal
        let response = panel.runModal()
        if let overlayWindow, let overlayLevel {
            overlayWindow.level = overlayLevel
            overlayWindow.makeKeyAndOrderFront(nil)
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try pngData(for: image).write(to: url, options: .atomic)
            status.stringValue = "Saved \(url.lastPathComponent)"
            if overlayWindow != nil { finishCaptureOverlay(message: "Capture saved · lab image restored") }
        } catch { showError("Could not save PNG: \(error.localizedDescription)") }
    }

    private func selectedCrop() -> CGImage? {
        guard let image = sourceImage, let bounds = session?.selected?.bounds else { return nil }
        let rect = bounds.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: rect)
    }

    private func renderPreview(to url: URL) {
        defer {
            if exitsAfterPreview { Darwin.exit(EXIT_SUCCESS) }
        }
        canvas.layoutSubtreeIfNeeded()
        let scale = window?.backingScaleFactor ?? 1
        let width = max(1, Int((canvas.bounds.width * scale).rounded()))
        let height = max(1, Int((canvas.bounds.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0) else {
            showError("Could not render the preview image.")
            return
        }
        representation.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            showError("Could not encode the preview image.")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            status.stringValue = "Rendered preview to \(url.lastPathComponent)"
        } catch { showError("Could not save preview: \(error.localizedDescription)") }
    }

    private func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    @objc func captureScreen() {
        let captureInterval = pipelineSignposter.beginInterval("Capture")
        status.stringValue = "Capturing active display…"
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            showError("Could not identify the display under the pointer.")
            return
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let screenFrame = screen.frame
        Task {
            do {
                let capture = try await Self.captureDisplay(displayID: displayID, pointer: pointer, screenFrame: screenFrame)
                pipelineSignposter.endInterval("Capture", captureInterval)
                labSnapshot = LabSnapshot(sourceImage: sourceImage, session: session, report: report, pendingReport: pendingReport, currentURL: currentURL, baseCandidates: baseCandidates)
                installImage(capture.image, candidates: capture.candidates, anchor: capture.anchor)
                currentURL = nil
                showCaptureOverlay(on: screen, image: capture.image)
                status.stringValue = "Display captured · analyzing…"
            } catch {
                pipelineSignposter.endInterval("Capture", captureInterval)
                status.stringValue = "Screen capture unavailable"
                showError("Screen capture could not start. Allow Screen Recording for Smart Screenshot Lab in System Settings → Privacy & Security, then try again. \(error.localizedDescription)")
            }
        }
    }

    private static func captureDisplay(displayID: CGDirectDisplayID, pointer: CGPoint, screenFrame: CGRect) async throws -> (image: CGImage, candidates: [Candidate], anchor: CGPoint) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let labWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: labWindows)
        let configuration = SCStreamConfiguration()
        let info = SCShareableContent.info(for: filter)
        configuration.width = Int(display.frame.width * CGFloat(info.pointPixelScale))
        configuration.height = Int(display.frame.height * CGFloat(info.pointPixelScale))
        configuration.showsCursor = false
        let captureInterval = pipelineSignposter.beginInterval("Capture Image")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        pipelineSignposter.endInterval("Capture Image", captureInterval)
        let xScale = CGFloat(image.width) / display.frame.width
        let yScale = CGFloat(image.height) / display.frame.height
        let frontToBack = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        var zOrder: [CGWindowID: Int] = [:]
        for (index, item) in frontToBack.enumerated() {
            if let number = item[kCGWindowNumber as String] as? NSNumber {
                zOrder[CGWindowID(number.uint32Value)] = index
            }
        }
        let windows = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
            .sorted {
                let left = zOrder[$0.windowID] ?? Int.max
                let right = zOrder[$1.windowID] ?? Int.max
                return left == right ? $0.windowID < $1.windowID : left < right
            }
            .compactMap { window -> Candidate? in
                let frame = window.frame.intersection(display.frame)
                guard !frame.isNull, frame.width >= 8, frame.height >= 8 else { return nil }
                let pixelRect = CGRect(
                    x: (frame.minX - display.frame.minX) * xScale,
                    y: (frame.minY - display.frame.minY) * yScale,
                    width: frame.width * xScale,
                    height: frame.height * yScale
                ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard !pixelRect.isNull, pixelRect.width >= 8, pixelRect.height >= 8 else { return nil }
                return Candidate(id: "window-\(window.windowID)", label: "Window", bounds: pixelRect, score: 2, kind: .window)
            }
        let anchor = CGPoint(
            x: min(max((pointer.x - screenFrame.minX) * CGFloat(image.width) / screenFrame.width, 0), CGFloat(image.width)),
            y: min(max((screenFrame.maxY - pointer.y) * CGFloat(image.height) / screenFrame.height, 0), CGFloat(image.height))
        )
        return (image, windows, anchor)
    }

    private func showCaptureOverlay(on screen: NSScreen, image: CGImage) {
        let overlayInterval = pipelineSignposter.beginInterval("Overlay Shown")
        let overlay = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        overlay.level = .screenSaver
        overlay.acceptsMouseMovedEvents = true
        overlay.isOpaque = true
        overlay.backgroundColor = .black
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.setFrame(screen.frame, display: false)

        let overlayCanvas = SelectionCanvas(frame: overlay.contentView?.bounds ?? screen.frame)
        overlayCanvas.autoresizingMask = [.width, .height]
        overlayCanvas.image = image
        overlayCanvas.session = session
        overlayCanvas.showsOverlayHints = true
        configure(overlayCanvas)
        overlay.contentView = overlayCanvas
        self.overlayCanvas = overlayCanvas
        self.overlayWindow = overlay
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
        overlay.makeFirstResponder(overlayCanvas)
        overlayCanvas.needsDisplay = true
        pipelineSignposter.endInterval("Overlay Shown", overlayInterval)
    }

    private func finishCaptureOverlay(message: String) {
        detectionTask?.cancel()
        detectionTask = nil
        invalidateSnap(clearAlternatives: true)
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
        overlayCanvas = nil
        guard let snapshot = labSnapshot else { return }
        sourceImage = snapshot.sourceImage
        session = snapshot.session
        report = snapshot.report
        pendingReport = snapshot.pendingReport
        currentURL = snapshot.currentURL
        baseCandidates = snapshot.baseCandidates
        labSnapshot = nil
        activeAnalysis = UUID()
        canvas.image = sourceImage
        canvas.session = session
        canvas.needsDisplay = true
        refreshDimensions()
        if sourceImage != nil, report == nil { runDetection() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        status.stringValue = message
    }

    private func clearSelection() {
        detectionTask?.cancel()
        detectionTask = nil
        if overlayWindow != nil {
            finishCaptureOverlay(message: "Capture cancelled · clipboard unchanged")
            return
        }
        if sourceImage == nil { return }
        invalidateSnap(clearAlternatives: true)
        sourceImage = nil
        baseCandidates = []
        report = nil
        pendingReport = nil
        session = nil
        canvas.image = nil
        canvas.session = nil
        canvas.needsDisplay = true
        status.stringValue = "Selection cleared · clipboard unchanged"
        dimensions.stringValue = ""
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Smart Screenshot Lab"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: overlayWindow ?? window!)
    }
}

@MainActor
final class SelectionCanvas: NSView {
    var image: CGImage?
    var session: SelectionSession?
    var snapRoughBounds: CGRect?
    var snapPreviewBounds: CGRect?
    var onHover: ((CGPoint) -> Void)?
    var onBeginInteraction: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onManual: ((CGRect, Bool, Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onSave: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var showsOverlayHints = false
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var bypassSnapForDrag = false
    private var didStartManualDrag = false
    private var tracking: NSTrackingArea?
    private var didSignpostFirstDraw = false

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseMoved(with event: NSEvent) {
        guard dragStart == nil else { return }
        if let point = sourcePoint(from: convert(event.locationInWindow, from: nil)) { onHover?(point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onBeginInteraction?()
        bypassSnapForDrag = event.modifierFlags.contains(.option)
        didStartManualDrag = false
        let point = convert(event.locationInWindow, from: nil)
        guard sourcePoint(from: point) != nil else { return }
        dragStart = point
        dragCurrent = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        if let start = dragStart, let current = dragCurrent,
           hypot(current.x - start.x, current.y - start.y) > 4,
           let source = dragRect() {
            bypassSnapForDrag = bypassSnapForDrag || event.modifierFlags.contains(.option)
            if !didStartManualDrag {
                didStartManualDrag = true
                onDragStart?()
            }
            onManual?(source, false, bypassSnapForDrag)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        if let start = dragStart, let current = dragCurrent,
           hypot(current.x - start.x, current.y - start.y) <= 4 {
            onCommit?()
        } else if let source = dragRect() {
            if !didStartManualDrag { onDragStart?() }
            bypassSnapForDrag = bypassSnapForDrag || event.modifierFlags.contains(.option)
            onManual?(source, true, bypassSnapForDrag)
        }
        dragStart = nil
        dragCurrent = nil
        bypassSnapForDrag = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let drawInterval = didSignpostFirstDraw ? nil : pipelineSignposter.beginInterval("First Draw")
        if !didSignpostFirstDraw {
            didSignpostFirstDraw = true
        }
        defer { if let drawInterval { pipelineSignposter.endInterval("First Draw", drawInterval) } }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let image else {
            let message = "Open an image to compare region detection"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor]
            let size = message.size(withAttributes: attributes)
            (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        let destination = imageRect(for: image)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: destination)
        context.restoreGState()

        guard let selected = session?.selected else { return }
        let selection = viewRect(for: selected.bounds, image: image, destination: destination)
        context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        let dimmingPath = CGMutablePath()
        dimmingPath.addRect(bounds)
        dimmingPath.addRect(selection)
        context.addPath(dimmingPath)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(selection.insetBy(dx: 1, dy: 1))
        if let snapRoughBounds {
            let rough = viewRect(for: snapRoughBounds, image: image, destination: destination).insetBy(dx: 2, dy: 2)
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.25)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rough)
            context.setLineDash(phase: 0, lengths: [])
        }
        if let snapPreviewBounds {
            let preview = viewRect(for: snapPreviewBounds, image: image, destination: destination).insetBy(dx: 1, dy: 1)
            context.setStrokeColor(NSColor.systemTeal.cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [7, 3])
            context.stroke(preview)
            context.setLineDash(phase: 0, lengths: [])
        }
        if let dragStart, let dragCurrent {
            let dragRect = CGRect(x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y), width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
            context.setStrokeColor(NSColor.systemYellow.cgColor)
            context.setLineWidth(1.5)
            context.stroke(dragRect)
        }
        if showsOverlayHints { drawOverlayHints(in: context) }
    }

    private func drawOverlayHints(in context: CGContext) {
        let selected = session?.selected
        let hintText = "Drag to snap   ⌥ drag exact   Tab snap choices   ↑ / ↓ resize   Return copy   ⌘S save   Esc cancel"
        let dimensionText = selected.map { "\(Int($0.bounds.width)) × \(Int($0.bounds.height)) px · \($0.label)\(session?.isLocked == true ? " · Locked" : "")" } ?? ""
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let dimensionAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.78)]
        let hintSize = hintText.size(withAttributes: hintAttributes)
        let dimensionSize = dimensionText.size(withAttributes: dimensionAttributes)
        let width = min(bounds.width - 48, max(hintSize.width, dimensionSize.width) + 32)
        let height: CGFloat = 54
        let plate = CGRect(x: (bounds.width - width) / 2, y: 22, width: width, height: height)
        let path = CGPath(roundedRect: plate, cornerWidth: 9, cornerHeight: 9, transform: nil)
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.88).cgColor)
        context.addPath(path)
        context.fillPath()
        (hintText as NSString).draw(at: CGPoint(x: plate.minX + 16, y: plate.minY + 29), withAttributes: hintAttributes)
        (dimensionText as NSString).draw(at: CGPoint(x: plate.minX + 16, y: plate.minY + 9), withAttributes: dimensionAttributes)
    }

    private func imageRect(for image: CGImage) -> CGRect {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func sourcePoint(from point: CGPoint) -> CGPoint? {
        guard let image else { return nil }
        let destination = imageRect(for: image)
        guard destination.contains(point) else { return nil }
        return CGPoint(x: (point.x - destination.minX) / destination.width * CGFloat(image.width), y: (destination.maxY - point.y) / destination.height * CGFloat(image.height))
    }

    private func dragRect() -> CGRect? {
        guard let image, let dragStart, let dragCurrent else { return nil }
        let a = sourcePoint(from: dragStart) ?? sourceClamped(from: dragStart, image: image)
        let b = sourcePoint(from: dragCurrent) ?? sourceClamped(from: dragCurrent, image: image)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func sourceClamped(from point: CGPoint, image: CGImage) -> CGPoint {
        let destination = imageRect(for: image)
        let x = min(max(point.x, destination.minX), destination.maxX)
        let y = min(max(point.y, destination.minY), destination.maxY)
        return CGPoint(x: (x - destination.minX) / destination.width * CGFloat(image.width), y: (destination.maxY - y) / destination.height * CGFloat(image.height))
    }

    private func viewRect(for source: CGRect, image: CGImage, destination: CGRect) -> CGRect {
        CGRect(x: destination.minX + source.minX / CGFloat(image.width) * destination.width,
               y: destination.maxY - source.maxY / CGFloat(image.height) * destination.height,
               width: source.width / CGFloat(image.width) * destination.width,
               height: source.height / CGFloat(image.height) * destination.height)
    }
}
