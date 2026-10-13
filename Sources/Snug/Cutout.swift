import AppKit
import CoreImage.CIFilterBuiltins
import Vision

extension Pref {
    /// Whether the cut-out output is trimmed to the subject (S in the preview); off, it keeps the selection's size.
    static let cutoutCrop = "SnugCutoutCrop"
}

/// One choice in the cut-out preview: the crop with everything but the chosen instances transparent, the outline traced around them,
/// and their bounding box.
struct CutoutSubject {
    /// At the crop's size, in the crop's color space.
    var image: CGImage
    /// A gray and alpha image at the crop's size whose alpha is a ring just outside the subject's edge, the preview's outline.
    var outline: CGImage
    /// The box around the pixels with alpha above 0, image pixels relative to the crop, top-left origin.
    var bounds: CGRect
}

extension OverlayController {
    /// K: cuts the selection (or the hovered rectangle) out of the frozen image with Vision's foreground instance mask, run on that crop
    /// alone with no margin, and opens the cut-out preview over it. The overlay stays as it is while the mask runs (tens of milliseconds);
    /// with no subject it shows "No subject found" and changes nothing else. A K while the mask runs replaces that run.
    func cutOut() {
        guard let area = selection?.rect ?? hoverRect, let image else { return beep() }
        let (rect, outline) = (area.integral, (1.5 * scale).rounded())
        textTask?.cancel()
        textTask = Task {
            do {
                let subjects = try await Self.cutoutSubjects(image.cropping(to: rect)!, outline: outline)
                try Task.checkCancellation()
                guard !subjects.isEmpty else {
                    text.notice = "No subject found"
                    return refresh()
                }
                showCutout(subjects, in: rect, radii: cornerRadii(of: area))
            } catch {
                report(error)
            }
        }
    }

    /// The cut-out choices for `image`: every foreground instance together, then, when there are several, each one alone; empty when
    /// Vision finds no subject. Each outline is `outline` pixels wide. The handler, observation and Core Image context are released on
    /// return, so the preview holds only the images.
    @concurrent
    static func cutoutSubjects(_ image: CGImage, outline: CGFloat) async throws -> [CutoutSubject] {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()), !observation.allInstances.isEmpty else { return [] }
        let all = observation.allInstances
        let choices = all.count > 1 ? [all] + all.map { IndexSet(integer: $0) } : [all]
        let context = CIContext()
        return try choices.map { instances in
            let buffer = try observation.generateMaskedImage(for: instances, imageFrom: handler, croppedToInstancesExtent: false)
            let masked = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: image.colorSpace!])
            let cut = context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: image.colorSpace!)!
            let grown = CIFilter.morphologyMaximum()
            grown.inputImage = masked
            grown.radius = Float(outline)
            let ring = CIFilter.sourceOutCompositing()
            ring.inputImage = grown.outputImage!
            ring.backgroundImage = masked
            let data = cut.dataProvider!.data!
            let pixels = CFDataGetBytePtr(data)!
            var (minX, minY, maxX, maxY) = (cut.width, cut.height, -1, -1)
            for y in 0..<cut.height {
                for x in 0..<cut.width where pixels[y * cut.bytesPerRow + x * 4 + 3] > 0 {
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            return CutoutSubject(image: cut, outline: context.createCGImage(ring.outputImage!, from: masked.extent, format: .LA8,
                                                                  colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)!,
                                 bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
    }
}
