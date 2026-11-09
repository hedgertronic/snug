import AppKit
import CoreImage.CIFilterBuiltins

/// The `--warm-vision` child that `OverlayController.warmVisionInChild` starts once per newly built binary.
@MainActor
enum VisionWarmup {
    /// `--warm-vision`: runs Tab's accurate OCR and barcode requests on the warm-up page, then Shift-Return's accurate OCR on each of its
    /// script rows alone, and exits. Vision compiles each model into the on-disk cache on a binary's first use of it: the text detector,
    /// orientation, the barcode networks, and one recognizer per script, which automatic language detection only reaches for a row on its
    /// own. A child process pays that once per binary and takes the requests' memory with it when it exits. Prints the time, the items
    /// found, and the footprint before and after.
    static func runAndExit() async throws {
        let before = footprint()
        let start = ContinuousClock.now
        let (page, cells) = fixture()
        let items = try await OverlayController.findItems(in: page)
        for cell in cells { _ = try await OverlayController.recognize(page, crop: cell) }
        print("warm-vision: \(String(format: "%.1f", start.duration(to: .now).milliseconds)) ms, \(items.count) items, footprint \(before) before, \(footprint()) after")
        exit(EXIT_SUCCESS)
    }

    /// The found-items page at 2000 x 1100 px with an Arabic and a Devanagari row of text above it, and each row's rect (top-left origin,
    /// pixels). Those two scripts have recognizers of their own; Cyrillic, Chinese, Japanese, Korean and Thai rows compiled nothing more.
    static func fixture() -> (page: CGImage, cells: [CGRect]) {
        let (width, height) = (2000, 1100)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(itemsFixture(width: width, height: height), in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = ["مرحبا بك في التطبيق", "नमस्ते, आप कैसे हैं"]
        var cells: [CGRect] = []
        for (index, text) in rows.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]))
            let baseline = CGPoint(x: 40 + index * 640, y: 1050)
            context.textPosition = baseline
            CTLineDraw(line, context)
            cells.append(CGRect(x: baseline.x - 20, y: CGFloat(height) - baseline.y - 38, width: 640, height: 50))
        }
        return (context.makeImage()!, cells)
    }

    /// A white page of `width` x `height` pixels with a link, an email address and a phone number in large text from the top left, and a
    /// 500 px QR code of a URL 200 px from the bottom-right corner.
    static func itemsFixture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, text) in ["Docs: https://example.com/snug", "Mail you@example.com", "Call +1 (555) 010-4477"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 200, y: CGFloat(height - 300 - index * 160))
            CTLineDraw(line, context)
        }
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data("https://example.org/qr".utf8)
        let code = CIContext().createCGImage(qr.outputImage!, from: qr.outputImage!.extent)!
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: width - 700, y: 200, width: 500, height: 500))
        return context.makeImage()!
    }
}

/// The process's physical memory footprint, as Activity Monitor's Memory column shows it.
func footprint() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    precondition(result == KERN_SUCCESS)
    return String(format: "%.1f MiB", Double(info.phys_footprint) / 1_048_576)
}
