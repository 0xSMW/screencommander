import ArgumentParser
import Foundation
import ScreenCommanderPresence

/// `screencommander serve --mcp` — persistent daemon mode. One engine instance stays
/// warm across calls (no per-action process startup or permission re-prompting), and
/// screenshots are delivered to the client in-band as image content instead of file
/// paths. stdout carries only protocol lines; diagnostics go to stderr.
struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run as an MCP server over stdio.",
        discussion: """
            The tools mirror the commands (state is app_state, apps is list_apps, launch is \
            launch_app, select-text is select_text, action is perform_action, observe is \
            observe_wait) and return the same JSON envelopes. Screenshots come back as image content. \
            The server has its own agent session, serve-<pid>, unless SCREENCOMMANDER_SESSION is set. \
            A lease on an app ends once the session leaves it alone for 15 seconds \
            (SCREENCOMMANDER_LEASE_IDLE_MS), and every lease ends when the server exits or its input \
            closes. Logs go to stderr.

            Example:
              screencommander serve --mcp
            """
    )

    @Flag(name: .long, help: "Serve the Model Context Protocol (newline-delimited JSON-RPC 2.0). Currently required.")
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
        // `serve: true` gives this server its own presence session, and the engine's
        // per-pid serializer keeps parallel tool calls from interleaving input.
        let engine = ScreenCommanderEngine.live(shareableContentTTL: 2.0, serve: true)
        let registry = MCPToolRegistry(engine: engine, doctor: DoctorService())
        let server = MCPServer(registry: registry)
        let outputLock = NSLock()
        // Presence keeps the display awake while sessions are active. With presence
        // off, this server does it itself for two minutes after each tool call.
        let keepAwake: ActivityKeepAwake? = PresenceSettings.presenceEnabled()
            ? nil
            : ActivityKeepAwake(keepAwake: KeepAwake.live())
        let keepAwakeTimer = keepAwake.map { activity -> DispatchSourceTimer in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { activity.tick() }
            timer.resume()
            return timer
        }
        defer {
            keepAwakeTimer?.cancel()
            keepAwake?.stop()
        }
        let session = MCPServeSession(server: server, onToolCall: keepAwake.map { activity in { activity.noteActivity() } }) { line in
            outputLock.lock()
            defer { outputLock.unlock() }
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        while let line = readLine(strippingNewline: true) {
            session.receive(line: line)
        }

        try AsyncBridge.run {
            await session.finish()
        }
        // Input ended. Release this server's leases and end its sessions now
        // rather than when the process happens to exit. A server that is killed
        // gets the same result when presence sees its connection close.
        engine.endPresence()
    }
}
