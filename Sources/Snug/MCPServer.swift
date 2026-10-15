import Foundation
import ScreenshotCore

extension Pref {
    /// The folder holding agent handoff bundles; unset, `HandoffStore.defaultRoot`. Debug runs point it at their scratch folder, and
    /// `Snug --mcp -SnugAgentFolder DIR` serves another.
    static let agentFolder = "SnugAgentFolder"
}

extension HandoffStore {
    /// The store in `Pref.agentFolder`.
    init(defaults: UserDefaults) {
        self.init(root: defaults.string(forKey: Pref.agentFolder).map { URL(fileURLWithPath: $0) } ?? Self.defaultRoot)
    }
}

/// `Snug --mcp`: the read-only MCP server for agent handoffs, one JSON-RPC message per line on stdin and stdout (see `HandoffServer`).
/// `main` starts it before the app, so it never shows the menu bar item, takes focus, or registers the capture shortcut. It serves
/// `Pref.agentFolder`, which `-SnugAgentFolder DIR` on the command line overrides. Only protocol messages go to stdout.
enum MCPServer {
    static func run() -> Never {
        let store = HandoffStore(defaults: .standard)
        let server = HandoffServer(store: store, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        FileHandle.standardError.write(Data("Snug MCP server for \(store.root.path)\n".utf8))
        while let line = readLine() {
            guard let response = server.respond(to: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
        exit(EXIT_SUCCESS)
    }
}
