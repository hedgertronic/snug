import AppKit
import FoundationModels
import ImageIO
import OSLog
import ScreenshotCore

/// Names saved captures with Apple's on-device language model (Settings > General > Name with Apple Intelligence). The capture is
/// saved under its context name first; once the model describes it, the file is renamed with that description as its {title}.
/// On macOS 27 with a model that reads images, the model sees the capture itself; otherwise it reads the capture's text (fast OCR),
/// the app and the window title. Nothing leaves the Mac.
enum CaptureNamer {
    private static let log = Logger(subsystem: "com.hedgertronic.snug", category: "naming")
    /// How long a description may take before the context name stands.
    static let timeout: Duration = .seconds(10)
    /// The most OCR text the prompt carries, in characters, so the prompt stays well inside the model's context.
    static let textLimit = 1_200
    /// The longest side of the image the model sees, in pixels.
    static let imageLimit = 1_024

    static let instructions = """
        You name screenshot files. Reply with only a title of 2 to 6 words in Title Case that says what the screenshot shows, \
        specific enough to find it again later, such as "Lisbon Flight Confirmation" or "Xcode Build Errors". Do not include the app's \
        name, a date, quotes, end punctuation or a file extension.
        """

    /// Why the model cannot name captures right now, for Settings; nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading."
        case .unavailable: "Apple Intelligence is unavailable."
        }
    }

    /// What describes a capture for `rename`: the model (`describe`). Debug runs swap in a stand-in.
    @MainActor static var describer: @Sendable (Data, CaptureContext?) async -> String? = { await describe(png: $0, context: $1) }
    /// The latest `rename`, which debug runs await; its value is the file renamed to, or nil when nothing was renamed.
    @MainActor private(set) static var lastRename: Task<URL?, Never>?
    /// The renames still waiting on the model, by the file each renames; a rename runs only while its file's token is still here.
    @MainActor private static var pending: [URL: UUID] = [:]

    /// Drops the pending rename of `file`, once the user acts on it (Rename, Trash, Share or a drag from its toast), so the file keeps
    /// the name and place they handed on.
    @MainActor static func cancelRename(of file: URL) { pending[file] = nil }

    /// Renames the saved `file` to what `pattern` gives with the model's description of `png` as its title, keeping the app and `date`.
    /// Nothing happens when the model is unavailable, slow, declines or gives no title, when the user acted on the file from its toast
    /// meanwhile (`cancelRename`), or when the file was renamed, moved or trashed. A toast showing the file, and a pasteboard holding
    /// it, follow the rename.
    @MainActor
    static func rename(_ file: URL, png: Data, context: CaptureContext?, date: Date, pattern: String, pasteboard: NSPasteboard) {
        let describe = describer
        let token = UUID()
        pending[file] = token
        lastRename = Task {
            let description = await describe(png, context)
            guard pending[file] == token else { return nil }
            pending[file] = nil
            guard let description else { return nil }
            let base = CaptureName.name(pattern: pattern, app: context?.app, description: description, date: date)
            let target = file.deletingLastPathComponent().appending(path: base).appendingPathExtension(file.pathExtension)
            guard target != file, FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let moved = try UniqueFile.move(file, to: target)
                Toast.fileMoved(from: file, to: moved, pasteboard: pasteboard)
                return moved
            } catch {
                log.error("rename failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// The model's description of a capture, cleaned for a file name (`CaptureName.description(fromModel:)`); nil when the model is
    /// unavailable, takes longer than `timeout`, declines, or answers with no usable title.
    @concurrent
    static func describe(png: Data, context: CaptureContext?) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let started = ContinuousClock.now
        do {
            let reply = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await respond(model: model, png: png, context: context) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            let description = reply.flatMap(CaptureName.description(fromModel:))
            log.notice("described in \(Int(started.duration(to: .now).milliseconds)) ms: \(description == nil ? "no title" : "titled", privacy: .public)")
            return description
        } catch {
            log.notice("no description: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// One answer from a fresh session. A model that reads images (macOS 27) sees the capture itself with the app and title; a text-only
    /// model gets the capture's text from Text mode's accurate OCR (`OverlayController.recognize`, warmed at launch) instead.
    private static func respond(model: SystemLanguageModel, png: Data, context: CaptureContext?) async throws -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var facts = ["Name this screenshot."]
        if let app = context?.app { facts.append("App: \(app)") }
        if let title = context?.title { facts.append("Window title: \(title)") }
        let session = LanguageModelSession(model: model, instructions: instructions)
        if #available(macOS 27, *), model.capabilities.contains(.vision), !forcesText, let small = thumbnail(source) {
            let prompt = facts.joined(separator: "\n")
            return try await session.respond { prompt; Attachment(small) }.content
        }
        let reading = ContinuousClock.now
        let lines = try await OverlayController.recognize(image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let text = String(lines.map(\.text).joined(separator: "\n").prefix(textLimit))
        log.notice("read \(text.count) characters in \(Int(reading.duration(to: .now).milliseconds)) ms")
        if !text.isEmpty { facts.append("Text in the screenshot:\n\(text)") }
        return try await session.respond(to: facts.joined(separator: "\n")).content
    }
    /// Debug builds take the text-only path when SNUG_FORCE_TEXT is set, so a Mac whose model reads images can still exercise it.
    #if DEBUG
    static let forcesText = ProcessInfo.processInfo.environment["SNUG_FORCE_TEXT"] != nil
    #else
    static let forcesText = false
    #endif

    /// The capture with its longest side at most `imageLimit` pixels.
    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: imageLimit,
                                                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
}
