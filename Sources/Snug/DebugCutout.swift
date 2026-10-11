import AppKit
import CoreImage
import ImageIO
import ScreenshotCore
import Vision
import VisionKit

/// Masks and timings from Vision's foreground instance segmentation of one image.
struct CutoutResult {
    var milliseconds: [Double]
    var instanceCount: Int
    var centerInstances: [Int]
    /// The image with every instance kept and the rest transparent, full size.
    var combined: CGImage
    /// Each instance alone, cropped to its extent.
    var instances: [CGImage]
    var footprintAlive: String
}

extension DebugRun {
    /// `--cutout IN.png OUT_DIR [--visionkit]`: runs `GenerateForegroundInstanceMaskRequest` off the main thread three times on fresh
    /// handlers and writes `combined.png`, `instance-N.png` and `checker-combined.png` (the combined cutout over a checkerboard). Prints
    /// timings, instance counts, the combined mask's bounding box and coverage, and the memory footprint before, while the observation is
    /// alive, and after release. Then it writes the app's preview outline (`outline.png`) and outputs (`output-crop.png`, `-rounded`,
    /// `-shadow`, `-crop-shadow`, `-frame`) for all instances together. With `--visionkit` it then lifts subjects with VisionKit's `.visualLookUp` analysis into `subject-N.png`
    /// and `checker-subjects.png`, and fails if they do not arrive within 60 s.
    static func cutout(_ input: URL, into directory: URL, visionKit: Bool) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("\(input.lastPathComponent) \(image.width)x\(image.height)")
        let before = footprint()
        let result = try await foregroundMasks(image)
        print("vision: \(result.milliseconds.map { String(format: "%.0f", $0) }.joined(separator: ", ")) ms; instances \(result.instanceCount); at center \(result.centerInstances)")
        print("vision footprint: \(before) before, \(result.footprintAlive) with observation and handler alive")
        try write(result.combined, directory.appending(path: "combined.png"))
        for (index, instance) in result.instances.enumerated() {
            try write(instance, directory.appending(path: "instance-\(index + 1).png"))
            print("  instance \(index + 1): \(instance.width)x\(instance.height)")
        }
        let (box, coverage, cornerAlpha) = maskStats(result.combined)
        print("combined mask: box \(box), coverage \(String(format: "%.3f", coverage)), top-left alpha \(cornerAlpha)")
        try write(checkered([result.combined], size: CGSize(width: image.width, height: image.height)), directory.appending(path: "checker-combined.png"))
        print("vision footprint after release: \(footprint())")
        // The app's preview subjects and its outputs at 2x: cropped to the alpha > 0 box, rounded by 24 pt, with the window shadow, framed.
        let subject = try await OverlayController.cutoutSubjects(image, outline: 3).first
        if let subject {
            print("preview subject: alpha > 0 box \(subject.bounds) vs Vision's extent \(result.instances.count == 1 ? "\(result.instances[0].width)x\(result.instances[0].height)" : "(several instances)")")
            try write(subject.outline, directory.appending(path: "outline.png"))
            let outputs = [("crop", subject.bounds, CornerRadii.zero, false, false), ("rounded", nil, CornerRadii(48), false, false),
                           ("shadow", nil, .zero, false, true), ("crop-shadow", subject.bounds, .zero, false, true), ("frame", nil, .zero, true, false)]
            for (name, bounds, radii, framed, shadow) in outputs {
                let output = try OutputFrame.renderCutout(subject.image, bounds: bounds, cornerRadii: radii, framed: framed, shadow: shadow, scale: 2)
                try write(output, directory.appending(path: "output-\(name).png"))
                print("  output-\(name): \(output.width)x\(output.height)")
            }
        }
        guard visionKit else { exit(EXIT_SUCCESS) }

