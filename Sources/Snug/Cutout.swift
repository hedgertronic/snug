import AppKit
import CoreImage
import Vision

extension OverlayController {
    /// K: cuts the selection (or the hovered rectangle) out of the frozen image with Vision's foreground instance mask, run on that crop
    /// alone with no margin, and delivers the transparent PNG through the usual copy or copy-and-save path with the toast. The overlay
    /// stays open while the mask runs (tens of milliseconds); with no subject it shows "No subject found" and changes nothing else.
    func cutOut() {
        guard let rect = (selection?.rect ?? hoverRect)?.integral, let image else { return NSSound.beep() }
        textTask = Task {
            do {
                let cutout = try await Self.cutout(image.cropping(to: rect)!)
                try Task.checkCancellation()
                guard let cutout else {
                    text.notice = "No subject found"
                    return refresh()
                }
                // Clearing the task first keeps `dismiss` from cancelling it, so a failed save still reports.
                textTask = nil
                let (pasteboard, defaults, saves) = (pasteboard, defaults, afterCaptureSaves)
                dismiss()
                try Output.publish(png: cutout.png, detail: "\(cutout.width) x \(cutout.height)  cut out", copy: true, save: saves,
                                   pasteboard: pasteboard, defaults: defaults)
            } catch {
                report(error)
            }
        }
    }

    /// Every foreground instance of `image` with the rest transparent, cropped to their extent and encoded as a PNG in the image's color
    /// space, or nil when Vision finds no subject. The handler, observation and Core Image context are released on return.
    @concurrent
    static func cutout(_ image: CGImage) async throws -> (png: Data, width: Int, height: Int)? {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()), !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateMaskedImage(for: observation.allInstances, imageFrom: handler, croppedToInstancesExtent: true)
        let masked = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: image.colorSpace!])
        let cutout = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: image.colorSpace!)!
        return (try await Output.png(cutout), cutout.width, cutout.height)
    }
}
