import Foundation

/// Writes a file that never replaces another.
public enum UniqueFile {
    /// Writes `data` to `file`, or, when that name is taken, to the name with " 2", " 3", and so on before the extension. The write refuses
    /// an existing name, so two saves racing for one name keep both. Returns the file written.
    public static func write(_ data: Data, to file: URL) throws -> URL {
        var candidate = file
        var number = 2
        while true {
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                let stem = file.deletingPathExtension().lastPathComponent
                candidate = file.deletingLastPathComponent().appending(path: "\(stem) \(number)").appendingPathExtension(file.pathExtension)
                number += 1
            }
        }
    }
}
