import CoreGraphics
import CoreML
import Foundation
import ScreenshotCore
import Vision
import VisionKit

/// `ocr-probe`: times Vision requests in one fresh process, one line per step.
/// A step is `NAME[@WIDTH]`: `ocr` (RecognizeTextRequest, level from --level), `ocr:fast`, `ocr:accurate`,
/// `idle` (nothing, a baseline footprint), `barcode` (DetectBarcodesRequest), `document` (RecognizeDocumentsRequest) or `livetext` (VisionKit's ImageAnalyzer, text and codes).
/// `@WIDTH` shrinks the image first. Each line ends with the footprint after the step and what the step found: OCR lines and the
/// visual rows `TextLayout` groups them into, a document's paragraphs, tables, lists, data detector matches and barcodes. `dump`
/// prints the lines, rows and table cells.
enum OCRProbe {
    static func run(image: CGImage, steps: [String], fast: Bool, correction: Bool, detectLanguage: Bool,
                    languages: [String], width: Int?, device: String?, dump: Bool) async throws {
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
            var found = ""
            let size = CGSize(width: source.width, height: source.height)
            func layout(_ lines: [TextLine]) -> String {
                let rows = TextLayout.rows(lines)
                if dump { print(TextLayout.table(rows)) }
                return "\(lines.count) lines, \(rows.count) rows"
            }
            switch name {
            case "ocr", "ocr:fast", "ocr:accurate":
                var request = RecognizeTextRequest()
                request.recognitionLevel = (name == "ocr" ? fast : name == "ocr:fast") ? .fast : .accurate
                request.usesLanguageCorrection = correction
                request.automaticallyDetectsLanguage = detectLanguage
                if !languages.isEmpty { request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) } }
                if let device {
                    let supported = request.supportedComputeStageDevices[.main] ?? []
                    print("main-stage devices: \(supported)")
                    request.setComputeDevice(supported.first { "\($0)".lowercased().contains(device) }, for: .main)
                }
                let observations = try await ImageRequestHandler(source).perform(request)
                count = observations.count
                found = layout(observations.map { TextLine(text: $0.topCandidates(1)[0].string, bounds: $0.boundingBox.toImageCoordinates(size, origin: .upperLeft)) })
            case "idle":
                break
            case "barcode":
                count = try await ImageRequestHandler(source).perform(DetectBarcodesRequest()).count
            case "document":
                let documents = try await ImageRequestHandler(source).perform(RecognizeDocumentsRequest())
                count = documents.count
                for document in documents.map(\.document) {
                    let lines = document.text.lines.map { TextLine(text: $0.topCandidates(1)[0].string, bounds: $0.boundingBox.toImageCoordinates(size, origin: .upperLeft)) }
                    let tables = document.tables.map { "\($0.rows.count)x\($0.columns.count)" }
                    found += "\(layout(lines)), \(document.paragraphs.count) paragraphs, tables [\(tables.joined(separator: " "))], \(document.lists.count) lists, "
                        + "\(document.text.detectedData.count) data matches, \(document.barcodes.count) barcodes"
                    guard dump else { continue }
                    for (index, table) in document.tables.enumerated() {
                        print("table \(index):")
                        for row in table.rows { print(row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")) }
                    }
                    for match in document.text.detectedData { print("data: \(match.match.details)") }
                }
            case "livetext":
                let analysis = try await ImageAnalyzer().analyze(source, orientation: .up, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode]))
                count = analysis.transcript.split(whereSeparator: \.isNewline).count
                found = "transcript \(count) lines, codes \(analysis.hasResults(for: .machineReadableCode))"
                if dump { print(analysis.transcript) }
            default:
                throw BenchError.message("unknown step \(step)")
            }
            let duration = start.duration(to: .now).components
            var info = task_vm_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            precondition(withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount) }
            } == KERN_SUCCESS)
            print(String(format: "%@ %.1f ms (%d results), footprint %.1f MiB; %@", step, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, count,
                         Double(info.phys_footprint) / 1_048_576, found))
        }
    }
}
