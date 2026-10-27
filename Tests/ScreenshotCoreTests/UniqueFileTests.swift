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
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3, "no temporary file is left beside the captures")
        for (index, url) in written.enumerated() { #expect(try Data(contentsOf: url) == Data("capture \(index + 1)".utf8)) }
    }

    @Test func filesWrittenInPlaceMoveToTheNextFreeName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Snug 2026-10-17 at 10.00.00.mov")
        let moved = try (1...2).map { number in
            let temporary = UniqueFile.temporary(beside: file)
            try Data("recording \(number)".utf8).write(to: temporary)
            return try UniqueFile.move(temporary, to: file)
        }
        #expect(moved.map(\.lastPathComponent) == ["Snug 2026-10-17 at 10.00.00.mov", "Snug 2026-10-17 at 10.00.00 2.mov"])
        #expect(try Data(contentsOf: moved[0]) == Data("recording 1".utf8) && Data(contentsOf: moved[1]) == Data("recording 2".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test func scratchFilesOfOneNameNeverReplaceEachOther() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try UniqueFile.scratch(Data("first".utf8), named: "Snug.png", under: folder)
        let second = try UniqueFile.scratch(Data("second".utf8), named: "Snug.png", under: folder)
        #expect(first != second && first.lastPathComponent == "Snug.png" && second.lastPathComponent == "Snug.png")
        #expect(try Data(contentsOf: first) == Data("first".utf8) && Data(contentsOf: second) == Data("second".utf8))
    }

    @Test func aScratchFileUnderAFileFails() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appending(path: "blocker")
        try Data().write(to: blocker)
        #expect(throws: CocoaError.self) { try UniqueFile.scratch(Data(), named: "Snug.png", under: blocker) }
    }

    @Test func aMissingFolderThrowsInsteadOfLooping() {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CocoaError.self) { try UniqueFile.write(Data(), to: folder.appending(path: "none/a.png")) }
    }
}
