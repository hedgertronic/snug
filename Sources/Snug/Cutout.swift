import AppKit
import CoreImage.CIFilterBuiltins
import ScreenshotCore
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
                guard let crop = image.cropping(to: rect) else { throw CocoaError(.fileReadCorruptFile) }
                let subjects = try await Self.cutoutSubjects(crop, outline: outline)
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

    /// The cut-out choices for `image`: every foreground instance together, then, when there are several, each one alone, as many as
    /// `CutoutLimits.choices` allows for the crop's size; empty when Vision finds no subject. A crop over `CutoutLimits.maximumPixels`
    /// throws. Each outline is `outline` pixels wide. A canceled cut-out stops between choices. The handler, observation and Core Image
    /// context are released on return, so the preview holds only the images.
    @concurrent
    static func cutoutSubjects(_ image: CGImage, outline: CGFloat) async throws -> [CutoutSubject] {
        guard CutoutLimits.choices(instances: 1, pixels: image.width * image.height) != nil else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "The selection is too large to cut out. Select a smaller area."])
        }
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()), !observation.allInstances.isEmpty else { return [] }
        let all = observation.allInstances
        let count = CutoutLimits.choices(instances: all.count, pixels: image.width * image.height) ?? 1
        let choices = ([all] + (all.count > 1 ? all.map { IndexSet(integer: $0) } : [])).prefix(count)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext()
        var subjects: [CutoutSubject] = []
        for instances in choices {
            try Task.checkCancellation()
            let buffer = try observation.generateMaskedImage(for: instances, imageFrom: handler, croppedToInstancesExtent: false)
            let masked = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
            let grown = CIFilter.morphologyMaximum()
            grown.inputImage = masked
            grown.radius = Float(outline)
            let ring = CIFilter.sourceOutCompositing()
            ring.inputImage = grown.outputImage
            ring.backgroundImage = masked
            guard let cut = context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space),
                  let data = cut.dataProvider?.data, let pixels = CFDataGetBytePtr(data), let ringImage = ring.outputImage,
                  let edge = context.createCGImage(ringImage, from: masked.extent, format: .LA8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
            else { throw CocoaError(.fileReadCorruptFile) }
            var (minX, minY, maxX, maxY) = (cut.width, cut.height, -1, -1)
            for y in 0..<cut.height {
                for x in 0..<cut.width where pixels[y * cut.bytesPerRow + x * 4 + 3] > 0 {
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            // An instance whose mask came back empty has no subject to offer.
            guard maxX >= 0 else { continue }
            subjects.append(CutoutSubject(image: cut, outline: edge, bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)))
        }
        return subjects
    }
}
