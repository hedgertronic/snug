import AppKit
import ScreenshotCore

extension DebugRun {
    /// `--loupe-frames DIR`: drags a selection's bottom-right corner in 0.25 pt and then 0.1 pt steps across several source pixels with the loupe on.
    /// For each frame it writes the loupe as the view draws it (`frame-NN.png`, device pixels) and prints where the selection outline falls
    /// against the loupe's cells: the outline's side of the center cell, its stroke centroid in device pixels, and the stroke's coverage.
    static func loupeFrames(into directory: URL, image: CGImage, frame: CGRect, overlay: OverlayController) async throws {
        _ = privateSetup(overlay)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        overlay.defaults.set(true, forKey: Pref.loupe)
        overlay.present(image: image, frame: frame, displayID: nil)
        let view = overlay.view, guides = view.guides, scale = overlay.scale
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            overlay.window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        let size = Int(Guides.loupeSize * scale), cell = Guides.loupeSize * scale / CGFloat(Guides.loupePixels)
        let middle = cell * CGFloat(Guides.loupePixels / 2)
        /// `layer` drawn alone into a device-pixel bitmap the disc's size, bottom-left origin.
        func render(_ layer: CALayer) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
            }
            return bytes
        }
        // `render(in:)` ignores `.nearest` and interpolates, so the cells' boundaries are computed: with nearest filtering the device pixel whose
        // center is at c + 0.5 shows source column floor((c + 0.5) / cell).
        let starts = (1..<size).filter { Int((CGFloat($0) + 0.5) / cell) != Int((CGFloat($0) - 0.5) / cell) }
        print("cell \(cell) device px; computed cell starts \(starts); grid lines at \((1..<Guides.loupePixels).map { (CGFloat($0) * cell * 1000).rounded() / 1000 })")

        let start = CGPoint(x: 300, y: 200), corner = CGPoint(x: 465, y: 261)
        for increment: CGFloat in [0.25, 0.1] {
            mouse(.leftMouseDown, start)
            print("\(increment) pt steps")
            print("step pointer_pt pointer_px column edge_side centroid_px centroid_minus_center_left covered_cols full_cols alpha_sum loupe_origin_px")
            for step in 0...16 {
                let point = CGPoint(x: corner.x + CGFloat(step) * increment, y: corner.y + CGFloat(step) * increment)
                mouse(.leftMouseDragged, point)
                let pixel = overlay.pointer
                // The outline's vertical (right) edge, read along a row through the disc's upper half where only that edge crosses.
                let edges = render(guides.edges)
                let line = (0..<size).map { CGFloat(edges[((size / 4) * size + $0) * 4 + 3]) / 255 }
                let total = line.reduce(0, +)
                let centroid = line.enumerated().reduce(0) { $0 + (CGFloat($1.offset) + 0.5) * $1.element } / total
                let box = guides.edges.path!.boundingBox
                let side = (box.maxX * scale - middle) / cell
                let origin = CGPoint(x: guides.loupe.frame.minX * scale, y: guides.loupe.frame.minY * scale)
                print(String(format: "%2d %8.2f %8.2f %4d %+5.2f %7.2f %+6.2f %2d %2d %5.2f (%.2f, %.2f)", step, point.x, pixel.x, Int(pixel.x), side, centroid, centroid - middle,
                             line.filter { $0 > 0.01 }.count, line.filter { $0 > 0.99 }.count, total, origin.x, origin.y))
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                let flipped = CGRect(x: guides.loupe.frame.minX * scale, y: (view.bounds.height - guides.loupe.frame.maxY) * scale,
                                     width: guides.loupe.frame.width * scale, height: guides.loupe.frame.height * scale)
                let crop = rep.cgImage!.cropping(to: flipped)!
                try NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!
                    .write(to: directory.appending(path: String(format: "frame-%.2f-%02d.png", increment, step)))
            }
            mouse(.leftMouseUp, CGPoint(x: corner.x + 4, y: corner.y + 4))
            overlay.dismiss()
            overlay.present(image: image, frame: frame, displayID: nil)
        }
        overlay.dismiss()
        exit(EXIT_SUCCESS)
    }
}
