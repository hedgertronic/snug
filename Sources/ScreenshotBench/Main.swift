import AppKit
import Darwin
import ImageIO
import ScreenshotCore
import UniformTypeIdentifiers

enum BenchError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(text) = self { text } else { "Error" } }
}

enum PNG {
    @MainActor
    static func rasterize(_ image: NSImage, width: Int, height: Int) throws -> CGImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BenchError.message("Cannot allocate render bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
            operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = bitmap.cgImage else { throw BenchError.message("Cannot render bitmap") }
        return result
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BenchError.message("Cannot read \(url.path)") }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw BenchError.message("Cannot create \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchError.message("Cannot write \(url.path)") }
    }
}

struct BenchmarkResult: Codable {
    let file: String
    let pixelWidth: Int
    let pixelHeight: Int
    let detector: DetectorKind
    let samplesMilliseconds: [Double]
    let peakProcessRSSBytes: Int64
    let candidateCount: Int
    let defaultIoU: Double?
    let bestCandidateIoU: Double?
    let defaultEdgesWithin8Pixels: Bool?
    let bestEdgesWithin8Pixels: Bool?
    let minimumKeyboardCorrectionsWithinTwo: Int?
    let selected: Candidate?
    let candidates: [Candidate]
    let error: String?
}

@main
struct ScreenshotBench {
    @MainActor
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1) }
    }

    @MainActor
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if args.first == "snap", let input = option("--image"),
           let rectangle = option("--rect"), let output = option("--output") {
            let values = rectangle.split(separator: ",").compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy(\.isFinite) else {
                throw BenchError.message("--rect requires x,y,width,height in source pixels")
            }
            let image = try PNG.read(URL(fileURLWithPath: input))
            let rough = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            let start = ContinuousClock.now
            let suggestions = try await Task.detached {
                try await SmartSnap().suggest(in: image, roughBounds: rough, scale: CGFloat(option("--scale").flatMap { Double($0) } ?? 1))
            }.value
            let duration = start.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            let candidates = suggestions.enumerated().map { index, suggestion in
                Candidate(id: "snap-\(index)", label: suggestion.reason, bounds: suggestion.bounds,
                          score: suggestion.confidence, kind: .manual)
            }
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidates).write(to: directory.appendingPathComponent("suggestions.json"))
            try writePreview(image, candidates: candidates, target: rough, selected: candidates.first,
                             to: directory.appendingPathComponent("preview.png"))
            print("\(suggestions.count) suggestions; \(String(format: "%.1f", milliseconds)) ms; first=\(String(describing: suggestions.first?.bounds))")
            return
        }
        if args.first == "ocr-probe", let input = option("--image"), let steps = option("--steps") {
            try await OCRProbe.run(image: try PNG.read(URL(fileURLWithPath: input)), steps: steps.split(separator: ",").map(String.init),
                                   fast: option("--level") == "fast", correction: option("--correction") != "off",
                                   detectLanguage: option("--detect-language") != "off",
                                   languages: option("--languages")?.split(separator: ",").map(String.init) ?? [], width: option("--width").flatMap { Int($0) }, device: option("--device"))
            return
        }
        if args.first == "evaluate", let labels = option("--labels"),
           let results = option("--results"), let output = option("--output") {
            try evaluate(labelsURL: URL(fileURLWithPath: labels), resultsURL: URL(fileURLWithPath: results),
                         outputURL: URL(fileURLWithPath: output))
            return
        }
        if args.first == "suite", let manifest = option("--manifest"), let output = option("--output") {
            try await ScreenshotBenchSuite.run(manifestURL: URL(fileURLWithPath: manifest),
                               baselineURL: option("--baseline").map { URL(fileURLWithPath: $0) },
                               outputURL: URL(fileURLWithPath: output, isDirectory: true))
            return
        }
        if args.first == "fixtures", args.count == 2 {
            try Fixtures.write(to: URL(fileURLWithPath: args[1], isDirectory: true))
            print("Wrote six synthetic fixtures and manifest to \(args[1])")
            return
        }
        guard args.first == "analyze", let input = option("--image"), let output = option("--output"),
              let detector = DetectorKind(rawValue: option("--detector") ?? "geometry") else {
            throw BenchError.message("Usage: ScreenshotBench fixtures DIR | analyze --image FILE --output DIR --detector geometry|vision [--repeat N] [--manifest FILE] | snap --image FILE --rect x,y,width,height --output DIR | evaluate --labels FILE --results DIR --output FILE | suite --manifest FILE [--baseline FILE] --output DIR | ocr-probe --image FILE --steps ocr,ocr [--level fast] [--correction off] [--detect-language off] [--languages en-US] [--width N] [--device cpu|gpu|neuralengine]")
        }
        let repetitions = max(1, min(100, Int(option("--repeat") ?? "1") ?? 1))
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let image = try PNG.read(inputURL)
        var fixture: Fixture?
        if let path = option("--manifest") {
            fixture = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path))).first { $0.file == inputURL.lastPathComponent }
        }
        if let fixture, image.width != fixture.pixelWidth || image.height != fixture.pixelHeight {
            throw BenchError.message("Fixture pixel dimensions do not match the labeled manifest")
        }
        var times: [Double] = []
        var candidates: [Candidate] = []
        var failure: String?
        for _ in 0..<repetitions {
            do {
                let report = try await Task.detached { try await Detection.run(detector, image: image) }.value
                times.append(report.elapsedMilliseconds)
                candidates = report.candidates
            } catch { failure = String(describing: error); break }
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let anchor = fixture?.anchor ?? CGPoint(x: extent.midX, y: extent.midY)
        let session = SelectionSession(candidates: candidates, extent: extent, anchor: anchor)
        let target = fixture?.target
        let best = target.flatMap { target in candidates.max { Detection.overlap($0.bounds, target) < Detection.overlap($1.bounds, target) } }
        func edgesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
            max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)) <= 8
        }
        var minimumCorrections: Int?
        if let target {
            var frontier = [session]
            for depth in 0...2 {
                if frontier.contains(where: { edgesMatch($0.selected?.bounds ?? .zero, target) }) {
                    minimumCorrections = depth
                    break
                }
                frontier = frontier.flatMap { state in
                    (0..<4).map { action in
                        var next = state
                        switch action {
                        case 0: next.cycle()
                        case 1: next.cycle(backward: true)
                        case 2: next.expand()
                        default: next.shrink()
                        }
                        return next
                    }
                }
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result = BenchmarkResult(file: inputURL.lastPathComponent, pixelWidth: image.width, pixelHeight: image.height, detector: detector, samplesMilliseconds: times,
            peakProcessRSSBytes: Int64(usage.ru_maxrss), candidateCount: candidates.count,
            defaultIoU: target.map { Detection.overlap(session.selected?.bounds ?? .zero, $0) },
            bestCandidateIoU: target.map { Detection.overlap(best?.bounds ?? .zero, $0) },
            defaultEdgesWithin8Pixels: target.map { edgesMatch(session.selected?.bounds ?? .zero, $0) },
            bestEdgesWithin8Pixels: target.map { target in candidates.contains { edgesMatch($0.bounds, target) } },
            minimumKeyboardCorrectionsWithinTwo: minimumCorrections,
            selected: session.selected, candidates: candidates, error: failure)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stem = "\(inputURL.deletingPathExtension().lastPathComponent)-\(detector.rawValue)"
        try encoder.encode(result).write(to: outputURL.appendingPathComponent("\(stem).json"))
        try writePreview(image, candidates: candidates, target: target, selected: session.selected, to: outputURL.appendingPathComponent("\(stem).png"))
        if let selected = session.selected, let crop = image.cropping(to: selected.bounds.integral) {
            try PNG.write(crop, to: outputURL.appendingPathComponent("\(stem)-crop.png"))
        }
        let timing = times.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        print("\(stem): \(candidates.count) candidates; ms=[\(timing)]; peak RSS=\(usage.ru_maxrss / 1_048_576) MiB; selected IoU=\(result.defaultIoU ?? -1); best IoU=\(result.bestCandidateIoU ?? -1)")
        if let failure { throw BenchError.message(failure) }
    }

    @MainActor
    static func writePreview(_ image: CGImage, candidates: [Candidate], target: CGRect?, selected: Candidate?, to url: URL) throws {
        let size = NSSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: size)
        let rendered = NSImage(size: size, flipped: true) { _ in
            nsImage.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            for candidate in candidates {
                NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
                let path = NSBezierPath(rect: candidate.bounds); path.lineWidth = 1; path.stroke()
            }
            if let target { NSColor.systemGreen.setStroke(); let path = NSBezierPath(rect: target); path.lineWidth = 5; path.stroke() }
            if let selected { NSColor.systemPink.setStroke(); let path = NSBezierPath(rect: selected.bounds); path.lineWidth = 3; path.stroke() }
            return true
        }
        let cg = try PNG.rasterize(rendered, width: image.width, height: image.height)
        try PNG.write(cg, to: url)
    }
}
