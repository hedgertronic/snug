import Foundation
import Testing
@testable import ScreenshotCore

struct UniqueFileTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "snug-unique-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func aTakenNameGetsTheNextNumberBeforeTheExtension() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Snug 2026-10-14 at 10.00.00.png")
        let written = try (1...3).map { try UniqueFile.write(Data("capture \($0)".utf8), to: file) }
        #expect(written.map(\.lastPathComponent) == ["Snug 2026-10-14 at 10.00.00.png", "Snug 2026-10-14 at 10.00.00 2.png", "Snug 2026-10-14 at 10.00.00 3.png"])
        for (index, url) in written.enumerated() { #expect(try Data(contentsOf: url) == Data("capture \(index + 1)".utf8)) }
    }

    @Test func aMissingFolderThrowsInsteadOfLooping() {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CocoaError.self) { try UniqueFile.write(Data(), to: folder.appending(path: "none/a.png")) }
    }
}
