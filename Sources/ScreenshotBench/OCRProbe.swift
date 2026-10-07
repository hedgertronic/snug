import CoreGraphics
import Foundation
import Vision

/// `ocr-probe`: times Vision requests in one fresh process, one line per step.
/// A step is `NAME[@WIDTH]`: `ocr` (RecognizeTextRequest, level from --level), `ocr:fast`, `ocr:accurate`,
/// `barcode` (DetectBarcodesRequest) or `document` (RecognizeDocumentsRequest). `@WIDTH` shrinks the image first.
enum OCRProbe {
    static func run(image: CGImage, steps: [String], fast: Bool, correction: Bool, detectLanguage: Bool,
                    languages: [String], width: Int?) async throws {
        for step in steps {
            let parts = step.split(separator: "@")
            let name = String(parts[0])
            var source = image
            if let width = parts.count > 1 ? Int(parts[1]) : width, width < image.width {
                let height = image.height * width / image.width
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                source = context.makeImage()!
            }
            let start = ContinuousClock.now
            var count = 0
            switch name {
            case "ocr", "ocr:fast", "ocr:accurate":
                var request = RecognizeTextRequest()
                request.recognitionLevel = (name == "ocr" ? fast : name == "ocr:fast") ? .fast : .accurate
                request.usesLanguageCorrection = correction
                request.automaticallyDetectsLanguage = detectLanguage
                if !languages.isEmpty { request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) } }
                request.minimumTextHeightFraction = 0.004
                count = try await ImageRequestHandler(source).perform(request).count
            case "barcode":
                count = try await ImageRequestHandler(source).perform(DetectBarcodesRequest()).count
            case "document":
                count = try await ImageRequestHandler(source).perform(RecognizeDocumentsRequest()).count
            default:
                throw BenchError.message("unknown step \(step)")
            }
            let duration = start.duration(to: .now).components
            print(String(format: "%@ %.1f ms (%d results)", step, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, count))
        }
    }
}
