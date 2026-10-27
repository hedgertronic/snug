import Foundation

/// Reads newline-separated lines from a file descriptor without ever holding more than `limit` bytes of one line: a longer line is
/// reported as `.tooLong` and its bytes are skipped through its newline.
public final class LineReader {
    public enum Line: Equatable, Sendable {
        case text(String)
        case tooLong
    }

    private let descriptor: Int32
    private let limit: Int
    private var buffer: [UInt8] = []
    private var chunk = [UInt8](repeating: 0, count: 65_536)
    private var ended = false

    public init(descriptor: Int32, limit: Int) {
        self.descriptor = descriptor
        self.limit = limit
    }

    /// The next line without its newline (and a trailing carriage return), `.tooLong`, or nil once the input ends. A last line without a
    /// newline is still returned.
    public func next() -> Line? {
        var skipping = false
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if skipping || line.count > limit { return .tooLong }
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                return .text(String(decoding: line, as: UTF8.self))
            }
            if buffer.count > limit {
                // Past the limit with no newline yet: drop what is held and keep reading to the line's end.
                buffer.removeAll(keepingCapacity: true)
                skipping = true
            }
            if ended {
                guard !buffer.isEmpty || skipping else { return nil }
                defer { buffer.removeAll() }
                return skipping ? .tooLong : .text(String(decoding: buffer, as: UTF8.self))
            }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer += chunk[..<count]
            } else if count == 0 || errno != EINTR {
                ended = true
            }
        }
    }
}
