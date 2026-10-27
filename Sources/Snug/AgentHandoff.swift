import AppKit
import ScreenshotCore

extension NSPasteboard.PasteboardType {
    /// The manifest JSON on a Copy for Agent clipboard item. A type is a UTI, which allows no "+".
    static let snugCapture = NSPasteboard.PasteboardType("com.hedgertronic.snug.capture-json")
}

/// Copy for Agent (Cmd-Return, the strip's Agent button).
extension OverlayController {
    /// The last Copy for Agent toast's message and detail; debug runs, which suppress toasts, read it here.
    static var lastAgentToast: (message: String, detail: String)?

    /// Copies the selection, or the hovered target, for an agent. The crop is the frozen pixels at full resolution with no Frame and
    /// no rounded corners, so its pixels map one-to-one to the screen. It is written with its manifest as a bundle in the agent folder,
    /// then copied as one clipboard item: the PNG (the manifest in its text chunk), the reference line, and the manifest.
    /// The target's Accessibility data comes from one read at the crop's center (`Accessibility.handoff`), only on a live capture outside
    /// debug runs, for every kind of target; when that reads nothing, from what the hover read for this rectangle. The source is the
    /// window holding the crop, with the app's bundle and version and, from that read, the window's document and the web page's URL and title.
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
        let (tolerance, displayName) = (max(4, 6 / scale), displayID == nil ? nil : window.screen?.localizedName)
        dismiss()
        commitTask = Task { [pasteboard, defaults] in
            do {
                let info = windowID.flatMap { (CGWindowListCopyWindowInfo([.optionIncludingWindow], $0) as? [[String: Any]])?.first }
                let pid = info?[kCGWindowOwnerPID as String] as? Int32
                let lookup = if live, let pid {
                    await Accessibility.handoff(at: CGPoint(x: global.midX, y: global.midY), pid: pid, crop: global, display: display, tolerance: tolerance)
                } else { nil as (frames: [AXFrame], document: String?, url: String?, pageTitle: String?)? }
                let read: (frames: [AXFrame], observedAt: Date)? = if let lookup, !lookup.frames.isEmpty { (lookup.frames, .now) } else { observation }
                let target = HandoffManifest.Target(kind: kind, label: label, provenance: provenance, frames: read?.frames ?? [], observedAt: read?.observedAt,
                                                    crop: global, display: display, tolerance: tolerance)
                var warnings: [HandoffManifest.Warning] = []
                if !live || !AXIsProcessTrusted() { warnings.append(.accessibilityUnavailable) }
                if let observed = target.observedAt, observed.timeIntervalSince(capturedAt) > HandoffManifest.staleAfter { warnings.append(.accessibilityStale) }
                if !live { warnings.append(.sourceUnavailable) }
                let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                let source = windowID.map { id in
                    HandoffManifest.Source(app: info?[kCGWindowOwnerName as String] as? String, bundleId: app?.bundleIdentifier, bundlePath: app?.bundleURL?.path,
                                           appVersion: app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String },
                                           pid: pid, windowId: id, windowTitle: (info?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                           windowFrame: info.map { CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)! },
                                           document: lookup?.document, url: lookup?.url, pageTitle: lookup?.pageTitle)
                }
                let manifest = HandoffManifest(captureId: HandoffManifest.newId(), capturedAt: capturedAt,
                                               image: .init(width: Int(crop.width), height: Int(crop.height), scale: scale),
                                               geometry: .init(cropPixels: crop, scale: scale, displayId: displayID, displayName: displayName, displayFrame: display),
                                               source: source, target: target, warnings: warnings)
                let json = try manifest.json()
                let png = HandoffManifest.embedding(json, in: try await Output.png(image.cropping(to: crop)!))
                let store = HandoffStore(defaults: defaults)
                _ = try await Task.detached { try store.write(png: png, manifest: manifest) }.value
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png), item.setString(manifest.reference, forType: .string), item.setData(json, forType: .snugCapture) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
                Self.lastAgentToast = ("Copied for agent", manifest.captureId)
                Toast.show(png: png, message: "Copied for agent", detail: manifest.captureId, defaults: defaults, pasteboard: pasteboard)
                Sound.capture.play(defaults: defaults)
            } catch {
                report(error)
            }
        }
    }
}