        Task {
            try? await Task.sleep(for: .seconds(60))
            FileHandle.standardError.write(Data("VisionKit subject lifting did not finish within 60 s\n".utf8))
            exit(EXIT_FAILURE)
        }
        let start = ContinuousClock.now
        print("visionkit: analyzing")
        let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.visualLookUp]))
        let analyzed = start.duration(to: .now).milliseconds
        print("visionkit: analyzed in \(String(format: "%.0f", analyzed)) ms, visual look up results \(analysis.hasResults(for: .visualLookUp)), lifting subjects")
        // `subjects` has not returned in headless runs, with the view outside any window or in this borderless one never ordered front.
        let size = CGSize(width: image.width, height: image.height)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: .borderless, backing: .buffered, defer: true)
        let view = ImageAnalysisOverlayView(frame: CGRect(origin: .zero, size: size))
        window.contentView = view
        view.preferredInteractionTypes = .imageSubject
        view.analysis = analysis
        view.beginSubjectAnalysisIfNecessary()
        let subjects = await view.subjects
        let lifted = start.duration(to: .now).milliseconds
        for (index, subject) in subjects.enumerated() {
            var rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let lift = try await view.image(for: [subject]).cgImage(forProposedRect: &rect, context: nil, hints: nil)!
            try write(lift, directory.appending(path: "subject-\(index + 1).png"))
            print("  subject \(index + 1): bounds \(subject.bounds), image \(lift.width)x\(lift.height)")
        }
        print("visionkit: analyze \(String(format: "%.0f", analyzed)) ms, subjects \(String(format: "%.0f", lifted)) ms; subjects \(subjects.count); footprint \(footprint())")
        if !subjects.isEmpty {
            let all = try await view.image(for: subjects)
            var rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            try write(checkered([all.cgImage(forProposedRect: &rect, context: nil, hints: nil)!], size: CGSize(width: image.width, height: image.height)),
                      directory.appending(path: "checker-subjects.png"))
        }
        exit(EXIT_SUCCESS)
    }

    /// Three foreground mask requests on fresh handlers, timed one by one, then the masked images from the last.
    @concurrent nonisolated static func foregroundMasks(_ image: CGImage) async throws -> CutoutResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var milliseconds: [Double] = []
        var last: (ImageRequestHandler, InstanceMaskObservation?)?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let handler = ImageRequestHandler(image)
            let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest())
            milliseconds.append(start.duration(to: .now).milliseconds)
            last = (handler, observation)
        }
        let (handler, found) = last!
        let alive = await footprint()
        guard let observation = found else {
            let empty = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
            return CutoutResult(milliseconds: milliseconds, instanceCount: 0, centerInstances: [], combined: empty, instances: [], footprintAlive: alive)
        }
        let context = CIContext()
        func cgImage(_ buffer: CVPixelBuffer) -> CGImage {
            let image = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        }
        let combined = cgImage(try observation.generateMaskedImage(for: observation.allInstances, imageFrom: handler))
        let instances = try observation.allInstances.map { cgImage(try observation.generateMaskedImage(for: [$0], imageFrom: handler, croppedToInstancesExtent: true)) }
        return CutoutResult(milliseconds: milliseconds, instanceCount: observation.allInstances.count,
                            centerInstances: Array(observation.instanceAtPoint(NormalizedPoint(x: 0.5, y: 0.5))),
                            combined: combined, instances: instances, footprintAlive: alive)
    }

    private static func write(_ image: CGImage, _ url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
    }

    /// The images drawn in order over a 16 px light and mid gray checkerboard.
    private static func checkered(_ images: [CGImage], size: CGSize) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<Int(size.height / 16) + 1 {
            for column in 0..<Int(size.width / 16) + 1 {
                context.setFillColor(gray: (row + column).isMultiple(of: 2) ? 0.92 : 0.62, alpha: 1)
                context.fill(CGRect(x: column * 16, y: row * 16, width: 16, height: 16))
            }
        }
        for image in images { context.draw(image, in: CGRect(origin: .zero, size: size)) }
        return context.makeImage()!
    }

    /// The bounding box (top-left origin, pixels) of alpha above half, the fraction of pixels above half, and the top-left pixel's alpha.
    private static func maskStats(_ image: CGImage) -> (CGRect, Double, UInt8) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var (minX, minY, maxX, maxY, count) = (image.width, image.height, -1, -1, 0)
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 127 {
                (minX, minY, maxX, maxY, count) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y), count + 1)
            }
        }
        let box = maxX < 0 ? CGRect.null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (box, Double(count) / Double(image.width * image.height), pixels[3])
    }
}
