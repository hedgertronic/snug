import AppKit
import CoreImage
import Vision

/// One choice in the cut-out preview: the crop with everything but the chosen instances transparent, at the crop's size to show in
/// place, and the same image cropped to those instances' extent to copy or save.
struct CutoutSubject {
    var preview: CGImage
    var output: CGImage
}

extension OverlayController {
    /// K: cuts the selection (or the hovered rectangle) out of the frozen image with Vision's foreground instance mask, run on that crop
    /// alone with no margin, and opens the cut-out preview over it. The overlay stays as it is while the mask runs (tens of milliseconds);
    /// with no subject it shows "No subject found" and changes nothing else.
    func cutOut() {
        guard let rect = (selection?.rect ?? hoverRect)?.integral, let image else { return NSSound.beep() }
        textTask = Task {
            do {
                let subjects = try await Self.cutoutSubjects(image.cropping(to: rect)!)
                try Task.checkCancellation()
                guard !subjects.isEmpty else {
                    text.notice = "No subject found"
                    return refresh()
                }
                showCutout(subjects, in: rect)
            } catch {
                report(error)
            }
        }
    }

    /// The cut-out choices for `image`: every foreground instance together, then, when there are several, each one alone; empty when
    /// Vision finds no subject. Images are in the image's color space. The handler, observation and Core Image context are released on
    /// return, so the preview holds only the images.
    @concurrent
    static func cutoutSubjects(_ image: CGImage) async throws -> [CutoutSubject] {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()), !observation.allInstances.isEmpty else { return [] }
        let all = observation.allInstances
        let choices = all.count > 1 ? [all] + all.map { IndexSet(integer: $0) } : [all]
        let context = CIContext()
        func render(_ instances: IndexSet, cropped: Bool) throws -> CGImage {
            let buffer = try observation.generateMaskedImage(for: instances, imageFrom: handler, croppedToInstancesExtent: cropped)
            let masked = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: image.colorSpace!])
            return context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: image.colorSpace!)!
        }
        return try choices.map { CutoutSubject(preview: try render($0, cropped: false), output: try render($0, cropped: true)) }
    }
}
