import ArgumentParser
import Foundation

/// `screencommander serve --mcp` — persistent daemon mode. One engine instance stays
/// warm across calls (no per-action process startup or permission re-prompting), and
/// screenshots are delivered to the client in-band as image content instead of file
/// paths. stdout carries only protocol lines; diagnostics go to stderr.
struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run screencommander as a persistent server (currently: an MCP server over stdio)."
    )

    @Flag(name: .long, help: "Speak the Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).")
    var mcp = false

    func run() throws {
        guard mcp else {
            throw ValidationError("serve currently requires --mcp.")
        }

        // The screenshot tool can capture windows, which needs the window-server
        // connection established while the main thread is still free.
        WindowServerConnection.ensureInitialized()

        // Server-owned engine with a short SCShareableContent TTL: a burst of tool
        // calls (windows → screenshot → click) pays the ~100–300 ms window/display
        // enumeration once instead of per call. The CLI keeps TTL 0 (always fresh).
        let engine = ScreenCommanderEngine.live(shareableContentTTL: 2.0)
        let registry = MCPToolRegistry(engine: engine, doctor: DoctorService())
        let server = MCPServer(registry: registry)

        while let line = readLine(strippingNewline: true) {
            let response = try AsyncBridge.run {
                await server.handle(line: line)
            }
            if let response {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
