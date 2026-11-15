import Foundation

/// The file `name` in the repository's `Tests/Fixtures` folder, which the tests and the app's debug runs share.
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/\(name)")
}
