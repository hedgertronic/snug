import Foundation
import Testing
@testable import ScreenshotCore

struct LineReaderTests {
    private func lines(_ input: Data, limit: Int) throws -> [LineReader.Line] {
        // A file, not a pipe, holds the input, so writing more than a pipe's buffer never blocks.
        let file = FileManager.default.temporaryDirectory.appending(path: "snug-lines-\(UUID().uuidString)")
        try input.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let reader = LineReader(descriptor: handle.fileDescriptor, limit: limit)
        var read: [LineReader.Line] = []
        while let line = reader.next() { read.append(line) }
        return read
    }

    @Test func linesSplitOnNewlinesAndTheLastNeedsNone() throws {
        #expect(try lines(Data("one\r\ntwo\n\nthree".utf8), limit: 100) == [.text("one"), .text("two"), .text(""), .text("three")])
        #expect(try lines(Data(), limit: 100).isEmpty)
    }

    @Test func anOverlongLineIsSkippedWholeAndReadingGoesOn() throws {
        let long = String(repeating: "x", count: 200_000)
        #expect(try lines(Data("first\n\(long)\nnext\n\(long)".utf8), limit: 1_000) == [.text("first"), .tooLong, .text("next"), .tooLong])
        #expect(try lines(Data("12345\n123456\n".utf8), limit: 5) == [.text("12345"), .tooLong])
    }
}
