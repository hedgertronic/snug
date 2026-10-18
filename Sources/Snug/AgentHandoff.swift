import AppKit
import ScreenshotCore

extension NSPasteboard.PasteboardType {
    /// The manifest JSON on a Copy for Agent clipboard item. A type is a UTI, which allows no "+".
    static let snugCapture = NSPasteboard.PasteboardType("local.snug.capture-json")
}

/// Copy for Agent (Cmd-Return, the strip's Agent button).
extension OverlayController {
    /// The last Copy for Agent toast's message and detail; debug runs, which suppress toasts, read it here.
    static var lastAgentToast: (message: String, detail: String)?

    /// Copies the selection, or the hovered target, for an agent. The crop is the frozen pixels at full resolution with no Frame and
    /// no rounded corners, so its pixels map one-to-one to the screen. It is written with its manifest as a bundle in the agent folder,
    /// then copied as one clipboard item: the PNG (the manifest in its text chunk), the reference line, and the manifest.
    /// The target's Accessibility data is what the hover read for this rectangle; without it (a drawn area, a candidate from geometry),
    /// one hit test at the crop's center, only on a live capture outside debug runs. The source is the window holding the crop.
    func copyForAgent() {
        let hovered = selection == nil ? session?.selected : nil
        guard let image, let rect = selection?.rect ?? hovered?.bounds else { return }
        let crop = rect.integral.intersection(extent)
        let candidate = hovered ?? session?.candidates.first { $0.bounds == rect }
        let index = candidate?.kind == .window ? Int(candidate!.id.dropFirst("window-".count))! : windows.firstIndex { $0.insetBy(dx: -2, dy: -2).contains(crop) }
        let windowID = index.flatMap { windowIDs.indices.contains($0) ? windowIDs[$0] : nil }
        let (kind, provenance, label): (HandoffManifest.Kind, HandoffManifest.Provenance, String) = switch candidate?.kind {
        case .window?: (.window, .windowList, index.flatMap { windowNames.indices.contains($0) ? windowNames[$0] : nil } ?? candidate!.label)
        case .display?: (.display, .userArea, "Full screen")
        case nil: crop == extent ? (.display, .userArea, "Full screen") : (.area, .userArea, "Area")
        case _? where candidate!.id.hasPrefix("fill-"): (.fill, .geometry, candidate!.label)
        case _?: (.element, candidate!.id.hasPrefix("ax-") ? .accessibility : .geometry, candidate!.label)
        }
        let display = CGRect(x: window.frame.minX, y: NSScreen.screens[0].frame.height - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        let global = CGRect(x: display.minX + crop.minX / scale, y: display.minY + crop.minY / scale, width: crop.width / scale, height: crop.height / scale)
        let observation = accessibilityObservations[rect]
        let (scale, displayID, capturedAt, live) = (scale, displayID, frozenAt, displayID != nil && !isHeadless)
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let info = windowID.flatMap { (CGWindowListCopyWindowInfo([.optionIncludingWindow], $0) as? [[String: Any]])?.first }
                let pid = info?[kCGWindowOwnerPID as String] as? Int32
                let read: (frames: [AXFrame], observedAt: Date)? = if let observation { observation } else if live, let pid {
                    (await Accessibility.frames(at: CGPoint(x: global.midX, y: global.midY), pid: pid), .now)
                } else { nil }
                let target = HandoffManifest.Target(kind: kind, label: label, provenance: provenance, frames: read?.frames ?? [], observedAt: read?.observedAt,
                                                    crop: global, display: display, tolerance: max(4, 6 / scale))
                var warnings: [HandoffManifest.Warning] = []
                if !live || !AXIsProcessTrusted() { warnings.append(.accessibilityUnavailable) }
                if let observed = target.observedAt, observed.timeIntervalSince(capturedAt) > HandoffManifest.staleAfter { warnings.append(.accessibilityStale) }
                if !live { warnings.append(.sourceUnavailable) }
                let source = windowID.map { id in
                    HandoffManifest.Source(app: info?[kCGWindowOwnerName as String] as? String,
                                           bundleId: pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }, pid: pid, windowId: id,
                                           windowTitle: (info?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                           windowFrame: info.map { CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)! })
                }
                let manifest = HandoffManifest(captureId: HandoffManifest.newId(), capturedAt: capturedAt,
                                               image: .init(width: Int(crop.width), height: Int(crop.height), scale: scale),
                                               geometry: .init(cropPixels: crop, scale: scale, displayId: displayID, displayFrame: display),
                                               source: source, target: target, warnings: warnings)
                let json = try manifest.json()
                let png = HandoffManifest.embedding(json, in: try await Output.png(image.cropping(to: crop)!))
                let store = HandoffStore(defaults: defaults)
                try await Task.detached { try store.write(png: png, manifest: manifest) }.value
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png), item.setString(manifest.reference, forType: .string), item.setData(json, forType: .snugCapture) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
                Self.lastAgentToast = ("Copied for agent", manifest.captureId)
                Toast.show(png: png, message: "Copied for agent", detail: manifest.captureId, defaults: defaults, pasteboard: pasteboard)
            } catch {
                report(error)
            }
        }
    }
}
