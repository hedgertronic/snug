import Foundation

/// Writes a file that never replaces another.
public enum UniqueFile {
    /// Writes `data` to `file`, or, when that name is taken, to the name with " 2", " 3", and so on before the extension. The data is
    /// written whole to a temporary file beside the target, then moved (a rename within the folder) to the first free name; the move
    /// refuses an existing name, and needs no hard links, which USB and network volumes may lack. A failed write never leaves a partial
    /// file at the name. Returns the file written.
    public static func write(_ data: Data, to file: URL) throws -> URL {
        let temporary = file.deletingLastPathComponent().appending(path: ".snug-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try! FileManager.default.removeItem(at: temporary) } }
        var candidate = file
        var number = 2
        while true {
            do {
                try FileManager.default.moveItem(at: temporary, to: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                let stem = file.deletingPathExtension().lastPathComponent
                candidate = file.deletingLastPathComponent().appending(path: "\(stem) \(number)").appendingPathExtension(file.pathExtension)
                number += 1
            }
        }
    }
}
