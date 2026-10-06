import AppKit
import ScreenshotCore

struct Fixture: Codable {
    let file: String
    let pixelWidth: Int
    let pixelHeight: Int
    let target: CGRect
    let anchor: CGPoint
    let description: String
}

@MainActor
enum Fixtures {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [Fixture] = []
        for name in ["grid-table", "borderless-table", "dark-table", "cards", "chart-panel", "nested-panels"] {
            let dark = name == "dark-table"
            let ink = dark ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)
            let page = dark ? NSColor(calibratedWhite: 0.09, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
            let panel = dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor.white
            let line = dark ? NSColor(calibratedWhite: 0.38, alpha: 1) : NSColor(calibratedWhite: 0.74, alpha: 1)
            let image = NSImage(size: NSSize(width: 1280, height: 800), flipped: true) { _ in
                func fill(_ rect: CGRect, _ color: NSColor) { color.setFill(); rect.fill() }
                func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 16, bold: Bool = false) {
                    (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                        .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                        .foregroundColor: ink
                    ])
                }
                func border(_ rect: CGRect) { line.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke() }
                fill(CGRect(x: 0, y: 0, width: 1280, height: 800), page)
                fill(CGRect(x: 0, y: 0, width: 220, height: 800), dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.87, alpha: 1))
                text("SCREENSHOT LAB", 22, 28, 17, bold: true)
                for (i, item) in ["Overview", "Reports", "Sessions", "Settings"].enumerated() { text(item, 24, CGFloat(110 + i * 54)) }
                text("Weekly activity", 280, 36, 30, bold: true)
                text("A synthetic interface for comparing region selection", 280, 82)
                if name == "cards" {
                    for (i, title) in ["Total sessions", "Active users", "Completion rate"].enumerated() {
                        let rect = CGRect(x: 280 + i * 300, y: 200, width: 260, height: 230)
                        fill(rect, panel); border(rect)
                        text(title, rect.minX + 20, 225, 18, bold: true)
                        text(["128", "42", "94%"][i], rect.minX + 20, 280, 44, bold: true)
                        text("Updated today", rect.minX + 20, 370)
                    }
                } else if name == "chart-panel" {
                    let rect = CGRect(x: 280, y: 190, width: 880, height: 460)
                    fill(rect, panel); border(rect)
                    text("Sessions per day", 305, 213, 20, bold: true)
                    for i in 0..<7 {
                        let h = CGFloat([120, 180, 145, 240, 200, 290, 260][i])
                        fill(CGRect(x: CGFloat(345 + i * 105), y: 580 - h, width: 60, height: h), .systemBlue)
                        text(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][i], CGFloat(351 + i * 105), 592)
                    }
                } else if name == "nested-panels" {
                    fill(CGRect(x: 270, y: 160, width: 920, height: 530), panel)
                    border(CGRect(x: 270, y: 160, width: 920, height: 530))
                    text("Summary panel", 300, 185, 22, bold: true)
                    fill(CGRect(x: 320, y: 260, width: 550, height: 300), dark ? page : NSColor(calibratedWhite: 0.93, alpha: 1))
                    border(CGRect(x: 320, y: 260, width: 550, height: 300))
                    text("Selected detail", 345, 285, 20, bold: true)
                    text("This region sits inside a larger card.", 345, 340)
                    text("Arrow up should expand the selection.", 345, 380)
                    text("Sidebar notes", 925, 280, 17, bold: true)
                } else {
                    let table = CGRect(x: 280, y: 200, width: 880, height: 400)
                    let borderless = name == "borderless-table"
                    if !borderless {
                        fill(table, panel)
                        fill(CGRect(x: 280, y: 200, width: 880, height: 50), dark ? .darkGray : NSColor(calibratedWhite: 0.83, alpha: 1))
                        border(table)
                        for row in 1..<8 { fill(CGRect(x: 280, y: 200 + row * 50, width: 880, height: 1), line) }
                        for col in 1..<4 { fill(CGRect(x: 280 + col * 220, y: 200, width: 1, height: 400), line) }
                    }
                    let rows = [
                        ["Team", "Sessions", "Duration", "Status"],
                        ["Alpha", "24", "42 min", "Complete"],
                        ["Bravo", "18", "38 min", "Complete"],
                        ["Charlie", "32", "51 min", "In progress"],
                        ["Delta", "16", "35 min", "Complete"],
                        ["Echo", "21", "44 min", "In progress"],
                        ["Foxtrot", "19", "39 min", "Complete"],
                        ["Golf", "28", "47 min", "Complete"]
                    ]
                    for (row, cells) in rows.enumerated() {
                        for (col, value) in cells.enumerated() { text(value, CGFloat(296 + col * 220), CGFloat(215 + row * 50), 17, bold: row == 0) }
                    }
                }
                text("Last updated just now", 280, 735, 14)
                return true
            }
            let cg = try PNG.rasterize(image, width: 1280, height: 800)
            try PNG.write(cg, to: directory.appendingPathComponent("\(name).png"))
            let target: CGRect
            switch name {
            case "cards": target = CGRect(x: 580, y: 200, width: 260, height: 230)
            case "chart-panel": target = CGRect(x: 280, y: 190, width: 880, height: 460)
            case "nested-panels": target = CGRect(x: 320, y: 260, width: 550, height: 300)
            case "borderless-table": target = CGRect(x: 292, y: 211, width: 790, height: 376)
            default: target = CGRect(x: 280, y: 200, width: 880, height: 400)
            }
            manifest.append(Fixture(file: "\(name).png", pixelWidth: 1280, pixelHeight: 800, target: target, anchor: CGPoint(x: target.midX, y: target.midY), description: name))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }
}
